/// Puts a transcript where the user was typing, or on the pasteboard with a
/// reason when pasting isn't safe. The user's clipboard is put back after a paste.
public actor Deliverer {
    private let env: any DeliveryEnvironment
    private let pasteboard: any Pasteboard
    private let clock: any Clock<Duration>
    private var pending: PendingRestore?
    /// Public operations run one at a time. The actor alone isn't enough: it
    /// interleaves at every await, and two pastes overlapping would snapshot each
    /// other's text instead of the user's clipboard.
    private var tail: Task<Void, Never>?
    /// The last paste, undoable until it expires (C-UNDO) or is used.
    private var undo: (offer: UndoOffer, expiry: Task<Void, Never>)?
    /// Why the last paste didn't get an undo offer, for logs.
    public private(set) var lastUndoSkip: String?

    private struct PendingRestore {
        let snapshot: PasteboardSnapshot
        /// The change count right after our write; anything else means the user copied since.
        let ourChangeCount: Int
        let timer: Task<Void, Never>
    }

    public init(env: any DeliveryEnvironment, pasteboard: any Pasteboard, clock: any Clock<Duration>) {
        self.env = env
        self.pasteboard = pasteboard
        self.clock = clock
    }

    public func capturePressContext() async -> PressContext {
        PressContext(pid: await env.frontmostPID(), focus: await env.focusedElement())
    }

    /// The Settings test field: Speak is frontmost, and that's the target.
    public func captureOwnFieldContext() async -> PressContext {
        PressContext(pid: nil, focus: await env.focusedElement(), ownField: true)
    }

    /// Pastes or copies `text`. Cancelling the caller before the write abandons it.
    /// `modifierWait` is how long held modifier keys may delay the paste.
    public func deliver(_ text: String, context: PressContext?,
                        modifierWait: Duration = Constants.modWait) async -> DeliveryOutcome {
        await serially { await $0.deliverNow(text, context: context, modifierWait: modifierWait) }
    }

    /// A plain, retrievable copy (Copy last, and saving text on quit).
    public func copy(_ text: String) async {
        await serially { await $0.copyNow(text) }
    }

    /// Saves text that would otherwise be lost (a hung paste, sleep, quit). Skips
    /// the queue on purpose: a paste stuck in an unresponsive app must not hold it
    /// up. A pending restore then sees the change count moved and leaves it alone.
    public func rescue(_ text: String) async {
        await pasteboard.write(text, as: .normal)
    }

    /// Brings `pid` to the front and waits briefly for it (after the preview panel).
    public func activate(_ pid: Int32) async {
        if await env.frontmostPID() == pid { return }
        await env.activate(pid: pid)
        let step: Duration = .milliseconds(20)
        var waited: Duration = .zero
        while await env.frontmostPID() != pid, waited < Constants.activate {
            _ = await Deadline(after: step, on: clock).reached()
            waited += step
        }
    }

    /// A recent paste can still be undone (the menu shows Undo insert).
    public var canUndo: Bool { undo != nil }

    /// Undo is safe only in the same app and field, with the text apparently untouched.
    public func undoIsSafe() async -> Bool {
        guard let offer = undo?.offer else { return false }
        return undoAllowed(offer, now: await undoSnapshot(for: offer))
    }

    /// Why undo is or isn't offered, as numbers and flags only (for logs).
    public func undoDiagnostics() async -> String {
        guard let offer = undo?.offer else { return "offer=none skip=\(lastUndoSkip ?? "expired or used")" }
        let now = await undoSnapshot(for: offer)
        let expected = offer.expectedLength.map(String.init) ?? "nil"
        let length = now.textLength.map(String.init) ?? "nil"
        let same = now.sameElement.map(String.init) ?? "nil"
        return "samePID=\(now.frontmostPID == offer.pid) sameElement=\(same) expectedLength=\(expected) length=\(length)"
    }

    /// Sends ⌘Z once if it's still safe. The offer is used up either way.
    @discardableResult
    public func undoLastInsert() async -> Bool {
        await serially { await $0.undoNow() }
    }

    /// Puts the user's clipboard back now instead of waiting, if it's still ours.
    public func restoreNow() async {
        await serially { await $0.restorePending() }
    }

    // MARK: Private

    private func serially<T: Sendable>(_ operation: @escaping @Sendable (isolated Deliverer) async -> T) async -> T {
        let previous = tail
        let work = Task { () -> T in
            await previous?.value
            return await operation(self)
        }
        tail = Task { _ = await work.value }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private func deliverNow(_ text: String, context: PressContext?, modifierWait: Duration) async -> DeliveryOutcome {
        await restorePending()
        let modifiersHeld = await waitForModifiers(upTo: modifierWait)
        let focusNow = await env.focusedElement()
        var snapshot = DeliverySnapshot(
            text: text,
            accessibilityTrusted: await env.accessibilityTrusted(),
            secureInput: await env.secureInputActive(focusNow),
            pressPID: context?.pid,
            frontmostPID: await env.frontmostPID(),
            focus: await compare(focusNow, with: context?.focus),
            modifiersHeld: modifiersHeld)
        snapshot.ownField = context?.ownField ?? false

        // The session ended (sleep, quit) while we waited: touch nothing.
        if Task.isCancelled { return .empty }
        switch evaluateDelivery(snapshot) {
        case .nothing:
            return .empty
        case .copy(let reason, let concealed):
            await pasteboard.write(text, as: concealed ? .concealed : .normal)
            return .copied(reason)
        case .paste:
            await recordUndo(for: text, pid: snapshot.frontmostPID, focus: focusNow)
            await paste(text)
            return .inserted
        }
    }

    private func copyNow(_ text: String) async {
        await restorePending()
        await pasteboard.write(text, as: .normal)
    }

    private func restorePending() async {
        guard let pending else { return }
        self.pending = nil
        pending.timer.cancel()
        await restoreIfUnchanged(pending)
    }

    private func paste(_ text: String) async {
        let saved = await pasteboard.snapshot()
        let ours = await pasteboard.write(text, as: .transient)
        await env.postPaste(keyCode: keyCode(for: "v", in: await env.keyboardLayout()))
        // A lazy or promised item can't be restored faithfully, so leave the text in place.
        guard let saved else { return }
        let delay = Constants.slowPasteApps.contains(await env.frontmostBundleID() ?? "")
            ? Constants.restoreSlow : Constants.restore
        let deadline = Deadline(after: delay, on: clock)
        let timer = Task { [weak self] in
            guard await deadline.reached() else { return }
            await self?.restoreNow()
        }
        pending = PendingRestore(snapshot: saved, ourChangeCount: ours, timer: timer)
    }

    private func restoreIfUnchanged(_ pending: PendingRestore) async {
        // If the user copied something since, theirs wins.
        guard await pasteboard.changeCount() == pending.ourChangeCount else { return }
        await pasteboard.restore(pending.snapshot)
    }

    private func recordUndo(for text: String, pid: Int32?, focus: FocusedElement) async {
        undo?.expiry.cancel()
        undo = nil
        lastUndoSkip = nil
        guard let pid else { return lastUndoSkip = "no target app" }
        guard case .element(let element) = focus else { return lastUndoSkip = "focus \(focus.kind)" }
        var expected: Int?
        if let length = await env.textLength(of: element) {
            // A paste replaces the selection.
            expected = length - (await env.selectionLength(of: element) ?? 0) + text.utf16.count
        }
        let deadline = Deadline(after: Constants.undo, on: clock)
        let expiry = Task { [weak self] in
            guard await deadline.reached() else { return }
            await self?.expireUndo()
        }
        undo = (UndoOffer(pid: pid, element: element, expectedLength: expected), expiry)
    }

    private func expireUndo() {
        undo = nil
    }

    private func undoNow() async -> Bool {
        guard let offer = undo?.offer else { return false }
        undo?.expiry.cancel()
        undo = nil
        guard undoAllowed(offer, now: await undoSnapshot(for: offer)) else { return false }
        await env.postUndo(keyCode: keyCode(for: "z", in: await env.keyboardLayout()))
        return true
    }

    private func undoSnapshot(for offer: UndoOffer) async -> UndoSnapshot {
        var sameElement: Bool?
        var length: Int?
        if case .element(let now) = await env.focusedElement() {
            sameElement = await env.isSameElement(offer.element, now)
            length = await env.textLength(of: now)
        }
        return UndoSnapshot(frontmostPID: await env.frontmostPID(), sameElement: sameElement, textLength: length)
    }

    /// ⌘V is wrong if the user is still holding Shift or Option, so wait briefly.
    private func waitForModifiers(upTo limit: Duration) async -> Bool {
        let step: Duration = .milliseconds(20)
        var waited: Duration = .zero
        while await env.modifiersDown() {
            if waited >= limit { return true }
            _ = await Deadline(after: step, on: clock).reached()
            waited += step
        }
        return false
    }

    private func compare(_ now: FocusedElement, with atPress: FocusedElement?) async -> FocusQuery {
        switch now {
        case .none: return .none
        case .error: return .error
        case .element(let current):
            guard case .element(let before)? = atPress else { return .element(sameAsAtPress: nil) }
            return .element(sameAsAtPress: await env.isSameElement(before, current))
        }
    }
}

/// The keycode that types `letter` in this layout, so ⌘V and ⌘Z work on Dvorak
/// and friends. Falls back to the ANSI position.
public func keyCode(for letter: Character, in layout: [UInt16: Character]) -> UInt16 {
    layout.filter { $0.value == letter }.keys.min() ?? (letter == "z" ? 6 : 9)
}

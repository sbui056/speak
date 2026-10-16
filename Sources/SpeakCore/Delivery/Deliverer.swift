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

    /// Pastes or copies `text`. Cancelling the caller before the write abandons it.
    public func deliver(_ text: String, context: PressContext?) async -> DeliveryOutcome {
        await serially { await $0.deliverNow(text, context: context) }
    }

    /// A plain, retrievable copy (Copy last, and saving text on quit).
    public func copy(_ text: String) async {
        await serially { await $0.copyNow(text) }
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

    private func deliverNow(_ text: String, context: PressContext?) async -> DeliveryOutcome {
        await restorePending()
        let modifiersHeld = await waitForModifiers()
        let focusNow = await env.focusedElement()
        let snapshot = DeliverySnapshot(
            text: text,
            accessibilityTrusted: await env.accessibilityTrusted(),
            secureInput: await env.secureInputActive(focusNow),
            pressPID: context?.pid,
            frontmostPID: await env.frontmostPID(),
            focus: await compare(focusNow, with: context?.focus),
            modifiersHeld: modifiersHeld)

        // The session ended (sleep, quit) while we waited: touch nothing.
        if Task.isCancelled { return .empty }
        switch evaluateDelivery(snapshot) {
        case .nothing:
            return .empty
        case .copy(let reason, let concealed):
            await pasteboard.write(text, as: concealed ? .concealed : .normal)
            return .copied(reason)
        case .paste:
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
        await env.postPaste(keyCode: pasteKeyCode(in: await env.keyboardLayout()))
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

    /// ⌘V is wrong if the user is still holding Shift or Option, so wait briefly.
    private func waitForModifiers() async -> Bool {
        let step: Duration = .milliseconds(20)
        var waited: Duration = .zero
        while await env.modifiersDown() {
            if waited >= Constants.modWait { return true }
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

/// The keycode that types "v" in this layout, so ⌘V works on Dvorak and friends.
/// Falls back to the ANSI position.
public func pasteKeyCode(in layout: [UInt16: Character]) -> UInt16 {
    layout.filter { $0.value == "v" }.keys.min() ?? 9
}

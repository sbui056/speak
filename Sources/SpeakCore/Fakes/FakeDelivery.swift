import Synchronization

/// A scriptable desktop: which app is frontmost, what's focused, which keys are down.
public final class FakeDeliveryEnvironment: DeliveryEnvironment {
    public final class Element: Sendable {
        public let name: String
        public init(_ name: String) { self.name = name }
    }

    public struct World: Sendable {
        public var frontmostPID: Int32? = 100
        public var bundleID: String? = "com.example.editor"
        public var focus: FocusedElement = .element(ElementRef(Element("field")))
        public var accessibilityTrusted = true
        public var secureInput = false
        /// Modifiers report down for this many polls, then up.
        public var modifierPolls = 0
        public var layout: [UInt16: Character] = [9: "v"]
        public var pastes: [UInt16] = []
        public init() {}
    }

    private let world = Mutex(World())
    /// When set, each ⌘V waits for `releasePaste()`, so a test can overlap deliveries.
    private let pasteHold = Mutex<(enabled: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))
    public init() {}

    public func update(_ change: (inout World) -> Void) { world.withLock { change(&$0) } }
    public var pastes: [UInt16] { world.withLock { $0.pastes } }

    public func frontmostPID() async -> Int32? { world.withLock { $0.frontmostPID } }
    public func frontmostBundleID() async -> String? { world.withLock { $0.bundleID } }
    public func focusedElement() async -> FocusedElement { world.withLock { $0.focus } }
    public func isSameElement(_ a: ElementRef, _ b: ElementRef) async -> Bool { a.raw === b.raw }
    public func accessibilityTrusted() async -> Bool { world.withLock { $0.accessibilityTrusted } }
    public func secureInputActive(_ focus: FocusedElement) async -> Bool { world.withLock { $0.secureInput } }
    public func keyboardLayout() async -> [UInt16: Character] { world.withLock { $0.layout } }
    public func postPaste(keyCode: UInt16) async {
        world.withLock { $0.pastes.append(keyCode) }
        guard pasteHold.withLock({ $0.enabled }) else { return }
        await withCheckedContinuation { continuation in pasteHold.withLock { $0.waiting.append(continuation) } }
    }

    public func holdPastes() { pasteHold.withLock { $0.enabled = true } }
    public var heldPastes: Int { pasteHold.withLock { $0.waiting.count } }

    /// Lets the oldest held ⌘V finish.
    public func releasePaste() {
        pasteHold.withLock { $0.waiting.isEmpty ? nil : $0.waiting.removeFirst() }?.resume()
    }

    public func modifiersDown() async -> Bool {
        world.withLock { w in
            guard w.modifierPolls > 0 else { return false }
            w.modifierPolls -= 1
            return true
        }
    }
}

/// An in-memory pasteboard that records how each write was marked.
public final class FakePasteboard: Pasteboard {
    public struct Contents: Sendable {
        public var items: [[String: [UInt8]]] = [["public.utf8-plain-text": Array("banana".utf8)]]
        public var changeCount = 1
        /// Simulates a promised item that can't be read eagerly.
        public var hasLazyItem = false
        public var writes: [PasteboardWrite] = []
        public var restores = 0
        public init() {}
    }

    private let contents = Mutex(Contents())
    public init() {}

    public func update(_ change: (inout Contents) -> Void) { contents.withLock { change(&$0) } }
    public var current: Contents { contents.withLock { $0 } }
    public var text: String? {
        current.items.first?["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) }
    }

    /// The user copies something else.
    public func userCopies(_ text: String) {
        contents.withLock {
            $0.items = [["public.utf8-plain-text": Array(text.utf8)]]
            $0.changeCount += 1
        }
    }

    public func changeCount() async -> Int { contents.withLock { $0.changeCount } }

    public func snapshot() async -> PasteboardSnapshot? {
        contents.withLock { $0.hasLazyItem ? nil : PasteboardSnapshot(items: $0.items) }
    }

    @discardableResult
    public func write(_ text: String, as kind: PasteboardWrite) async -> Int {
        contents.withLock {
            $0.items = [["public.utf8-plain-text": Array(text.utf8)]]
            $0.changeCount += 1
            $0.writes.append(kind)
            return $0.changeCount
        }
    }

    public func restore(_ snapshot: PasteboardSnapshot) async {
        contents.withLock {
            $0.items = snapshot.items
            $0.changeCount += 1
            $0.restores += 1
        }
    }
}

/// A hotkey the test presses by hand.
public final class FakeHotkeySource: HotkeySource {
    private struct State {
        var isDown = false
        var continuation: AsyncStream<HotkeyEvent>.Continuation?
    }

    private let state = Mutex(State())
    private let clock: @Sendable () -> KeyTime

    /// `clock` supplies key timestamps, so they line up with the test's clock.
    public init(clock: @escaping @Sendable () -> KeyTime) {
        self.clock = clock
    }

    public func start(_ key: HotkeyChoice) -> AsyncStream<HotkeyEvent> {
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream(bufferingPolicy: .unbounded)
        state.withLock { $0.continuation = continuation }
        return stream
    }

    public func stop() { state.withLock { $0.continuation }?.finish() }
    public func isKeyDown(_ key: HotkeyChoice) -> Bool { state.withLock { $0.isDown } }
    public func now() -> KeyTime { clock() }

    public func press() { set(down: true, .pressed(at: clock())) }
    public func release() { set(down: false, .released(at: clock())) }
    /// The key went up but the event never arrived.
    public func loseRelease() { state.withLock { $0.isDown = false } }
    public func emit(_ event: HotkeyEvent) { state.withLock { $0.continuation }?.yield(event) }

    private func set(down: Bool, _ event: HotkeyEvent) {
        let continuation = state.withLock { s in
            s.isDown = down
            return s.continuation
        }
        continuation?.yield(event)
    }
}

/// Permissions the test grants and revokes by hand.
public final class FakePermissionChecker: PermissionChecker {
    private let state = Mutex<(granted: Set<Permission>, requests: [Permission], opened: [Permission])>(([], [], []))

    public init(granted: Set<Permission> = Set(Permission.allCases)) {
        state.withLock { $0.granted = granted }
    }

    public func set(_ permission: Permission, granted: Bool) {
        state.withLock { s in
            if granted { s.granted.insert(permission) } else { s.granted.remove(permission) }
        }
    }

    public var opened: [Permission] { state.withLock { $0.opened } }

    public func isGranted(_ permission: Permission) async -> Bool { state.withLock { $0.granted.contains(permission) } }

    public func request(_ permission: Permission) async -> Bool {
        state.withLock { $0.requests.append(permission) }
        return permission == .microphone
    }

    public func openSettings(_ permission: Permission) async { state.withLock { $0.opened.append(permission) } }
}

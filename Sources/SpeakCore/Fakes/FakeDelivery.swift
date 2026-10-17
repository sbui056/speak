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
        public var undos: [UInt16] = []
        /// What `activate` does: bring that PID to the front, or ignore the request.
        public var activationWorks = true
        public var activations: [Int32] = []
        /// Accessibility text and selection lengths of the focused field (nil = unreadable).
        public var textLength: Int? = 10
        public var selectionLength: Int? = 0
        public init() {}
    }

    private let world = Mutex(World())
    /// When set, each ⌘V waits for `releasePaste()`, so a test can overlap deliveries.
    private let pasteHold = Mutex<(enabled: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    public init() {}

    // MARK: Test controls

    public func update(_ change: (inout World) -> Void) { world.withLock { change(&$0) } }
    public var pastes: [UInt16] { world.withLock { $0.pastes } }
    public var undos: [UInt16] { world.withLock { $0.undos } }
    public var activations: [Int32] { world.withLock { $0.activations } }

    public func holdPastes() { pasteHold.withLock { $0.enabled = true } }
    public var heldPastes: Int { pasteHold.withLock { $0.waiting.count } }

    /// Lets the oldest held ⌘V finish.
    public func releasePaste() {
        pasteHold.withLock { $0.waiting.isEmpty ? nil : $0.waiting.removeFirst() }?.resume()
    }

    // MARK: DeliveryEnvironment

    public func frontmostPID() async -> Int32? { world.withLock { $0.frontmostPID } }
    public func frontmostBundleID() async -> String? { world.withLock { $0.bundleID } }
    public func focusedElement() async -> FocusedElement { world.withLock { $0.focus } }
    public func isSameElement(_ a: ElementRef, _ b: ElementRef) async -> Bool { a.raw === b.raw }
    public func accessibilityTrusted() async -> Bool { world.withLock { $0.accessibilityTrusted } }
    public func secureInputActive(_ focus: FocusedElement) async -> Bool { world.withLock { $0.secureInput } }
    public func keyboardLayout() async -> [UInt16: Character] { world.withLock { $0.layout } }
    public func textLength(of element: ElementRef) async -> Int? { world.withLock { $0.textLength } }
    public func selectionLength(of element: ElementRef) async -> Int? { world.withLock { $0.selectionLength } }

    public func modifiersDown() async -> Bool {
        world.withLock { w in
            guard w.modifierPolls > 0 else { return false }
            w.modifierPolls -= 1
            return true
        }
    }

    public func postPaste(keyCode: UInt16) async {
        world.withLock { $0.pastes.append(keyCode) }
        guard pasteHold.withLock({ $0.enabled }) else { return }
        await withCheckedContinuation { continuation in pasteHold.withLock { $0.waiting.append(continuation) } }
    }

    public func postUndo(keyCode: UInt16) async { world.withLock { $0.undos.append(keyCode) } }

    public func activate(pid: Int32) async {
        world.withLock { w in
            w.activations.append(pid)
            if w.activationWorks { w.frontmostPID = pid }
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

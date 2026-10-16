// The system boundaries. SpeakCore talks to the outside world only through these,
// so every decision can be tested with fakes. Real implementations live in the app.

// MARK: Hotkey

public enum HotkeyEvent: Equatable, Sendable {
    case pressed(at: KeyTime)
    case released(at: KeyTime)
    case chord
    case cancel
    /// The event tap was disabled and re-enabled; the hotkey may have changed meanwhile.
    case tapReenabled(keyIsDown: Bool, at: KeyTime)
}

public enum HotkeyChoice: String, CaseIterable, Sendable {
    case rightOption, rightCommand, rightControl

    /// Tracked by keycode so a held Left Option never triggers it.
    public var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        }
    }
}

public protocol HotkeySource: Sendable {
    /// Starts watching the key. Events arrive in order and are never dropped.
    func start(_ key: HotkeyChoice) -> AsyncStream<HotkeyEvent>
    func stop()
    /// Live state of the hotkey, read from the system rather than from events.
    func isKeyDown(_ key: HotkeyChoice) -> Bool
    func now() -> KeyTime
}

// MARK: Audio and transcription

/// One converted audio buffer, opaque to SpeakCore. Only the transcriber that
/// pairs with the audio source knows what's inside.
public struct AudioFrames: @unchecked Sendable {
    // Unchecked: the payload is handed off once (audio thread → transcriber)
    // and never touched again by the sender.
    public let payload: Any
    public init(_ payload: Any) { self.payload = payload }
}

public enum AudioEvent: Equatable, Sendable {
    /// Current RMS level (0...1) for the HUD, and the clip's peak so far in dBFS.
    case level(rms: Float, peakDBFS: Double)
    case deviceChanged
}

extension AudioFailure: Error {}

public protocol AudioSource: Sendable {
    /// Opens the mic. Frames flow until `stop()`. Throws `AudioFailure`.
    func start(onEvent: @escaping @Sendable (AudioEvent) -> Void) async throws -> AsyncStream<AudioFrames>
    /// Closes the mic and finishes the frame stream. Safe to call repeatedly.
    func stop() async
}

public enum TranscriberEvent: Equatable, Sendable {
    /// Audio was consumed, even if no words came out yet.
    case active
    /// Everything recognized so far, finished segments plus the volatile tail.
    case partial(String)
}

public protocol Transcriber: Sendable {
    /// Creates a fresh single-use session reading `frames`. `contextualStrings`
    /// are words the recognizer should expect (the user's dictionary).
    func start(frames: AsyncStream<AudioFrames>, contextualStrings: [String],
               onEvent: @escaping @Sendable (TranscriberEvent) -> Void) async throws -> any TranscriberSession
}

public protocol TranscriberSession: Sendable {
    /// Waits for the audio to end and returns the full transcript.
    func finalize() async throws -> String
    /// Stops immediately. Safe to call repeatedly.
    func cancel() async
}

public protocol SpeechModelStore: Sendable {
    func status() async -> SpeechModelStatus
    /// Downloads the model if needed, reporting progress.
    func install(progress: @escaping @Sendable (Int) -> Void) async throws
}

// MARK: Delivery

/// The focused element, as an opaque reference only the environment can compare.
public struct ElementRef: @unchecked Sendable {
    // Unchecked: an immutable system handle; it's only compared, never mutated.
    public let raw: AnyObject
    public init(_ raw: AnyObject) { self.raw = raw }
}

public enum FocusedElement: Sendable {
    case element(ElementRef)
    case none
    case error
}

/// Where the user was when they pressed the hotkey.
public struct PressContext: Sendable {
    /// Nil when Speak itself was frontmost.
    public var pid: Int32?
    public var focus: FocusedElement
    public init(pid: Int32?, focus: FocusedElement) {
        self.pid = pid
        self.focus = focus
    }
}

public protocol DeliveryEnvironment: Sendable {
    /// The frontmost app, or nil when it's Speak.
    func frontmostPID() async -> Int32?
    func frontmostBundleID() async -> String?
    func focusedElement() async -> FocusedElement
    func isSameElement(_ a: ElementRef, _ b: ElementRef) async -> Bool
    func accessibilityTrusted() async -> Bool
    /// System secure input, or a secure text field focused.
    func secureInputActive(_ focus: FocusedElement) async -> Bool
    func modifiersDown() async -> Bool
    /// What each keycode types in the current layout (for finding "v").
    func keyboardLayout() async -> [UInt16: Character]
    func postPaste(keyCode: UInt16) async
    /// Posts ⌘Z (with the layout's "z" keycode).
    func postUndo(keyCode: UInt16) async
    /// Asks the app to come to the front. Doesn't wait for it.
    func activate(pid: Int32) async
    /// The element's text length in UTF-16 units, if Accessibility can read it.
    func textLength(of element: ElementRef) async -> Int?
    /// The selected text's length in UTF-16 units, if readable.
    func selectionLength(of element: ElementRef) async -> Int?
}

public enum PasteboardWrite: Equatable, Sendable {
    /// Ordinary item; stays in clipboard history.
    case normal
    /// Kept out of clipboard history (secure fields).
    case concealed
    /// The paste path: transient and concealed, restored afterwards.
    case transient
}

/// Every pasteboard item with every type read eagerly.
public struct PasteboardSnapshot: Equatable, Sendable {
    public var items: [[String: [UInt8]]]
    public init(items: [[String: [UInt8]]]) { self.items = items }
}

public protocol Pasteboard: Sendable {
    func changeCount() async -> Int
    /// Nil if some item is a lazy or promised type that can't be read now.
    func snapshot() async -> PasteboardSnapshot?
    /// Returns the change count after writing.
    @discardableResult func write(_ text: String, as kind: PasteboardWrite) async -> Int
    func restore(_ snapshot: PasteboardSnapshot) async
}

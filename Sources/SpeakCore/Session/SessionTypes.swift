/// Identifies one dictation. Every effect and completion carries it, so a late
/// callback from an earlier session can be recognized and dropped.
public struct SessionID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
    public static func < (a: SessionID, b: SessionID) -> Bool { a.raw < b.raw }
    public var description: String { "#\(raw)" }
}

/// Time since a fixed origin (the hotkey adapter stamps key events from the
/// monotonic clock). Hold and stuck-key decisions use these stamps, not the time
/// an event happened to be processed.
public typealias KeyTime = Duration

public enum Phase: Equatable, Sendable {
    case idle
    /// Mic open, waiting to see whether the press is a hold or a tap.
    case arming
    case listening
    /// Mic closed, transcriber finishing.
    case finalizing
    /// The language model is cleaning up the literal (Concise or Polished).
    case rewriting
    /// The preview panel is open; nothing is inserted until the user decides.
    case awaitingAcceptance
    case delivering
}

public enum SpeechModelStatus: Equatable, Sendable {
    case installed
    case downloading(percent: Int)
    case unavailable(language: String)
}

public enum AudioFailure: Equatable, Sendable {
    case denied
    case busy
}

public enum TimerKind: Equatable, Sendable {
    case hold
    case sttStart
    case cap
    case finalize
    case rewrite
    /// Delivery watchdog: a hung app must not leave dictation stuck.
    case deliver
    /// Periodic hotkey state poll that catches a lost key-up.
    case keyPoll
}

/// How the delivery ended. A copy carries the reason shown to the user.
public enum DeliveryOutcome: Equatable, Sendable {
    case inserted
    case copied(Messages)
    case empty
}

public enum SessionEvent: Equatable, Sendable {
    // Hotkey
    case pressed(at: KeyTime)
    case released(at: KeyTime)
    /// Another key or modifier joined the press.
    case chord
    /// Esc.
    case cancel
    /// Hotkey state, from the periodic poll or after the event tap is re-enabled.
    case keyState(isDown: Bool, at: KeyTime)

    // Audio
    case audioStarted(SessionID)
    case audioFailed(SessionID, AudioFailure)
    /// Whole-clip peak so far, in dBFS.
    case audioPeak(SessionID, dBFS: Double)
    case deviceChanged(SessionID)

    // Transcriber
    /// The transcriber consumed audio; it is alive even if no text came yet.
    case transcriberActive(SessionID)
    /// Finished segments plus the current volatile tail.
    case partial(SessionID, String)
    case finalized(SessionID, String)
    case transcriberFailed(SessionID)

    /// The final transcript after Literal cleanup and dictionary correction.
    case literalReady(SessionID, String)
    /// A validated rewrite, or nil when it failed or was rejected.
    case rewritten(SessionID, String?)
    /// The user's choice in the preview panel.
    case preview(SessionID, PreviewAction)

    case timer(SessionID, TimerKind)
    case delivered(SessionID, DeliveryOutcome)

    // Environment
    case rewriteSettings(mode: RewriteMode, alwaysPreview: Bool)
    case modelStatus(SpeechModelStatus)
    case micPermission(granted: Bool)
    case systemSleep
    case quit
}

public enum PreviewAction: Equatable, Sendable {
    /// Insert this text: the rewrite as shown, or the user's edit of it.
    case insert(String)
    /// Insert the unchanged literal; counts as rejecting the rewrite.
    case insertLiteral
    /// Copy this text instead of inserting it.
    case copy(String)
    case cancel
}

public enum HUDContent: Equatable, Sendable {
    case listening
    case processing
    case rewriting
    case partial(String)
    case error(Messages)
    case result(Messages)
}

public enum Effect: Equatable, Sendable {
    /// Record the frontmost app and focused element for the delivery rules.
    case capturePressContext(SessionID)
    /// Open the mic and stream it into a fresh transcriber.
    case startCapture(SessionID)
    /// Close the mic. Safe to repeat.
    case stopAudio(SessionID)
    case finalizeTranscriber(SessionID)
    /// Clean the raw transcript and apply the dictionary, then report `.literalReady`.
    case prepareLiteral(SessionID, String)
    /// Load the language model ahead of a likely rewrite.
    case prewarmRewriter(RewriteMode)
    case rewrite(SessionID, String, RewriteMode)
    case showPreview(SessionID, literal: String, rewrite: String)
    case closePreview
    case cancelTranscriber(SessionID)
    case startTimer(SessionID, TimerKind, after: Duration)
    /// Run the delivery rules and paste or copy.
    case deliver(SessionID, String)
    /// After the preview: bring the original app back to the front, then deliver.
    case handoff(SessionID, String)
    /// A plain pasteboard copy that saves text a hung, interrupted, or cancelled delivery would lose.
    case copyToPasteboard(String)
    case showHUD(HUDContent)
    case hideHUD
    /// Cancel every task and timer that belongs to the session.
    case endSession(SessionID)
}

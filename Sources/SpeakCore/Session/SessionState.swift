/// Everything the state machine knows. Plain value, so tests compare it directly.
public struct SessionState: Equatable, Sendable {
    public var phase: Phase = .idle
    /// The session in flight; nil when idle.
    public var current: SessionID?
    public var lastIssued: UInt64 = 0

    // Per-session values, reset on every press.
    public var pressedAt: KeyTime = .zero
    public var transcriberActive = false
    public var peakDBFS: Double = -.infinity
    /// Latest partial text, used if finalizing hangs.
    public var lastPartial = ""
    public var usedPartialFallback = false
    /// The transcriber hung twice in a row; tell the user once this session ends.
    public var restartAdvised = false
    /// When the hotkey was first seen up while still listening.
    public var keyUpSince: KeyTime?
    /// The mode this session was started in; a change mid-session applies next time.
    public var sessionMode: RewriteMode = .literal
    /// Waiting for `.literalReady` after the transcript arrived.
    public var preparingLiteral = false
    /// Shown instead of "Inserted" when the literal went in for a reason (too long, rewrite failed).
    public var resultNote: Messages?

    // Survive across sessions.
    /// The last literal transcript, kept for Paste/Copy last.
    public var literal: String?
    /// What was actually inserted or copied: the literal, the accepted rewrite, or an edit.
    public var delivered: String?
    /// How long the key was held in the last dictation that reached finalizing, for the Stats section.
    public var spoken: Duration = .zero
    public var mode: RewriteMode = .literal
    public var previewPolicy: PreviewPolicy = .whenChanged
    /// The last delivery was a rewrite with changed words that skipped the preview (Show preview = Never).
    public var autoInsertedRewrite = false
    public var model: SpeechModelStatus = .installed
    public var micGranted = true
    /// Set on quit, so a press during shutdown can't open the mic again.
    public var terminating = false
    /// Transcriber calls abandoned to a watchdog in a row.
    public var consecutiveAbandons = 0

    public init() {}

    /// What Paste/Copy last use: what went in, except a rewrite the user never saw, where it's their own words.
    public var lastTranscript: String? { autoInsertedRewrite ? literal : delivered ?? literal }

    /// Clears per-session values and returns to idle.
    mutating func resetSession() {
        phase = .idle
        current = nil
        pressedAt = .zero
        transcriberActive = false
        peakDBFS = -.infinity
        lastPartial = ""
        usedPartialFallback = false
        restartAdvised = false
        keyUpSince = nil
        sessionMode = .literal
        preparingLiteral = false
        resultNote = nil
    }
}

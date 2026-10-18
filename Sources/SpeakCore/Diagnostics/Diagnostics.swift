import Foundation

/// One measured step. Holds enums and durations only, never text.
public enum TimingLine: Equatable, Sendable {
    /// Release to inserted or copied, or to the preview opening when `previewed`.
    case dictation(mode: RewriteMode, previewed: Bool, duration: Duration, stages: DictationStages = DictationStages())
    /// After the preview: bringing the app back, then pasting.
    case handoff(DeliveryTimings)

    public var text: String {
        switch self {
        case .dictation(let mode, let previewed, let duration, let stages):
            "dictation mode=\(mode.rawValue) preview=\(previewed) \(seconds(duration))" + fields([
                ("finalize", stages.finalize), ("cleanup", stages.cleanup), ("first", stages.firstToken),
                ("rewrite", stages.rewrite), ("modwait", stages.modWait), ("paste", stages.paste),
            ])
        case .handoff(let t):
            "handoff" + fields([("activate", t.activate), ("modwait", t.modWait), ("paste", t.paste)])
        }
    }

    private func fields(_ pairs: [(String, Duration?)]) -> String {
        pairs.compactMap { name, d in d.map { " \(name)=\(seconds($0))" } }.joined()
    }

    private func seconds(_ d: Duration) -> String {
        let (s, attos) = d.components
        return String(format: "%.3fs", Double(s) + Double(attos) / 1e18)
    }
}

/// Where one dictation's time went. Steps that didn't run (no rewrite in Literal) stay nil.
public struct DictationStages: Equatable, Sendable {
    /// Release to the final transcript.
    public var finalize: Duration?
    /// Final transcript to literal text (dictionary and spelling).
    public var cleanup: Duration?
    /// Literal text to the model's first token, as the model reports it.
    public var firstToken: Duration?
    /// Literal text to the model's whole reply.
    public var rewrite: Duration?
    /// Waiting for held modifier keys before the paste.
    public var modWait: Duration?
    /// The delivery itself, after the modifier wait.
    public var paste: Duration?

    public init(finalize: Duration? = nil, cleanup: Duration? = nil, firstToken: Duration? = nil,
                rewrite: Duration? = nil, modWait: Duration? = nil, paste: Duration? = nil) {
        self.finalize = finalize
        self.cleanup = cleanup
        self.firstToken = firstToken
        self.rewrite = rewrite
        self.modWait = modWait
        self.paste = paste
    }
}

/// How long a delivery took. `activate` is set only after the preview.
public struct DeliveryTimings: Equatable, Sendable {
    public var activate: Duration?
    public var modWait: Duration
    public var paste: Duration

    public init(activate: Duration? = nil, modWait: Duration, paste: Duration) {
        self.activate = activate
        self.modWait = modWait
        self.paste = paste
    }
}

/// Turns one dictation's stage marks into a timing line. Release starts it; the
/// text landing or the preview opening finishes it.
public struct DictationTimer: Sendable {
    private var started: (at: ContinuousClock.Instant, mode: RewriteMode)?
    private var lastMark: ContinuousClock.Instant?
    private var stages = DictationStages()

    public init() {}

    public mutating func released(at instant: ContinuousClock.Instant, mode: RewriteMode) {
        started = (instant, mode)
        lastMark = instant
        stages = DictationStages()
    }

    /// Records a stage. Returns a line of its own only for a delivery after the preview.
    public mutating func mark(_ stage: SessionStage, at instant: ContinuousClock.Instant) -> TimingLine? {
        guard started != nil, let last = lastMark else {
            if case .delivered(let t) = stage, t.activate != nil { return .handoff(t) }
            return nil
        }
        switch stage {
        case .finalized: stages.finalize = instant - last
        case .literalReady: stages.cleanup = instant - last
        case .rewritten(let firstToken):
            stages.rewrite = instant - last
            stages.firstToken = firstToken
        case .delivered(let t):
            stages.modWait = t.modWait
            stages.paste = t.paste
        }
        lastMark = instant
        return nil
    }

    public mutating func finish(previewed: Bool, at instant: ContinuousClock.Instant) -> TimingLine? {
        guard let (start, mode) = started else { return nil }
        let line = TimingLine.dictation(mode: mode, previewed: previewed, duration: instant - start, stages: stages)
        reset()
        return line
    }

    public mutating func reset() {
        started = nil
        lastMark = nil
        stages = DictationStages()
    }
}

/// The most recent timings, for Copy diagnostics.
public struct TimingLog: Equatable, Sendable {
    public static let capacity = 20
    public private(set) var entries: [TimingLine] = []

    public init() {}

    public mutating func add(_ line: TimingLine) {
        entries.append(line)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    public var lines: [String] { entries.map(\.text) }
}

/// What Copy diagnostics puts on the clipboard: versions, permissions, model
/// status, settings values, and timings. Nothing the user said or typed.
public struct Diagnostics: Sendable {
    public var appVersion: String
    public var osVersion: String
    public var permissions: [Permission: Bool]
    public var model: SpeechModelStatus
    public var rewrite: RewriteAvailability
    /// Setting names and values; values are enums, flags, counts, or a language code.
    public var settings: [(String, String)]
    public var timings: TimingLog

    public init(appVersion: String, osVersion: String, permissions: [Permission: Bool], model: SpeechModelStatus,
                rewrite: RewriteAvailability, settings: [(String, String)], timings: TimingLog) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.permissions = permissions
        self.model = model
        self.rewrite = rewrite
        self.settings = settings
        self.timings = timings
    }

    public var report: String {
        let perms = Permission.allCases.map { "\($0.title)=\(permissions[$0] == true ? "granted" : "missing")" }
        let modelText = switch model {
        case .installed: "installed"
        case .downloading(let percent): "downloading \(percent)%"
        case .unavailable: "unavailable"
        }
        let timingLines = timings.lines.isEmpty ? ["none yet"] : timings.lines
        return ([
            "Speak \(appVersion) · macOS \(osVersion)",
            "Permissions: \(perms.joined(separator: ", "))",
            "Speech model: \(modelText)",
            "Rewrites: \(rewrite)",
            "Settings: \(settings.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))",
            "Timings (last \(TimingLog.capacity)):",
        ] + timingLines).joined(separator: "\n")
    }
}

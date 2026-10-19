/// What the menu shows as its first line, most urgent first.
public func menuStatus(permissions: [Permission: Bool], needsRelaunch: Bool, model: SpeechModelStatus,
                       hotkey: HotkeyChoice) -> String {
    if needsRelaunch { return Messages.inputMonitoringRelaunch.text }
    if permissions[.inputMonitoring] == false { return Messages.inputMonitoring.text }
    if permissions[.microphone] == false { return Messages.mic.text }
    switch model {
    case .downloading(let percent): return Messages.modelDownloading(percent: percent).text
    case .unavailable(let language): return Messages.modelUnavailable(language: language).text
    case .installed: break
    }
    if permissions[.accessibility] == false { return Messages.accessibilityMissing.text }
    return "Ready — hold \(hotkey.title)"
}

public enum MenuIcon: Equatable, Sendable {
    case idle, listening, processing, problem

    public init(phase: Phase, hasProblem: Bool) {
        switch phase {
        case .arming, .listening: self = .listening
        case .finalizing, .rewriting, .delivering: self = .processing
        // The preview panel itself shows what's going on.
        case .idle, .awaitingAcceptance: self = hasProblem ? .problem : .idle
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .idle: "mic"
        case .listening: "mic.fill"
        case .processing: "ellipsis.circle"
        case .problem: "exclamationmark.triangle"
        }
    }
}

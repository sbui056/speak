import Foundation

/// One measured step. Holds enums and durations only, never text.
public enum TimingLine: Equatable, Sendable {
    /// Release to inserted or copied, or to the preview opening when `previewed`.
    case dictation(mode: RewriteMode, previewed: Bool, duration: Duration)

    public var text: String {
        switch self {
        case .dictation(let mode, let previewed, let duration):
            "dictation mode=\(mode.rawValue) preview=\(previewed) \(seconds(duration))"
        }
    }

    private func seconds(_ d: Duration) -> String {
        let (s, attos) = d.components
        return String(format: "%.3fs", Double(s) + Double(attos) / 1e18)
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

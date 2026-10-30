import Foundation
import Observation

/// One day's totals. Numbers only: no text, app, or time of day.
public struct DayUsage: Codable, Equatable, Sendable {
    /// Local calendar day, `yyyy-MM-dd`, so days sort as text.
    public let day: String
    public var dictations: Int
    public var words: Int
    public var seconds: Double
}

public enum UsageRange: String, CaseIterable, Sendable {
    case today, week, month, all

    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All time"
        }
    }

    /// How many days back it reaches, counting today; nil for everything.
    var dayCount: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }
}

/// The totals of a range, and what the Stats section shows for them.
public struct UsageSummary: Equatable, Sendable {
    public var dictations = 0
    public var words = 0
    public var seconds = 0.0

    public var averageWords: Int? { dictations > 0 ? Int((Double(words) / Double(dictations)).rounded()) : nil }
    public var averageSeconds: Double? { dictations > 0 ? seconds / Double(dictations) : nil }

    /// Typing the same words at `Constants.typingWordsPerMinute`, minus the time spent speaking. An estimate.
    public var secondsSaved: Double {
        max(0, Double(words) / Double(Constants.typingWordsPerMinute) * 60 - seconds)
    }

    public static func durationText(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        let minutes = (whole + 30) / 60
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Totals per day for dictations that gave the user text. Saved after every change.
@MainActor
@Observable
public final class UsageModel {
    public private(set) var days: [DayUsage]
    /// The last save failed; today's numbers last until Speak quits.
    public private(set) var saveFailed = false
    @ObservationIgnored private let files: AppFiles
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar

    public init(files: AppFiles, now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.files = files
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        days = files.loadUsage().value
    }

    public func record(_ text: String, spoken: Duration) {
        let words = wordCount(text)
        guard words > 0 else { return }
        let today = dayKey(now())
        let seconds = Double(spoken.components.seconds) + Double(spoken.components.attoseconds) / 1e18
        if let index = days.lastIndex(where: { $0.day == today }) {
            days[index].dictations += 1
            days[index].words += words
            days[index].seconds += seconds
        } else {
            days.append(DayUsage(day: today, dictations: 1, words: words, seconds: seconds))
        }
        do {
            try files.saveUsage(days)
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }

    public func summary(_ range: UsageRange) -> UsageSummary {
        var first = ""
        if let count = range.dayCount, let start = calendar.date(byAdding: .day, value: 1 - count, to: now()) {
            first = dayKey(start)
        }
        var summary = UsageSummary()
        for day in days where day.day >= first {
            summary.dictations += day.dictations
            summary.words += day.words
            summary.seconds += day.seconds
        }
        return summary
    }

    /// Removes every total, the file, and any copies set aside as corrupt.
    public func reset() {
        days = []
        files.deleteUsage()
        saveFailed = false
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

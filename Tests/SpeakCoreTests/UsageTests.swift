import Foundation
import Testing
@testable import SpeakCore

private let utc = TimeZone(identifier: "UTC")!
private let day: TimeInterval = 86_400
/// 2026-10-30 12:00 UTC.
private let noon = Date(timeIntervalSince1970: 1_793_361_600)

@MainActor
struct UsageTests {
    @Test func addsUpADayAndSurvivesARelaunch() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let usage = UsageModel(files: files, now: { noon }, timeZone: utc)
        usage.record("one two three", spoken: .seconds(2))
        usage.record("four", spoken: .milliseconds(1500))
        #expect(usage.days == [DayUsage(day: "2026-10-30", dictations: 2, words: 4, seconds: 3.5)])

        let reloaded = UsageModel(files: files, now: { noon }, timeZone: utc)
        #expect(reloaded.days == usage.days)
        let mode = try FileManager.default.attributesOfItem(
            atPath: files.directory.appendingPathComponent("usage.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func theFileHoldsNoTextOrTimeOfDay() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        UsageModel(files: files, now: { noon }, timeZone: utc).record("secret plans", spoken: .seconds(1))
        let saved = try String(contentsOf: files.directory.appendingPathComponent("usage.json"), encoding: .utf8)
        #expect(!saved.contains("secret"))
        #expect(!saved.contains("12:00"))
    }

    @Test func emptyTextCountsForNothing() {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let usage = UsageModel(files: files, now: { noon }, timeZone: utc)
        usage.record("  ", spoken: .seconds(4))
        #expect(usage.days.isEmpty)
    }

    @Test func rangesCountTodayAndStopAtTheirEdge() {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var now = noon - 30 * day
        let usage = UsageModel(files: files, now: { now }, timeZone: utc)
        for back in [30.0, 29, 7, 6, 1, 0] {
            now = noon - back * day
            usage.record("word", spoken: .seconds(1))
        }
        now = noon
        #expect(usage.summary(.today).dictations == 1)
        #expect(usage.summary(.week).dictations == 3) // today, 1 and 6 days back
        #expect(usage.summary(.month).dictations == 5) // not 30 days back
        #expect(usage.summary(.all).dictations == 6)
    }

    @Test func aCorruptFileIsSetAsideAndResetRemovesEverything() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let usage = UsageModel(files: files, now: { noon }, timeZone: utc)
        usage.record("word", spoken: .seconds(1))
        let url = files.directory.appendingPathComponent("usage.json")
        try Data("not json".utf8).write(to: url)

        let reloaded = UsageModel(files: files, now: { noon }, timeZone: utc)
        #expect(reloaded.days.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
        #expect(aside.contains { $0.hasPrefix("usage.json.corrupt-") })

        reloaded.record("word", spoken: .seconds(1))
        reloaded.reset()
        #expect(reloaded.days.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.directory.path).isEmpty)
    }

    @Test func averagesAndTimeSaved() {
        var summary = UsageSummary()
        #expect(summary.averageWords == nil)
        #expect(summary.averageSeconds == nil)
        #expect(summary.secondsSaved == 0)
        summary = UsageSummary(dictations: 4, words: 200, seconds: 60)
        #expect(summary.averageWords == 50)
        #expect(summary.averageSeconds == 15)
        #expect(summary.secondsSaved == 240) // 5 minutes of typing, 1 of speaking
        // Speaking slower than typing saves nothing rather than going negative.
        #expect(UsageSummary(dictations: 1, words: 1, seconds: 60).secondsSaved == 0)
    }

    @Test func durationsReadNaturally() {
        #expect(UsageSummary.durationText(0) == "0 s")
        #expect(UsageSummary.durationText(59.4) == "59 s")
        #expect(UsageSummary.durationText(60) == "1 min")
        #expect(UsageSummary.durationText(3599) == "1 h 0 min")
        #expect(UsageSummary.durationText(3900) == "1 h 5 min")
    }

    @Test func aReleaseAndTheCapBothSetTheSpokenTime() {
        let id = SessionID(1)
        func listening() -> SessionState {
            var state = reduce(SessionState(), .pressed(at: .seconds(10))).0
            state = reduce(state, .timer(id, .hold)).0
            return reduce(state, .audioPeak(id, dBFS: -20)).0
        }
        #expect(reduce(listening(), .released(at: .seconds(13))).0.spoken == .seconds(3))
        #expect(reduce(listening(), .timer(id, .cap)).0.spoken == Constants.cap)
    }
}

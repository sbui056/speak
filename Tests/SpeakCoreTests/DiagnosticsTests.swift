import Testing
@testable import SpeakCore

struct DiagnosticsTests {
    @Test func timingLogKeepsTheLast20LinesAsNumbersOnly() {
        var log = TimingLog()
        for i in 0..<25 { log.add(.dictation(mode: .literal, previewed: false, duration: .milliseconds(100 + i))) }
        log.add(.dictation(mode: .polished, previewed: true, duration: .milliseconds(1234)))
        #expect(log.lines.count == TimingLog.capacity)
        #expect(TimingLog.capacity == 20)
        #expect(log.lines.first == "dictation mode=literal preview=false 0.106s")
        #expect(log.lines.last == "dictation mode=polished preview=true 1.234s")
    }

    @Test func reportHasEveryFieldAndNoText() {
        var timings = TimingLog()
        timings.add(.dictation(mode: .concise, previewed: false, duration: .milliseconds(820)))
        let report = Diagnostics(
            appVersion: "1.0 (16)", osVersion: "26.0",
            permissions: [.microphone: true, .inputMonitoring: true, .accessibility: false],
            model: .downloading(percent: 40), rewrite: .appleIntelligenceOff,
            settings: [("mode", "concise"), ("previewPolicy", "never"), ("history", "off"), ("dictionaryTerms", "3")],
            timings: timings
        ).report
        #expect(report == """
            Speak 1.0 (16) · macOS 26.0
            Permissions: Microphone=granted, Input Monitoring=granted, Accessibility=missing
            Speech model: downloading 40%
            Rewrites: appleIntelligenceOff
            Settings: mode=concise, previewPolicy=never, history=off, dictionaryTerms=3
            Timings (last 20):
            dictation mode=concise preview=false 0.820s
            """)
    }

    @Test func emptyTimingsSaySo() {
        let report = Diagnostics(appVersion: "1", osVersion: "26", permissions: [:], model: .installed,
                                 rewrite: .available, settings: [], timings: TimingLog()).report
        #expect(report.hasSuffix("Timings (last 20):\nnone yet"))
        #expect(report.contains("Speech model: installed"))
    }
}

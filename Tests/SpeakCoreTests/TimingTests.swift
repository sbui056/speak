import Testing
@testable import SpeakCore

struct TimingTests {
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }

    @Test func dictationLineListsOnlyTheStagesThatRan() {
        let literal = TimingLine.dictation(mode: .literal, previewed: false, duration: .milliseconds(105),
                                           stages: DictationStages(finalize: .milliseconds(60), cleanup: .milliseconds(2),
                                                                   modWait: .zero, paste: .milliseconds(25)))
        #expect(literal.text == "dictation mode=literal preview=false 0.105s"
            + " finalize=0.060s cleanup=0.002s modwait=0.000s paste=0.025s")
        let rewrite = TimingLine.dictation(mode: .polished, previewed: true, duration: .milliseconds(990),
                                           stages: DictationStages(finalize: .milliseconds(50), cleanup: .milliseconds(1),
                                                                   firstToken: .milliseconds(300), rewrite: .milliseconds(900)))
        #expect(rewrite.text == "dictation mode=polished preview=true 0.990s"
            + " finalize=0.050s cleanup=0.001s first=0.300s rewrite=0.900s")
    }

    @Test func speculationOutcomeEndsTheLine() {
        let line = TimingLine.dictation(mode: .polished, previewed: false, duration: .milliseconds(500),
                                        stages: DictationStages(firstToken: .milliseconds(380), rewrite: .milliseconds(200),
                                                                speculation: .hit))
        #expect(line.text == "dictation mode=polished preview=false 0.500s first=0.380s rewrite=0.200s spec=hit")
    }

    @Test func handoffLineHasItsThreeSteps() {
        let line = TimingLine.handoff(DeliveryTimings(activate: .milliseconds(120), modWait: .milliseconds(40),
                                                      paste: .milliseconds(20)))
        #expect(line.text == "handoff activate=0.120s modwait=0.040s paste=0.020s")
    }

    @Test func literalDictationIsSplitIntoStages() {
        var timer = DictationTimer()
        timer.released(at: at(0), mode: .literal)
        _ = timer.mark(.finalized, at: at(60))
        _ = timer.mark(.literalReady, at: at(62))
        _ = timer.mark(.delivered(DeliveryTimings(modWait: .zero, paste: .milliseconds(30))), at: at(95))
        let line = timer.finish(previewed: false, at: at(100))
        #expect(line == .dictation(mode: .literal, previewed: false, duration: .milliseconds(100),
                                   stages: DictationStages(finalize: .milliseconds(60), cleanup: .milliseconds(2),
                                                           modWait: .zero, paste: .milliseconds(30))))
        #expect(timer.finish(previewed: false, at: at(200)) == nil)
    }

    @Test func rewriteTimeStartsWhenTheLiteralIsReady() {
        var timer = DictationTimer()
        timer.released(at: at(0), mode: .polished)
        _ = timer.mark(.finalized, at: at(50))
        _ = timer.mark(.literalReady, at: at(51))
        _ = timer.mark(.rewritten(firstToken: .milliseconds(280)), at: at(851))
        let line = timer.finish(previewed: true, at: at(860))
        #expect(line == .dictation(mode: .polished, previewed: true, duration: .milliseconds(860),
                                   stages: DictationStages(finalize: .milliseconds(50), cleanup: .milliseconds(1),
                                                           firstToken: .milliseconds(280), rewrite: .milliseconds(800))))
    }

    @Test func deliveryAfterThePreviewIsItsOwnHandoffLine() {
        var timer = DictationTimer()
        timer.released(at: at(0), mode: .polished)
        _ = timer.finish(previewed: true, at: at(900))
        let handoff = DeliveryTimings(activate: .milliseconds(100), modWait: .zero, paste: .milliseconds(20))
        #expect(timer.mark(.delivered(handoff), at: at(5000)) == .handoff(handoff))
        // A plain delivery outside a timed dictation isn't a handoff.
        #expect(timer.mark(.delivered(DeliveryTimings(modWait: .zero, paste: .zero)), at: at(6000)) == nil)
    }

    @Test func marksOutsideADictationAreIgnoredAndResetDropsIt() {
        var timer = DictationTimer()
        #expect(timer.mark(.finalized, at: at(10)) == nil)
        timer.released(at: at(0), mode: .literal)
        timer.reset()
        #expect(timer.finish(previewed: false, at: at(100)) == nil)
        // A new release starts from scratch.
        timer.released(at: at(200), mode: .literal)
        let line = timer.finish(previewed: false, at: at(300))
        #expect(line == .dictation(mode: .literal, previewed: false, duration: .milliseconds(100)))
    }
}

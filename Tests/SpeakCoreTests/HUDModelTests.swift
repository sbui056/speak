import Testing
@testable import SpeakCore

@MainActor
struct HUDModelTests {
    @Test func repeatedErrorIsShownOnceButStillEndsProcessing() async {
        let hud = HUDModel(clock: TestClock())
        hud.show(.error(.appChanged))
        #expect(hud.content == .error(.appChanged))
        hud.show(.processing)
        hud.show(.error(.appChanged))
        #expect(hud.content == nil)
    }

    @Test func resultsHideThemselves() async {
        let clock = TestClock()
        let hud = HUDModel(clock: clock)
        hud.show(.result(.inserted))
        await clock.advance(by: Constants.hudOK - .milliseconds(10))
        #expect(hud.content == .result(.inserted))
        await clock.advance(by: .milliseconds(20))
        #expect(await eventually { hud.content == nil })
    }

    @Test func partialTextIsThrottledLatestWins() async {
        let clock = TestClock()
        let hud = HUDModel(clock: clock)
        hud.show(.partial("a"))
        hud.show(.partial("ab"))
        hud.show(.partial("abc"))
        #expect(hud.content == .partial("a"))
        await settle() // the throttle task must be asleep before time moves, or its deadline starts late
        await clock.advance(by: .seconds(1 / Constants.hudRate) + .milliseconds(10))
        #expect(hud.content == .partial("abc"))
    }

    @Test func hoveringKeepsAnErrorOpen() async {
        let clock = TestClock()
        let hud = HUDModel(clock: clock)
        hud.show(.error(.noField))
        hud.hover(true)
        await clock.advance(by: Constants.hudError * 2)
        #expect(hud.content == .error(.noField))
        hud.hover(false)
        await clock.advance(by: Constants.hudError + .milliseconds(20))
        #expect(await eventually { hud.content == nil })
    }

    @Test func everyChangeIsReported() async {
        let clock = TestClock()
        let hud = HUDModel(clock: clock)
        var seen: [HUDContent?] = []
        hud.onContentChange = { seen.append($0) }
        hud.show(.listening)
        hud.show(.processing)
        hud.show(.result(.inserted))
        await clock.advance(by: Constants.hudOK + .milliseconds(20))
        // The woken hide task hops back to the main actor; under a loaded CI pool that can take more turns than advance's settle.
        #expect(await eventually { seen.count == 4 })
        #expect(seen == [.listening, .processing, .result(.inserted), nil])
    }
}

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
        #expect(hud.content == nil)
    }

    @Test func partialTextIsThrottledLatestWins() async {
        let clock = TestClock()
        let hud = HUDModel(clock: clock)
        hud.show(.partial("a"))
        hud.show(.partial("ab"))
        hud.show(.partial("abc"))
        #expect(hud.content == .partial("a"))
        await clock.advance(by: .seconds(1 / Constants.hudRate) + .milliseconds(10))
        #expect(hud.content == .partial("abc"))
    }
}

@MainActor
struct HUDHoverTests {
    @Test func hoveringKeepsAnErrorOpen() async {
        let clock = TestClock()
        let hud = HUDModel(clock: clock)
        hud.show(.error(.noField))
        hud.hover(true)
        await clock.advance(by: Constants.hudError * 2)
        #expect(hud.content == .error(.noField))
        hud.hover(false)
        await clock.advance(by: Constants.hudError + .milliseconds(20))
        #expect(hud.content == nil)
    }
}

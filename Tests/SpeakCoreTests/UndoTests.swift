import Testing
@testable import SpeakCore

@Suite(.timeLimit(.minutes(1)))
struct UndoTests {
    let clock = TestClock()
    let env = FakeDeliveryEnvironment()
    let pasteboard = FakePasteboard()

    /// Pastes "Hi" into a 10-character field, which the app then shows as 12.
    private func pasted() async -> Deliverer {
        let d = Deliverer(env: env, pasteboard: pasteboard, clock: clock)
        let context = PressContext(pid: await env.frontmostPID(), focus: await env.focusedElement())
        #expect(await d.deliver("Hi", context: context) == .inserted)
        env.update { $0.textLength = 12 }
        return d
    }

    @Test func undoSendsCommandZOnceInTheSameField() async {
        let d = await pasted()
        #expect(await d.canUndo)
        #expect(await d.undoIsSafe())
        #expect(await d.undoLastInsert())
        #expect(env.undos == [6])
        #expect(!(await d.canUndo))
        #expect(!(await d.undoLastInsert()))
        #expect(env.undos == [6])
    }

    @Test func undoUsesTheLayoutsZ() async {
        env.update { $0.layout = [9: "v", 44: "z"] }
        let d = await pasted()
        #expect(await d.undoLastInsert())
        #expect(env.undos == [44])
    }

    @Test func expiresAfterTheUndoWindow() async {
        let d = await pasted()
        await clock.advance(by: Constants.undo - .milliseconds(20))
        #expect(await d.canUndo)
        await clock.advance(by: .milliseconds(40))
        #expect(!(await d.canUndo))
        #expect(!(await d.undoLastInsert()))
        #expect(env.undos.isEmpty)
    }

    @Test func refusedAfterSwitchingApps() async {
        let d = await pasted()
        env.update { $0.frontmostPID = 7 }
        #expect(!(await d.undoIsSafe()))
        #expect(!(await d.undoLastInsert()))
        #expect(env.undos.isEmpty)
    }

    @Test func refusedAfterFocusMoves() async {
        let d = await pasted()
        env.update { $0.focus = .element(ElementRef(FakeDeliveryEnvironment.Element("other"))) }
        #expect(!(await d.undoLastInsert()))
        #expect(env.undos.isEmpty)
    }

    @Test func refusedWhenTheFieldWasEditedSince() async {
        let d = await pasted()
        env.update { $0.textLength = 15 }
        #expect(!(await d.undoLastInsert()))
    }

    @Test func selectionReplacedByThePasteIsAccountedFor() async {
        env.update { $0.selectionLength = 4 }
        let d = await pasted()
        env.update { $0.textLength = 8 } // 10 - 4 selected + 2 pasted
        #expect(await d.undoLastInsert())
    }

    @Test func unreadableLengthStillAllowsUndo() async {
        env.update { $0.textLength = nil }
        let d = await pasted()
        env.update { $0.textLength = nil }
        #expect(await d.undoLastInsert())
    }

    @Test func copyDoesNotOfferUndo() async {
        env.update { $0.accessibilityTrusted = false }
        let d = Deliverer(env: env, pasteboard: pasteboard, clock: clock)
        _ = await d.deliver("Hi", context: PressContext(pid: 100, focus: await env.focusedElement()))
        #expect(!(await d.canUndo))
    }
}

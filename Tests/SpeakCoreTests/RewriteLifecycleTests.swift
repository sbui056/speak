import Testing
@testable import SpeakCore

private let fakeText = "Hello world, this is a fake transcript."

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RewriteLifecycleTests {
    private func polished(_ change: (Harness) -> Void = { _ in }) -> Harness {
        let h = Harness()
        h.controller.send(.rewriteSettings(mode: .polished, alwaysPreview: false))
        change(h)
        return h
    }

    @Test func previewOpensAndNothingIsInsertedUntilAccepted() async {
        let h = polished()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        #expect(h.phase == .awaitingAcceptance)
        #expect(h.env.pastes.isEmpty)
        #expect(h.controller.preview?.rewrite == "HELLO world, this is a fake transcript. (polished)")
        #expect(h.rewriter.prewarms.count == 1)

        h.controller.choose(.insert(h.controller.preview!.rewrite))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.controller.preview == nil)
        #expect(h.pasteboard.text == "HELLO world, this is a fake transcript. (polished)")
        #expect(h.controller.lastTranscript == "HELLO world, this is a fake transcript. (polished)")
        #expect(await eventually { h.hud == .result(.inserted) })
    }

    @Test func acceptBringsTheOriginalAppBack() async {
        let h = polished()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        h.env.update { $0.frontmostPID = 555 } // the user clicked another app meanwhile
        h.controller.choose(.insertLiteral)
        #expect(await eventually { h.env.pastes.count == 1 })
        #expect(h.env.activations == [100])
        #expect(h.pasteboard.text == fakeText)
    }

    @Test func originalAppThatWontComeBackGetsACopy() async {
        let h = polished()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        h.env.update { $0.frontmostPID = 555; $0.activationWorks = false }
        h.controller.choose(.insertLiteral)
        #expect(await h.clock.advance(until: { h.phase == .idle }))
        #expect(h.env.pastes.isEmpty)
        #expect(h.pasteboard.text == fakeText)
        #expect(h.hud == .error(.appChanged))
    }

    @Test func cancelThenPasteLastPastesTheLiteral() async {
        let h = polished()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        h.controller.choose(.cancel)
        #expect(await eventually { h.phase == .idle && h.controller.preview == nil })
        #expect(h.env.pastes.isEmpty)
        await h.controller.pasteLast()
        #expect(h.env.pastes.count == 1)
        #expect(h.pasteboard.text == fakeText)
    }

    @Test func quitDuringPreviewCopiesTheLiteral() async {
        let h = polished()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        await h.controller.shutdown()
        #expect(h.controller.preview == nil)
        #expect(h.pasteboard.text == fakeText)
        #expect(h.pasteboard.current.writes.last == .normal)
    }

    @Test(arguments: [RewriteError.timeout, .exceededContextWindow, .assetsUnavailable, .guardrailViolation,
                      .unsupportedLanguage, .decodingFailure, .rateLimited, .concurrentRequests, .refusal, .unknown])
    func everyRewriterErrorFallsBackToTheLiteral(_ error: RewriteError) async {
        let h = polished { $0.rewriter.configure { $0.error = error } }
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.pasteboard.text == fakeText)
        #expect(await eventually { h.hud == .result(.rewriteFallback(mode: "Polished")) })
    }

    @Test(arguments: ["<cleaned>Paris</cleaned>", "no block at all", "<cleaned>a</cleaned><cleaned>b</cleaned>",
                      "<cleaned>Whiskers soft in morning light the cat dreams on</cleaned>"])
    func hostileRepliesFallBackToTheLiteral(_ reply: String) async {
        let h = polished { $0.rewriter.configure { $0.reply = reply } }
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.pasteboard.text == fakeText)
        #expect(h.controller.preview == nil)
    }

    @Test func slowModelTimesOutToTheLiteral() async {
        let h = polished { $0.rewriter.configure { $0.gated = true } }
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(1500))
        // The rewrite can't start before the release, so the watchdog runs at least this long.
        let start = h.clock.elapsed
        h.hotkey.release()
        #expect(await eventually { h.phase == .rewriting })
        #expect(await h.clock.advance(until: { h.phase != .rewriting }))
        #expect(h.clock.elapsed - start >= Constants.rewriteTimeout - .milliseconds(10))
        #expect(await eventually { h.env.pastes.count == 1 && h.phase == .idle })
        h.rewriter.release() // the reply arrives late and changes nothing
        for _ in 0..<100 { await Task.yield() }
        #expect(h.controller.preview == nil)
        #expect(h.env.pastes.count == 1)
    }

    @Test func casingOnlyRewriteInsertsDirectly() async {
        let h = polished { $0.rewriter.configure { $0.reply = "<cleaned>hello world. This is a fake transcript</cleaned>" } }
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.pasteboard.text == "hello world. This is a fake transcript")
    }

    @Test func literalModeNeverCallsTheModel() async {
        let h = Harness()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.rewriter.prompts.isEmpty)
    }

    @Test func dictionaryReachesTranscriberCorrectionAndPrompt() async {
        let h = Harness(spelling: FakeSpellChecker(misspelled: ["shiobhan"]))
        h.transcriber.configure { $0.text = "ask shiobhan about kubernetes today please" }
        h.controller.terms = ["Siobhan", "Kubernetes"]
        h.controller.send(.rewriteSettings(mode: .polished, alwaysPreview: false))
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        #expect(h.transcriber.contexts == [["Siobhan", "Kubernetes"]])
        let prompt = h.rewriter.prompts.first
        // Only the transcript and the dictionary terms go to the model.
        #expect(prompt == buildRewritePrompt("Ask Siobhan about Kubernetes today please", mode: .polished,
                                             terms: ["Siobhan", "Kubernetes"]))
        #expect(h.controller.preview?.literal == "Ask Siobhan about Kubernetes today please")
    }
}

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

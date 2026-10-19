import Testing
@testable import SpeakCore

private let fakeText = Harness.fakeText
/// What the fake rewriter returns for the fake transcript in Polished.
private let fakeRewrite = "HELLO world, this is a fake transcript. too"

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RewriteLifecycleTests {
    private func polished(_ change: (Harness) -> Void = { _ in }) -> Harness {
        let h = Harness()
        h.controller.send(.rewriteSettings(mode: .polished, preview: .whenChanged))
        change(h)
        return h
    }

    @Test func previewOpensAndNothingIsInsertedUntilAccepted() async {
        let h = polished()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        #expect(h.phase == .awaitingAcceptance)
        #expect(h.env.pastes.isEmpty)
        #expect(h.controller.preview?.rewrite == fakeRewrite)
        #expect(h.rewriter.prewarms.count == 1)

        h.controller.choose(.insert(h.controller.preview!.rewrite))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.controller.preview == nil)
        #expect(h.pasteboard.text == fakeRewrite)
        #expect(h.controller.lastTranscript == fakeRewrite)
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

    @Test func optionStillHeldAfterTheChoiceGetsTheLongerWait() async {
        let h = polished()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        // About 1 s of Option still down (20 ms per poll): longer than the normal modifier wait.
        h.env.update { $0.modifierPolls = 50 }
        h.controller.choose(.insertLiteral)
        #expect(await h.clock.advance(until: { h.phase == .idle }))
        #expect(h.env.pastes.count == 1)
        #expect(h.hud == .result(.inserted))
    }

    @Test func optionHeldPastTheHandoffWaitCopies() async {
        let h = polished()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        h.env.update { $0.modifierPolls = 1000 }
        h.controller.choose(.insertLiteral)
        #expect(await h.clock.advance(until: { h.phase == .idle }))
        #expect(h.env.pastes.isEmpty)
        #expect(h.hud == .error(.modifiers))
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

    @Test func polishedThatChangesAnUnknownWordFallsBackAndSaysWhy() async {
        let h = Harness(spelling: FakeSpellChecker(misspelled: ["kubectl"]))
        h.controller.send(.rewriteSettings(mode: .polished, preview: .whenChanged))
        h.transcriber.configure { $0.text = "run kubectl apply on the cluster now" }
        h.rewriter.configure { $0.reply = "<cleaned>Run cuddle apply on the cluster now.</cleaned>" }
        var rejections: [RewriteRejection] = []
        h.controller.onRewriteRejected = { _, why in rejections.append(why) }
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.pasteboard.text == "Run kubectl apply on the cluster now")
        #expect(rejections == [.keep(.lostProtected)])
    }

    @Test func polishedCantUndoAReplacementPair() async {
        let h = polished()
        h.transcriber.configure { $0.text = "please open a pool request for the fix today" }
        h.controller.pairs = [ReplacementPair(heard: "pool request", write: "pull request")]
        h.rewriter.configure { $0.reply = "<cleaned>Please open a pool request for the fix today.</cleaned>" }
        var rejections: [RewriteRejection] = []
        h.controller.onRewriteRejected = { _, why in rejections.append(why) }
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.pasteboard.text == "Please open a pull request for the fix today")
        #expect(rejections == [.keep(.lostProtected)])
        #expect(h.rewriter.prompts.first?.prompt.hasSuffix("Keep these words exactly: pull request.") == true)
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
        await settle()
        #expect(h.controller.preview == nil)
        #expect(h.env.pastes.count == 1)
    }

    @Test func casingOnlyRewriteInsertsDirectly() async {
        let h = polished { $0.rewriter.configure { $0.reply = "<cleaned>hello world. This is a fake transcript</cleaned>" } }
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.pasteboard.text == "hello world. This is a fake transcript")
    }

    @Test func neverPreviewInsertsTheRewriteAndPasteLastGivesTheLiteral() async {
        let h = Harness()
        h.controller.send(.rewriteSettings(mode: .polished, preview: .never))
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.controller.preview == nil)
        #expect(h.pasteboard.text == fakeRewrite)
        h.env.update { $0.textLength = 10 + fakeRewrite.utf16.count } // the field now shows the paste
        #expect(await h.controller.undoIsSafe())
        #expect(h.controller.lastTranscript == fakeText)
        await h.controller.pasteLast()
        #expect(h.env.pastes.count == 2)
        #expect(h.pasteboard.text == fakeText)
    }

    @Test func neverPreviewStillFallsBackOnAHostileReply() async {
        let h = polished { $0.rewriter.configure { $0.reply = "<cleaned>Paris</cleaned>" } }
        h.controller.send(.rewriteSettings(mode: .polished, preview: .never))
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.pasteboard.text == fakeText)
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
        h.controller.send(.rewriteSettings(mode: .polished, preview: .whenChanged))
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        #expect(h.transcriber.terms == [["Siobhan", "Kubernetes"]])
        let prompt = h.rewriter.prompts.first
        // Only the transcript and the dictionary terms go to the model.
        #expect(prompt == buildRewritePrompt("Ask Siobhan about Kubernetes today please", mode: .polished,
                                             terms: ["Siobhan", "Kubernetes"]))
        #expect(h.controller.preview?.literal == "Ask Siobhan about Kubernetes today please")
    }

    @Test func pairsReachLiteralAndRescoring() async {
        let h = Harness()
        h.transcriber.configure { $0.text = "open a pool request for kubernetes" }
        h.controller.terms = ["Kubernetes"]
        h.controller.pairs = [ReplacementPair(heard: "pool request", write: "pull request")]
        await h.hold(for: .milliseconds(1000))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(h.pasteboard.text == "Open a pull request for Kubernetes")
        #expect(h.transcriber.terms == [["Kubernetes", "pull request"]])
    }

    @Test func stagesAreReportedInOrderThenTheHandoffHasItsOwn() async {
        let h = polished()
        var stages: [SessionStage] = []
        h.controller.onStage = { stages.append($0) }
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        #expect(stages == [.finalized, .literalReady, .rewritten(firstToken: nil)])

        h.controller.choose(.insertLiteral)
        #expect(await eventually { h.phase == .idle })
        guard case .delivered(let timings)? = stages.last else { Issue.record("no delivery stage"); return }
        #expect(timings.activate != nil)
    }

    @Test func literalStagesHaveNoRewriteAndADeliveryWithoutHandoff() async {
        let h = Harness()
        var stages: [SessionStage] = []
        h.controller.onStage = { stages.append($0) }
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle })
        #expect(stages.prefix(2) == [.finalized, .literalReady])
        #expect(stages.count == 3)
        guard case .delivered(let timings)? = stages.last else { Issue.record("no delivery stage"); return }
        #expect(timings.activate == nil)
    }
}

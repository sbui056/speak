import Testing
@testable import SpeakCore

private let s1 = SessionID(1)
private func ms(_ n: Int) -> KeyTime { .milliseconds(n) }

private func run(_ events: [SessionEvent], from start: SessionState = SessionState()) -> (SessionState, [Effect]) {
    var state = start
    var last: [Effect] = []
    for event in events { (state, last) = reduce(state, event) }
    return (state, last)
}

private let literal = "Um so I think we should move the meeting to Thursday"
private let rewrite = "I think we should move the meeting to Thursday."

/// A session in `mode` that has reached the literal.
private func session(_ mode: RewriteMode, literal text: String = literal, alwaysPreview: Bool = false) -> [SessionEvent] {
    [.rewriteSettings(mode: mode, alwaysPreview: alwaysPreview), .pressed(at: ms(0)), .timer(s1, .hold),
     .audioPeak(s1, dBFS: -20), .released(at: ms(1500)), .finalized(s1, text), .literalReady(s1, text)]
}

/// Polished, with the rewrite in the preview.
private let previewing = session(.polished) + [.rewritten(s1, rewrite)]

struct RewriteReducerTests {
    @Test func rewriteModeAsksTheModel() {
        let (state, effects) = run(session(.polished))
        #expect(state.phase == .rewriting)
        #expect(effects == [.rewrite(s1, literal, .polished), .startTimer(s1, .rewrite, after: Constants.rewriteTimeout),
                            .showHUD(.rewriting)])
    }

    @Test func listeningInARewriteModePrewarms() {
        let (_, effects) = run([.rewriteSettings(mode: .concise, alwaysPreview: false), .pressed(at: ms(0)), .timer(s1, .hold)])
        #expect(effects.last == .prewarmRewriter(.concise))
        let (_, literalEffects) = run([.pressed(at: ms(0)), .timer(s1, .hold)])
        #expect(!literalEffects.contains(.prewarmRewriter(.literal)))
    }

    @Test func modeIsTakenAtPress() {
        let events: [SessionEvent] = [.rewriteSettings(mode: .polished, alwaysPreview: false), .pressed(at: ms(0)),
                                      .timer(s1, .hold), .audioPeak(s1, dBFS: -20),
                                      .rewriteSettings(mode: .literal, alwaysPreview: false),
                                      .released(at: ms(1500)), .finalized(s1, literal), .literalReady(s1, literal)]
        #expect(run(events).0.phase == .rewriting)
    }

    @Test func changedWordingWaitsForTheUser() {
        let (state, effects) = run(previewing)
        #expect(state.phase == .awaitingAcceptance)
        #expect(effects == [.hideHUD, .showPreview(s1, literal: literal, rewrite: rewrite)])
    }

    @Test func casingOrPunctuationOnlyInsertsWithoutPreview() {
        let (state, effects) = run(session(.polished, literal: "move the meeting to thursday") +
                                   [.rewritten(s1, "Move the meeting to Thursday.")])
        #expect(state.phase == .delivering)
        #expect(effects.first == .deliver(s1, "Move the meeting to Thursday."))
    }

    @Test func alwaysPreviewShowsEvenUnchangedWording() {
        let (state, _) = run(session(.polished, literal: "move the meeting to thursday", alwaysPreview: true) +
                             [.rewritten(s1, "Move the meeting to Thursday.")])
        #expect(state.phase == .awaitingAcceptance)
    }

    @Test func acceptDeliversTheRewriteAfterHandoff() {
        let (state, effects) = run(previewing + [.preview(s1, .insert(rewrite))])
        #expect(state.phase == .delivering)
        #expect(effects == [.closePreview, .handoff(s1, rewrite), .startTimer(s1, .deliver, after: Constants.deliver)])
        #expect(state.delivered == rewrite)
        #expect(state.literal == literal)
    }

    @Test func editedTextIsDelivered() {
        let edited = "I think we should move the meeting to Friday."
        let (state, effects) = run(previewing + [.preview(s1, .insert(edited))])
        #expect(effects.contains(.handoff(s1, edited)))
        #expect(state.delivered == edited)
    }

    @Test func insertLiteralDeliversTheLiteralByteForByte() {
        let (state, effects) = run(previewing + [.preview(s1, .insertLiteral)])
        #expect(effects.contains(.handoff(s1, literal)))
        guard case .handoff(_, let text)? = effects.first(where: { if case .handoff = $0 { true } else { false } }) else {
            Issue.record("no handoff"); return
        }
        #expect(Array(text.utf8) == Array(literal.utf8))
        #expect(state.delivered == literal)
    }

    @Test func cancelInsertsNothingAndKeepsTheLiteral() {
        let (state, effects) = run(previewing + [.preview(s1, .cancel)])
        #expect(state.phase == .idle)
        #expect(effects == [.closePreview, .hideHUD, .endSession(s1)])
        #expect(state.literal == literal)
        #expect(state.delivered == nil)
    }

    @Test func copyFromThePreview() {
        let (state, effects) = run(previewing + [.preview(s1, .copy(rewrite))])
        #expect(effects == [.closePreview, .copyToPasteboard(rewrite), .showHUD(.result(.copied)), .endSession(s1)])
        #expect(state.delivered == rewrite)
    }

    @Test func pressDuringPreviewSaysBusy() {
        let (state, effects) = run(previewing + [.pressed(at: ms(9000))])
        #expect(state.phase == .awaitingAcceptance)
        #expect(effects == [.showHUD(.error(.busy))])
    }

    @Test func hotkeyEscDuringPreviewIsIgnored() {
        let (state, effects) = run(previewing + [.cancel])
        #expect(state.phase == .awaitingAcceptance)
        #expect(effects.isEmpty)
    }

    @Test(arguments: [SessionEvent.quit, .systemSleep])
    func quitOrSleepDuringPreviewCopiesTheLiteral(_ event: SessionEvent) {
        let (state, effects) = run(previewing + [event])
        #expect(state.phase == .idle)
        #expect(effects.first == .copyToPasteboard(literal))
        #expect(effects.contains(.closePreview))
    }

    @Test func quitWhileRewritingCopiesTheLiteral() {
        let (_, effects) = run(session(.polished) + [.quit])
        #expect(effects.first == .copyToPasteboard(literal))
    }

    @Test func failedRewriteFallsBackToTheLiteral() {
        let (state, effects) = run(session(.concise) + [.rewritten(s1, nil)])
        #expect(effects.first == .deliver(s1, literal))
        let (_, done) = reduce(state, .delivered(s1, .inserted))
        #expect(done == [.showHUD(.result(.rewriteFallback(mode: "Concise"))), .endSession(s1)])
    }

    @Test func timeoutFallsBackAndIgnoresTheLateReply() {
        let (state, effects) = run(session(.polished) + [.timer(s1, .rewrite)])
        #expect(effects.first == .deliver(s1, literal))
        let (late, lateEffects) = reduce(state, .rewritten(s1, rewrite))
        #expect(late == state)
        #expect(lateEffects.isEmpty)
        let (_, done) = reduce(state, .delivered(s1, .inserted))
        #expect(done.first == .showHUD(.result(.rewriteFallback(mode: "Polished"))))
    }

    @Test func fallbackThatGetsCopiedShowsTheCopyReason() {
        let (_, done) = run(session(.polished) + [.rewritten(s1, nil), .delivered(s1, .copied(.noField))])
        #expect(done.first == .showHUD(.error(.noField)))
    }

    @Test func belowTheMinimumSkipsTheRewrite() {
        let (state, effects) = run(session(.polished, literal: "Sounds good to"))
        #expect(state.phase == .delivering)
        #expect(effects.first == .deliver(s1, "Sounds good to"))
        #expect(!effects.contains { if case .rewrite = $0 { true } else { false } })
        #expect(run(session(.polished, literal: "Sounds good to me")).0.phase == .rewriting)
    }

    @Test func aboveTheMaximumInsertsTheLiteralAndSaysSo() {
        let long = Array(repeating: "word", count: Constants.rewriteMaxWords + 1).joined(separator: " ")
        let (state, effects) = run(session(.polished, literal: long))
        #expect(effects.first == .deliver(s1, long))
        let (_, done) = reduce(state, .delivered(s1, .inserted))
        #expect(done.first == .showHUD(.result(.tooLong)))
        let atMax = Array(repeating: "word", count: Constants.rewriteMaxWords).joined(separator: " ")
        #expect(run(session(.polished, literal: atMax)).0.phase == .rewriting)
    }

    @Test func slowTranscriptionSkipsTheRewrite() {
        let events: [SessionEvent] = [.rewriteSettings(mode: .polished, alwaysPreview: false), .pressed(at: ms(0)),
                                      .timer(s1, .hold), .audioPeak(s1, dBFS: -20), .released(at: ms(1500)),
                                      .partial(s1, literal), .timer(s1, .finalize), .literalReady(s1, literal)]
        #expect(run(events).0.phase == .delivering)
    }

    @Test func pasteLastValueFollowsTheSession() {
        let (accepted, _) = run(previewing + [.preview(s1, .insert(rewrite)), .delivered(s1, .inserted)])
        #expect(accepted.delivered == rewrite)
        // The next literal replaces both.
        let s2 = SessionID(2)
        let (next, _) = run([.pressed(at: ms(9000)), .timer(s2, .hold), .audioPeak(s2, dBFS: -20),
                             .released(at: ms(11000)), .finalized(s2, "x"), .literalReady(s2, "Next one")], from: accepted)
        #expect(next.literal == "Next one")
        #expect(next.delivered == "Next one")
    }

    @Test func previewActionFromAnotherSessionIsIgnored() {
        let (before, _) = run(previewing)
        let (after, effects) = reduce(before, .preview(SessionID(7), .insertLiteral))
        #expect(after == before)
        #expect(effects.isEmpty)
    }
}

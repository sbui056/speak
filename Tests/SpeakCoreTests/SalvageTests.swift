import Testing
@testable import SpeakCore

struct SalvageTests {
    private func salvage(_ literal: String, _ cleaned: String, terms: [String] = [], language: String = "en") -> String? {
        salvageRewrite("<cleaned>\(cleaned)</cleaned>", literal: literal, terms: terms, unknownWords: [],
                       language: language)
    }

    @Test func oneChangedSentenceRevertsAndTheRestStaysCleaned() {
        let literal = "Um, so the build is slow on CI. The demo is going to be like two minutes. "
            + "We should, uh, rehearse twice before the call."
        let cleaned = "The build is slow on CI. The demo will be about two minutes. We should rehearse twice before the call."
        #expect(keepGuard(literal: literal, cleaned: cleaned, terms: [], unknownWords: [], language: "en") == .unrelated)
        #expect(salvage(literal, cleaned)
            == "The build is slow on CI. The demo is going to be like two minutes. We should rehearse twice before the call.")
    }

    @Test func mergedSentencesAreJudgedTogether() {
        // The reply joins sentences two and three, so they revert as one; the first stays cleaned.
        let literal = "So the tests pass now. The deploy is going to be like slow. It runs at night."
        let cleaned = "The tests pass now. The deploy will be fairly slow, and it runs at night."
        #expect(salvage(literal, cleaned) == "The tests pass now. The deploy is going to be like slow. It runs at night.")
    }

    @Test func splitSentenceStaysWithItsLiteral() {
        let literal = "Um, the cache is fine. We ask for the email, then the name, and by then people leave. Uh, the retry loop spins."
        let cleaned = "The cache is fine. We ask for the email, then the name. By then, people leave. The retry loop spins."
        // Nothing to salvage: the whole reply already passes.
        #expect(keepGuard(literal: literal, cleaned: cleaned, terms: [], unknownWords: [], language: "en") == nil)
        let changed = "The cache is fine. We ask for the email. By then, folks bail. The retry loop spins."
        #expect(salvage(literal, changed)
            == "The cache is fine. We ask for the email, then the name, and by then people leave. The retry loop spins.")
    }

    @Test func paragraphBreaksBetweenKeptSentencesSurvive() {
        let literal = "Um, the tests pass. The deploy is going to be like slow. So the docs are done."
        let cleaned = "The tests pass.\n\nThe deploy will be fairly slow. The docs are done."
        #expect(salvage(literal, cleaned) == "The tests pass. The deploy is going to be like slow. The docs are done.")
        let twoKept = "Um, the tests pass. Uh, the docs are done. The deploy is going to be like slow."
        let twoCleaned = "The tests pass.\n\nThe docs are done. The deploy will be fairly slow."
        #expect(salvage(twoKept, twoCleaned) == "The tests pass.\n\nThe docs are done. The deploy is going to be like slow.")
    }

    @Test func nothingWorthKeepingGivesNil() {
        // A single sentence, or a reply where every sentence fails, falls back as before.
        #expect(salvage("The demo is going to be like two minutes.", "The demo will be about two minutes.") == nil)
        #expect(salvage("The demo is going to be like two minutes. We ship it on Monday.",
                        "The demo will be about two minutes. We ship it on Tuesday.") == nil)
        // Only the kept sentence changed, and only its fillers: still worth keeping.
        #expect(salvage("The demo is going to be like two minutes. Um, so we ship.",
                        "The demo will be about two minutes. So we ship.")
            == "The demo is going to be like two minutes. So we ship.")
    }

    @Test func malformedReplyGivesNil() {
        #expect(salvageRewrite("no tags here", literal: "One. Two.", terms: [], unknownWords: [], language: "en") == nil)
    }

    @Test func lostNumberInOneSentenceRevertsOnlyThatOne() {
        let literal = "Um, the job takes eight minutes. So, uh, the cache never hits."
        let cleaned = "The job takes a few minutes. The cache never hits."
        #expect(salvage(literal, cleaned) == "Um, the job takes eight minutes. The cache never hits.")
    }

    @Test func japaneseSentencesSplitOnTheirOwnFullStop() {
        let literal = "サーバーが2回落ちました。原因はたぶんデータベースです。"
        let cleaned = "サーバーが落ちました。原因はおそらくデータベースです。"
        #expect(salvage(literal, cleaned, language: "ja_JP") == "サーバーが2回落ちました。原因はおそらくデータベースです。")
    }
}

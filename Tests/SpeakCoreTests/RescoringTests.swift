import Testing
@testable import SpeakCore

struct RescoringTests {
    /// The recognizer unsure of every word, unless a confidence is given.
    private func seg(_ text: String, alts: [String] = [], confidence: Double = 0.5) -> RecognizedSegment {
        RecognizedSegment(text: text, alternatives: alts,
                          confidences: Array(repeating: confidence, count: comparableWords(text).count))
    }

    @Test func confidentEverydayWordIsNotSwappedForALowercaseTerm() {
        // "cash" heard clearly stays cash even with the pack's "cache" in the dictionary.
        #expect(rescore([seg("I paid in cash", alts: ["I paid in cache"], confidence: 0.99)], terms: ["cache"])
            == "I paid in cash")
        #expect(rescore([RecognizedSegment(text: "I paid in cash", alternatives: ["I paid in cache"], confidences: nil)],
                        terms: ["cache"]) == "I paid in cash")
    }

    @Test func onlyTheReplacedWordsNeedLowConfidence() {
        let segment = RecognizedSegment(text: "I paid in cash", alternatives: ["I paid in cache"],
                                        confidences: [0.99, 0.99, 0.99, 0.6])
        #expect(rescore([segment], terms: ["cache"]) == "I paid in cache")
    }

    @Test func termWithACapitalNeedsNoLowConfidence() {
        #expect(rescore([seg("See, I should be green", alts: ["CI should be green"], confidence: 0.99)], terms: ["CI"])
            == "CI should be green")
    }

    @Test func alternativeWithTheTermReplacesTheTop() {
        #expect(rescore([seg("the cash wasn't the problem", alts: ["the cache wasn't the problem"])], terms: ["cache"])
            == "the cache wasn't the problem")
    }

    @Test func termMayReplaceTwoWords() {
        #expect(rescore([seg("See, I should be green", alts: ["CI should be green"])], terms: ["CI"])
            == "CI should be green")
    }

    @Test func alternativeWithoutTheTermIsIgnored() {
        #expect(rescore([seg("I paid in cash", alts: ["I paid in Cash at"])], terms: ["cache"]) == "I paid in cash")
    }

    @Test func alternativeThatRepeatsAWordIsRejected() {
        #expect(rescore([seg("I like the reaction items", alts: ["I like the, the action items"])], terms: ["action items"])
            == "I like the reaction items")
    }

    @Test func changeLongerThanTheTermAllowsIsRejected() {
        // "main" is one word: at most 3 changed words.
        #expect(rescore([seg("push the fix to man now", alts: ["pushed a fix into main now"])], terms: ["main"])
            == "push the fix to man now")
    }

    @Test func topThatAlreadyHasTheTermIsKept() {
        #expect(rescore([seg("push to main", alts: ["push to Maine"])], terms: ["main"]) == "push to main")
        #expect(rescore([seg("push to Main", alts: ["push to main"])], terms: ["main"]) == "push to Main")
    }

    @Test func alternativeThatLosesATermTheTopHasIsRejected() {
        #expect(rescore([seg("the cache app", alts: ["the cash app"])], terms: ["cache", "cash app"]) == "the cache app")
    }

    @Test func oneCharacterTermsNeverRescore() {
        // "C++" compares as "c": any lone letter would match it.
        #expect(rescore([seg("the plan see", alts: ["the plan C"])], terms: ["C++"]) == "the plan see")
    }

    @Test func chosenAlternativeKeepsTheTopReadingsOuterSpacing() {
        let segments = [seg("I pushed it."), seg(" The cash is cold.", alts: ["The cache is cold. "])]
        #expect(rescore(segments, terms: ["cache"]) == "I pushed it. The cache is cold.")
    }

    @Test func firstPassingAlternativeInRankOrderWins() {
        let segment = seg("the cash is cold", alts: ["the cash is gold", "the Cache is cold", "the cache is old"])
        #expect(rescore([segment], terms: ["cache"]) == "the Cache is cold")
    }

    @Test func wordsThatOnlyJoinIntoATermAreNotTheTerm() {
        // "red is" joins to "redis" but isn't Redis; a replacement pair handles real splits.
        #expect(rescore([seg("the read is done", alts: ["the red is done"])], terms: ["Redis"]) == "the read is done")
    }

    @Test func termMatchIsWholeWord() {
        #expect(rescore([seg("the cash is cold", alts: ["the caches is cold"])], terms: ["cache"]) == "the cash is cold")
    }

    @Test func multiWordTermMustAppearInOrder() {
        #expect(rescore([seg("open a pool request", alts: ["open a pull request"])], terms: ["pull request"])
            == "open a pull request")
        #expect(rescore([seg("open a pool request", alts: ["open a request pull"])], terms: ["pull request"])
            == "open a pool request")
    }

    @Test func onlyTheSegmentWithTheTermChanges() {
        let segments = [seg("I pushed the fix.", alts: ["I pushed the fix to."]),
                        seg(" The cash is cold.", alts: [" The cache is cold."])]
        #expect(rescore(segments, terms: ["cache"]) == "I pushed the fix. The cache is cold.")
    }

    @Test func noTermsOrNoAlternativesJoinTheTexts() {
        #expect(rescore([seg("Hello"), seg("world.")], terms: ["cache"]) == "Hello world.")
        #expect(rescore([seg("the cash", alts: ["the cache"])], terms: []) == "the cash")
        #expect(rescore([], terms: ["cache"]) == "")
    }

    @Test func joinAddsASpaceOnlyWhereNeitherSideHasOne() {
        #expect(joinedTranscript("Hello", "world") == "Hello world")
        #expect(joinedTranscript("Hello ", "world") == "Hello world")
        #expect(joinedTranscript("Hello", " world") == "Hello world")
        #expect(joinedTranscript("", "world") == "world")
    }

    @Test func alignWordsMarksSameDeleteAndInsert() {
        #expect(alignWords(["a", "b", "c"], ["a", "x", "c"]) == [.same(0, 0), .delete(1), .insert(1), .same(2, 2)])
        #expect(alignWords([String](), ["a"]) == [.insert(0)])
    }
}

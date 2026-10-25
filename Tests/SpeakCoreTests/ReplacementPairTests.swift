import Foundation
import Testing
@testable import SpeakCore

struct ReplacementPairTests {
    private func pair(_ heard: String, _ write: String) -> ReplacementPair {
        ReplacementPair(heard: heard, write: write)
    }

    @Test func replacesTheHeardPhrase() {
        let pairs = [pair("pool request", "pull request")]
        #expect(applyPairs("open a pool request now", pairs: pairs) == "open a pull request now")
        #expect(applyPairs("open a pool   request", pairs: pairs) == "open a pull request")
    }

    @Test func keepsALeadingCapital() {
        #expect(applyPairs("Pool request opened", pairs: [pair("pool request", "pull request")]) == "Pull request opened")
        #expect(applyPairs("Cash me", pairs: [pair("cash", "iOS")]) == "iOS me")
    }

    @Test func midSentenceCapitalIsNotCarried() {
        // The recognizer capitalizes what it takes for a name.
        let pairs = [pair("jason", "json")]
        #expect(applyPairs("send the Jason file", pairs: pairs) == "send the json file")
        #expect(applyPairs("Done. Jason file sent", pairs: pairs) == "Done. Json file sent")
    }

    @Test func matchesWholeWordsOnly() {
        #expect(applyPairs("the cashier has cash", pairs: [pair("cash", "cache")]) == "the cashier has cache")
    }

    @Test func longestHeardWins() {
        let pairs = [pair("try", "attempt"), pair("really try", "retry")]
        #expect(applyPairs("really try it", pairs: pairs) == "retry it")
    }

    @Test func singlePassNeverChains() {
        #expect(applyPairs("open a PR", pairs: [pair("PR", "pull request PR")]) == "open a pull request PR")
        #expect(applyPairs("a b", pairs: [pair("a b", "c"), pair("c", "d")]) == "c")
    }

    @Test func sharedLeadingWordKeepsItsSpokenCasing() {
        // A context word on both sides stays as spoken, capital and all.
        let pairs = [pair("the read me", "the README"), pair("pushed to maine", "pushed to main")]
        #expect(applyPairs("The read me. Pushed to Maine", pairs: pairs) == "The README. Pushed to main")
        #expect(applyPairs("see THE read me", pairs: pairs) == "see THE README")
    }

    @Test func regexCharactersAreLiteral() {
        #expect(applyPairs("use c++ here", pairs: [pair("c++", "C++")]) == "use C++ here")
        #expect(applyPairs("use cxx here", pairs: [pair("c..", "C++")]) == "use cxx here")
    }

    @Test func noPairsLeaveTheTextAlone() {
        #expect(applyPairs("open a pool request", pairs: []) == "open a pool request")
    }

    // MARK: Validation

    @Test func pairSidesAreTrimmedAndNormalized() throws {
        var d = TermDictionary()
        try d.addPair(heard: "  pool request ", write: "Cafe\u{301}")
        #expect(d.pairs == [pair("pool request", "Café")])
    }

    @Test(arguments: [("a", "pull request", TermError.length), ("pool request", "x", .length),
                      ("pool <b>", "pull", .angleBrackets), ("pool", "pull>", .angleBrackets),
                      ("pool\trequest", "pull", .controlCharacters), ("Pool Request", "pool request", .sameText)])
    func invalidPairsAreRefused(_ heard: String, _ write: String, _ error: TermError) {
        #expect(TermDictionary().validatePair(heard: heard, write: write) == .failure(error))
    }

    @Test func heardIsUniqueIgnoringCase() throws {
        var d = TermDictionary()
        try d.addPair(heard: "pool request", write: "pull request")
        #expect(d.validatePair(heard: "Pool Request", write: "pull requests") == .failure(.duplicate))
        // Editing a pair may keep its own heard side.
        #expect(d.validatePair(heard: "Pool Request", write: "PR", replacing: 0) == .success(pair("Pool Request", "PR")))
    }

    @Test func enforcesThePairLimit() throws {
        var d = TermDictionary()
        for i in 0..<Constants.pairsMax { try d.addPair(heard: "heard \(i)", write: "write \(i)") }
        #expect(throws: TermError.pairLimit) { try d.addPair(heard: "one more", write: "extra") }
        #expect(Constants.pairsMax == 100)
        #expect(TermError.pairLimit.message == "Limit of 100 reached")
        #expect(TermError.sameText.message == "Heard and Write are the same")
    }

    @Test func pairsAreEditedAndRemoved() throws {
        var d = TermDictionary()
        try d.addPair(heard: "pool request", write: "pull request")
        try d.addPair(heard: "really try", write: "retry")
        try d.replacePair(at: 0, heard: "pool requests", write: "pull requests")
        d.removePair(at: 1)
        #expect(d.pairs == [pair("pool requests", "pull requests")])
    }

    @Test func untrustedPairsKeepOnlyValidOnes() {
        let d = TermDictionary(validating: ["Siobhan"],
                               pairs: [pair("pool request", "pull request"), pair("<x>", "y"), pair("Pool Request", "PR")])
        #expect(d.terms == ["Siobhan"])
        #expect(d.pairs == [pair("pool request", "pull request")])
    }

    // MARK: Pipeline

    @MainActor @Test func literalAppliesPairsThenTerms() {
        let out = makeLiteral("open a pool request for kubernetes", terms: ["Kubernetes", "pull request"],
                              pairs: [pair("pool request", "pull request")], spelling: FakeSpellChecker(), language: "en")
        #expect(out == "Open a pull request for Kubernetes")
    }

    @MainActor @Test func nearMissPassLeavesWhatAPairWrote() {
        let out = makeLiteral("open graph ickle now", terms: ["GraphQL"], pairs: [pair("graph ickle", "GraphiQL")],
                              spelling: FakeSpellChecker(misspelled: ["graphiql"]), language: "en")
        #expect(out == "Open GraphiQL now")
    }

    @MainActor @Test func spokenTextThatOnlyLooksLikeAPairOutputStillGetsTerms() {
        // "the docker container" was spoken, not written by the pair, so the term recases it.
        let pairs = [pair("darker container", "Docker container"), pair("the read me", "the README")]
        let out = makeLiteral("start the docker container and update the readme", terms: ["Docker", "README"],
                              pairs: pairs, spelling: FakeSpellChecker(), language: "en")
        #expect(out == "Start the Docker container and update the README")
        let written = makeLiteral("The read me", terms: ["README", "Read"], pairs: pairs,
                                  spelling: FakeSpellChecker(), language: "en")
        #expect(written == "The README")
    }

    @MainActor @Test func whatAPairWroteKeepsItsCasing() {
        let out = makeLiteral("run swift format now", terms: ["Swift"], pairs: [pair("swift format", "swift-format")],
                              spelling: FakeSpellChecker(), language: "en")
        #expect(out == "Run swift-format now")
    }

    @MainActor @Test func worstCaseLiteralIsFast() {
        let text = Array(repeating: "please open the pool request on staging before lunch", count: 67)
            .joined(separator: " ")
        let terms = (0..<200).map { "Term\($0)x" }
        let pairs = (0..<100).map { pair("heard phrase \($0)", "written \($0)") }
        let start = ContinuousClock.now
        _ = makeLiteral(text, terms: terms, pairs: pairs, spelling: FakeSpellChecker(), language: "en")
        #expect(ContinuousClock.now - start < .milliseconds(100))
    }
}

struct DictionaryFileVersionTests {
    @MainActor @Test func modelSavesPairEditsAndAnnouncesThem() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let model = DictionaryModel(files: files)
        var announced: [TermDictionary] = []
        model.onChange = { announced.append($0) }
        try model.addPair(heard: "pool request", write: "pull request")
        try model.replacePair(at: 0, heard: "pool requests", write: "pull requests")
        #expect(throws: TermError.sameText) { try model.addPair(heard: "same", write: "SAME") }
        #expect(announced.last?.pairs == [ReplacementPair(heard: "pool requests", write: "pull requests")])
        model.removePair(at: 0)
        #expect(announced.count == 3)
        #expect(files.loadDictionary().value.pairs.isEmpty)
    }

    @Test func versionOneFileLoadsWithNoPairs() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"terms":["Siobhan"]}"#.utf8).write(to: files.directory.appendingPathComponent("dictionary.json"))
        let loaded = files.loadDictionary()
        #expect(loaded.value.terms == ["Siobhan"])
        #expect(loaded.value.pairs.isEmpty)
        #expect(!loaded.wasCorrupt)
    }

    @Test func pairsRoundTripInVersionTwo() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var d = TermDictionary()
        try d.add("Siobhan")
        try d.addPair(heard: "pool request", write: "pull request")
        try files.saveDictionary(d)
        #expect(files.loadDictionary().value == d)
        let json = try String(contentsOf: files.directory.appendingPathComponent("dictionary.json"), encoding: .utf8)
        #expect(json.contains(#""version":2"#))
    }

    @Test func malformedPairInFileKeepsEverythingElse() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(#"{"version":2,"terms":["Kubernetes"],"pairs":[{"heard":"pool request"},{"heard":"x","write":5},"oops",{"heard":"really try","write":"retry"}]}"#.utf8)
            .write(to: files.directory.appendingPathComponent("dictionary.json"))
        let loaded = files.loadDictionary()
        #expect(!loaded.wasCorrupt)
        #expect(loaded.value.terms == ["Kubernetes"])
        #expect(loaded.value.pairs == [ReplacementPair(heard: "really try", write: "retry")])
    }

    @Test func invalidPairInFileIsDropped() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(#"{"version":2,"terms":[],"pairs":[{"heard":"x","write":"y"},{"heard":"pool request","write":"pull request"}]}"#.utf8)
            .write(to: files.directory.appendingPathComponent("dictionary.json"))
        #expect(files.loadDictionary().value.pairs == [ReplacementPair(heard: "pool request", write: "pull request")])
    }
}

struct TechTermsTests {
    @Test func everyPackEntryIsValidAndUnique() {
        var d = TermDictionary()
        for term in TechTerms.terms { #expect(throws: Never.self) { try d.add(term) } }
        for p in TechTerms.pairs { #expect(throws: Never.self) { try d.addPair(heard: p.heard, write: p.write) } }
        #expect((60...80).contains(TechTerms.terms.count))
    }

    @Test func packNeverRewritesEverydayPhrases() {
        let text = "I'll really try to keep the kitchen clean."
        #expect(applyPairs(text, pairs: TechTerms.pairs) == text)
    }

    @Test func packPairsHearAtLeastTwoWords() {
        // A lone heard word is allowed only when it isn't an English word.
        let nonWords: Set = ["frederix", "kubernati"]
        for p in TechTerms.pairs where !nonWords.contains(p.heard.lowercased()) {
            #expect(p.heard.split(separator: " ").count >= 2, "\(p.heard)")
        }
    }

    // Misheard on real voice (build 71). Each fix needs tech context next to the
    // everyday word, so the same word in plain English stays as spoken.
    @Test(arguments: [
        ("Run it with darker compose.", "Run it with Docker Compose."),
        ("Pull it from darker hub", "Pull it from Docker Hub"),
        ("start the darker container", "start the Docker container"),
        ("stop all darker containers", "stop all Docker containers"),
        ("update the darker file", "update the Dockerfile"),
        ("I pushed to Maine.", "I pushed to main."),
        ("Merge it into Maine after review", "Merge it into main after review"),
        ("merged into Maine", "merged into main"),
        ("rebase on Maine first", "rebase on main first"),
        ("check out the Maine branch", "check out the main branch"),
        ("Fixed main, see I should be green.", "Fixed main, CI should be green."),
        ("Fixed main see I should be green.", "Fixed main CI should be green."),
        ("the see I is red", "the CI is red"),
        ("See I is failing again", "CI is failing again"),
        ("add a step to the see I pipeline", "add a step to the CI pipeline"),
        ("update the read me", "update the README"),
        ("The read me is out of date.", "The README is out of date."),
        ("add a read me and our read me badge", "add a README and our README badge"),
        ("write a Frederix for that", "write a regex for that"),
        // Build 91 verify run.
        ("Can you add a doctor file for the API service?", "Can you add a Dockerfile for the API service?"),
        ("Deploy it to the Kubernati clusters", "Deploy it to the Kubernetes clusters"),
        ("My cousin lives in Portland, main.", "My cousin lives in Portland, Maine."),
        ("Can you bump the cash key, rerun the pipeline", "Can you bump the cache key, rerun the pipeline"),
    ])
    func packFixesTechMishearings(_ heard: String, _ fixed: String) {
        #expect(applyPairs(heard, pairs: TechTerms.pairs) == fixed)
    }

    @Test(arguments: [
        "I'll really try to keep the kitchen clean.",
        "The room got darker as the sun went down.",
        "Use a darker image for the background.",
        "It gets darker in winter.",
        "We drove up to Portland, Maine, last summer.",
        "She moved to Maine in May.",
        "The Maine coast is lovely.",
        "Read me a story before bed.",
        "Can you read me the list?",
        "I see, I think that works.",
        "You'll see I was right.",
        "See, I told you.",
        "See, I should be more careful.",
        "The doctor filed the report on Monday.",
        "Keep the cash in a safe.",
        "Portland is the main city in the state.",
    ])
    func packNeverRewritesEverydaySentences(_ text: String) {
        #expect(applyPairs(text, pairs: TechTerms.pairs) == text)
    }

    @Test func packFillsUpToTheLimitAndCountsTheRest() throws {
        var d = TermDictionary()
        for i in 0..<190 { try d.add("own term \(i)") }
        let result = d.addPack(terms: TechTerms.terms, pairs: TechTerms.pairs)
        #expect(d.terms.count == Constants.dictMaxEntries)
        #expect(result.added == 10 + TechTerms.pairs.count)
        #expect(result.skipped == TechTerms.terms.count - 10)
    }

    @Test func addingThePackTwiceAddsNothing() {
        var d = TermDictionary()
        _ = d.addPack(terms: TechTerms.terms, pairs: TechTerms.pairs)
        let again = d.addPack(terms: TechTerms.terms, pairs: TechTerms.pairs)
        #expect(again.added == 0)
        #expect(again.skipped == TechTerms.terms.count + TechTerms.pairs.count)
    }

    @Test func removeTakesOutOnlyWhatThePackAdded() throws {
        var d = TermDictionary()
        try d.add("Siobhan")
        try d.add("Kubernetes") // also a pack term: the user's own, so it stays
        try d.addPair(heard: "jason", write: "json")
        _ = d.addPack(terms: TechTerms.terms, pairs: TechTerms.pairs)
        #expect(d.pack?.terms.contains("Kubernetes") == false)
        let removed = d.removePack()
        #expect(d.terms == ["Siobhan", "Kubernetes"])
        #expect(d.pairs == [ReplacementPair(heard: "jason", write: "json")])
        #expect(removed == TechTerms.terms.count - 1 + TechTerms.pairs.count)
        #expect(d.pack == nil)
    }

    @Test func packIsRememberedInTheFile() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var d = TermDictionary()
        try d.add("Kubernetes")
        _ = d.addPack(terms: TechTerms.terms, pairs: TechTerms.pairs)
        try files.saveDictionary(d)
        var loaded = files.loadDictionary().value
        #expect(loaded == d)
        _ = loaded.removePack()
        #expect(loaded.terms == ["Kubernetes"])
    }

    @Test func malformedPackInFileIsIgnored() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(#"{"version":2,"terms":["Kubernetes"],"pack":"oops"}"#.utf8)
            .write(to: files.directory.appendingPathComponent("dictionary.json"))
        let loaded = files.loadDictionary()
        #expect(!loaded.wasCorrupt)
        #expect(loaded.value.terms == ["Kubernetes"])
        #expect(loaded.value.pack == nil)
    }

    @MainActor @Test func modelAddsAndRemovesThePackWithOneAnnouncementEach() {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let model = DictionaryModel(files: files)
        var announced = 0
        model.onChange = { _ in announced += 1 }
        let result = model.addPack(terms: TechTerms.terms, pairs: TechTerms.pairs)
        #expect(result.added == TechTerms.terms.count + TechTerms.pairs.count)
        #expect(files.loadDictionary().value.terms.count == TechTerms.terms.count)
        #expect(model.removePack() == result.added)
        #expect(announced == 2)
        #expect(files.loadDictionary().value.terms.isEmpty)
    }
}

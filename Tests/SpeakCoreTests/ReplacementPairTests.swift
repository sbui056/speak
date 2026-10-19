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

    @Test func invalidPairInFileIsDropped() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(#"{"version":2,"terms":[],"pairs":[{"heard":"x","write":"y"},{"heard":"pool request","write":"pull request"}]}"#.utf8)
            .write(to: files.directory.appendingPathComponent("dictionary.json"))
        #expect(files.loadDictionary().value.pairs == [ReplacementPair(heard: "pool request", write: "pull request")])
    }
}

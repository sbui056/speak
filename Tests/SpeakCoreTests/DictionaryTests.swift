import Foundation
import Testing
@testable import SpeakCore

struct TermDictionaryTests {
    @Test func trimsAndNormalizesToNFC() throws {
        var d = TermDictionary()
        try d.add("  Cafe\u{301}  ")
        #expect(d.terms == ["Caf\u{E9}"])
        #expect(d.terms[0].unicodeScalars.count == 4)
    }

    @Test func rejectsCaseInsensitiveDuplicates() throws {
        var d = TermDictionary()
        try d.add("Kubernetes")
        #expect(throws: TermError.duplicate) { try d.add("kubernetes") }
        try d.add("Cafe\u{301}")
        #expect(throws: TermError.duplicate) { try d.add("CAF\u{C9}") } // same word, other normalization
    }

    @Test(arguments: [("a", TermError.length), (String(repeating: "x", count: 65), .length),
                      ("<b>", .angleBrackets), ("a>b", .angleBrackets),
                      ("tab\there", .controlCharacters), ("line\u{0}x", .controlCharacters)])
    func rejectsInvalid(_ raw: String, _ error: TermError) {
        #expect(TermDictionary().validate(raw) == .failure(error))
    }

    @Test func acceptsLengthBoundaries() {
        #expect(TermDictionary().validate("ab") == .success("ab"))
        #expect(TermDictionary().validate(String(repeating: "x", count: 64)) == .success(String(repeating: "x", count: 64)))
    }

    @Test func enforcesEntryLimit() throws {
        var d = TermDictionary()
        for i in 0..<Constants.dictMaxEntries { try d.add("term\(i)") }
        #expect(throws: TermError.limit) { try d.add("one more") }
        // Editing at the limit is still allowed.
        try d.replace(at: 0, with: "renamed")
        #expect(d.terms[0] == "renamed")
    }

    @Test func editKeepsItsOwnSpellingButNotOthers() throws {
        var d = TermDictionary()
        try d.add("Siobhan")
        try d.add("Kubernetes")
        try d.replace(at: 0, with: "siobhan") // re-casing itself is fine
        #expect(d.terms[0] == "siobhan")
        #expect(throws: TermError.duplicate) { try d.replace(at: 0, with: "KUBERNETES") }
    }

    @Test func untrustedInputKeepsOnlyValidTerms() {
        let d = TermDictionary(validating: ["ok", "OK", "<x>", "a", " Fine "])
        #expect(d.terms == ["ok", "Fine"])
    }
}

struct TermCorrectionTests {
    private func correct(_ text: String, _ terms: [String], misspelled: Set<String> = []) -> String {
        correctTerms(text, terms: terms) { misspelled.contains($0.lowercased()) }
    }

    @Test func wholeWordTakesTermCasing() {
        #expect(correct("ask siobhan about kubernetes", ["Siobhan", "Kubernetes"]) == "ask Siobhan about Kubernetes")
    }

    @Test func lowercaseTermKeepsTheSpokenCasing() {
        #expect(correct("Commit the fix.", ["commit"]) == "Commit the fix.")
        #expect(correct("please COMMIT", ["commit"]) == "please COMMIT")
        #expect(correct("Pull request merged", ["pull request"]) == "Pull request merged")
        #expect(correct("kubernetes is up", ["Kubernetes"]) == "Kubernetes is up")
    }

    @Test func lowercaseTermStillBlocksFuzzyOnItsWords() {
        // "retry" matches exactly, so the near miss "retro" term never touches it.
        #expect(correct("Retry it", ["retry", "Retro"], misspelled: ["retry"]) == "Retry it")
    }

    @Test func lowercaseTermStillFixesNearMisses() {
        #expect(correct("run kubectal now", ["kubectl"], misspelled: ["kubectal"]) == "run kubectl now")
    }

    @Test func changedTermsAreUsedNextTime() {
        #expect(correct("ask siobhan", ["Siobhan"]) == "ask Siobhan")
        #expect(correct("ask siobhan", ["SIOBHAN"]) == "ask SIOBHAN")
        #expect(correct("ask siobhan", []) == "ask siobhan")
    }

    @Test func doesNotMatchInsideWords() {
        #expect(correct("the iosevka font", ["iOS"]) == "the iosevka font")
        #expect(correct("ios and macos", ["iOS"]) == "iOS and macos")
    }

    @Test func possessiveStillMatches() {
        #expect(correct("siobhan's laptop", ["Siobhan"]) == "Siobhan's laptop")
    }

    @Test func phraseMatchesAcrossWhitespaceAndPrefersLongest() {
        #expect(correct("read the new  york times", ["New York", "New York Times"]) == "read the New York Times")
        #expect(correct("visit new york", ["New York", "New York Times"]) == "visit New York")
    }

    @Test func regexCharactersInTermsAreLiteral() {
        #expect(correct("i like c++ and node.js", ["C++", "Node.js"]) == "i like C++ and Node.js")
        #expect(correct("nodexjs", ["Node.js"]) == "nodexjs")
    }

    @Test func fuzzyFixesMisspelledNearMiss() {
        #expect(correct("ask Shiobhan", ["Siobhan"], misspelled: ["shiobhan"]) == "ask Siobhan")
        #expect(correct("kubernetis is up", ["Kubernetes"], misspelled: ["kubernetis"]) == "Kubernetes is up")
    }

    @Test func fuzzyNeverChangesCorrectlySpelledWords() {
        // "Thera" is one edit from "there", but "there" is a real word.
        #expect(correct("over there", ["Thera"]) == "over there")
    }

    @Test func fuzzyOnlyForTermsOfFiveOrMoreCharacters() {
        #expect(correct("ask Jom", ["Jon"], misspelled: ["jom"]) == "ask Jom")
    }

    @Test func fuzzyOnlyWithinOneEdit() {
        #expect(correct("ask Shivon", ["Siobhan"], misspelled: ["shivon"]) == "ask Shivon")
    }

    @Test func fuzzySkipsAmbiguousMatches() {
        #expect(correct("Marta", ["Marla", "Marga"], misspelled: ["marta"]) == "Marta")
    }

    @Test func emptyInputsPassThrough() {
        #expect(correct("", ["Siobhan"]) == "")
        #expect(correct("hello", []) == "hello")
    }

    @Test(arguments: [("kitten", "sitten", true), ("abc", "abcd", true), ("abcd", "abc", true),
                      ("abc", "abc", false), ("abc", "ABC", false), ("abc", "xyz", false), ("ab", "ba", false)])
    func oneEditAway(_ a: String, _ b: String, _ expected: Bool) {
        #expect(isOneEditAway(a, b) == expected)
    }

    @MainActor @Test func literalPipelineCleansThenCorrects() {
        let out = makeLiteral("  iphone   sync with shiobhan ", terms: ["iPhone", "Siobhan"], pairs: [],
                              spelling: FakeSpellChecker(misspelled: ["shiobhan"]), language: "en_US")
        #expect(out == "iPhone sync with Siobhan")
    }
}

struct AppFilesTests {
    @Test func roundTripsWithPrivatePermissions() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var d = TermDictionary()
        try d.add("Siobhan")
        try files.saveDictionary(d)

        let loaded = files.loadDictionary()
        #expect(loaded.value == d)
        #expect(!loaded.wasCorrupt)
        let fm = FileManager.default
        let dirMode = try fm.attributesOfItem(atPath: files.directory.path)[.posixPermissions] as? Int
        let fileMode = try fm.attributesOfItem(atPath: files.directory.appendingPathComponent("dictionary.json").path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
        #expect(fileMode == 0o600)
        #expect(try files.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func missingFileStartsEmpty() {
        let loaded = tempFiles().loadDictionary()
        #expect(loaded.value.terms.isEmpty)
        #expect(!loaded.wasCorrupt)
    }

    @Test func corruptFileIsMovedAsideAndAppStartsEmpty() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: files.directory.appendingPathComponent("dictionary.json"))

        let loaded = files.loadDictionary()
        #expect(loaded.value.terms.isEmpty)
        #expect(loaded.wasCorrupt)
        let names = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
        #expect(names.count == 1)
        #expect(names[0].hasPrefix("dictionary.json.corrupt-"))
    }

    @Test func invalidTermsInFileAreDropped() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"terms":["Siobhan","<x>","siobhan"]}"#.utf8)
            .write(to: files.directory.appendingPathComponent("dictionary.json"))
        #expect(files.loadDictionary().value.terms == ["Siobhan"])
    }
}

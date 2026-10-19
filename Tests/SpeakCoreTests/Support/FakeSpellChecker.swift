@testable import SpeakCore
/// Reports only the listed words as misspelled.
public struct FakeSpellChecker: SpellChecker {
    public let misspelled: Set<String>
    public init(misspelled: Set<String> = []) { self.misspelled = misspelled }
    public func isMisspelled(_ word: String, language: String) -> Bool {
        misspelled.contains(word.lowercased())
    }
}

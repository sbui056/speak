import Observation

/// The dictionary as the app uses it: edits are validated, saved right away,
/// and announced so the session picks up the new terms.
@MainActor
@Observable
public final class DictionaryModel {
    public private(set) var dictionary: TermDictionary
    /// The saved file couldn't be read and was set aside; shown once in the window.
    public var showCorruptNotice: Bool
    /// The last save failed; the edit is kept in memory for this run.
    public private(set) var saveFailed = false
    @ObservationIgnored public var onChange: ((TermDictionary) -> Void)?
    @ObservationIgnored private let files: AppFiles

    public init(files: AppFiles) {
        self.files = files
        let loaded = files.loadDictionary()
        dictionary = loaded.value
        showCorruptNotice = loaded.wasCorrupt
    }

    public var terms: [String] { dictionary.terms }
    public var pairs: [ReplacementPair] { dictionary.pairs }

    public func add(_ raw: String) throws(TermError) {
        try dictionary.add(raw)
        changed()
    }

    public func replace(at index: Int, with raw: String) throws(TermError) {
        try dictionary.replace(at: index, with: raw)
        changed()
    }

    public func remove(at index: Int) {
        dictionary.remove(at: index)
        changed()
    }

    public func addPair(heard: String, write: String) throws(TermError) {
        try dictionary.addPair(heard: heard, write: write)
        changed()
    }

    public func replacePair(at index: Int, heard: String, write: String) throws(TermError) {
        try dictionary.replacePair(at: index, heard: heard, write: write)
        changed()
    }

    public func removePair(at index: Int) {
        dictionary.removePair(at: index)
        changed()
    }

    public func addPack(terms: [String], pairs: [ReplacementPair]) -> (added: Int, skipped: Int) {
        let result = dictionary.addPack(terms: terms, pairs: pairs)
        changed()
        return result
    }

    public func removePack(terms: [String], pairs: [ReplacementPair]) -> Int {
        let removed = dictionary.removePack(terms: terms, pairs: pairs)
        changed()
        return removed
    }

    private func changed() {
        do {
            try files.saveDictionary(dictionary)
            saveFailed = false
        } catch {
            saveFailed = true
        }
        onChange?(dictionary)
    }
}

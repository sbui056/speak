import Foundation

/// Why a dictionary term was refused. `message` is shown inline in the
/// Dictionary window.
public enum TermError: Error, Equatable, Sendable {
    case duplicate
    case length
    case limit
    case angleBrackets
    case controlCharacters
    case sameText
    case pairLimit

    public var message: String {
        switch self {
        case .duplicate: "Already in dictionary"
        case .length:
            "Must be \(Constants.dictTermLength.lowerBound)–\(Constants.dictTermLength.upperBound) characters"
        case .limit: "Limit of \(Constants.dictMaxEntries) reached"
        case .angleBrackets: "Can't contain < or >"
        case .controlCharacters: "Can't contain tabs or line breaks"
        case .sameText: "Heard and Write are the same"
        case .pairLimit: "Limit of \(Constants.pairsMax) reached"
        }
    }
}

/// The entries a pack added.
public struct PackRecord: Codable, Equatable, Sendable {
    public var terms: [String]
    public var pairs: [ReplacementPair]
}

/// Names and terms the user wants spelled their way. Every stored term is
/// trimmed, NFC-normalized, unique ignoring case, and free of `<` `>`, which
/// keeps it safe to put in a rewrite prompt. Replacement pairs follow the same
/// rules on both sides, with "heard" unique ignoring case.
public struct TermDictionary: Equatable, Sendable {
    public private(set) var terms: [String] = []
    public private(set) var pairs: [ReplacementPair] = []
    /// What "Add common tech terms" actually added, so Remove takes out only
    /// that (never the user's own copy of a pack term). Nil until it's added.
    public private(set) var pack: PackRecord?

    public init() {}

    /// Builds from untrusted input (a file), keeping only entries that pass validation.
    public init(validating raw: [String], pairs rawPairs: [ReplacementPair] = [], pack: PackRecord? = nil) {
        for term in raw { try? add(term) }
        for pair in rawPairs { try? addPair(heard: pair.heard, write: pair.write) }
        self.pack = pack
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// The normalized term, or why it can't be stored. `replacing` is the index
    /// being edited, which doesn't count as a duplicate of itself.
    public func validate(_ raw: String, replacing index: Int? = nil) -> Result<String, TermError> {
        let term: String
        switch Self.check(raw) {
        case .success(let checked): term = checked
        case .failure(let error): return .failure(error)
        }
        let duplicate = terms.indices.contains { $0 != index && terms[$0].caseInsensitiveCompare(term) == .orderedSame }
        if duplicate { return .failure(.duplicate) }
        if index == nil, terms.count >= Constants.dictMaxEntries { return .failure(.limit) }
        return .success(term)
    }

    public mutating func add(_ raw: String) throws(TermError) {
        terms.append(try validate(raw).get())
    }

    public mutating func replace(at index: Int, with raw: String) throws(TermError) {
        guard terms.indices.contains(index) else { return }
        terms[index] = try validate(raw, replacing: index).get()
    }

    public mutating func remove(at index: Int) {
        guard terms.indices.contains(index) else { return }
        terms.remove(at: index)
    }

    /// The normalized pair, or why it can't be stored. `replacing` is the index
    /// being edited, which doesn't count as a duplicate of itself.
    public func validatePair(heard rawHeard: String, write rawWrite: String,
                             replacing index: Int? = nil) -> Result<ReplacementPair, TermError> {
        let heard: String, write: String
        switch (Self.check(rawHeard), Self.check(rawWrite)) {
        case (.failure(let error), _), (_, .failure(let error)): return .failure(error)
        case (.success(let h), .success(let w)): (heard, write) = (h, w)
        }
        if heard.caseInsensitiveCompare(write) == .orderedSame { return .failure(.sameText) }
        let duplicate = pairs.indices.contains {
            $0 != index && pairs[$0].heard.caseInsensitiveCompare(heard) == .orderedSame
        }
        if duplicate { return .failure(.duplicate) }
        if index == nil, pairs.count >= Constants.pairsMax { return .failure(.pairLimit) }
        return .success(ReplacementPair(heard: heard, write: write))
    }

    public mutating func addPair(heard: String, write: String) throws(TermError) {
        pairs.append(try validatePair(heard: heard, write: write).get())
    }

    public mutating func replacePair(at index: Int, heard: String, write: String) throws(TermError) {
        guard pairs.indices.contains(index) else { return }
        pairs[index] = try validatePair(heard: heard, write: write, replacing: index).get()
    }

    public mutating func removePair(at index: Int) {
        guard pairs.indices.contains(index) else { return }
        pairs.remove(at: index)
    }

    /// Adds every pack entry that passes validation and fits, and remembers
    /// which; duplicates and entries past a limit count as skipped.
    public mutating func addPack(terms packTerms: [String], pairs packPairs: [ReplacementPair]) -> (added: Int, skipped: Int) {
        var record = pack ?? PackRecord(terms: [], pairs: [])
        for term in packTerms where (try? add(term)) != nil { record.terms.append(term) }
        for pair in packPairs where (try? addPair(heard: pair.heard, write: pair.write)) != nil { record.pairs.append(pair) }
        let added = record.terms.count + record.pairs.count - (pack.map { $0.terms.count + $0.pairs.count } ?? 0)
        pack = record
        return (added, packTerms.count + packPairs.count - added)
    }

    /// Removes the entries the pack added and still present, and returns how many went.
    public mutating func removePack() -> Int {
        guard let record = pack else { return 0 }
        let before = terms.count + pairs.count
        terms.removeAll { record.terms.contains($0) }
        pairs.removeAll { record.pairs.contains($0) }
        pack = nil
        return before - terms.count - pairs.count
    }

    /// The rules every stored text follows: normalized, no control characters
    /// or angle brackets, within `Constants.dictTermLength`.
    private static func check(_ raw: String) -> Result<String, TermError> {
        let text = normalize(raw)
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .failure(.controlCharacters)
        }
        if text.contains("<") || text.contains(">") { return .failure(.angleBrackets) }
        guard Constants.dictTermLength.contains(text.count) else { return .failure(.length) }
        return .success(text)
    }
}

import Foundation

/// Why a dictionary term was refused. `message` is shown inline in the
/// Dictionary window.
public enum TermError: Error, Equatable, Sendable {
    case duplicate
    case length
    case limit
    case angleBrackets
    case controlCharacters

    public var message: String {
        switch self {
        case .duplicate: "Already in dictionary"
        case .length: "Must be 2–64 characters"
        case .limit: "Limit of 200 reached"
        case .angleBrackets: "Can't contain < or >"
        case .controlCharacters: "Can't contain tabs or line breaks"
        }
    }
}

/// Names and terms the user wants spelled their way. Every stored term is
/// trimmed, NFC-normalized, unique ignoring case, and free of `<` `>`, which
/// keeps it safe to put in a rewrite prompt.
public struct TermDictionary: Equatable, Sendable {
    public private(set) var terms: [String] = []

    public init() {}

    /// Builds from untrusted input (a file), keeping only terms that pass validation.
    public init(validating raw: [String]) {
        for term in raw { try? add(term) }
    }

    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// The normalized term, or why it can't be stored. `replacing` is the index
    /// being edited, which doesn't count as a duplicate of itself.
    public func validate(_ raw: String, replacing index: Int? = nil) -> Result<String, TermError> {
        let term = Self.normalize(raw)
        if term.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .failure(.controlCharacters)
        }
        if term.contains("<") || term.contains(">") { return .failure(.angleBrackets) }
        guard Constants.dictTermLength.contains(term.count) else { return .failure(.length) }
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
}

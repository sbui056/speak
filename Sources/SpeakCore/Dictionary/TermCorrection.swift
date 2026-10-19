import Foundation
import Synchronization

/// Answers whether a word is misspelled, so near-miss correction never alters
/// a real word ("there" must not become "Thera").
public protocol SpellChecker: Sendable {
    @MainActor func isMisspelled(_ word: String, language: String) -> Bool
    /// Every misspelled word in `text`, as written. The default asks word by word.
    @MainActor func misspelledWords(in text: String, language: String) -> [String]
}

/// Literal mode's full pipeline: tidy the text, apply the user's replacements,
/// then their spellings.
@MainActor
public func makeLiteral(_ raw: String, terms: [String], pairs: [ReplacementPair], spelling: any SpellChecker,
                        language: String) -> String {
    correctTerms(applyPairs(cleanLiteral(raw), pairs: pairs), terms: terms, shielding: pairs.map(\.write)) {
        spelling.isMisspelled($0, language: language)
    }
}

/// Rewrites dictionary terms to the user's exact spelling.
/// - A whole-word or phrase match, ignoring case, takes the term's casing. A
///   term with no capital letter keeps the spoken casing ("Commit the fix"
///   stays capitalized for the term "commit"); it only shields the words from
///   the near-miss pass.
/// - A word one edit away from a single-word term of 5+ characters is replaced
///   only if `isMisspelled` says it isn't a real word.
/// - `shielding` (what replacement pairs wrote) is never near-miss corrected
///   and keeps its casing, except where it is also a term: then the term's
///   casing wins ("github" written by a pair becomes the term "GitHub").
public func correctTerms(_ text: String, terms: [String], shielding: [String] = [],
                         isMisspelled: (String) -> Bool) -> String {
    guard !terms.isEmpty, !text.isEmpty else { return text }
    let ns = text as NSString
    // `replace` is false for matches that only shield their words from the near-miss pass.
    var edits: [(range: NSRange, term: String, replace: Bool)] = []

    let termSet = Set(terms.map { $0.lowercased() })
    let shields = shielding.filter { !termSet.contains($0.lowercased()) }
    let (byLength, regex) = termPattern(terms + shields)
    let shieldSet = Set(shields.map { $0.lowercased() })
    if let regex {
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let group = (1..<match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound })
            else { continue }
            let term = byLength[group - 1]
            // A term with no capital keeps the spoken casing.
            edits.append((match.range, term, !shieldSet.contains(term.lowercased()) && term.contains(where: \.isUppercase)))
        }
    }

    // Lowercased once up front: this loop runs words × terms times.
    let fuzzyTerms = terms.filter { $0.count >= 5 && !$0.contains(where: \.isWhitespace) }
        .map { (term: $0, chars: Array($0.lowercased())) }
    if !fuzzyTerms.isEmpty, let words = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+") {
        let exact = edits.map(\.range)
        for match in words.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if exact.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            let word = ns.substring(with: match.range)
            let chars = Array(word.lowercased())
            let near = fuzzyTerms.filter { isOneEditAway(chars, $0.chars) }.map(\.term)
            // Two terms equally close is a guess; leave the word alone.
            guard near.count == 1, isMisspelled(word) else { continue }
            edits.append((match.range, near[0], true))
        }
    }

    let result = NSMutableString(string: text)
    for edit in edits.sorted(by: { $0.range.location > $1.range.location }) where edit.replace {
        result.replaceCharacters(in: edit.range, with: edit.term)
    }
    return result as String
}

/// The last few alternations (terms; terms plus pair outputs; pairs' heard
/// sides), kept because the same lists come back every dictation and a
/// 200-term pattern is slow to compile.
private let patternCache = Mutex<[(terms: [String], byLength: [String], regex: NSRegularExpression?)]>([])

/// The terms longest first, so "New York Times" wins over "New York" at the
/// same spot, and one case-insensitive pattern with a group per term.
func termPattern(_ terms: [String]) -> (byLength: [String], regex: NSRegularExpression?) {
    if let cached = patternCache.withLock({ $0.first { $0.terms == terms } }) { return (cached.byLength, cached.regex) }
    let byLength = terms.sorted { $0.count > $1.count }
    let regex = phraseRegex(byLength)
    patternCache.withLock { cache in
        cache.insert((terms, byLength, regex), at: 0)
        if cache.count > 4 { cache.removeLast() }
    }
    return (byLength, regex)
}

/// One case-insensitive pattern matching any of `phrases` as whole words
/// (any whitespace between their words), with capture group n + 1 for phrase n.
func phraseRegex(_ phrases: [String]) -> NSRegularExpression? {
    let alternatives = phrases.map { phrase in
        phrase.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
    }
    let pattern = "(?<![\\p{L}\\p{N}_])(?:" + alternatives.map { "(\($0))" }.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
    return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}

/// True when the words differ (ignoring case) by exactly one insertion,
/// deletion, or substitution.
func isOneEditAway(_ a: String, _ b: String) -> Bool {
    isOneEditAway(Array(a.lowercased()), Array(b.lowercased()))
}

private func isOneEditAway(_ x: [Character], _ y: [Character]) -> Bool {
    guard abs(x.count - y.count) <= 1, x != y else { return false }
    var i = 0, j = 0, edits = 0
    while i < x.count, j < y.count {
        if x[i] == y[j] {
            i += 1; j += 1
            continue
        }
        edits += 1
        if edits > 1 { return false }
        if x.count > y.count { i += 1 } else if x.count < y.count { j += 1 } else { i += 1; j += 1 }
    }
    return edits + (x.count - i) + (y.count - j) <= 1
}

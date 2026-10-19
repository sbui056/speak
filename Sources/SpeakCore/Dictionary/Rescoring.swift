/// One finished stretch of recognized speech, with the recognizer's other
/// readings of it.
public struct RecognizedSegment: Equatable, Sendable {
    public let text: String
    /// Other readings, most likely first; never the top text.
    public let alternatives: [String]
    /// The recognizer's confidence (0–1) in each of the top text's words
    /// (`comparableWords`), or nil when unknown.
    public let confidences: [Double]?

    public init(text: String, alternatives: [String], confidences: [Double]? = nil) {
        self.text = text
        self.alternatives = alternatives
        self.confidences = confidences.flatMap { $0.count == comparableWords(text).count ? $0 : nil }
    }

    /// From the recognizer's runs (pieces of the top text with one confidence
    /// each). A word split across runs leaves the confidences unknown.
    public init(text: String, alternatives: [String], runs: [(text: String, confidence: Double?)]) {
        let perWord = runs.flatMap { run in Array(repeating: run.confidence ?? 1, count: comparableWords(run.text).count) }
        self.init(text: text, alternatives: alternatives, confidences: perWord)
    }
}

/// The transcript, with each segment's top reading swapped for the first
/// alternative that spells a dictionary term the top reading misheard. An
/// alternative is taken only when:
/// - it holds a term (whole words, any case) that the top reading lacks, and
///   loses none of the terms the top reading has;
/// - a word it changes lies inside that term, and it changes at most
///   2 × the term's words + 1 words, counting both sides;
/// - it doesn't repeat a word side by side where the top reading didn't ("the, the");
/// - for a term with no capital (an everyday word like "cache" or "main"), the
///   recognizer was unsure of every word it replaces (confidence below 0.95),
///   so speech that clearly said "cash" stays "cash".
/// Terms that compare as one character ("C++" → "c") never rescore: any lone
/// letter would match them.
public func rescore(_ segments: [RecognizedSegment], terms: [String]) -> String {
    let terms = terms.filter { comparableWords($0).joined().count > 1 }
        .map { RescoreTerm(words: comparableWords($0), hasCapital: $0.contains(where: \.isUppercase)) }
    return segments.reduce("") { text, segment in
        joinedTranscript(text, terms.isEmpty ? segment.text : bestReading(segment, terms: terms))
    }
}

/// Joins transcript pieces, adding a space only where neither side has one.
public func joinedTranscript(_ a: String, _ b: String) -> String {
    guard let last = a.last, let first = b.first else { return a + b }
    return last.isWhitespace || first.isWhitespace ? a + b : a + " " + b
}

/// Below this the recognizer counts as unsure of a word (lab: misheard words
/// median 0.62, correct ones 0.985).
private let lowConfidence = 0.95

private struct RescoreTerm {
    let words: [String]
    let hasCapital: Bool
}

private func bestReading(_ segment: RecognizedSegment, terms: [RescoreTerm]) -> String {
    let top = comparableWords(segment.text)
    let found = terms.map { (term: $0, count: occurrences(of: $0.words, in: top).count) }
    let missing = found.filter { $0.count == 0 }.map(\.term)
    let kept = found.filter { $0.count > 0 }
    guard !missing.isEmpty else { return segment.text }
    let topRepeats = adjacentRepeats(top)
    for alternative in segment.alternatives {
        let words = comparableWords(alternative)
        guard adjacentRepeats(words).isSubset(of: topRepeats),
              kept.allSatisfy({ occurrences(of: $0.term.words, in: words).count >= $0.count }) else { continue }
        let ops = alignWords(top, words)
        let changed = ops.filter { if case .same = $0 { false } else { true } }.count
        let inserted = ops.compactMap { if case .insert(let j) = $0 { j } else { nil } }
        let replaced = ops.compactMap { if case .delete(let i) = $0 { i } else { nil } }
        let unsure = segment.confidences.map { c in replaced.allSatisfy { c[$0] < lowConfidence } } ?? false
        for term in missing where changed <= 2 * term.words.count + 1 && (term.hasCapital || unsure) {
            let spans = occurrences(of: term.words, in: words)
            if inserted.contains(where: { j in spans.contains { $0.contains(j) } }) {
                return withOuterSpace(of: segment.text, alternative)
            }
        }
    }
    return segment.text
}

/// `text` trimmed, with `original`'s leading and trailing whitespace, so a
/// chosen alternative joins its neighbours as the top reading did.
private func withOuterSpace(of original: String, _ text: String) -> String {
    let leading = original.prefix(while: \.isWhitespace)
    let trailing = String(original.reversed().prefix(while: \.isWhitespace).reversed())
    let core = text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()
    return leading + String(core) + trailing
}

/// Where `phrase` occurs in `words`, as word ranges.
private func occurrences(of phrase: [String], in words: [String]) -> [Range<Int>] {
    guard !phrase.isEmpty, words.count >= phrase.count else { return [] }
    return (0...(words.count - phrase.count)).map { $0..<($0 + phrase.count) }
        .filter { words[$0].elementsEqual(phrase) }
}

private func adjacentRepeats(_ words: [String]) -> Set<String> {
    Set(zip(words, words.dropFirst()).filter { $0 == $1 }.map(\.0))
}

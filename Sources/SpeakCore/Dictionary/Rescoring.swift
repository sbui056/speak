/// One finished stretch of recognized speech, with the recognizer's other
/// readings of it.
public struct RecognizedSegment: Equatable, Sendable {
    public let text: String
    /// Other readings, most likely first; never the top text.
    public let alternatives: [String]

    public init(text: String, alternatives: [String]) {
        self.text = text
        self.alternatives = alternatives
    }
}

/// The transcript, with each segment's top reading swapped for the first
/// alternative that spells a dictionary term the top reading misheard. An
/// alternative is taken only when:
/// - it holds a term (whole words, any case) that the top reading lacks;
/// - a word it changes lies inside that term, and it changes at most
///   2 × the term's words + 1 words, counting both sides;
/// - it doesn't repeat a word side by side where the top reading didn't ("the, the").
public func rescore(_ segments: [RecognizedSegment], terms: [String]) -> String {
    let terms = terms.map(comparableWords).filter { !$0.isEmpty }
    return segments.reduce("") { text, segment in
        joinedTranscript(text, terms.isEmpty ? segment.text : bestReading(segment, terms: terms))
    }
}

/// Joins transcript pieces, adding a space only where neither side has one.
public func joinedTranscript(_ a: String, _ b: String) -> String {
    guard let last = a.last, let first = b.first else { return a + b }
    return last.isWhitespace || first.isWhitespace ? a + b : a + " " + b
}

private func bestReading(_ segment: RecognizedSegment, terms: [[String]]) -> String {
    let top = comparableWords(segment.text)
    let topRepeats = adjacentRepeats(top)
    for alternative in segment.alternatives {
        let words = comparableWords(alternative)
        guard adjacentRepeats(words).isSubset(of: topRepeats) else { continue }
        let ops = alignWords(top, words)
        let changed = ops.filter { if case .same = $0 { false } else { true } }.count
        let inserted = ops.compactMap { if case .insert(let j) = $0 { j } else { nil } }
        for term in terms where changed <= 2 * term.count + 1 && occurrences(of: term, in: top).isEmpty {
            let spans = occurrences(of: term, in: words)
            if inserted.contains(where: { j in spans.contains { $0.contains(j) } }) { return alternative }
        }
    }
    return segment.text
}

/// Where `phrase` occurs in `words`, as word ranges.
private func occurrences(of phrase: [String], in words: [String]) -> [Range<Int>] {
    guard !phrase.isEmpty, words.count >= phrase.count else { return [] }
    return (0...(words.count - phrase.count)).filter { Array(words[$0..<($0 + phrase.count)]) == phrase }
        .map { $0..<($0 + phrase.count) }
}

private func adjacentRepeats(_ words: [String]) -> Set<String> {
    Set(zip(words, words.dropFirst()).filter { $0 == $1 }.map(\.0))
}

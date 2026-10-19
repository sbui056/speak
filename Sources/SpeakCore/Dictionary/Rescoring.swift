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
/// - it holds a term (whole words, any case) that the top reading lacks, and
///   loses none of the terms the top reading has;
/// - a word it changes lies inside that term, and it changes at most
///   2 × the term's words + 1 words, counting both sides;
/// - it doesn't repeat a word side by side where the top reading didn't ("the, the").
/// Terms that compare as one character ("C++" → "c") never rescore: any lone
/// letter would match them.
public func rescore(_ segments: [RecognizedSegment], terms: [String]) -> String {
    let terms = terms.map(comparableWords).filter { $0.joined().count > 1 }
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
    let found = terms.map { (term: $0, count: occurrences(of: $0, in: top).count) }
    let missing = found.filter { $0.count == 0 }.map(\.term)
    let kept = found.filter { $0.count > 0 }
    guard !missing.isEmpty else { return segment.text }
    let topRepeats = adjacentRepeats(top)
    for alternative in segment.alternatives {
        let words = comparableWords(alternative)
        guard adjacentRepeats(words).isSubset(of: topRepeats),
              kept.allSatisfy({ occurrences(of: $0.term, in: words).count >= $0.count }) else { continue }
        let ops = alignWords(top, words)
        let changed = ops.filter { if case .same = $0 { false } else { true } }.count
        let inserted = ops.compactMap { if case .insert(let j) = $0 { j } else { nil } }
        for term in missing where changed <= 2 * term.count + 1 {
            let spans = occurrences(of: term, in: words)
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

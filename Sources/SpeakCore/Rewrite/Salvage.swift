import Foundation
import NaturalLanguage

/// A long Polished reply the keep guard turned down is often right but for one
/// sentence ("is going to be like" → "will be about"), and rejecting it throws
/// away every other sentence's cleanup after the user already waited for it.
/// This lines the reply up with the literal sentence by sentence and keeps each
/// stretch that passes the guard on its own; the rest stays as spoken. Nil when
/// there's nothing to keep: a malformed reply, a single sentence, no stretch that
/// passes, or a result that fails the full check.
public func salvageRewrite(_ output: String, literal: String, terms: [String], unknownWords: Set<String>,
                           language: String) -> String? {
    guard let cleaned = cleanedBlock(output) else { return nil }
    let heard = sentenceRanges(literal, language: language), wrote = sentenceRanges(cleaned, language: language)
    guard heard.count > 1, wrote.count > 1 else { return nil }

    let starts = groupStarts(heard.map { String(literal[$0]) }, wrote.map { String(cleaned[$0]) })
    guard starts.count > 1 else { return nil }
    let bounds = zip(starts, starts.dropFirst() + [(heard.count, wrote.count)])
    var result = "", keptAny = false, previousKept = false
    for ((h, w), (hEnd, wEnd)) in bounds {
        let spoken = String(literal[heard[h].lowerBound..<heard[hEnd - 1].upperBound])
        let written = String(cleaned[wrote[w].lowerBound..<wrote[wEnd - 1].upperBound])
        let keep = keepGuard(literal: spoken, cleaned: written, terms: terms, unknownWords: unknownWords,
                             language: language) == nil
        if h > 0 {
            // Between two kept stretches the reply's own break (maybe a paragraph); otherwise the spoken one.
            result += keep && previousKept ? String(cleaned[wrote[w - 1].upperBound..<wrote[w].lowerBound])
                : String(literal[heard[h - 1].upperBound..<heard[h].lowerBound])
        }
        result += keep ? written : spoken
        keptAny = keptAny || keep
        previousKept = keep
    }
    guard keptAny, result != literal,
          case .success(let text) = checkRewrite("<cleaned>\(result)</cleaned>", literal: literal, mode: .polished,
                                                 terms: terms, unknownWords: unknownWords, language: language)
    else { return nil }
    return text
}

/// Where the stretches start, as (literal sentence, reply sentence) pairs. A new
/// stretch starts where a literal sentence and a reply sentence begin with the
/// same aligned word (leading fillers aside), so merged or split sentences stay
/// in one stretch and no word pair crosses a boundary.
private func groupStarts(_ heard: [String], _ wrote: [String]) -> [(Int, Int)] {
    let words = { (sentences: [String]) in
        sentences.enumerated().flatMap { i, text in comparableWords(text).map { (sentence: i, word: $0) } }
    }
    let a = words(heard), b = words(wrote)
    let leadA = leadIndices(a), leadB = leadIndices(b)
    var starts = [(0, 0)]
    for case .same(let i, let j) in alignWords(a.map(\.word), b.map(\.word)) {
        guard let last = starts.last, leadA.contains(i), leadB.contains(j),
              a[i].sentence > last.0, b[j].sentence > last.1 else { continue }
        starts.append((a[i].sentence, b[j].sentence))
    }
    return starts
}

/// The index of each sentence's first word that isn't a filler.
private func leadIndices(_ words: [(sentence: Int, word: String)]) -> Set<Int> {
    var leads: Set<Int> = [], done: Set<Int> = []
    for (i, w) in words.enumerated() where !done.contains(w.sentence) && !droppable.contains(w.word) {
        leads.insert(i)
        done.insert(w.sentence)
    }
    return leads
}

/// Each sentence's range without the whitespace after it.
private func sentenceRanges(_ text: String, language: String) -> [Range<String.Index>] {
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    let code = Locale(identifier: language).language.languageCode?.identifier ?? language
    tokenizer.setLanguage(NLLanguage(rawValue: code))
    return tokenizer.tokens(for: text.startIndex..<text.endIndex).compactMap { range in
        var end = range.upperBound
        while end > range.lowerBound, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return end > range.lowerBound ? range.lowerBound..<end : nil
    }
}

import Foundation

/// "When Speak hears this, write that": for mishearings a term can't fix,
/// like "pool request" → "pull request".
public struct ReplacementPair: Codable, Equatable, Sendable {
    public let heard: String
    public let write: String

    public init(heard: String, write: String) {
        self.heard = heard
        self.write = write
    }
}

/// Replaces each "heard" phrase (whole words, any case, any whitespace between
/// its words) with its "write" text. Longest first, one pass over the original
/// text, so a replacement is never replaced again. A capitalized match at the
/// start of a sentence keeps its capital when "write" is all lowercase ("Pool
/// request" → "Pull request"); otherwise "write" is used exactly as typed, since
/// a capital mid-sentence is the recognizer guessing a name ("Jason" → "json").
/// A leading context word both sides share keeps its spoken text ("The read
/// me" → "The README" for "the read me" → "the README").
public func applyPairs(_ text: String, pairs: [ReplacementPair]) -> String {
    guard !pairs.isEmpty, !text.isEmpty else { return text }
    let (byLength, pattern) = termPattern(pairs.map(\.heard))
    // "heard" is unique ignoring case, so each matched phrase has one "write".
    let writes = Dictionary(pairs.map { ($0.heard.lowercased(), $0.write) }, uniquingKeysWith: { first, _ in first })
    guard let regex = pattern else { return text }
    let ns = text as NSString
    let result = NSMutableString(string: text)
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
        guard let heard = matchedPhrase(match, in: byLength), var write = writes[heard.lowercased()] else { continue }
        let spoken = ns.substring(with: match.range)
        if let shared = firstWord(heard), let own = firstWord(write), shared.caseInsensitiveCompare(own) == .orderedSame,
           let said = firstWord(spoken) {
            write = said + write.dropFirst(own.count)
        } else if spoken.first?.isUppercase == true, !write.contains(where: \.isUppercase),
           startsSentence(ns.substring(to: match.range.location)) {
            write = write.prefix(1).uppercased() + write.dropFirst()
        }
        result.replaceCharacters(in: match.range, with: write)
    }
    return result as String
}

/// The text before the first space, or nil when there is no space.
private func firstWord(_ phrase: String) -> String? {
    phrase.firstIndex(where: \.isWhitespace).map { String(phrase[..<$0]) }
}

/// True when `before` is empty or ends a sentence (., !, ?), ignoring spaces.
private func startsSentence(_ before: String) -> Bool {
    guard let last = before.last(where: { !$0.isWhitespace }) else { return true }
    return ".!?".contains(last)
}

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
public func applyPairs(_ text: String, pairs: [ReplacementPair]) -> String {
    guard !pairs.isEmpty, !text.isEmpty else { return text }
    let (byLength, pattern) = termPattern(pairs.map(\.heard))
    // "heard" is unique ignoring case, so each matched phrase has one "write".
    let writes = Dictionary(pairs.map { ($0.heard.lowercased(), $0.write) }, uniquingKeysWith: { first, _ in first })
    guard let regex = pattern else { return text }
    let ns = text as NSString
    let result = NSMutableString(string: text)
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
        guard let group = (1..<match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound })
        else { continue }
        guard var write = writes[byLength[group - 1].lowercased()] else { continue }
        if ns.substring(with: match.range).first?.isUppercase == true, !write.contains(where: \.isUppercase),
           startsSentence(ns.substring(to: match.range.location)) {
            write = write.prefix(1).uppercased() + write.dropFirst()
        }
        result.replaceCharacters(in: match.range, with: write)
    }
    return result as String
}

/// True when `before` is empty or ends a sentence (., !, ?), ignoring spaces.
private func startsSentence(_ before: String) -> Bool {
    guard let last = before.last(where: { !$0.isWhitespace }) else { return true }
    return ".!?".contains(last)
}

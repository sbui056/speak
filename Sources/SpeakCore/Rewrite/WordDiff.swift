/// One run of the preview's word diff. Each word keeps the whitespace that
/// followed it, so the rewrite's paragraph breaks survive.
public enum DiffSegment: Equatable, Sendable {
    case same(String)
    case inserted(String)
    case deleted(String)
}

/// A word-level diff from `old` to `new` (longest common subsequence), with
/// adjacent words of the same kind merged. Words compare exactly, so a casing
/// or punctuation change shows as a replacement.
public func wordDiff(from old: String, to new: String) -> [DiffSegment] {
    let a = tokens(old), b = tokens(new)
    var out: [DiffSegment] = []
    func append(_ segment: DiffSegment) {
        switch (out.last, segment) {
        case (.same(let x)?, .same(let y)): out[out.count - 1] = .same(x + y)
        case (.inserted(let x)?, .inserted(let y)): out[out.count - 1] = .inserted(x + y)
        case (.deleted(let x)?, .deleted(let y)): out[out.count - 1] = .deleted(x + y)
        default: out.append(segment)
        }
    }
    for op in alignWords(a.map(\.word), b.map(\.word)) {
        switch op {
        case .same(_, let j): append(.same(b[j].text))
        case .delete(let i): append(.deleted(a[i].text))
        case .insert(let j): append(.inserted(b[j].text))
        }
    }
    return out
}

/// One step of a word alignment: a word kept (index in each list), dropped
/// from the first list, or added from the second.
public enum AlignOp: Equatable, Sendable {
    case same(Int, Int)
    case delete(Int)
    case insert(Int)
}

/// Aligns two word lists by their longest common subsequence. On a tie the
/// deletion goes first, so a replacement reads "old → new".
public func alignWords<Word: Equatable>(_ a: [Word], _ b: [Word]) -> [AlignOp] {
    // lcs[i][j] = common subsequence length of a[i...] and b[j...].
    var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
        }
    }
    var ops: [AlignOp] = []
    var i = 0, j = 0
    while i < a.count || j < b.count {
        if i < a.count, j < b.count, a[i] == b[j] {
            ops.append(.same(i, j)); i += 1; j += 1
        } else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] {
            ops.append(.delete(i)); i += 1
        } else {
            ops.append(.insert(j)); j += 1
        }
    }
    return ops
}

private struct Token {
    let word: Substring
    /// The word plus the whitespace after it (a single space for the last word,
    /// so a deleted last word still reads apart from what follows).
    let text: String
}

private func tokens(_ text: String) -> [Token] {
    var result: [Token] = []
    var index = text.startIndex
    while index < text.endIndex {
        guard let start = text[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
        let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
        let next = text[end...].firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
        let gap = next == text.endIndex ? " " : String(text[end..<next])
        result.append(Token(word: text[start..<end], text: String(text[start..<end]) + gap))
        index = next
    }
    return result
}

/// What the preview panel shows.
public struct PreviewContent: Equatable, Sendable {
    public let id: SessionID
    public let mode: RewriteMode
    public let literal: String
    public let rewrite: String
    public let diff: [DiffSegment]

    public init(id: SessionID, mode: RewriteMode, literal: String, rewrite: String) {
        self.id = id
        self.mode = mode
        self.literal = literal
        self.rewrite = rewrite
        diff = wordDiff(from: literal, to: rewrite)
    }
}

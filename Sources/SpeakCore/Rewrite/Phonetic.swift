/// A rough sound key for an English word (Metaphone-like): what the speech
/// recognizer might have confused it with sounds the same. "cash" and "cache"
/// both give "KX"; "Thursday" gives "0RST" and "Tuesday" "XST".
func phoneticKey(_ word: String) -> String {
    let w = Array(word.lowercased().filter { ("a"..."z").contains($0) })
    var out: [Character] = []
    var i = 0
    outer: while i < w.count {
        for (pattern, sound) in digraphs where matches(w, at: i, pattern) {
            out.append(contentsOf: sound)
            i += pattern.count
            continue outer
        }
        let c = w[i]
        i += 1
        if "aeiou".contains(c) {
            // Only a word-initial vowel counts, and it's dropped again below.
            if out.isEmpty && i == 1 { out.append("A") }
            continue
        }
        if let sound = letterSounds[c] { out.append(contentsOf: sound) } else { out.append(contentsOf: c.uppercased()) }
    }
    var key: [Character] = []
    for c in out where key.last != c { key.append(c) }
    let trimmed = key.drop(while: { $0 == "A" })
    return trimmed.isEmpty ? String(key) : String(trimmed)
}

/// True when the words heard and the words meant sound close enough to be a
/// mishearing: the joined keys are within a weighted edit distance of
/// max(1, 40% of the longer key) and share at least 60% of the shorter one.
/// A one-sound key ("tough" → "T") must match exactly: one sound says too little.
func soundsAlike(_ heard: [String], _ meant: [String]) -> Bool {
    let a = Array(heard.map(phoneticKey).joined()), b = Array(meant.map(phoneticKey).joined())
    let shorter = min(a.count, b.count), longer = max(a.count, b.count)
    guard shorter >= 1 else { return false }
    if shorter == 1 { return a == b }
    return weightedDistance(a, b) <= max(1, 0.4 * Double(longer))
        && Double(commonSubsequence(a, b)) >= 0.6 * Double(shorter)
}

// Ordered: longer patterns first where they overlap.
private let digraphs: [(String, String)] = [
    ("tion", "XN"), ("sion", "XN"), ("ture", "XR"), ("tu", "X"), ("ch", "X"), ("sh", "X"), ("ph", "F"),
    ("th", "0"), ("ck", "K"), ("qu", "K"), ("gh", ""), ("wh", "W"), ("kn", "N"), ("wr", "R"), ("ce", "S"),
    ("ci", "S"), ("cy", "S"), ("ge", "J"), ("gi", "J"), ("x", "KS"),
]

private let letterSounds: [Character: String] = [
    "c": "K", "g": "K", "q": "K", "z": "S", "d": "T", "b": "P", "v": "F", "j": "J", "y": "",
]

/// Sounds the recognizer confuses: a substitution between them costs half.
private let nearSounds: Set<Set<Character>> = [
    ["X", "T"], ["X", "S"], ["S", "T"], ["N", "L"], ["R", "L"], ["M", "N"], ["K", "T"], ["F", "0"],
]

private func matches(_ w: [Character], at i: Int, _ pattern: String) -> Bool {
    let p = Array(pattern)
    return i + p.count <= w.count && Array(w[i..<(i + p.count)]) == p
}

private func weightedDistance(_ a: [Character], _ b: [Character]) -> Double {
    var previous = (0...b.count).map(Double.init)
    for i in a.indices {
        var current = [Double(i + 1)] + Array(repeating: 0, count: b.count)
        for j in b.indices {
            let cost: Double = a[i] == b[j] ? 0 : nearSounds.contains([a[i], b[j]]) ? 0.5 : 1
            current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
        }
        previous = current
    }
    return previous[b.count]
}

private func commonSubsequence(_ a: [Character], _ b: [Character]) -> Int {
    alignWords(a, b).filter { if case .same = $0 { true } else { false } }.count
}

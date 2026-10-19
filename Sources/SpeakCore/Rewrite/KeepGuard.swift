import Foundation

/// Why the keep guard turned down a Polished reply. Logged by name only.
public enum KeepFailure: String, Equatable, Sendable {
    /// A number, day, month, time, name, acronym, dictionary term, or word the
    /// spell checker doesn't know went missing or changed.
    case lostProtected
    /// A number, day, month, or time appeared that wasn't spoken.
    case addedProtected
    /// A "not", "no", "never", or "n't" was added or dropped.
    case negation
    /// A word was replaced by one that neither sounds like it nor is a grammar fix.
    case unrelated
    /// More sound-alike fixes than max(2, words / 10).
    case tooManyFixes
}

/// Lets Polished fix mishearings and grammar but nothing else (invariant 7).
/// The reply is aligned with the literal word by word; protected words must
/// survive, and each changed stretch must be a filler or grammar change, an
/// inflection, a join or split ("follow up" → "follow-up"), or a word that
/// sounds like the one replaced. Outside English only the language-neutral
/// protections apply (digits, terms, acronyms, unknown words).
/// `unknownWords` are the literal's words the spell checker doesn't know,
/// lowercased with apostrophes removed.
func keepGuard(literal: String, cleaned: String, terms: [String], unknownWords: Set<String>,
               language: String) -> KeepFailure? {
    let english = language.lowercased().hasPrefix("en")
    let before = keepTokens(literal, english: english), after = keepTokens(cleaned, english: english)

    let (heardNumbers, wroteNumbers) = (numberDigits(before), numberDigits(after))
    if heardNumbers != wroteNumbers {
        return wroteNumbers.count > heardNumbers.count ? .addedProtected : .lostProtected
    }
    if english {
        let (heardTimes, wroteTimes) = (calendarWords(before), calendarWords(after))
        if !heardTimes.isSubset(of: wroteTimes) { return .lostProtected }
        if !wroteTimes.isSubset(of: heardTimes) { return .addedProtected }
    }
    let present = presentForms(after)
    let termKeys = terms.map(comparableWords).filter { !$0.isEmpty }
    for term in termKeys where contains(before.map(\.key), term) {
        if !contains(after.map(\.key), term) && !present.contains(term.joined()) { return .lostProtected }
    }
    for (i, token) in before.enumerated() where isProtected(token, english: english, unknownWords: unknownWords) {
        let joins = [i > 0 ? before[i - 1].base + token.base : nil, i + 1 < before.count ? token.base + before[i + 1].base : nil]
        if !present.contains(token.base) && !joins.contains(where: { $0.map(present.contains) == true }) {
            return .lostProtected
        }
    }
    guard english else { return nil }
    if negations(before) != negations(after) { return .negation }

    var fixes = 0
    for run in changedRuns(before.map(\.key), after.map(\.key)) {
        switch classify(run.deleted, run.inserted) {
        case .grammar: continue
        case .soundAlike: fixes += 1
        case .unrelated: return .unrelated
        }
    }
    return fixes > max(2, before.count / 10) ? .tooManyFixes : nil
}

/// The literal's distinct words the spell checker doesn't know, as the keep
/// guard's `unknownWords`. Words are checked as written ("don't", "Sarah's").
@MainActor
public func unknownWords(in literal: String, spelling: any SpellChecker, language: String) -> Set<String> {
    var seen: Set<String> = [], unknown: Set<String> = []
    for token in keepTokens(literal, english: false) where !token.isNumber && seen.insert(token.key).inserted {
        if spelling.isMisspelled(token.raw, language: language) { unknown.insert(token.base) }
    }
    return unknown
}

// MARK: Tokens

private struct KeepToken {
    /// As written, without surrounding punctuation.
    let raw: String
    /// Lowercased letters and digits ("Don't" → "dont"); a number run is one key ("#230").
    let key: String
    /// `key` without a possessive ("Sarah's" → "sarah").
    let base: String
    let startsSentence: Bool
    let isNumber: Bool
}

/// Words and digit runs. Hyphenated words split ("follow-up" → "follow", "up");
/// in English, spoken numbers and digits become one token per run of numbers,
/// keyed by their digits ("two thirty" and "2:30" both "#230").
private func keepTokens(_ text: String, english: Bool) -> [KeepToken] {
    let ns = text as NSString
    var tokens: [KeepToken] = []
    var lastEnd = 0
    for match in tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let raw = ns.substring(with: match.range)
        let gap = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
        lastEnd = match.range.location + match.range.length
        let startsSentence = tokens.isEmpty || gap.contains(where: { ".!?\n".contains($0) })
        let key = String(raw.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !key.isEmpty, key != "oclock" else { continue }
        var base = raw.lowercased()
        for suffix in ["'s", "’s"] where base.hasSuffix(suffix) { base = String(base.dropLast(2)) }
        tokens.append(KeepToken(raw: raw, key: key, base: String(base.filter { $0.isLetter || $0.isNumber }),
                                startsSentence: startsSentence, isNumber: key.allSatisfy(\.isNumber)))
    }
    return mergeNumbers(tokens, spoken: english)
}

private let tokenPattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{M}]+(?:['’][\\p{L}\\p{M}]+)*|\\p{N}+")

private func mergeNumbers(_ tokens: [KeepToken], spoken: Bool) -> [KeepToken] {
    var out: [KeepToken] = []
    var i = 0
    while i < tokens.count {
        var j = i
        while j < tokens.count, isNumberToken(tokens, j, spoken: spoken) { j += 1 }
        if j == i {
            out.append(tokens[i])
            i += 1
            continue
        }
        // ":00" after an hour is how "four o'clock" is written.
        let run = tokens[i..<j].enumerated().filter { $0.offset == 0 || $0.element.key != "00" }.map(\.element)
        let digits = "#" + spokenDigits(run.map(\.key))
        out.append(KeepToken(raw: tokens[i..<j].map(\.raw).joined(separator: " "), key: digits, base: digits,
                             startsSentence: tokens[i].startsSentence, isNumber: true))
        i = j
    }
    return out
}

/// A digit run, or (in English) a number word; "oh" counts only next to another number.
private func isNumberToken(_ tokens: [KeepToken], _ i: Int, spoken: Bool) -> Bool {
    let key = tokens[i].key
    if tokens[i].isNumber { return true }
    guard spoken else { return false }
    if key == "oh" {
        let neighbour = { (j: Int) in tokens.indices.contains(j) && (tokens[j].isNumber || numberValues[tokens[j].key] != nil) }
        return neighbour(i - 1) || neighbour(i + 1)
    }
    return numberValues[key] != nil
}

private let numberValues: [String: Int] = {
    var values: [String: Int] = ["oh": 0, "hundred": 100, "thousand": 1000]
    let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    for (n, word) in ones.enumerated() { values[word] = n }
    for (n, word) in ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() {
        values[word] = (n + 2) * 10
    }
    return values
}()

/// The digits a run of numbers is written with: "twenty five" → "25",
/// "five five five oh one" → "55501", "two thirty" → "230", "one hundred five" → "105".
private func spokenDigits(_ keys: [String]) -> String {
    var out = "", current: Int?, last = 0
    func flush() {
        if let value = current { out += String(value) }
        current = nil
    }
    for key in keys {
        guard let value = numberValues[key] else {
            flush()
            out += key // written digits, leading zeros kept
            last = 0
            continue
        }
        // "twenty" + "five", "hundred" + "five"/"fifteen"/"thirty" add up; anything else starts a new number.
        let adds = (value < 10 && last >= 20 && last % 10 == 0) || (value < 100 && last >= 100)
        if value == 100 || value == 1000 {
            current = (current ?? 1) * value
        } else if adds, let sum = current {
            current = sum + value
        } else {
            flush()
            current = value
        }
        last = value
    }
    flush()
    return out
}

// MARK: Protected words

private func numberDigits(_ tokens: [KeepToken]) -> String {
    tokens.filter(\.isNumber).map { String($0.key.dropFirst()) }.joined()
}

private let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
private let months: Set<String> = ["january", "february", "april", "june", "july", "august", "september",
                                   "october", "november", "december"]

/// Days, months, noon/midnight, and am/pm after a number. "May" and "March"
/// count only capitalized, since they're also ordinary words.
private func calendarWords(_ tokens: [KeepToken]) -> Set<String> {
    var found: Set<String> = []
    for (i, token) in tokens.enumerated() {
        let key = token.key
        let capital = token.raw.first?.isUppercase == true
        if weekdays.contains(key) || months.contains(key) || key == "noon" || key == "midnight"
            || (capital && (key == "may" || key == "march"))
            || ((key == "am" || key == "pm") && i > 0 && tokens[i - 1].isNumber) {
            found.insert(key)
        }
    }
    return found
}

/// Acronyms and mixed case ("API", "iOS"), unknown words, and in English names:
/// capitalized words that don't start a sentence.
private func isProtected(_ token: KeepToken, english: Bool, unknownWords: Set<String>) -> Bool {
    if token.isNumber { return false }
    if unknownWords.contains(token.key) || unknownWords.contains(token.base) { return true }
    let letters = token.raw.filter(\.isLetter)
    guard letters.count >= 2, !["ok", "okay"].contains(token.key) else { return false }
    if letters.dropFirst().contains(where: \.isUppercase) { return true }
    guard english, letters.first?.isUppercase == true, !token.startsSentence else { return false }
    return !["i", "im", "ill", "ive", "id"].contains(token.key)
}

/// Every word form in the reply, plus each pair of neighbours joined, so a
/// join ("swift UI" → "SwiftUI") or a split still counts as kept.
private func presentForms(_ tokens: [KeepToken]) -> Set<String> {
    var forms = Set(tokens.map(\.base)).union(tokens.map(\.key))
    for (a, b) in zip(tokens, tokens.dropFirst()) { forms.insert(a.base + b.base) }
    return forms
}

private func negations(_ tokens: [KeepToken]) -> Int {
    tokens.filter { ["not", "no", "never", "cannot"].contains($0.key) || $0.raw.lowercased().hasSuffix("n't")
        || $0.raw.lowercased().hasSuffix("n’t") }.count
}

private func contains(_ words: [String], _ phrase: [String]) -> Bool {
    guard !phrase.isEmpty, words.count >= phrase.count else { return false }
    return (0...(words.count - phrase.count)).contains { words[$0..<($0 + phrase.count)].elementsEqual(phrase) }
}

// MARK: Changes

private func changedRuns(_ a: [String], _ b: [String]) -> [(deleted: [String], inserted: [String])] {
    var runs: [(deleted: [String], inserted: [String])] = []
    var deleted: [String] = [], inserted: [String] = []
    for op in alignWords(a, b) {
        switch op {
        case .same:
            if !deleted.isEmpty || !inserted.isEmpty { runs.append((deleted, inserted)) }
            deleted = []
            inserted = []
        case .delete(let i): deleted.append(a[i])
        case .insert(let j): inserted.append(b[j])
        }
    }
    if !deleted.isEmpty || !inserted.isEmpty { runs.append((deleted, inserted)) }
    return runs
}

private enum ChangeKind { case grammar, soundAlike, unrelated }

/// Fillers and function words don't count; what's left must match, be an
/// inflection or a join/split, or sound alike (at most three words a side).
private func classify(_ deleted: [String], _ inserted: [String]) -> ChangeKind {
    let content = { (words: [String]) in
        words.flatMap { contractions[$0] ?? [$0] }.filter { !droppable.contains($0) && !functionWords.contains($0) }
    }
    let heard = content(deleted), wrote = content(inserted)
    if wrote.isEmpty || heard == wrote || heard.joined() == wrote.joined() { return .grammar }
    if heard.isEmpty { return .unrelated }
    if heard.count == wrote.count, zip(heard, wrote).allSatisfy(isInflection) { return .grammar }
    if heard.count <= 3, wrote.count <= 3, soundsAlike(heard, wrote) { return .soundAlike }
    return .unrelated
}

private func isInflection(_ a: String, _ b: String) -> Bool {
    let (short, long) = a.count <= b.count ? (a, b) : (b, a)
    return long.hasPrefix(short) && ["s", "es", "d", "ed", "ing"].contains(String(long.dropFirst(short.count)))
}

private let contractions: [String: [String]] = [
    "dont": ["do", "not"], "doesnt": ["does", "not"], "didnt": ["did", "not"], "isnt": ["is", "not"],
    "arent": ["are", "not"], "wasnt": ["was", "not"], "werent": ["were", "not"], "cant": ["can", "not"],
    "cannot": ["can", "not"], "wont": ["will", "not"], "wouldnt": ["would", "not"], "shouldnt": ["should", "not"],
    "couldnt": ["could", "not"], "havent": ["have", "not"], "hasnt": ["has", "not"], "hadnt": ["had", "not"],
    "im": ["i", "am"], "ive": ["i", "have"], "ill": ["i", "will"], "id": ["i", "would"], "youre": ["you", "are"],
    "theyre": ["they", "are"], "its": ["it", "is"], "thats": ["that", "is"], "lets": ["let", "us"],
    "gonna": ["going", "to"], "wanna": ["want", "to"], "gotta": ["got", "to"], "kinda": ["kind", "of"],
]

/// Articles, pronouns, auxiliaries, prepositions, conjunctions: grammar fixes
/// add, drop, or swap these freely. Negations are counted separately.
private let functionWords: Set<String> = [
    "a", "an", "the", "this", "that", "these", "those", "i", "me", "my", "mine", "you", "your", "yours", "he", "him",
    "his", "she", "her", "hers", "it", "its", "we", "us", "our", "ours", "they", "them", "their", "theirs",
    "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "have", "has", "had", "will",
    "would", "shall", "should", "can", "could", "might", "must", "to", "of", "in", "on", "at", "by", "for",
    "with", "from", "into", "onto", "about", "as", "than", "then", "and", "or", "but", "if", "because", "while",
    "there", "here", "also", "too", "very", "let", "not", "no", "never",
]

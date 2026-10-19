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
        if !containsAllowingInflection(after.map(\.key), term) && !present.contains(term.joined()) { return .lostProtected }
    }
    for (i, token) in before.enumerated() where isProtected(token, english: english, unknownWords: unknownWords) {
        let joins = [i > 0 ? before[i - 1].base + token.base : nil, i + 1 < before.count ? token.base + before[i + 1].base : nil]
        if !present.contains(token.base) && !joins.contains(where: { $0.map(present.contains) == true }) {
            return .lostProtected
        }
    }
    guard english else { return nil }
    if negations(before) != negations(after) { return .negation }

    // A capitalized word may be a name: never "fixed" as a sound-alike.
    let capitalized = Set(before.filter { $0.raw.first?.isUppercase == true && !["i", "im", "ill", "ive", "id"].contains($0.key) }
        .map(\.key))
    let kept = Set(after.map(\.key))
    var fixes = 0
    for run in changedRuns(before.map(\.key), after.map(\.key)) {
        switch classify(run.deleted, run.inserted, keptWords: kept, capitalized: capitalized) {
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
    Set(spelling.misspelledWords(in: literal, language: language).flatMap { keepTokens($0, english: false).map(\.base) })
}

extension SpellChecker {
    @MainActor public func misspelledWords(in text: String, language: String) -> [String] {
        var seen: Set<String> = []
        return keepTokens(text, english: false)
            .filter { !$0.isNumber && seen.insert($0.key).inserted && isMisspelled($0.raw, language: language) }
            .map(\.raw)
    }
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
    /// Punctuation between this token and the one before ("," ".").
    let breaksFromPrevious: Bool
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
        // "1st", "22nd": the suffix belongs to the number.
        if gap.isEmpty, tokens.last?.isNumber == true, ["st", "nd", "rd", "th"].contains(key) { continue }
        let breaks = gap.contains(where: { ".,;!?\n".contains($0) })
        // "noon" is written "12 PM" just as often.
        if english, let time = ["noon": "pm", "midnight": "am"][key] {
            tokens.append(KeepToken(raw: raw, key: "12", base: "12", startsSentence: startsSentence, isNumber: true,
                                    breaksFromPrevious: breaks))
            tokens.append(KeepToken(raw: raw, key: time, base: time, startsSentence: false, isNumber: false,
                                    breaksFromPrevious: false))
            continue
        }
        var base = raw.lowercased()
        for suffix in ["'s", "’s"] where base.hasSuffix(suffix) { base = String(base.dropLast(2)) }
        tokens.append(KeepToken(raw: raw, key: key, base: String(base.filter { $0.isLetter || $0.isNumber }),
                                startsSentence: startsSentence, isNumber: key.allSatisfy(\.isNumber),
                                breaksFromPrevious: breaks))
    }
    return mergeNumbers(tokens, spoken: english)
}

private let tokenPattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{M}]+(?:['’][\\p{L}\\p{M}]+)*|\\p{N}+")

private func mergeNumbers(_ tokens: [KeepToken], spoken: Bool) -> [KeepToken] {
    var out: [KeepToken] = []
    var i = 0
    while i < tokens.count {
        var j = i
        while j < tokens.count, isNumberToken(tokens, j, spoken: spoken),
              j == i || !tokens[j].breaksFromPrevious || (tokens[j - 1].isNumber && tokens[j].isNumber) {
            j += 1
        }
        if j == i {
            out.append(tokens[i])
            i += 1
            continue
        }
        // ":00" after an hour is how "four o'clock" is written.
        let run = tokens[i..<j].enumerated().filter { $0.offset == 0 || $0.element.key != "00" }.map(\.element)
        let digits = "#" + spokenDigits(run.map(\.key))
        out.append(KeepToken(raw: tokens[i..<j].map(\.raw).joined(separator: " "), key: digits, base: digits,
                             startsSentence: tokens[i].startsSentence, isNumber: true,
                             breaksFromPrevious: tokens[i].breaksFromPrevious))
        i = j
    }
    return out
}

/// A digit run, or (in English) a number word; "oh" counts only right after
/// another number ("five oh one"), never as "Oh, one more thing".
private func isNumberToken(_ tokens: [KeepToken], _ i: Int, spoken: Bool) -> Bool {
    let key = tokens[i].key
    if tokens[i].isNumber { return true }
    guard spoken else { return false }
    if key == "oh" {
        return i > 0 && !tokens[i].breaksFromPrevious
            && (tokens[i - 1].isNumber || numberValues[tokens[i - 1].key] != nil)
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
    // Ordinals, so "first" and "1st" are the same number.
    let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
                    "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
                    "eighteenth", "nineteenth"]
    for (n, word) in ordinals.enumerated() { values[word] = n + 1 }
    for (n, word) in ["twentieth", "thirtieth"].enumerated() { values[word] = (n + 2) * 10 }
    return values
}()

/// The digits a run of numbers is written with: "twenty five" → "25",
/// "five five five oh one" → "55501", "two thirty" → "230", "one hundred five" → "105",
/// "two thousand five hundred" → "2500".
private func spokenDigits(_ keys: [String]) -> String {
    var out = "", total = 0, group = 0, active = false, last = 0
    func flush() {
        if active { out += String(total + group) }
        (total, group, active) = (0, 0, false)
    }
    for key in keys {
        guard let value = numberValues[key] else {
            flush()
            out += key // written digits, leading zeros kept
            last = 0
            continue
        }
        // "twenty" + "five" and "hundred" + "five"/"fifteen"/"thirty" add up; anything else starts a new number.
        let adds = (value < 10 && last >= 20 && last % 10 == 0) || (value < 100 && last >= 100)
        if value == 1000 {
            total += max(group, 1) * 1000
            group = 0
        } else if value == 100 {
            group = max(group, 1) * 100
        } else if active && adds {
            group += value
        } else {
            flush()
            group = value
        }
        active = true
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

private let negationWords: Set<String> = ["not", "no", "never", "cannot", "nothing", "nobody", "none", "neither",
                                          "nor", "nowhere", "without"]

private func negations(_ tokens: [KeepToken]) -> Int {
    tokens.filter { negationWords.contains($0.key) || $0.raw.lowercased().hasSuffix("n't")
        || $0.raw.lowercased().hasSuffix("n’t") }.count
}

/// `phrase` in `words`, its last word possibly inflected ("deploy" → "deploys",
/// "pull request" → "pull requests").
private func containsAllowingInflection(_ words: [String], _ phrase: [String]) -> Bool {
    guard let last = phrase.last, words.count >= phrase.count else { return false }
    return (0...(words.count - phrase.count)).contains { start in
        let window = words[start..<(start + phrase.count)]
        return window.dropLast().elementsEqual(phrase.dropLast())
            && (window.last == last || isInflection(window.last ?? "", last))
    }
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

/// Fillers don't count. Function words may be added or dropped, or swapped
/// only for agreement ("is" → "are"); content words may be dropped only if they
/// still appear elsewhere (a repeated false start). What's left must match, be
/// an inflection or a join/split, or sound alike (at most three words a side,
/// not a capitalized word, not an antonym like "increase" → "decrease").
private func classify(_ deleted: [String], _ inserted: [String], keptWords: Set<String>,
                      capitalized: Set<String>) -> ChangeKind {
    if deleted.joined() == inserted.joined() { return .grammar }
    let expand = { (words: [String]) in words.flatMap { contractions[$0] ?? [$0] }.filter { !fillers.contains($0) } }
    let heardAll = expand(deleted), wroteAll = expand(inserted)
    let heard = heardAll.filter { !functionWords.contains($0) }, wrote = wroteAll.filter { !functionWords.contains($0) }
    let heardFunction = heardAll.filter(functionWords.contains), wroteFunction = wroteAll.filter(functionWords.contains)
    let functionsAgree = isSubmultiset(heardFunction, of: wroteFunction) || isSubmultiset(wroteFunction, of: heardFunction)
        || heardFunction.map(agreementGroup).sorted() == wroteFunction.map(agreementGroup).sorted()
    let mayFix = !deleted.contains(where: capitalized.contains) && !isAntonymSwap(deleted, inserted)
    // The same digits written another way ("one on one" → "1:1"); the number check has the values.
    let digits = { (words: [String]) in words.allSatisfy { $0.hasPrefix("#") } ? words.map { $0.dropFirst() }.joined() : nil }
    if !heard.isEmpty, let h = digits(heard), h == digits(wrote) { return .grammar }

    if functionsAgree {
        if heard == wrote { return .grammar }
        if wrote.isEmpty {
            if heard.allSatisfy(keptWords.contains) { return .grammar }
        } else if !heard.isEmpty {
            if heard.count == wrote.count, zip(heard, wrote).allSatisfy(isInflection) { return .grammar }
            if mayFix, heard.count <= 3, wrote.count <= 3, soundsAlike(heard, wrote) { return .soundAlike }
        }
    }
    // A mishearing can span small words: "it's called" → "to call".
    if mayFix, !heard.isEmpty || !wrote.isEmpty, deleted.count <= 3, inserted.count <= 3, soundsAlike(deleted, inserted) {
        return .soundAlike
    }
    return .unrelated
}

private func isSubmultiset(_ a: [String], of b: [String]) -> Bool {
    var remaining = b
    for word in a {
        guard let i = remaining.firstIndex(of: word) else { return false }
        remaining.remove(at: i)
    }
    return true
}

/// Concise's droppable words minus the function words, which are checked on their own.
private let fillers = droppable.subtracting(functionWords)

/// Function words a grammar fix may swap for one another.
private func agreementGroup(_ word: String) -> String {
    switch word {
    case "is", "are", "am", "be": "be"
    case "was", "were": "was"
    case "a", "an", "the": "a"
    case "has", "have": "have"
    case "do", "does": "do"
    default: word
    }
}

/// Opposites that sound alike enough to pass as a mishearing.
private let antonyms: [(String, String)] = [
    ("increase", "decrease"), ("include", "exclude"), ("accept", "except"), ("merge", "purge"), ("enable", "disable"),
    ("add", "remove"), ("hire", "fire"), ("import", "export"), ("input", "output"), ("inbound", "outbound"),
    ("upload", "download"), ("encrypt", "decrypt"), ("inflate", "deflate"), ("ascending", "descending"),
]

private func isAntonymSwap(_ heard: [String], _ wrote: [String]) -> Bool {
    let form = { (word: String, base: String) in word == base || isInflection(word, base) }
    return heard.contains { h in
        wrote.contains { w in antonyms.contains { (form(h, $0.0) && form(w, $0.1)) || (form(h, $0.1) && form(w, $0.0)) } }
    }
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
    "hes": ["he", "is"], "shes": ["she", "is"], "whats": ["what", "is"], "theres": ["there", "is"],
    "heres": ["here", "is"], "wheres": ["where", "is"], "whos": ["who", "is"], "hows": ["how", "is"],
    "itll": ["it", "will"], "thatll": ["that", "will"], "theyll": ["they", "will"], "youll": ["you", "will"],
    "weve": ["we", "have"], "theyve": ["they", "have"], "youve": ["you", "have"], "theyd": ["they", "would"],
    "youd": ["you", "would"], "wouldve": ["would", "have"], "couldve": ["could", "have"],
    "shouldve": ["should", "have"],
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
    "there", "here", "also", "too", "very", "let", "not", "no", "never", "what", "who", "how", "where",
]

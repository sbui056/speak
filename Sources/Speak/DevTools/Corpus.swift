#if DEBUG
import AppKit
import SpeakCore

/// Debug builds only, for `scripts/corpus.sh`: `SPEAK_CORPUS=<file.json>` runs each
/// fixed dictation through the real model in Concise and Polished, exactly as a
/// session would (prompt, model, guard), prints one result per line, and quits.
struct Corpus {
    struct Case: Decodable {
        let id: String
        let text: String
        /// Words the cleaned text must keep (`three|3` accepts either); losing one means meaning was dropped.
        let keep: [String]
        /// Words that mean the model answered or obeyed instead of cleaning up.
        var reject: [String]?
        var terms: [String]?
        /// Words a Polished fix of a mishearing should produce; missing ones make the
        /// verdict `unfixed` (informational, not a failure).
        var fix: [String]?
        /// The dictation language, as a session passes it (default English).
        var language: String?
    }

    let url: URL

    init?(environment: [String: String]) {
        guard let path = environment["SPEAK_CORPUS"] else { return nil }
        url = URL(fileURLWithPath: path)
    }

    @MainActor
    func run() async {
        guard let data = try? Data(contentsOf: url), let cases = try? JSONDecoder().decode([Case].self, from: data) else {
            return print("corpus: can't read \(url.path)")
        }
        let rewriter = FoundationRewriter()
        guard await rewriter.availability() == .available else { return print("corpus: model unavailable") }
        for mode in [RewriteMode.concise, .polished] {
            for c in cases {
                // As in a session: prepared at key press, asked after the speech.
                await rewriter.prewarm(instructions: rewriteInstructions(mode))
                try? await Task.sleep(for: .seconds(1))
                print(await result(c, mode, rewriter)); fflush(stdout)
            }
        }
    }

    /// `ok|unfixed|dropped|answered|fallback  mode  id  first  total  missing=…  :: output  why=…`
    @MainActor
    private func result(_ c: Case, _ mode: RewriteMode, _ rewriter: FoundationRewriter) async -> String {
        let terms = c.terms ?? []
        let language = c.language ?? "en"
        // The model gets the Literal text, as in a session (cleanup and term spellings first).
        let literal = makeLiteral(c.text, terms: terms, pairs: [], spelling: SystemSpellChecker(), language: language)
        let prompt = buildRewritePrompt(literal, mode: mode, terms: terms, language: language)
        let start = ContinuousClock.now
        let reply = try? await rewriter.respond(to: prompt)
        let total = ContinuousClock.now - start
        let unknown = mode == .polished ? unknownWords(in: literal, spelling: SystemSpellChecker(), language: language) : []
        let checked = reply.map { checkRewrite($0.text, literal: literal, mode: mode, terms: terms, unknownWords: unknown, language: language) }
        var accepted = try? checked?.get()
        var why: String
        switch checked {
        case .failure(let rejection)?: why = rejection.name
        case .success?: why = ""
        case nil: why = "error"
        }
        // As in a session: a rejected Polished reply keeps the sentences that pass on their own.
        if case .failure(.keep)? = checked, let reply,
           let text = salvageRewrite(reply.text, literal: literal, terms: terms, unknownWords: unknown, language: language) {
            accepted = text
            why = "salvaged." + why
        }
        let output = accepted ?? literal // a rejected reply falls back to the literal, as in a session
        let words = Set(output.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init))
        // Japanese and Chinese have no spaces to split on: look for the characters themselves.
        let found = { (word: Substring) in
            word.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) } ? output.contains(word) : words.contains(String(word))
        }
        let missing = c.keep.filter { word in !word.lowercased().split(separator: "|").contains(where: found) }
        let answered = (c.reject ?? []).filter { output.lowercased().contains($0.lowercased()) }
        let unfixed = mode == .polished ? (c.fix ?? []).filter { !words.contains($0.lowercased()) } : []
        let verdict = accepted == nil ? "fallback" : !answered.isEmpty ? "answered" : !missing.isEmpty ? "dropped"
            : !unfixed.isEmpty ? "unfixed" : "ok"
        let first = reply?.firstToken.map(Self.seconds) ?? "-"
        return "\(verdict)\t\(mode.rawValue)\t\(c.id)\tfirst=\(first)\ttotal=\(Self.seconds(total))"
            + "\tmissing=\(missing.joined(separator: ","))\t:: \(output.replacingOccurrences(of: "\n", with: " ⏎ "))"
            + "\twhy=\(why)" + (accepted == nil || why.hasPrefix("salvaged") ? "\traw=\((reply?.text ?? "").replacingOccurrences(of: "\n", with: " ⏎ "))" : "")
    }

    private static func seconds(_ d: Duration) -> String {
        let (s, attos) = d.components
        return String(format: "%.3fs", Double(s) + Double(attos) / 1e18)
    }
}
#endif

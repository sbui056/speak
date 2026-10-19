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

    /// `ok|dropped|answered|fallback  mode  id  first  total  missing=…  :: output`
    @MainActor
    private func result(_ c: Case, _ mode: RewriteMode, _ rewriter: FoundationRewriter) async -> String {
        let terms = c.terms ?? []
        // The model gets the Literal text, as in a session (cleanup and term spellings first).
        let literal = makeLiteral(c.text, terms: terms, pairs: [], spelling: SystemSpellChecker(), language: "en")
        let prompt = buildRewritePrompt(literal, mode: mode, terms: terms)
        let start = ContinuousClock.now
        let reply = try? await rewriter.respond(to: prompt)
        let total = ContinuousClock.now - start
        let accepted = reply.flatMap { validateRewrite($0.text, literal: literal, mode: mode, terms: terms) }
        let output = accepted ?? literal // a rejected reply falls back to the literal, as in a session
        let words = Set(output.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init))
        let missing = c.keep.filter { word in !word.lowercased().split(separator: "|").contains { words.contains(String($0)) } }
        let answered = (c.reject ?? []).filter { output.lowercased().contains($0.lowercased()) }
        let verdict = accepted == nil ? "fallback" : !answered.isEmpty ? "answered" : missing.isEmpty ? "ok" : "dropped"
        let first = reply?.firstToken.map(Self.seconds) ?? "-"
        return "\(verdict)\t\(mode.rawValue)\t\(c.id)\tfirst=\(first)\ttotal=\(Self.seconds(total))"
            + "\tmissing=\(missing.joined(separator: ","))\t:: \(output.replacingOccurrences(of: "\n", with: " ⏎ "))"
    }

    private static func seconds(_ d: Duration) -> String {
        let (s, attos) = d.components
        return String(format: "%.3fs", Double(s) + Double(attos) / 1e18)
    }
}
#endif

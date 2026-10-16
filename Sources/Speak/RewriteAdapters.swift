import AppKit
import FoundationModels
import SpeakCore

/// Concise and Polished with Apple's on-device model. A fresh session per
/// rewrite, so nothing from one dictation can leak into the next.
final class FoundationRewriter: Rewriter {
    func availability() async -> RewriteAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable: return .modelNotReady
        }
    }

    func prewarm(instructions: String) async {
        guard SystemLanguageModel.default.isAvailable else { return }
        LanguageModelSession(model: .default, tools: [], instructions: instructions).prewarm(promptPrefix: nil)
    }

    func respond(to prompt: RewritePrompt) async throws -> String {
        let session = LanguageModelSession(model: .default, tools: [], instructions: prompt.instructions)
        let started = ContinuousClock.now
        do {
            // Greedy: a cleanup should be repeatable, not creative.
            let reply = try await session.respond(to: prompt.prompt, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: prompt.maxResponseTokens))
            Log.rewrite.info("rewrite replied in \(ContinuousClock.now - started, privacy: .public)")
            return reply.content
        } catch let error as LanguageModelSession.GenerationError {
            let mapped = Self.map(error)
            Log.rewrite.error("rewrite failed \(String(describing: mapped), privacy: .public) after \(ContinuousClock.now - started, privacy: .public)")
            throw mapped
        } catch {
            let ns = error as NSError
            Log.rewrite.error("rewrite failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
            throw RewriteError.unknown
        }
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> RewriteError {
        switch error {
        case .exceededContextWindowSize: .exceededContextWindow
        case .assetsUnavailable: .assetsUnavailable
        case .guardrailViolation: .guardrailViolation
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        case .decodingFailure: .decodingFailure
        case .rateLimited: .rateLimited
        case .concurrentRequests: .concurrentRequests
        case .refusal: .refusal
        case .unsupportedGuide: .unknown // Only for guided generation, which isn't used.
        @unknown default: .unknown
        }
    }
}

/// Asks the system spell checker, so dictionary near-miss matching only ever
/// touches words that aren't real words.
final class SystemSpellChecker: SpellChecker {
    @MainActor func isMisspelled(_ word: String, language: String) -> Bool {
        let checker = NSSpellChecker.shared
        let lang = checker.availableLanguages.contains(language) ? language
            : checker.availableLanguages.first { $0.hasPrefix(language.prefix(2)) }
        let range = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location != NSNotFound
    }
}

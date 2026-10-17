import Synchronization

/// Stands in for the language model. Its default reply is the fake-mode one:
/// the first word uppercased plus " (polished)", so the preview path is visible.
public final class FakeRewriter: Rewriter {
    public struct Config: Sendable {
        public var availability: RewriteAvailability = .available
        /// A fixed raw reply instead of the default.
        public var reply: String?
        public var error: RewriteError?
        /// Replies wait for `release()`, like a slow model.
        public var gated = false
        public init() {}
    }

    private struct State {
        var config = Config()
        var prompts: [RewritePrompt] = []
        var prewarms: [String] = []
        var gates: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init(_ config: Config = Config()) {
        state.withLock { $0.config = config }
    }

    public func configure(_ change: (inout Config) -> Void) { state.withLock { change(&$0.config) } }
    public var prompts: [RewritePrompt] { state.withLock { $0.prompts } }
    public var prewarms: [String] { state.withLock { $0.prewarms } }
    public var waiting: Int { state.withLock { $0.gates.count } }

    /// Lets the oldest waiting reply finish.
    public func release() {
        state.withLock { s in s.gates.isEmpty ? nil : s.gates.removeFirst() }?.resume()
    }

    public func availability() async -> RewriteAvailability { state.withLock { $0.config.availability } }

    public func prewarm(instructions: String) async {
        state.withLock { $0.prewarms.append(instructions) }
    }

    public func respond(to prompt: RewritePrompt) async throws -> String {
        let config = state.withLock { s in
            s.prompts.append(prompt)
            return s.config
        }
        if config.gated {
            await withCheckedContinuation { continuation in state.withLock { $0.gates.append(continuation) } }
        }
        if let error = config.error { throw error }
        if let reply = config.reply { return reply }
        return "<cleaned>\(Self.polish(transcript(in: prompt.prompt)))</cleaned>"
    }

    private static func polish(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if let first = words.first { words[0] = first.uppercased() }
        return words.joined(separator: " ") + " (polished)"
    }

    private func transcript(in prompt: String) -> String {
        String(prompt.dropFirst("<transcript>".count).dropLast("</transcript>".count))
    }
}

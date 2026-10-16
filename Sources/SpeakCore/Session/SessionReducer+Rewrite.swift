/// Concise and Polished: the rewrite, its fallbacks, and the preview decision.
extension Reducer {
    /// The literal exists from here on, so it's never lost whatever the rewrite does.
    mutating func literalReady(_ literal: String) {
        guard state.phase == .finalizing, state.preparingLiteral, let id = state.current else { return }
        state.preparingLiteral = false
        guard !literal.isEmpty else { return finish(.result(.empty)) }
        state.literal = literal
        state.delivered = nil
        let mode = state.sessionMode
        // Partial text after a slow transcriber goes in as is, with its own note.
        if mode == .literal || state.usedPartialFallback { return deliver(literal) }
        let words = wordCount(literal)
        if words < Constants.rewriteMinWords { return deliver(literal) }
        if words > Constants.rewriteMaxWords {
            state.resultNote = .tooLong
            return deliver(literal)
        }
        state.phase = .rewriting
        emit(.rewrite(id, literal, mode), .startTimer(id, .rewrite, after: Constants.rewriteTimeout),
             .showHUD(.rewriting))
    }

    mutating func rewritten(_ text: String?) {
        guard state.phase == .rewriting, let id = state.current, let literal = state.literal else { return }
        guard let text else { return fallBackToLiteral() }
        // No silent rewrites: changed wording waits for the user.
        guard wordingChanged(literal, text) || state.alwaysPreview else { return deliver(text) }
        state.phase = .awaitingAcceptance
        emit(.hideHUD, .showPreview(id, literal: literal, rewrite: text))
    }

    mutating func fallBackToLiteral() {
        guard let literal = state.literal else { return }
        state.resultNote = .rewriteFallback(mode: state.sessionMode.title)
        deliver(literal)
    }

    mutating func preview(_ action: PreviewAction) {
        guard state.phase == .awaitingAcceptance, let id = state.current, let literal = state.literal else { return }
        emit(.closePreview)
        switch action {
        case .insert(let text): deliver(text, handoff: true)
        case .insertLiteral: deliver(literal, handoff: true)
        case .copy(let text):
            state.delivered = text
            emit(.copyToPasteboard(text))
            finish(.result(.copied))
        case .cancel:
            emit(.hideHUD, .endSession(id))
            state.resetSession()
        }
    }
}

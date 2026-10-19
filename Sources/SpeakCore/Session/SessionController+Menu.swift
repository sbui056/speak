/// What the menu and the preview panel can ask of the session.
extension SessionController {
    /// What the last dictation inserted or copied, else its literal; for Paste/Copy last.
    public var lastTranscript: String? { state.lastTranscript }

    /// The user's choice in the preview panel.
    public func choose(_ action: PreviewAction) {
        guard let id = preview?.id else { return }
        send(.preview(id, action))
    }

    public func pasteLast() async {
        guard let text = lastTranscript else { return }
        await insert(text)
    }

    /// Pastes `text` into the frontmost app's field the way a dictation would; for
    /// Paste last transcript.
    @discardableResult
    public func insert(_ text: String) async -> DeliveryOutcome {
        // Opening the menu doesn't activate Speak, so the target is whatever is frontmost now.
        let context = await deliverer.capturePressContext()
        let outcome = await deliverer.deliver(text, context: context)
        show(outcome)
        return outcome
    }

    /// Types `text` into Speak's own focused field (Settings → Test) through the
    /// same delivery rules, except that Speak itself is the target.
    @discardableResult
    public func insertIntoOwnField(_ text: String) async -> DeliveryOutcome {
        let context = await deliverer.captureOwnFieldContext()
        let outcome = await deliverer.deliver(text, context: context)
        show(outcome)
        return outcome
    }

    /// The last paste can be undone now: still within the undo window, same app and field.
    public func undoIsSafe() async -> Bool {
        await deliverer.undoIsSafe()
    }

    public func undoDiagnostics() async -> String {
        await deliverer.undoDiagnostics()
    }

    /// Sends ⌘Z for the last paste if that's still safe.
    @discardableResult
    public func undoLastInsert() async -> Bool {
        await deliverer.undoLastInsert()
    }

    public func copyLast() async {
        guard let text = lastTranscript else { return }
        await deliverer.copy(text)
        hud.show(.result(.copied))
    }

    private func show(_ outcome: DeliveryOutcome) {
        switch outcome {
        case .inserted: hud.show(.result(.inserted))
        case .copied(let reason): hud.show(.error(reason))
        case .empty: hud.show(.result(.empty))
        }
    }
}

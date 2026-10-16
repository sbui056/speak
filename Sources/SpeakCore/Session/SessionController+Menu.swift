/// What the menu and the preview panel can ask of the session.
extension SessionController {
    /// What the last dictation inserted or copied, else its literal; for Paste/Copy last.
    public var lastTranscript: String? { state.delivered ?? state.literal }

    /// The user's choice in the preview panel.
    public func choose(_ action: PreviewAction) {
        guard let id = preview?.id else { return }
        send(.preview(id, action))
    }

    public func pasteLast() async {
        guard let text = lastTranscript else { return }
        // Opening the menu doesn't activate Speak, so the target is whatever is frontmost now.
        let context = await deliverer.capturePressContext()
        let outcome = await deliverer.deliver(text, context: context)
        show(outcome)
    }

    /// The last paste can be undone now: still within the undo window, same app and field.
    public func undoIsSafe() async -> Bool {
        await deliverer.canUndo ? await deliverer.undoIsSafe() : false
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
}

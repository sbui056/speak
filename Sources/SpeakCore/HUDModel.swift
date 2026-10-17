import Observation

/// What the HUD shows, with its timing rules: partial text is throttled,
/// results and errors hide themselves, and a repeated error shows only once.
@MainActor
@Observable
public final class HUDModel {
    public private(set) var content: HUDContent? {
        didSet { if content != oldValue { onContentChange?(content) } }
    }
    /// Called on every change, for the window that shows or hides the HUD.
    @ObservationIgnored public var onContentChange: ((HUDContent?) -> Void)?

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var partialTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPartial: String?
    @ObservationIgnored private var recentErrors: [(message: Messages, shownAt: ContinuousClock.Instant)] = []

    public init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    public func show(_ new: HUDContent) {
        switch new {
        case .partial(let text):
            showPartial(text)
        case .error(let message):
            // Already shown: don't repeat it, but don't leave "processing" up either.
            guard !shownRecently(message) else { return hide() }
            set(new, hideAfter: Constants.hudError)
        case .result:
            set(new, hideAfter: Constants.hudOK)
        case .listening, .processing, .rewriting:
            set(new, hideAfter: nil)
        }
    }

    /// While the pointer is over an error, it stays up; leaving restarts its timer.
    public func hover(_ inside: Bool) {
        guard case .error = content else { return }
        if inside {
            hideTask?.cancel()
        } else if let content {
            set(content, hideAfter: Constants.hudError)
        }
    }

    public func hide() {
        cancelPending()
        content = nil
    }

    // MARK: Private

    private func set(_ new: HUDContent, hideAfter: Duration?) {
        cancelPending()
        content = new
        guard let hideAfter else { return }
        let deadline = Deadline(after: hideAfter, on: clock)
        hideTask = Task { [weak self] in
            guard await deadline.reached() else { return }
            self?.content = nil
        }
    }

    /// Latest text wins, at most `Constants.hudRate` updates a second.
    private func showPartial(_ text: String) {
        pendingPartial = text
        guard partialTask == nil else { return }
        flushPartial()
        let clock = self.clock
        let interval = Duration.seconds(1 / Constants.hudRate)
        partialTask = Task { [weak self] in
            while await Deadline(after: interval, on: clock).reached() {
                guard let self, self.pendingPartial != nil else { break }
                self.flushPartial()
            }
            // A cancelled loop may already have been replaced; don't clear the new one.
            if !Task.isCancelled { self?.partialTask = nil }
        }
    }

    private func flushPartial() {
        guard let text = pendingPartial else { return }
        pendingPartial = nil
        hideTask?.cancel()
        content = .partial(text)
    }

    private func cancelPending() {
        hideTask?.cancel()
        partialTask?.cancel()
        partialTask = nil
        pendingPartial = nil
    }

    /// Identical errors within `Constants.coalesce` show once. Uses wall time on purpose:
    /// this is about what the user just saw, not session timing.
    private func shownRecently(_ message: Messages) -> Bool {
        let now = ContinuousClock.now
        recentErrors.removeAll { now - $0.shownAt > Constants.coalesce }
        if recentErrors.contains(where: { $0.message == message }) { return true }
        recentErrors.append((message, now))
        return false
    }
}

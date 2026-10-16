import Observation

/// Runs the state machine: every input goes through one queue into `reduce`,
/// and the effects it returns are carried out here. Business rules live in the
/// reducer; this class only does the plumbing.
@MainActor
@Observable
public final class SessionController {
    public private(set) var state = SessionState()
    public let hud: HUDModel
    /// Mic level for the HUD meter, 0...1.
    public private(set) var level: Float = 0

    @ObservationIgnored private let audio: any AudioSource
    @ObservationIgnored private let transcriber: any Transcriber
    @ObservationIgnored private let deliverer: Deliverer
    @ObservationIgnored private let hotkey: any HotkeySource
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let events: AsyncStream<SessionEvent>
    @ObservationIgnored private let input: AsyncStream<SessionEvent>.Continuation
    @ObservationIgnored private var runtime: Runtime?
    /// Every audio start and stop, across sessions, runs in this order. A release
    /// during a slow engine start stops it once the start completes, and a stale
    /// stop can never close the next session's engine.
    @ObservationIgnored private var audioTail: Task<Void, Never>?
    /// Pasteboard copies made on quit or sleep, which quit has to wait for.
    @ObservationIgnored private var copyTail: Task<Void, Never>?
    @ObservationIgnored public var hotkeyChoice: HotkeyChoice = .rightOption
    /// Called after every transition, for logging. Never sees transcript text.
    @ObservationIgnored public var onTransition: ((Phase, Phase, SessionID?) -> Void)?

    /// Work that belongs to one session.
    private final class Runtime {
        let id: SessionID
        var press: Task<PressContext, Never>?
        var transcriber: Task<(any TranscriberSession)?, Never>?
        /// Timers, finalize, and delivery; cancelled when the session ends.
        var cancellable: [Task<Void, Never>] = []
        init(id: SessionID) { self.id = id }
    }

    public init(audio: any AudioSource, transcriber: any Transcriber, deliverer: Deliverer,
                hotkey: any HotkeySource, clock: any Clock<Duration>) {
        self.audio = audio
        self.transcriber = transcriber
        self.deliverer = deliverer
        self.hotkey = hotkey
        self.clock = clock
        self.hud = HUDModel(clock: clock)
        (events, input) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Consumes events until the stream ends. Start once, at launch.
    public func run() async {
        for await event in events { apply(event) }
    }

    public nonisolated func send(_ event: SessionEvent) {
        input.yield(event)
    }

    /// Forwards hotkey events into the queue until the stream ends.
    public func listen(to keys: AsyncStream<HotkeyEvent>) async {
        for await key in keys {
            switch key {
            case .pressed(let at):
                send(.pressed(at: at))
                // A new session puts the previous paste's clipboard back early. Not
                // awaited: a paste stuck in an unresponsive app must not delay the
                // press, and the new session's own delivery queues behind this anyway.
                let deliverer = self.deliverer
                Task { await deliverer.restoreNow() }
            case .released(let at): send(.released(at: at))
            case .chord: send(.chord)
            case .cancel: send(.cancel)
            case .tapReenabled(let down, let at): send(.keyState(isDown: down, at: at))
            }
        }
    }

    /// The literal from the last dictation, for Paste/Copy last.
    public var lastTranscript: String? { state.literal }

    public func pasteLast() async {
        guard let text = state.literal else { return }
        // Opening the menu doesn't activate Speak, so the target is whatever is frontmost now.
        let context = await deliverer.capturePressContext()
        let outcome = await deliverer.deliver(text, context: context)
        show(outcome)
    }

    public func copyLast() async {
        guard let text = state.literal else { return }
        await deliverer.copy(text)
        hud.show(.result(.copied))
    }

    /// Quit: stop the mic, keep any undelivered text, put the clipboard back.
    public func shutdown() async {
        // The reducer's stopAudio closes the mic through the ordered audio chain.
        // Quit doesn't wait for it: a hung engine start must not block quitting,
        // and the process exiting releases the mic anyway.
        apply(.quit)
        await copyTail?.value
        await deliverer.restoreNow()
    }

    // MARK: Event loop

    private func apply(_ event: SessionEvent) {
        let before = state
        let (next, effects) = reduce(state, event)
        state = next
        if before.phase != next.phase { onTransition?(before.phase, next.phase, before.current ?? next.current) }
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .capturePressContext(let id):
            let rt = Runtime(id: id)
            runtime = rt
            let deliverer = self.deliverer
            rt.press = Task { await deliverer.capturePressContext() }
        case .startCapture(let id):
            startCapture(id)
        case .stopAudio(let id):
            guard runtime(id) != nil else { return }
            let previous = audioTail
            let audio = self.audio
            audioTail = Task { await previous?.value; await audio.stop() }
            level = 0
        case .finalizeTranscriber(let id):
            guard let rt = runtime(id) else { return }
            let pending = rt.transcriber
            rt.cancellable.append(Task { [weak self] in
                guard let session = await pending?.value else { return }
                do {
                    let text = try await session.finalize()
                    self?.send(.finalized(id, text))
                } catch {
                    if !Task.isCancelled { self?.send(.transcriberFailed(id)) }
                }
            })
        case .cancelTranscriber(let id):
            guard let pending = runtime(id)?.transcriber else { return }
            // Stop the engine first, then cancel the analyzer. Not part of the
            // audio chain, since a cancel that hangs must not block the mic.
            let audioStopped = audioTail
            Task {
                await audioStopped?.value
                await pending.value?.cancel()
            }
        case .startTimer(let id, let kind, let after):
            guard let rt = runtime(id) else { return }
            let deadline = Deadline(after: after, on: clock)
            rt.cancellable.append(Task { [weak self] in
                guard await deadline.reached() else { return }
                self?.timerFired(id, kind)
            })
        case .deliver(let id, let text):
            guard let rt = runtime(id) else { return }
            let press = rt.press
            let deliverer = self.deliverer
            // Tracked, so sleep or quit mid-delivery cancels the paste.
            rt.cancellable.append(Task { [weak self] in
                let context = await press?.value
                let outcome = await deliverer.deliver(text, context: context)
                self?.send(.delivered(id, outcome))
            })
        case .copyToPasteboard(let text):
            let deliverer = self.deliverer
            let previous = copyTail
            copyTail = Task { await previous?.value; await deliverer.rescue(text) }
        case .showHUD(let content):
            hud.show(content)
        case .hideHUD:
            hud.hide()
        case .endSession(let id):
            guard let rt = runtime(id) else { return }
            rt.cancellable.forEach { $0.cancel() }
            runtime = nil
        }
    }

    private func runtime(_ id: SessionID) -> Runtime? {
        runtime?.id == id ? runtime : nil
    }

    private func timerFired(_ id: SessionID, _ kind: TimerKind) {
        if kind == .keyPoll {
            // Catch a lost key-up by asking the system directly.
            send(.keyState(isDown: hotkey.isKeyDown(hotkeyChoice), at: hotkey.now()))
        }
        send(.timer(id, kind))
    }

    private func startCapture(_ id: SessionID) {
        guard let rt = runtime(id) else { return }
        let audio = self.audio
        let transcriber = self.transcriber
        let input = self.input
        let onAudio: @Sendable (AudioEvent) -> Void = { [weak self] event in
            switch event {
            case .level(let rms, let peak):
                self?.setLevel(rms, for: id)
                input.yield(.audioPeak(id, dBFS: peak))
            case .deviceChanged:
                input.yield(.deviceChanged(id))
            }
        }
        let onTranscript: @Sendable (TranscriberEvent) -> Void = { event in
            switch event {
            case .active: input.yield(.transcriberActive(id))
            case .partial(let text): input.yield(.partial(id, text))
            }
        }
        let previous = audioTail
        let opened = Task { () -> AsyncStream<AudioFrames>? in
            await previous?.value
            do {
                let frames = try await audio.start(onEvent: onAudio)
                input.yield(.audioStarted(id))
                return frames
            } catch {
                input.yield(.audioFailed(id, error as? AudioFailure ?? .busy))
                return nil
            }
        }
        audioTail = Task { _ = await opened.value }
        rt.transcriber = Task {
            guard let frames = await opened.value else { return nil }
            do {
                return try await transcriber.start(frames: frames, onEvent: onTranscript)
            } catch {
                input.yield(.transcriberFailed(id))
                return nil
            }
        }
    }

    /// Level updates can arrive after the mic closed; only the live session's count.
    private nonisolated func setLevel(_ rms: Float, for id: SessionID) {
        Task { @MainActor in
            if self.runtime(id) != nil, self.state.phase == .arming || self.state.phase == .listening {
                self.level = rms
            }
        }
    }

    private func show(_ outcome: DeliveryOutcome) {
        switch outcome {
        case .inserted: hud.show(.result(.inserted))
        case .copied(let reason): hud.show(.error(reason))
        case .empty: hud.show(.result(.empty))
        }
    }
}

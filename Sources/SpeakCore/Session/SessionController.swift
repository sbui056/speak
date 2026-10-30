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
    /// The loudest level of the current or last session, for the timing log.
    public private(set) var loudestLevel: Float = 0
    /// The rewrite waiting for the user's decision, while the preview is open.
    public private(set) var preview: PreviewContent? {
        didSet { if preview != oldValue { onPreviewChange?(preview) } }
    }
    /// Dictionary terms: spellings for correction, the transcriber, and the rewriter.
    @ObservationIgnored public var terms: [String] = []
    /// Replacement pairs for Literal; their "write" sides also rescore the transcriber.
    @ObservationIgnored public var pairs: [ReplacementPair] = []
    /// Every spelling the user wrote: terms plus replacement outputs. The
    /// transcriber rescores toward them and the rewrite must keep them.
    private var userSpellings: [String] { terms + pairs.map(\.write) }
    /// Language for the spell checker, as a locale identifier.
    @ObservationIgnored public var language = "en_US"
    /// Called when the preview opens or closes, for the panel that shows it.
    @ObservationIgnored public var onPreviewChange: ((PreviewContent?) -> Void)?
    /// Called with every delivery result (pasted, or copied and why), for logging.
    @ObservationIgnored public var onDelivered: ((DeliveryOutcome) -> Void)?
    /// Called with the text a session gave the user (pasted or copied), for history.
    @ObservationIgnored public var onFinished: ((String) -> Void)?
    /// Called when the model's reply failed validation, with why, for logging. Never sees text.
    @ObservationIgnored public var onRewriteRejected: ((RewriteMode, RewriteRejection) -> Void)?
    /// A Polished reply the keep guard rejected whole, kept sentence by sentence instead. Never sees text.
    @ObservationIgnored public var onRewriteSalvaged: ((RewriteRejection) -> Void)?
    /// Called at each timed milestone of the current dictation. Never sees text.
    @ObservationIgnored public var onStage: ((SessionStage) -> Void)?
    /// Called after every transition, for logging. Never sees transcript text.
    @ObservationIgnored public var onTransition: ((Phase, Phase, SessionID?) -> Void)?
    /// Called when listening starts, and again once the mic has closed after it.
    @ObservationIgnored public var onCue: ((SoundCue) -> Void)?
    /// The key the poll asks about when a key-up may have been lost.
    @ObservationIgnored public var hotkeyChoice: HotkeyChoice = .rightOption

    @ObservationIgnored private let audio: any AudioSource
    @ObservationIgnored private let transcriber: any Transcriber
    @ObservationIgnored let deliverer: Deliverer
    @ObservationIgnored private let rewriter: any Rewriter
    @ObservationIgnored private let spelling: any SpellChecker
    @ObservationIgnored private let hotkey: any HotkeySource
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let events: AsyncStream<SessionEvent>
    @ObservationIgnored private let input: AsyncStream<SessionEvent>.Continuation
    @ObservationIgnored private var runtime: Runtime?
    /// Every audio start and stop, across sessions, runs in this order. A release
    /// during a slow engine start stops it once the start completes, and a stale
    /// stop can never close the next session's engine.
    @ObservationIgnored private var audioTail: Task<Void, Never>?
    /// Rescue copies (a hung paste, sleep, quit), which quit has to wait for.
    @ObservationIgnored private var copyTail: Task<Void, Never>?

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
                rewriter: any Rewriter, spelling: any SpellChecker,
                hotkey: any HotkeySource, clock: any Clock<Duration>) {
        self.audio = audio
        self.transcriber = transcriber
        self.deliverer = deliverer
        self.rewriter = rewriter
        self.spelling = spelling
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
        if case .delivered(let id, let outcome) = event, id == before.current { onDelivered?(outcome) }
        reportStage(event, before: before)
        reportFinished(event, before: before)
        if before.phase != next.phase { onTransition?(before.phase, next.phase, before.current ?? next.current) }
        for effect in effects { perform(effect) }
        reportCue(before: before)
    }

    /// Start waits out the hold, so taps stay silent. Stop follows the mic closing, so it's never
    /// recorded. A release so quick that listening starts and ends in one event plays neither.
    private func reportCue(before: SessionState) {
        if before.phase != .listening, state.phase == .listening { onCue?(.start) }
        if before.phase == .listening, state.phase != .listening {
            let closing = audioTail
            Task { [weak self] in
                await closing?.value
                self?.onCue?(.stop)
            }
        }
    }

    /// Finalize and cleanup, as the reducer accepts them. Rewrites and deliveries
    /// report from their own tasks, which know the model's and the paste's times.
    private func reportStage(_ event: SessionEvent, before: SessionState) {
        switch event {
        case .finalized(let id, _) where id == before.current && before.phase == .finalizing:
            onStage?(.finalized)
        case .literalReady(let id, _) where id == before.current && before.preparingLiteral:
            onStage?(.literalReady)
        default: break
        }
    }

    /// A delivery finished (inserted, or copied as a fallback), or the preview's Copy was chosen.
    private func reportFinished(_ event: SessionEvent, before: SessionState) {
        let delivered = before.phase == .delivering && state.phase != .delivering
        let copied = if case .preview(_, .copy) = event {
            before.phase == .awaitingAcceptance && state.phase != .awaitingAcceptance
        } else {
            false
        }
        if delivered || copied, let text = state.delivered { onFinished?(text) }
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .capturePressContext(let id):
            let rt = Runtime(id: id)
            runtime = rt
            let deliverer = self.deliverer
            rt.press = Task { await deliverer.capturePressContext() }
        case .startCapture(let id):
            loudestLevel = 0
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
        case .prepareLiteral(let id, let raw):
            // Local and quick (the spell checker is asked only about near misses).
            send(.literalReady(id, makeLiteral(raw, terms: terms, pairs: pairs, spelling: spelling, language: language)))
        case .prewarmRewriter(let mode):
            let rewriter = self.rewriter
            let instructions = rewriteInstructions(mode)
            Task { await rewriter.prewarm(instructions: instructions) }
        case .rewrite(let id, let literal, let mode):
            guard let rt = runtime(id) else { return }
            rt.cancellable.append(rewrite(id, literal, mode))
        case .showPreview(let id, let literal, let rewrite):
            preview = PreviewContent(id: id, mode: state.sessionMode, literal: literal, rewrite: rewrite)
        case .closePreview:
            preview = nil
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
        case .deliver(let id, let text), .handoff(let id, let text):
            guard let rt = runtime(id) else { return }
            let press = rt.press
            let deliverer = self.deliverer
            let clock = self.clock
            let returnToApp = if case .handoff = effect { true } else { false }
            // Tracked, so sleep or quit mid-delivery cancels the paste.
            rt.cancellable.append(Task { [weak self] in
                let context = await press?.value
                // After the preview, the app the user dictated into comes back first.
                // If it doesn't, the delivery rules see the app change and copy instead.
                var activate: Duration?
                if returnToApp, let pid = context?.pid {
                    activate = await clock.measure { await deliverer.activate(pid) }
                }
                var (outcome, timings) = await deliverer.deliverTimed(
                    text, context: context, modifierWait: returnToApp ? Constants.handoffModWait : Constants.modWait)
                timings.activate = activate ?? (returnToApp ? .zero : nil)
                // A delivery the watchdog already gave up on belongs to no timed dictation.
                if let self, state.current == id, state.phase == .delivering { onStage?(.delivered(timings)) }
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

    /// Asks the model, then keeps the reply only if it passes the injection
    /// guard. The reducer's watchdog decides when to stop waiting.
    private func rewrite(_ id: SessionID, _ literal: String, _ mode: RewriteMode) -> Task<Void, Never> {
        let rewriter = self.rewriter
        let terms = userSpellings
        let language = self.language
        // Words the spell checker doesn't know are jargon Polished must keep;
        // asked here, on the main actor, before the model runs.
        let unknown = mode == .polished ? unknownWords(in: literal, spelling: spelling, language: language) : []
        return Task { [weak self] in
            let prompt = buildRewritePrompt(literal, mode: mode, terms: terms, language: language)
            var accepted: String?
            let reply = try? await rewriter.respond(to: prompt)
            if let reply {
                switch checkRewrite(reply.text, literal: literal, mode: mode, terms: terms, unknownWords: unknown,
                                    language: language) {
                case .success(let text): accepted = text
                case .failure(let why):
                    if case .keep = why, let text = salvageRewrite(reply.text, literal: literal, terms: terms,
                                                                   unknownWords: unknown, language: language) {
                        accepted = text
                        self?.onRewriteSalvaged?(why)
                    } else {
                        self?.onRewriteRejected?(mode, why)
                    }
                }
            }
            // A reply after the watchdog gave up belongs to no timed dictation.
            if let self, state.current == id, state.phase == .rewriting {
                onStage?(.rewritten(firstToken: reply?.firstToken))
            }
            self?.send(.rewritten(id, accepted))
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
        let terms = userSpellings
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
                return try await transcriber.start(frames: frames, terms: terms, onEvent: onTranscript)
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
                self.loudestLevel = max(self.loudestLevel, rms)
            }
        }
    }
}

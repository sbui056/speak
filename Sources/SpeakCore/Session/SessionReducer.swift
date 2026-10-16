/// The session state machine as one pure function: no clock, no I/O, no awaits.
/// The controller feeds it events one at a time and runs the effects it returns,
/// so no two transitions can interleave.
public func reduce(_ state: SessionState, _ event: SessionEvent) -> (SessionState, [Effect]) {
    var reducer = Reducer(state: state)
    reducer.handle(event)
    return (reducer.state, reducer.effects)
}

/// How often the hotkey is polled while listening, to catch a lost key-up
/// within the stuck-key window.
public let keyPollInterval: Duration = Constants.stuck / 3

private struct Reducer {
    var state: SessionState
    var effects: [Effect] = []

    mutating func handle(_ event: SessionEvent) {
        // Invariant: an event from an earlier session never changes anything.
        if let id = event.sessionID, id != state.current { return }

        switch event {
        case .pressed(let at): press(at: at)
        case .released(let at): release(at: at)
        case .chord: if state.phase == .arming || state.phase == .listening { discard() }
        case .cancel: cancel()
        case .keyState(let isDown, let at): keyState(isDown: isDown, at: at)

        case .audioStarted: break
        case .audioFailed(_, let failure): audioFailed(failure)
        case .audioPeak(_, let dBFS): state.peakDBFS = max(state.peakDBFS, dBFS)
        case .deviceChanged:
            if state.phase == .arming || state.phase == .listening { fail(.device) }

        case .transcriberActive: state.transcriberActive = true
        case .partial(_, let text): partial(text)
        case .finalized(_, let text): finalized(text)
        case .transcriberFailed:
            if [.arming, .listening, .finalizing].contains(state.phase) { fail(.stt) }

        case .timer(_, let kind): timer(kind)
        case .delivered(_, let outcome): delivered(outcome)

        case .modelStatus(let status): state.model = status
        case .micPermission(let granted): state.micGranted = granted
        case .systemSleep: shutdown()
        case .quit:
            state.terminating = true
            shutdown()
        }
    }

    // MARK: Hotkey

    mutating func press(at: KeyTime) {
        // One session at a time.
        guard state.phase == .idle, !state.terminating else { return }
        guard state.micGranted else { return emit(.showHUD(.error(.mic))) }
        switch state.model {
        case .installed: break
        case .downloading(let percent): return emit(.showHUD(.error(.modelDownloading(percent: percent))))
        case .unavailable(let language): return emit(.showHUD(.error(.modelUnavailable(language: language))))
        }
        state.lastIssued += 1
        let id = SessionID(state.lastIssued)
        state.current = id
        state.phase = .arming
        state.pressedAt = at
        // The mic opens at press so the first word isn't lost.
        emit(.capturePressContext(id), .startCapture(id),
             .startTimer(id, .hold, after: Constants.hold))
    }

    mutating func release(at: KeyTime) {
        switch state.phase {
        case .arming:
            // The hold timer may simply not have been processed yet.
            if at - state.pressedAt >= Constants.hold {
                startListening()
                endCapture(at: at)
            } else {
                discard()
            }
        case .listening:
            endCapture(at: at)
        default:
            break
        }
    }

    mutating func cancel() {
        switch state.phase {
        case .arming, .listening: discard()
        default: break // Esc is ignored once capture has ended.
        }
    }

    mutating func keyState(isDown: Bool, at: KeyTime) {
        guard state.phase == .listening else { return }
        if isDown {
            state.keyUpSince = nil
            return
        }
        let since = state.keyUpSince ?? at
        state.keyUpSince = since
        if at - since >= Constants.stuck { discard() }
    }

    // MARK: Capture

    mutating func startListening() {
        guard let id = state.current else { return }
        state.phase = .listening
        emit(.showHUD(.listening),
             .startTimer(id, .sttStart, after: Constants.sttStart),
             .startTimer(id, .cap, after: Constants.cap),
             .startTimer(id, .keyPoll, after: keyPollInterval))
    }

    /// Release (or the cap) ends capture: too short or silent clips are dropped
    /// quietly, everything else is finalized.
    mutating func endCapture(at: KeyTime?) {
        guard let id = state.current else { return }
        if let at, at - state.pressedAt < Constants.minAudio { return discard() }
        if state.peakDBFS < Constants.silenceDBFS { return discard() }
        state.phase = .finalizing
        emit(.stopAudio(id), .finalizeTranscriber(id),
             .startTimer(id, .finalize, after: Constants.finalize),
             .showHUD(.processing))
    }

    mutating func partial(_ text: String) {
        state.transcriberActive = true
        state.lastPartial = text
        if state.phase == .listening { emit(.showHUD(.partial(text))) }
    }

    mutating func finalized(_ text: String) {
        guard state.phase == .finalizing else { return }
        state.consecutiveAbandons = 0
        deliver(cleanLiteral(text))
    }

    mutating func deliver(_ literal: String) {
        guard let id = state.current else { return }
        guard !literal.isEmpty else { return finish(.result(.empty)) }
        state.literal = literal
        state.phase = .delivering
        emit(.deliver(id, literal), .startTimer(id, .deliver, after: Constants.deliver))
    }

    mutating func audioFailed(_ failure: AudioFailure) {
        guard state.phase == .arming || state.phase == .listening else { return }
        switch failure {
        case .denied:
            state.micGranted = false
            fail(.mic)
        case .busy:
            fail(.micBusy)
        }
    }

    // MARK: Timers

    mutating func timer(_ kind: TimerKind) {
        guard let id = state.current else { return }
        switch (kind, state.phase) {
        case (.hold, .arming):
            startListening()
        case (.sttStart, .listening):
            if !state.transcriberActive { abandon(fallingBackTo: nil) }
        case (.cap, .listening):
            endCapture(at: nil)
        case (.keyPoll, .listening):
            emit(.startTimer(id, .keyPoll, after: keyPollInterval))
        case (.finalize, .finalizing):
            abandon(fallingBackTo: state.lastPartial)
        case (.deliver, .delivering):
            // Paste hung (an unresponsive app). Ending the session cancels it;
            // the text still ends up somewhere the user can get it.
            if let literal = state.literal { emit(.copyToPasteboard(literal)) }
            finish(.result(.copied))
        default:
            break // A timer for a phase already left.
        }
    }

    /// A transcriber call hung past its watchdog. Use the partial text if there
    /// is any; two hangs in a row means the engine needs a restart.
    mutating func abandon(fallingBackTo partial: String?) {
        guard let id = state.current else { return }
        state.consecutiveAbandons += 1
        state.restartAdvised = state.consecutiveAbandons >= 2
        emit(.stopAudio(id), .cancelTranscriber(id))
        if let partial {
            let literal = cleanLiteral(partial)
            if !literal.isEmpty {
                state.usedPartialFallback = true
                return deliver(literal)
            }
        }
        finish(.error(state.restartAdvised ? .restart : .stt))
    }

    // MARK: Delivery and exits

    mutating func delivered(_ outcome: DeliveryOutcome) {
        guard state.phase == .delivering else { return }
        // The text still lands, but a hung engine matters more than the result.
        if state.restartAdvised { return finish(.error(.restart)) }
        switch outcome {
        case .inserted: finish(.result(state.usedPartialFallback ? .finalize : .inserted))
        case .copied(let reason): finish(reason == .copied ? .result(.copied) : .error(reason))
        case .empty: finish(.result(.empty))
        }
    }

    /// Sleep or quit: stop the mic, and never lose a literal that wasn't delivered.
    mutating func shutdown() {
        guard let id = state.current else { return }
        if state.phase == .delivering, let literal = state.literal {
            emit(.copyToPasteboard(literal))
        }
        emit(.stopAudio(id), .cancelTranscriber(id), .hideHUD, .endSession(id))
        state.resetSession()
    }

    /// Silent exit: taps, chords, Esc, short or silent clips, a stuck key.
    mutating func discard() {
        guard let id = state.current else { return }
        emit(.stopAudio(id), .cancelTranscriber(id), .hideHUD, .endSession(id))
        state.resetSession()
    }

    mutating func fail(_ message: Messages) {
        guard let id = state.current else { return }
        emit(.stopAudio(id), .cancelTranscriber(id))
        finish(.error(message))
    }

    mutating func finish(_ hud: HUDContent) {
        guard let id = state.current else { return }
        emit(.showHUD(hud), .endSession(id))
        state.resetSession()
    }

    mutating func emit(_ new: Effect...) { effects += new }
}

extension SessionEvent {
    /// The session an adapter event belongs to; nil for user and system events.
    var sessionID: SessionID? {
        switch self {
        case .audioStarted(let id), .audioFailed(let id, _), .audioPeak(let id, _), .deviceChanged(let id),
             .transcriberActive(let id), .partial(let id, _), .finalized(let id, _),
             .transcriberFailed(let id), .timer(let id, _), .delivered(let id, _):
            id
        default:
            nil
        }
    }
}

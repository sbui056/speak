import Testing
@testable import SpeakCore

private let s1 = SessionID(1)
private func ms(_ n: Int) -> KeyTime { .milliseconds(n) }

/// Runs events through the reducer, returning the final state and the effects of the last event.
private func run(_ events: [SessionEvent], from start: SessionState = SessionState()) -> (SessionState, [Effect]) {
    var state = start
    var last: [Effect] = []
    for event in events { (state, last) = reduce(state, event) }
    return (state, last)
}

private let loud: SessionEvent = .audioPeak(s1, dBFS: -20)
/// Pressed, held past the hold threshold, with audible audio.
private let listening: [SessionEvent] = [.pressed(at: ms(0)), .timer(s1, .hold), loud]
/// Released after a normal utterance; now finalizing.
private let finalizing = listening + [.released(at: ms(1500))]
private let teardown: [Effect] = [.stopAudio(s1), .cancelTranscriber(s1), .hideHUD, .endSession(s1)]

struct ReducerTests {
    // MARK: Transition table

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let events: [SessionEvent]
        let phase: Phase
        let effects: [Effect]
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "press opens mic and starts hold timer", events: [.pressed(at: ms(0))], phase: .arming,
            effects: [.capturePressContext(s1), .startCapture(s1), .startTimer(s1, .hold, after: Constants.hold)]),
        Row(name: "hold timer starts listening", events: [.pressed(at: ms(0)), .timer(s1, .hold)], phase: .listening,
            effects: [.showHUD(.listening), .startTimer(s1, .sttStart, after: Constants.sttStart),
                      .startTimer(s1, .cap, after: Constants.cap), .startTimer(s1, .keyPoll, after: keyPollInterval)]),
        Row(name: "tap is discarded silently", events: [.pressed(at: ms(0)), .released(at: ms(150))], phase: .idle, effects: teardown),
        Row(name: "chord in arming discards", events: [.pressed(at: ms(0)), .chord], phase: .idle, effects: teardown),
        Row(name: "chord in listening discards", events: listening + [.chord], phase: .idle, effects: teardown),
        Row(name: "Esc in arming discards", events: [.pressed(at: ms(0)), .cancel], phase: .idle, effects: teardown),
        Row(name: "Esc in listening cancels", events: listening + [.cancel], phase: .idle, effects: teardown),
        Row(name: "Esc in finalizing is ignored", events: finalizing + [.cancel], phase: .finalizing, effects: []),
        Row(name: "release in listening finalizes", events: finalizing, phase: .finalizing,
            effects: [.stopAudio(s1), .finalizeTranscriber(s1), .startTimer(s1, .finalize, after: Constants.finalize), .showHUD(.processing)]),
        Row(name: "release past hold before the timer is processed",
            events: [.pressed(at: ms(0)), loud, .released(at: ms(900))], phase: .finalizing,
            effects: [.showHUD(.listening), .startTimer(s1, .sttStart, after: Constants.sttStart),
                      .startTimer(s1, .cap, after: Constants.cap), .startTimer(s1, .keyPoll, after: keyPollInterval),
                      .stopAudio(s1), .finalizeTranscriber(s1), .startTimer(s1, .finalize, after: Constants.finalize), .showHUD(.processing)]),
        Row(name: "audio shorter than the minimum is discarded", events: listening + [.released(at: ms(250))], phase: .idle, effects: teardown),
        Row(name: "silent clip is discarded",
            events: [.pressed(at: ms(0)), .timer(s1, .hold), .audioPeak(s1, dBFS: -60), .released(at: ms(1500))],
            phase: .idle, effects: teardown),
        Row(name: "partial updates the HUD", events: listening + [.partial(s1, "hello")], phase: .listening,
            effects: [.showHUD(.partial("hello"))]),
        Row(name: "final text is cleaned and delivered", events: finalizing + [.finalized(s1, "  hello   world ")],
            phase: .delivering, effects: [.deliver(s1, "Hello world"), .startTimer(s1, .deliver, after: Constants.deliver)]),
        Row(name: "empty transcript shows \"Didn't catch that\"", events: finalizing + [.finalized(s1, "  ")], phase: .idle,
            effects: [.showHUD(.result(.empty)), .endSession(s1)]),
        Row(name: "insert shows Inserted", events: finalizing + [.finalized(s1, "hi"), .delivered(s1, .inserted)],
            phase: .idle, effects: [.showHUD(.result(.inserted)), .endSession(s1)]),
        Row(name: "copy shows its reason", events: finalizing + [.finalized(s1, "hi"), .delivered(s1, .copied(.secure))],
            phase: .idle, effects: [.showHUD(.error(.secure)), .endSession(s1)]),
        Row(name: "device change fails with the device message", events: listening + [.deviceChanged(s1)], phase: .idle,
            effects: [.stopAudio(s1), .cancelTranscriber(s1), .showHUD(.error(.device)), .endSession(s1)]),
        Row(name: "busy mic fails with the mic-busy message", events: [.pressed(at: ms(0)), .audioFailed(s1, .busy)], phase: .idle,
            effects: [.stopAudio(s1), .cancelTranscriber(s1), .showHUD(.error(.micBusy)), .endSession(s1)]),
        Row(name: "transcriber error fails with the transcription message", events: finalizing + [.transcriberFailed(s1)], phase: .idle,
            effects: [.stopAudio(s1), .cancelTranscriber(s1), .showHUD(.error(.stt)), .endSession(s1)]),
        Row(name: "cap auto-stops and processes", events: listening + [.timer(s1, .cap)], phase: .finalizing,
            effects: [.stopAudio(s1), .finalizeTranscriber(s1), .startTimer(s1, .finalize, after: Constants.finalize), .showHUD(.processing)]),
        Row(name: "no transcriber activity fails with the transcription message", events: listening + [.timer(s1, .sttStart)], phase: .idle,
            effects: [.stopAudio(s1), .cancelTranscriber(s1), .showHUD(.error(.stt)), .endSession(s1)]),
        Row(name: "transcriber activity satisfies the start watchdog",
            events: listening + [.transcriberActive(s1), .timer(s1, .sttStart)], phase: .listening, effects: []),
        Row(name: "slow finalize uses the last partial",
            events: finalizing + [.partial(s1, "hello there"), .timer(s1, .finalize)], phase: .delivering,
            effects: [.stopAudio(s1), .cancelTranscriber(s1), .deliver(s1, "Hello there"),
                      .startTimer(s1, .deliver, after: Constants.deliver)]),
        Row(name: "key poll re-arms while the key is down", events: listening + [.timer(s1, .keyPoll)], phase: .listening,
            effects: [.startTimer(s1, .keyPoll, after: keyPollInterval)]),
        Row(name: "key up briefly is tolerated",
            events: listening + [.keyState(isDown: false, at: ms(500)), .keyState(isDown: false, at: ms(700))],
            phase: .listening, effects: []),
        Row(name: "lost key-up cancels after the stuck-key window",
            events: listening + [.keyState(isDown: false, at: ms(500)), .keyState(isDown: false, at: ms(800))],
            phase: .idle, effects: teardown),
        Row(name: "press while busy is ignored", events: finalizing + [.pressed(at: ms(2000))], phase: .finalizing, effects: []),
        Row(name: "quit while listening stops the mic", events: listening + [.quit], phase: .idle, effects: teardown),
        Row(name: "release exactly at the hold threshold starts listening, then drops the short clip",
            events: [.pressed(at: ms(0)), loud, .released(at: ms(200))], phase: .idle,
            effects: [.showHUD(.listening), .startTimer(s1, .sttStart, after: Constants.sttStart),
                      .startTimer(s1, .cap, after: Constants.cap), .startTimer(s1, .keyPoll, after: keyPollInterval)] + teardown),
        Row(name: "audio exactly the minimum length is kept", events: listening + [.released(at: ms(300))], phase: .finalizing,
            effects: [.stopAudio(s1), .finalizeTranscriber(s1), .startTimer(s1, .finalize, after: Constants.finalize), .showHUD(.processing)]),
        Row(name: "denied mic fails with the permission message", events: [.pressed(at: ms(0)), .audioFailed(s1, .denied)], phase: .idle,
            effects: [.stopAudio(s1), .cancelTranscriber(s1), .showHUD(.error(.mic)), .endSession(s1)]),
        Row(name: "press with no model for the language", events: [.modelStatus(.unavailable(language: "Klingon")), .pressed(at: ms(0))],
            phase: .idle, effects: [.showHUD(.error(.modelUnavailable(language: "Klingon")))]),
        Row(name: "device change after capture is ignored", events: finalizing + [.deviceChanged(s1)], phase: .finalizing, effects: []),
        Row(name: "transcriber error while delivering is ignored",
            events: finalizing + [.finalized(s1, "hi"), .transcriberFailed(s1)], phase: .delivering, effects: []),
        Row(name: "partial while finalizing doesn't touch the HUD", events: finalizing + [.partial(s1, "late")],
            phase: .finalizing, effects: []),
        Row(name: "plain copy shows Copied as a result",
            events: finalizing + [.finalized(s1, "hi"), .delivered(s1, .copied(.copied))], phase: .idle,
            effects: [.showHUD(.result(.copied)), .endSession(s1)]),
        Row(name: "hung delivery copies the literal and ends",
            events: finalizing + [.finalized(s1, "stuck"), .timer(s1, .deliver)], phase: .idle,
            effects: [.copyToPasteboard("Stuck"), .showHUD(.result(.copied)), .endSession(s1)]),
        Row(name: "delivery timer after delivery is ignored",
            events: finalizing + [.finalized(s1, "ok"), .delivered(s1, .inserted), .timer(s1, .deliver)],
            phase: .idle, effects: []),
        Row(name: "quit while idle does nothing", events: [.quit], phase: .idle, effects: []),
        Row(name: "quit while finalizing cancels the transcriber", events: finalizing + [.quit], phase: .idle, effects: teardown),
        Row(name: "press after quit is ignored", events: [.quit, .pressed(at: ms(0))], phase: .idle, effects: []),
        Row(name: "device change from an earlier session is ignored",
            events: listening + [.cancel, .pressed(at: ms(3000)), .deviceChanged(s1)], phase: .arming, effects: []),
        Row(name: "sleep while delivering copies the literal",
            events: finalizing + [.finalized(s1, "keep me"), .systemSleep], phase: .idle,
            effects: [.copyToPasteboard("Keep me")] + teardown),
    ]

    @Test(arguments: rows)
    func transition(_ row: Row) {
        let (state, effects) = run(row.events)
        #expect(state.phase == row.phase)
        #expect(effects == row.effects)
    }

    // MARK: Preconditions at press

    @Test func pressWithoutMicShowsPermissionError() {
        let (state, effects) = run([.micPermission(granted: false), .pressed(at: ms(0))])
        #expect(state.phase == .idle)
        #expect(effects == [.showHUD(.error(.mic))])
    }

    @Test func pressWhileModelDownloads() {
        let (state, effects) = run([.modelStatus(.downloading(percent: 42)), .pressed(at: ms(0))])
        #expect(state.phase == .idle)
        #expect(effects == [.showHUD(.error(.modelDownloading(percent: 42)))])
    }

    // MARK: Session tokens: late events from old sessions

    @Test func staleFinalIsDropped() {
        let s2 = SessionID(2)
        // Session 1's finalize hangs and is abandoned; session 2 reaches finalizing;
        // then session 1's final finally arrives.
        let first = finalizing + [.partial(s1, "slow"), .timer(s1, .finalize), .delivered(s1, .inserted)]
        let second: [SessionEvent] = [.pressed(at: ms(10_000)), .timer(s2, .hold), .audioPeak(s2, dBFS: -20),
                                      .released(at: ms(12_000))]
        let (before, _) = run(first + second)
        #expect(before.phase == .finalizing)
        let (after, effects) = reduce(before, .finalized(s1, "old text"))
        #expect(after == before)
        #expect(effects.isEmpty)
        #expect(after.literal == "Slow")
        let (_, delivered) = reduce(after, .finalized(s2, "new text"))
        #expect(delivered == [.deliver(s2, "New text"), .startTimer(s2, .deliver, after: Constants.deliver)])
    }

    @Test func staleHoldTimerDoesNotStartListening() {
        let (state, _) = run([.pressed(at: ms(0)), .released(at: ms(50)), .pressed(at: ms(100)), .timer(s1, .hold)])
        #expect(state.phase == .arming)
        #expect(state.current == SessionID(2))
    }

    @Test func literalSurvivesTheNextSession() {
        let (state, _) = run(finalizing + [.finalized(s1, "first"), .delivered(s1, .inserted), .pressed(at: ms(5000))])
        #expect(state.literal == "First")
    }

    // MARK: Watchdog streak

    @Test func twoAbandonsInARowAskForRestart() {
        let s2 = SessionID(2)
        let second: [SessionEvent] = [.pressed(at: ms(10_000)), .timer(s2, .hold), .audioPeak(s2, dBFS: -20), .timer(s2, .sttStart)]
        let (state, effects) = run(listening + [.timer(s1, .sttStart)] + second)
        #expect(state.phase == .idle)
        #expect(effects.contains(.showHUD(.error(.restart))))
    }

    @Test func successfulFinalizeResetsTheStreak() {
        let (state, _) = run(listening + [.timer(s1, .sttStart)])
        #expect(state.consecutiveAbandons == 1)
        let s2 = SessionID(2)
        let (after, _) = run([.pressed(at: ms(10_000)), .timer(s2, .hold), .audioPeak(s2, dBFS: -20),
                              .released(at: ms(12_000)), .finalized(s2, "ok")], from: state)
        #expect(after.consecutiveAbandons == 0)
    }

    @Test func secondAbandonStillDeliversThePartial() {
        let s2 = SessionID(2)
        let second: [SessionEvent] = [.pressed(at: ms(10_000)), .timer(s2, .hold), .audioPeak(s2, dBFS: -20),
                                      .released(at: ms(12_000)), .partial(s2, "keep this"), .timer(s2, .finalize)]
        let (state, effects) = run(listening + [.timer(s1, .sttStart)] + second)
        #expect(effects.contains(.deliver(s2, "Keep this")))
        let (_, done) = reduce(state, .delivered(s2, .inserted))
        #expect(done == [.showHUD(.error(.restart)), .endSession(s2)])
    }

    @Test func partialFallbackReportsSlowTranscription() {
        let (_, effects) = run(finalizing + [.partial(s1, "slow"), .timer(s1, .finalize), .delivered(s1, .inserted)])
        #expect(effects == [.showHUD(.result(.finalize)), .endSession(s1)])
    }

    // MARK: One session, honest mic, and stale events, over random sequences

    @Test func randomSequencesKeepTheMicHonest() {
        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0..<1000 {
            var state = SessionState()
            var openFor: SessionID?
            var now = 0

            func step(_ event: SessionEvent) {
                let (next, effects) = reduce(state, event)
                // An event from another session changes nothing.
                if let id = event.sessionID, id != state.current {
                    #expect(next == state)
                    #expect(effects.isEmpty)
                }
                for effect in effects {
                    if case .startCapture(let id) = effect {
                        #expect(openFor == nil, "one session at a time")
                        openFor = id
                    }
                    if case .stopAudio(let id) = effect, id == openFor { openFor = nil }
                }
                state = next
                if openFor != nil { #expect(state.phase == .arming || state.phase == .listening) }
            }

            for _ in 0..<rng.next(upTo: 40) {
                now += rng.next(upTo: 400)
                // Mostly the live session, sometimes an old or not-yet-issued one.
                let id = SessionID(UInt64(max(1, Int(state.lastIssued) + 1 - rng.next(upTo: 4))))
                step(randomEvent(&rng, id: id, at: ms(now)))
            }
            // Drain: let whatever is in flight finish, or be abandoned, normally.
            for _ in 0..<10 {
                guard let id = state.current else { break }
                switch state.phase {
                case .arming, .listening: step(.released(at: ms(now + 10_000)))
                case .finalizing: step(.timer(id, .finalize))
                case .delivering: step(.delivered(id, .inserted))
                case .idle: break
                }
            }
            #expect(state.phase == .idle)
            #expect(state.current == nil)
            #expect(openFor == nil)
        }
    }

    private func randomEvent(_ rng: inout SplitMix64, id: SessionID, at: KeyTime) -> SessionEvent {
        let kinds: [TimerKind] = [.hold, .sttStart, .cap, .finalize, .keyPoll, .deliver]
        switch rng.next(upTo: 22) {
        case 0, 1: return .pressed(at: at)
        case 2, 3: return .released(at: at)
        case 4: return .chord
        case 5: return .cancel
        case 6: return .keyState(isDown: rng.next(upTo: 2) == 0, at: at)
        case 7: return .audioPeak(id, dBFS: rng.next(upTo: 2) == 0 ? -20 : -70)
        case 8: return .audioFailed(id, rng.next(upTo: 2) == 0 ? .busy : .denied)
        case 9: return .deviceChanged(id)
        case 10: return .partial(id, "partial")
        case 11: return .finalized(id, rng.next(upTo: 3) == 0 ? "" : "final")
        case 12: return .transcriberFailed(id)
        case 13: return .timer(id, kinds[rng.next(upTo: kinds.count)])
        case 14: return .delivered(id, .inserted)
        case 15: return .audioStarted(id)
        case 16: return .transcriberActive(id)
        case 17: return .micPermission(granted: true)
        case 18: return .modelStatus(rng.next(upTo: 2) == 0 ? .installed : .downloading(percent: 50))
        case 19: return rng.next(upTo: 10) == 0 ? .quit : .systemSleep
        default: return .delivered(id, .copied(.noField))
        }
    }
}

/// Small deterministic generator so the property test is reproducible.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(upTo bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

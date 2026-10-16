import Testing
@testable import SpeakCore

/// The whole session pipeline with fakes and a manual clock.
@MainActor
final class Harness {
    let clock = TestClock()
    let audio = FakeAudioSource()
    let transcriber = FakeTranscriber()
    let env = FakeDeliveryEnvironment()
    let pasteboard = FakePasteboard()
    let hotkey: FakeHotkeySource
    let controller: SessionController

    init() {
        let clock = self.clock
        hotkey = FakeHotkeySource(clock: { clock.elapsed })
        controller = SessionController(
            audio: audio, transcriber: transcriber,
            deliverer: Deliverer(env: env, pasteboard: pasteboard, clock: clock),
            hotkey: hotkey, clock: clock)
        let controller = self.controller
        let keys = hotkey.start(.rightOption)
        Task { await controller.run() }
        Task { await controller.listen(to: keys) }
    }

    func hold(for duration: Duration) async {
        hotkey.press()
        await clock.advance(by: duration)
        hotkey.release()
        await clock.advance(by: .milliseconds(100))
    }

    var phase: Phase { controller.state.phase }
    var hud: HUDContent? { controller.hud.content }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LifecycleTests {
    static let fakeText = "Hello world, this is a fake transcript."

    @Test func holdProducesOneSessionAndPastes() async {
        let h = Harness()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle })
        #expect(h.audio.opens == 1)
        #expect(await eventually { !h.audio.isOpen })
        #expect(h.env.pastes == [9])
        #expect(h.pasteboard.current.writes == [.transient])
        #expect(h.controller.lastTranscript == Self.fakeText)
        #expect(await eventually { h.hud == .result(.inserted) })
        await h.clock.advance(by: Constants.restore)
        #expect(h.pasteboard.text == "banana")
    }

    @Test func tapIsSilent() async {
        let h = Harness()
        await h.hold(for: .milliseconds(100))
        #expect(await eventually { h.phase == .idle })
        #expect(await eventually { !h.audio.isOpen })
        #expect(await eventually { h.hud == nil })
        #expect(h.env.pastes.isEmpty)
    }

    @Test func chordAbortsWithoutHUD() async {
        let h = Harness()
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(150))
        h.hotkey.emit(.chord)
        await h.clock.advance(by: .milliseconds(100))
        h.hotkey.release()
        await h.clock.advance(by: .milliseconds(100))
        #expect(await eventually { h.phase == .idle })
        #expect(await eventually { !h.audio.isOpen })
        #expect(await eventually { h.hud == nil })
        #expect(h.env.pastes.isEmpty)
    }

    @Test func rapidPressReleasePressLeavesNoStuckMic() async {
        let h = Harness()
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(20))
        h.hotkey.release()
        await h.clock.advance(by: .milliseconds(20))
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.env.pastes.count == 1 && h.phase == .idle })
        #expect(await eventually { !h.audio.isOpen })
    }

    @Test func tapDuringSlowEngineStartStopsAfterStart() async {
        let h = Harness()
        h.audio.configure { $0.gated = true }
        await h.hold(for: .milliseconds(50))
        #expect(await eventually { h.phase == .idle })
        h.audio.openGate()
        #expect(await eventually { h.audio.opens == 1 && !h.audio.isOpen })
    }

    @Test func holdReleasedBeforeEngineStartsClosesTheMicAfterwards() async {
        let h = Harness()
        h.audio.configure { $0.gated = true }
        await h.hold(for: .milliseconds(1000))
        // No audio was captured, so the clip counts as silent and is dropped quietly.
        #expect(await eventually { h.phase == .idle })
        #expect(h.hud == nil)
        h.audio.openGate()
        #expect(await eventually { h.audio.opens == 1 && !h.audio.isOpen })
        #expect(h.env.pastes.isEmpty)
    }

    @Test func slowEngineStartDuringHoldStillDelivers() async {
        let h = Harness()
        h.audio.configure { $0.gated = true }
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(400))
        h.audio.openGate()
        await h.clock.advance(by: .milliseconds(600))
        h.hotkey.release()
        #expect(await eventually { h.env.pastes.count == 1 && h.phase == .idle })
        #expect(!h.audio.isOpen)
    }

    @Test func escWhileListeningCancels() async {
        let h = Harness()
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(500))
        h.hotkey.emit(.cancel)
        await h.clock.advance(by: .milliseconds(50))
        #expect(await eventually { h.phase == .idle })
        #expect(await eventually { !h.audio.isOpen })
        #expect(h.transcriber.cancelCount == 1)
        #expect(await eventually { h.hud == nil })
        h.hotkey.release()
        await h.clock.advance(by: .milliseconds(50))
        #expect(h.env.pastes.isEmpty)
    }

    @Test func deviceChangeFails() async {
        let h = Harness()
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(500))
        h.audio.unplug()
        await h.clock.advance(by: .milliseconds(50))
        #expect(await eventually { h.phase == .idle })
        #expect(await eventually { !h.audio.isOpen })
        #expect(await eventually { h.hud == .error(.device) })
    }

    @Test func busyMicFails() async {
        let h = Harness()
        h.audio.configure { $0.failure = .busy }
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(50))
        #expect(await eventually { h.phase == .idle })
        #expect(await eventually { h.hud == .error(.micBusy) })
    }

    @Test func capStopsAndProcesses() async {
        let h = Harness()
        h.hotkey.press()
        #expect(await h.clock.advance(until: { h.env.pastes.count == 1 && h.phase == .idle },
                                      step: .milliseconds(100), limit: Constants.cap * 2))
        #expect(h.clock.elapsed >= Constants.cap)
        #expect(await eventually { !h.audio.isOpen })
    }

    @Test func slowFinalizeUsesPartialText() async {
        let h = Harness()
        h.transcriber.configure { $0.hangOnFinalize = true }
        await h.hold(for: .milliseconds(1000))
        #expect(await eventually { h.phase == .finalizing })
        let released = h.clock.elapsed
        #expect(await h.clock.advance(until: { h.env.pastes.count == 1 }))
        #expect(h.clock.elapsed - released >= Constants.finalize - .milliseconds(150))
        #expect(h.controller.lastTranscript == "Hello")
        #expect(await eventually { h.hud == .result(.finalize) })
    }

    @Test func silentTranscriberFailsThenAsksForRestart() async {
        let h = Harness()
        h.transcriber.configure { $0.silent = true }
        h.hotkey.press()
        #expect(await h.clock.advance(until: { h.hud == .error(.stt) }))
        #expect(h.clock.elapsed >= Constants.hold + Constants.sttStart)
        #expect(await eventually { h.phase == .idle && !h.audio.isOpen })
        h.hotkey.release()
        await h.clock.advance(by: .milliseconds(50))

        let second = h.clock.elapsed
        h.hotkey.press()
        #expect(await h.clock.advance(until: { h.hud == .error(.restart) }))
        #expect(h.clock.elapsed - second >= Constants.hold + Constants.sttStart)
    }

    @Test func lostKeyUpIsCaughtByWatchdog() async {
        let h = Harness()
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(500))
        h.hotkey.loseRelease()
        let lost = h.clock.elapsed
        #expect(await h.clock.advance(until: { h.phase == .idle }))
        #expect(h.clock.elapsed - lost >= Constants.stuck)
        #expect(await eventually { !h.audio.isOpen })
        #expect(h.env.pastes.isEmpty)
    }

    @Test func quitWhileDeliveringKeepsTheLiteral() async {
        let h = Harness()
        // Held modifiers keep the delivery waiting.
        h.env.update { $0.modifierPolls = 1000 }
        await h.hold(for: .milliseconds(1000))
        #expect(await eventually { h.phase == .delivering })
        // Quit runs while the clock keeps moving, as it would for real; a delivery
        // that ignored the quit would otherwise just block it.
        let controller = h.controller
        _ = await h.clock.drive(Task { await controller.shutdown() })
        #expect(h.pasteboard.current.writes.first == .normal)
        #expect(h.pasteboard.text == Self.fakeText)
        // The abandoned delivery must not paste into whatever is frontmost later.
        await h.clock.advance(by: Constants.modWait * 2)
        #expect(h.env.pastes.isEmpty)
        #expect(h.pasteboard.current.writes == [.normal])
    }

    @Test func staleStopNeverClosesTheNextSessionsMic() async {
        let h = Harness()
        h.audio.configure { $0.gated = true }
        // Session 1: a tap while its engine is still starting.
        await h.hold(for: .milliseconds(50))
        // Session 2 presses before session 1's start has finished.
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(50))
        // Finish starts newest-first: if starts weren't ordered across sessions,
        // session 1's late stop would close session 2's engine.
        for _ in 0..<4 {
            h.audio.openNewestGate()
            await settle()
        }
        await h.clock.advance(by: .milliseconds(500))
        #expect(await eventually { h.phase == .listening })
        #expect(h.audio.isOpen)
        h.hotkey.release()
        #expect(await eventually { h.env.pastes.count == 1 && h.phase == .idle })
        #expect(await eventually { !h.audio.isOpen })
    }

    @Test func quitWhileListeningClosesTheMic() async {
        let h = Harness()
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(500))
        await h.controller.shutdown()
        #expect(await eventually { !h.audio.isOpen })
    }

    @Test func newPressPutsTheClipboardBackEarly() async {
        let h = Harness()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.env.pastes.count == 1 })
        #expect(h.pasteboard.text == Self.fakeText)
        h.hotkey.press()
        #expect(await eventually { h.pasteboard.text == "banana" })
        #expect(h.clock.elapsed < .milliseconds(1600) + Constants.restore)
    }

    @Test func pressWhileFinalizingIsIgnored() async {
        let h = Harness()
        h.transcriber.configure { $0.hangOnFinalize = true }
        await h.hold(for: .milliseconds(1000))
        h.hotkey.press()
        await h.clock.advance(by: .milliseconds(50))
        #expect(await eventually { h.phase == .finalizing })
        #expect(h.controller.state.current == SessionID(1))
    }
}

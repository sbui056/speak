import Testing
@testable import SpeakCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LifecycleTests {
    @Test func holdProducesOneSessionAndPastes() async {
        let h = Harness()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle })
        #expect(h.audio.opens == 1)
        #expect(await eventually { !h.audio.isOpen })
        #expect(h.env.pastes == [9])
        #expect(h.pasteboard.current.writes == [.transient])
        #expect(h.controller.lastTranscript == Harness.fakeText)
        #expect(await eventually { h.hud == .result(.inserted) })
        await h.clock.advance(by: Constants.restore)
        #expect(h.pasteboard.text == "banana")
    }

    @Test func theSessionsLoudestLevelOutlastsTheMeter() async {
        let h = Harness()
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle })
        #expect(h.controller.level == 0) // the meter drops when the mic closes
        #expect(h.controller.loudestLevel == 0.3) // kept for the timing log
    }

    @Test func testInsertGoesThroughTheRealDeliveryPath() async {
        let h = Harness()
        #expect(await h.controller.insert("Speak can type here.") == .inserted)
        #expect(h.env.pastes.count == 1)
        #expect(h.pasteboard.text == "Speak can type here.")
        #expect(h.hud == .result(.inserted))
        #expect(h.controller.lastTranscript == nil) // a test isn't a dictation
    }

    @Test func settingsTestTypesIntoSpeaksOwnField() async {
        let h = Harness()
        h.env.update { $0.frontmostPID = nil } // the Settings window is in front
        #expect(await h.controller.insertIntoOwnField("Speak can type here.") == .inserted)
        #expect(h.env.pastes.count == 1)
        #expect(h.hud == .result(.inserted))
    }

    @Test func pasteLastNeverTargetsSpeakItself() async {
        let h = Harness()
        h.env.update { $0.frontmostPID = nil }
        #expect(await h.controller.insert("Hi") == .copied(.appChanged))
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
        #expect(h.pasteboard.text == Harness.fakeText)
        // The abandoned delivery must not paste into whatever is frontmost later.
        await h.clock.advance(by: Constants.modWait * 2)
        #expect(h.env.pastes.isEmpty)
        #expect(h.pasteboard.current.writes == [.normal])
    }

    @Test func hungPasteIsRescuedByTheWatchdog() async {
        let h = Harness()
        h.env.holdPastes() // the target app never processes ⌘V
        await h.hold(for: .milliseconds(1000))
        #expect(await eventually { h.phase == .delivering })
        let started = h.clock.elapsed
        #expect(await h.clock.advance(until: { h.phase == .idle }))
        #expect(h.clock.elapsed - started >= Constants.deliver - .milliseconds(150))
        #expect(h.pasteboard.text == Harness.fakeText)
        #expect(h.pasteboard.current.writes == [.transient, .normal])
        #expect(await eventually { h.hud == .result(.copied) })
        // The next dictation still works.
        h.env.update { $0.pastes = [] }
        await h.hold(for: .milliseconds(1000))
        #expect(await eventually { h.phase == .delivering })
    }

    @Test func pasteFinishingAfterTheRescueIsNotTimed() async {
        let h = Harness()
        var stages: [SessionStage] = []
        h.controller.onStage = { stages.append($0) }
        h.env.holdPastes()
        await h.hold(for: .milliseconds(1000))
        #expect(await eventually { h.phase == .delivering })
        #expect(await h.clock.advance(until: { h.phase == .idle }))
        // The rescued dictation was not delivered by paste, so the late ⌘V reports no stage.
        h.env.releasePaste()
        await settle()
        #expect(!stages.contains { if case .delivered = $0 { true } else { false } })
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
        // Starts run one at a time, so each gate appears only after the previous
        // one opened. Wait for each instead of opening a fixed number of times:
        // on a slow runner a gate could arrive after the loop and never open.
        for _ in 0..<2 {
            #expect(await eventually { h.audio.waitingStarts > 0 })
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
        #expect(h.pasteboard.text == Harness.fakeText)
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

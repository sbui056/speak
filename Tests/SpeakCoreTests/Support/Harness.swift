@testable import SpeakCore

/// The whole session pipeline with fakes and a manual clock.
@MainActor
final class Harness {
    /// What the fake transcriber hears by default.
    nonisolated static let fakeText = "Hello world, this is a fake transcript."

    let clock = TestClock()
    let audio = FakeAudioSource()
    let transcriber = FakeTranscriber()
    let env = FakeDeliveryEnvironment()
    let pasteboard = FakePasteboard()
    let rewriter = FakeRewriter()
    let hotkey: FakeHotkeySource
    let controller: SessionController

    init(spelling: FakeSpellChecker = FakeSpellChecker()) {
        let clock = self.clock
        hotkey = FakeHotkeySource(clock: { clock.elapsed })
        controller = SessionController(
            audio: audio, transcriber: transcriber,
            deliverer: Deliverer(env: env, pasteboard: pasteboard, clock: clock),
            rewriter: rewriter, spelling: spelling,
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

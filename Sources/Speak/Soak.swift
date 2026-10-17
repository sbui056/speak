#if DEBUG
import AppKit
import SpeakCore

/// Debug builds only, for `scripts/soak.sh`: `SPEAK_FAKE=1 SPEAK_SOAK=<n>` drives n
/// fake dictations (alternating Literal and Polished, no preview) with a fake
/// hotkey and a fake paste target, so nothing is typed anywhere. It then prints
/// the footprint before and after and stays idle so `leaks` can inspect it.
struct Soak {
    let count: Int
    let hotkey = FakeHotkeySource(clock: { .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))) })
    let target = FakeDeliveryEnvironment()

    init?(environment: [String: String]) {
        guard environment["SPEAK_FAKE"] == "1", let count = environment["SPEAK_SOAK"].flatMap(Int.init), count > 0
        else { return nil }
        self.count = count
    }

    private static let warmup = 5

    @MainActor
    func run(_ controller: SessionController) async {
        controller.send(.micPermission(granted: true))
        try? await Task.sleep(for: .seconds(1)) // let launch-time settings land first
        var stuck = 0
        for i in 0..<Self.warmup { if await !dictate(i, controller) { stuck += 1 } }
        let before = physFootprintMB() ?? 0
        for i in 0..<count { if await !dictate(i, controller) { stuck += 1 } }
        try? await Task.sleep(for: .seconds(2)) // clipboard restores and HUD fades finish
        let after = physFootprintMB() ?? 0
        print(String(format: "soak done dictations=%d inserted=%d stuck=%d before=%.1fMB after=%.1fMB growth=%+.1fMB",
                     count, target.pastes.count - Self.warmup, stuck, before, after, after - before))
        fflush(stdout)
    }

    /// One press-hold-release. Returns false if the session didn't get back to idle in time.
    @MainActor
    private func dictate(_ i: Int, _ controller: SessionController) async -> Bool {
        controller.send(.rewriteSettings(mode: i.isMultiple(of: 2) ? .literal : .polished, preview: .never))
        hotkey.press()
        try? await Task.sleep(for: .milliseconds(400))
        hotkey.release()
        for _ in 0..<500 {
            try? await Task.sleep(for: .milliseconds(20))
            if controller.state.phase == .idle { return true }
        }
        return false
    }
}
#endif

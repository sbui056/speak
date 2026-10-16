import Testing
@testable import SpeakCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PermissionsTests {
    @Test func grantDuringRunIsNoticedByThePoll() async {
        let clock = TestClock()
        let checker = FakePermissionChecker(granted: [.microphone, .accessibility])
        let model = PermissionsModel(checker: checker, clock: clock)
        await model.refresh()
        #expect(model.missing == [.inputMonitoring])
        checker.set(.inputMonitoring, granted: true)
        #expect(await clock.advance(until: { model.allGranted }, limit: PermissionsModel.pollInterval * 3))
        // The event tap can only start after a relaunch.
        #expect(model.needsRelaunch)
    }

    @Test func grantedAtLaunchNeedsNoRelaunch() async {
        let model = PermissionsModel(checker: FakePermissionChecker(), clock: TestClock())
        await model.refresh()
        #expect(model.allGranted)
        #expect(!model.needsRelaunch)
    }

    @Test func changesAreReported() async {
        let checker = FakePermissionChecker()
        let model = PermissionsModel(checker: checker, clock: TestClock())
        var changes: [(Permission, Bool)] = []
        model.onChange = { changes.append(($0, $1)) }
        await model.refresh()
        checker.set(.microphone, granted: false)
        await model.refresh()
        #expect(changes.last.map { $0.0 == .microphone && !$0.1 } == true)
    }

    @Test func requestWithoutASystemPromptOpensSettings() async {
        let checker = FakePermissionChecker(granted: [])
        let model = PermissionsModel(checker: checker, clock: TestClock())
        await model.request(.accessibility)
        #expect(checker.opened == [.accessibility])
        await model.request(.microphone)
        #expect(checker.opened == [.accessibility])
    }

    @Test(arguments: [
        ([Permission.inputMonitoring: false], false, SpeechModelStatus.installed, Messages.inputMonitoring.text),
        ([.inputMonitoring: true], true, .installed, Messages.inputMonitoringRelaunch.text),
        ([.inputMonitoring: true, .microphone: false], false, .installed, Messages.mic.text),
        ([.inputMonitoring: true, .microphone: true], false, .downloading(percent: 42), "Speech model not ready (downloading 42%)"),
        ([.inputMonitoring: true, .microphone: true, .accessibility: false], false, .installed, Messages.accessibility.text),
        ([.inputMonitoring: true, .microphone: true, .accessibility: true], false, .installed, "Ready — hold Right Option"),
    ])
    func statusLine(_ permissions: [Permission: Bool], _ relaunch: Bool, _ model: SpeechModelStatus, _ expected: String) {
        #expect(menuStatus(permissions: permissions, needsRelaunch: relaunch, model: model, hotkey: .rightOption) == expected)
    }

    @Test func iconFollowsThePhase() {
        #expect(MenuIcon(phase: .idle, hasProblem: false).symbol == "mic")
        #expect(MenuIcon(phase: .listening, hasProblem: true).symbol == "mic.fill")
        #expect(MenuIcon(phase: .finalizing, hasProblem: false).symbol == "ellipsis.circle")
        #expect(MenuIcon(phase: .idle, hasProblem: true).symbol == "exclamationmark.triangle")
    }
}

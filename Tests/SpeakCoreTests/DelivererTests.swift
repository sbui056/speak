import Testing
@testable import SpeakCore

@Suite(.timeLimit(.minutes(1)))
struct DelivererTests {
    let clock = TestClock()
    let env = FakeDeliveryEnvironment()
    let pasteboard = FakePasteboard()
    var deliverer: Deliverer { Deliverer(env: env, pasteboard: pasteboard, clock: clock) }

    /// The context captured at press, with the same focused element as now.
    func pressContext() async -> PressContext {
        PressContext(pid: await env.frontmostPID(), focus: await env.focusedElement())
    }

    @Test func pastesWithTransientMarkerAndRestoresAfterDelay() async {
        let d = deliverer
        #expect(await d.deliver("Hi", context: await pressContext()) == .inserted)
        #expect(pasteboard.current.writes == [.transient])
        #expect(pasteboard.text == "Hi")
        await clock.advance(by: Constants.restore - .milliseconds(10))
        #expect(pasteboard.text == "Hi")
        await clock.advance(by: .milliseconds(20))
        #expect(pasteboard.text == "banana")
    }

    @Test func slowAppsGetTheLongerRestoreDelay() async {
        env.update { $0.bundleID = "com.microsoft.rdc.macos" }
        let d = deliverer
        _ = await d.deliver("Hi", context: await pressContext())
        await clock.advance(by: Constants.restore + .milliseconds(100))
        #expect(pasteboard.text == "Hi")
        await clock.advance(by: Constants.restoreSlow)
        #expect(pasteboard.text == "banana")
    }

    @Test func userCopyAfterPasteIsNotOverwritten() async {
        let d = deliverer
        _ = await d.deliver("Hi", context: await pressContext())
        pasteboard.userCopies("mine")
        await clock.advance(by: Constants.restore * 2)
        #expect(pasteboard.text == "mine")
        #expect(pasteboard.current.restores == 0)
    }

    @Test func lazyItemsSkipTheRestore() async {
        pasteboard.update { $0.hasLazyItem = true }
        let d = deliverer
        _ = await d.deliver("Hi", context: await pressContext())
        await clock.advance(by: Constants.restore * 2)
        #expect(pasteboard.current.restores == 0)
        #expect(pasteboard.text == "Hi")
    }

    @Test func restoreNowPutsTheClipboardBackEarly() async {
        let d = deliverer
        _ = await d.deliver("Hi", context: await pressContext())
        await d.restoreNow()
        #expect(pasteboard.text == "banana")
        await clock.advance(by: Constants.restore * 2)
        #expect(pasteboard.current.restores == 1)
    }

    @Test func fallbackCopyIsANormalItem() async {
        env.update { $0.accessibilityTrusted = false }
        #expect(await deliverer.deliver("Hi", context: await pressContext()) == .copied(.accessibility))
        #expect(pasteboard.current.writes == [.normal])
        #expect(env.pastes.isEmpty)
    }

    @Test func secureFieldCopyIsConcealed() async {
        env.update { $0.secureInput = true }
        #expect(await deliverer.deliver("Hi", context: await pressContext()) == .copied(.secure))
        #expect(pasteboard.current.writes == [.concealed])
    }

    @Test func focusMovedIsDetectedByIdentity() async {
        let context = await pressContext()
        env.update { $0.focus = .element(ElementRef(FakeDeliveryEnvironment.Element("other"))) }
        #expect(await deliverer.deliver("Hi", context: context) == .copied(.focusChanged))
    }

    @Test func pasteWaitsForModifiersToBeReleased() async {
        env.update { $0.modifierPolls = 3 }
        let d = deliverer
        let context = await pressContext()
        let result = Task { await d.deliver("Hi", context: context) }
        #expect(await clock.drive(result) == .inserted)
    }

    @Test func modifiersStillHeldAfterTheWaitCopy() async {
        env.update { $0.modifierPolls = 1000 }
        let d = deliverer
        let context = await pressContext()
        let result = Task { await d.deliver("Hi", context: context) }
        #expect(await clock.drive(result) == .copied(.modifiers))
    }

    @Test func overlappingDeliveriesKeepTheUsersClipboard() async {
        env.holdPastes()
        let d = deliverer
        let context = await pressContext()
        // The first paste is mid-flight (⌘V posted, restore not yet scheduled)
        // when the second one starts. Unserialized, the second would snapshot
        // the first's text instead of the user's clipboard.
        let first = Task { await d.deliver("One", context: context) }
        #expect(await eventually { env.heldPastes == 1 })
        let second = Task { await d.deliver("Two", context: context) }
        await settle()
        for _ in 0..<10_000 where env.pastes.count < 2 || env.heldPastes > 0 {
            env.releasePaste()
            await Task.yield()
        }
        _ = await (first.value, second.value)
        await clock.advance(by: Constants.restore * 2)
        #expect(pasteboard.text == "banana")
    }

    @Test func cancelledDeliveryTouchesNothing() async {
        env.update { $0.modifierPolls = 1000 }
        let d = deliverer
        let context = await pressContext()
        let task = Task { await d.deliver("Hi", context: context) }
        await clock.advance(by: .milliseconds(100))
        task.cancel()
        #expect(await clock.drive(task) == .empty)
        #expect(pasteboard.current.writes.isEmpty)
        #expect(env.pastes.isEmpty)
    }

    @Test func copyWritesANormalItem() async {
        await deliverer.copy("Hi")
        #expect(pasteboard.current.writes == [.normal])
        #expect(env.pastes.isEmpty)
    }

    @Test func speakFrontmostAtPressCopies() async {
        let context = PressContext(pid: nil, focus: await env.focusedElement())
        #expect(await deliverer.deliver("Hi", context: context) == .copied(.appChanged))
    }

    @Test func ownTestFieldPastesWhileSpeakIsFrontmostWithoutAnUndoOffer() async {
        env.update { $0.frontmostPID = nil }
        let d = deliverer
        #expect(await d.deliver("Hi", context: await d.captureOwnFieldContext()) == .inserted)
        #expect(env.pastes.count == 1)
        #expect(await d.canUndo == false) // ⌘Z later could land in whatever app is in front
    }

    @Test func noFocusedFieldCopies() async {
        let context = await pressContext()
        env.update { $0.focus = .none }
        #expect(await deliverer.deliver("Hi", context: context) == .copied(.noField))
    }

    @Test func accessibilityQueryErrorStillPastes() async {
        env.update { $0.focus = .error }
        #expect(await deliverer.deliver("Hi", context: await pressContext()) == .inserted)
    }

    @Test func emptyTextDoesNothing() async {
        #expect(await deliverer.deliver("  ", context: await pressContext()) == .empty)
        #expect(pasteboard.current.writes.isEmpty)
    }

    @Test func dvorakUsesTheKeyThatTypesV() async {
        // On Dvorak, "v" sits where ANSI has "." (keycode 47); keycode 9 types "k".
        env.update { $0.layout = [47: "v", 9: "k"] }
        _ = await deliverer.deliver("Hi", context: await pressContext())
        #expect(env.pastes == [47])
    }

    @Test func layoutWithoutVFallsBackToANSI() {
        #expect(keyCode(for: "v", in: [:]) == 9)
    }
}

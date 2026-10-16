import Testing
@testable import SpeakCore

/// Flag values as macOS reports them.
private enum Flags {
    static let option: UInt64 = 0x8_0000
    static let command: UInt64 = 0x10_0000
    static let shift: UInt64 = 0x2_0000
    static let rightOption: UInt64 = option | 0x40
    static let leftOption: UInt64 = option | 0x20
    static let rightCommand: UInt64 = command | 0x10
    static let leftShift: UInt64 = shift | 0x02
}

private enum Code {
    static let rightOption: UInt16 = 61
    static let leftOption: UInt16 = 58
    static let rightCommand: UInt16 = 54
    static let leftShift: UInt16 = 56
    static let e: UInt16 = 14
}

struct HotkeyDecoderTests {
    private func t(_ ms: Int) -> KeyTime { .milliseconds(ms) }

    @Test func pressAndRelease() {
        var d = HotkeyDecoder(key: .rightOption)
        #expect(d.decode(.flagsChanged, keyCode: Code.rightOption, flags: Flags.rightOption, isRepeat: false, at: t(1)) == .pressed(at: t(1)))
        #expect(d.decode(.flagsChanged, keyCode: Code.rightOption, flags: 0, isRepeat: false, at: t(2)) == .released(at: t(2)))
    }

    @Test func leftOptionNeverTriggers() {
        var d = HotkeyDecoder(key: .rightOption)
        #expect(d.decode(.flagsChanged, keyCode: Code.leftOption, flags: Flags.leftOption, isRepeat: false, at: t(1)) == nil)
        #expect(d.decode(.flagsChanged, keyCode: Code.leftOption, flags: 0, isRepeat: false, at: t(2)) == nil)
    }

    @Test func rightOptionWhileLeftIsHeldStillTriggers() {
        var d = HotkeyDecoder(key: .rightOption)
        _ = d.decode(.flagsChanged, keyCode: Code.leftOption, flags: Flags.leftOption, isRepeat: false, at: t(1))
        let both = Flags.leftOption | Flags.rightOption
        #expect(d.decode(.flagsChanged, keyCode: Code.rightOption, flags: both, isRepeat: false, at: t(2)) == .pressed(at: t(2)))
        // Releasing right while left stays down is a release (the Option bit stays set).
        #expect(d.decode(.flagsChanged, keyCode: Code.rightOption, flags: Flags.leftOption, isRepeat: false, at: t(3)) == .released(at: t(3)))
    }

    @Test func keyWhileHeldIsAChord() {
        var d = HotkeyDecoder(key: .rightOption)
        _ = d.decode(.flagsChanged, keyCode: Code.rightOption, flags: Flags.rightOption, isRepeat: false, at: t(1))
        #expect(d.decode(.keyDown, keyCode: Code.e, flags: Flags.rightOption, isRepeat: false, at: t(2)) == .chord)
    }

    @Test func autorepeatIsNotAChord() {
        var d = HotkeyDecoder(key: .rightOption)
        _ = d.decode(.flagsChanged, keyCode: Code.rightOption, flags: Flags.rightOption, isRepeat: false, at: t(1))
        #expect(d.decode(.keyDown, keyCode: Code.e, flags: Flags.rightOption, isRepeat: true, at: t(2)) == nil)
    }

    @Test func typingWithoutTheHotkeyIsIgnored() {
        var d = HotkeyDecoder(key: .rightOption)
        #expect(d.decode(.keyDown, keyCode: Code.e, flags: 0, isRepeat: false, at: t(1)) == nil)
        #expect(d.decode(.keyUp, keyCode: Code.e, flags: 0, isRepeat: false, at: t(2)) == nil)
    }

    @Test func addedModifierIsAChord() {
        var d = HotkeyDecoder(key: .rightOption)
        _ = d.decode(.flagsChanged, keyCode: Code.rightOption, flags: Flags.rightOption, isRepeat: false, at: t(1))
        #expect(d.decode(.flagsChanged, keyCode: Code.leftShift, flags: Flags.rightOption | Flags.leftShift, isRepeat: false, at: t(2)) == .chord)
    }

    @Test func leftTwinAddedWhileHeldIsAChord() {
        var d = HotkeyDecoder(key: .rightOption)
        _ = d.decode(.flagsChanged, keyCode: Code.rightOption, flags: Flags.rightOption, isRepeat: false, at: t(1))
        #expect(d.decode(.flagsChanged, keyCode: Code.leftOption, flags: Flags.rightOption | Flags.leftOption, isRepeat: false, at: t(2)) == .chord)
    }

    @Test func modifierAlreadyHeldAtPressIsNotAChord() {
        var d = HotkeyDecoder(key: .rightOption)
        let withShift = Flags.rightOption | Flags.leftShift
        _ = d.decode(.flagsChanged, keyCode: Code.rightOption, flags: withShift, isRepeat: false, at: t(1))
        // Letting go of Shift removes a modifier; that's not a chord.
        #expect(d.decode(.flagsChanged, keyCode: Code.leftShift, flags: Flags.rightOption, isRepeat: false, at: t(2)) == nil)
    }

    @Test func escapeCancels() {
        var d = HotkeyDecoder(key: .rightOption)
        _ = d.decode(.flagsChanged, keyCode: Code.rightOption, flags: Flags.rightOption, isRepeat: false, at: t(1))
        #expect(d.decode(.keyDown, keyCode: HotkeyDecoder.escapeKeyCode, flags: Flags.rightOption, isRepeat: false, at: t(2)) == .cancel)
    }

    @Test func rightCommandUsesItsOwnBit() {
        var d = HotkeyDecoder(key: .rightCommand)
        #expect(d.decode(.flagsChanged, keyCode: Code.rightOption, flags: Flags.rightOption, isRepeat: false, at: t(1)) == nil)
        #expect(d.decode(.flagsChanged, keyCode: Code.rightCommand, flags: Flags.rightCommand, isRepeat: false, at: t(2)) == .pressed(at: t(2)))
    }

    @Test func resyncAfterTapWasDisabled() {
        var d = HotkeyDecoder(key: .rightOption)
        _ = d.decode(.flagsChanged, keyCode: Code.rightOption, flags: Flags.rightOption, isRepeat: false, at: t(1))
        #expect(d.resync(keyIsDown: false, at: t(5)) == .tapReenabled(keyIsDown: false, at: t(5)))
        #expect(!d.isDown)
        // The next press is seen as a press, not ignored as a duplicate.
        #expect(d.decode(.flagsChanged, keyCode: Code.rightOption, flags: Flags.rightOption, isRepeat: false, at: t(6)) == .pressed(at: t(6)))
    }
}

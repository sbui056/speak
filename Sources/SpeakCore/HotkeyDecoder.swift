/// Turns raw keyboard events into hotkey events. Pure, so the tricky cases
/// (left vs right modifiers, chords, autorepeat) are tested without a keyboard.
public struct HotkeyDecoder: Sendable {
    public enum Kind: Sendable {
        case flagsChanged
        case keyDown
        case keyUp
    }

    public static let escapeKeyCode: UInt16 = 53

    public var key: HotkeyChoice
    public private(set) var isDown = false
    /// Modifier flags while the hotkey went down; adding another one is a chord.
    private var flagsAtPress: UInt64 = 0

    public init(key: HotkeyChoice) {
        self.key = key
    }

    public mutating func decode(_ kind: Kind, keyCode: UInt16, flags: UInt64,
                                isRepeat: Bool, at time: KeyTime) -> HotkeyEvent? {
        switch kind {
        case .flagsChanged where keyCode == key.keyCode:
            // The device-specific bit says whether the right-hand key itself is
            // down, so a held left-hand key of the same kind never counts.
            let down = flags & key.deviceMask != 0
            guard down != isDown else { return nil }
            isDown = down
            flagsAtPress = flags
            return down ? .pressed(at: time) : .released(at: time)
        case .flagsChanged:
            guard isDown else { return nil }
            let added = flags & ~flagsAtPress & Self.modifierMask
            flagsAtPress = flags
            return added != 0 ? .chord : nil
        case .keyDown:
            if keyCode == Self.escapeKeyCode { return .cancel }
            return isDown && !isRepeat ? .chord : nil
        case .keyUp:
            return nil
        }
    }

    /// The event tap was off for a while: resynchronize with the real key state.
    public mutating func resync(keyIsDown: Bool, at time: KeyTime) -> HotkeyEvent {
        isDown = keyIsDown
        return .tapReenabled(keyIsDown: keyIsDown, at: time)
    }

    /// Shift, Control, Option, Command, plus the per-side device bits so the
    /// left-hand twin of the hotkey also counts. Caps Lock and Fn don't chord.
    static let modifierMask: UInt64 =
        0x0002_0000 | 0x0004_0000 | 0x0008_0000 | 0x0010_0000 // Shift, Control, Option, Command
        | 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000 // left/right of each
}

public extension HotkeyChoice {
    /// The device-specific flag bit for this right-hand modifier.
    var deviceMask: UInt64 {
        switch self {
        case .rightOption: 0x40
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        }
    }
}

import AppKit
import SpeakCore

/// The built-in system sounds for start and stop, kept quiet because the start
/// sound plays while the mic is open.
@MainActor
final class SoundCues {
    private static let volume: Float = 0.25
    private lazy var start = Self.sound("Tink")
    private lazy var stop = Self.sound("Pop")

    func play(_ cue: SoundCue) {
        let sound = cue == .start ? start : stop
        sound?.stop()
        sound?.play()
    }

    private static func sound(_ name: String) -> NSSound? {
        let sound = NSSound(named: name)
        sound?.volume = volume
        return sound
    }
}

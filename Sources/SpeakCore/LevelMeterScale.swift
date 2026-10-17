import Foundation

/// Maps microphone loudness to the HUD meter. Hearing is logarithmic, so the bar
/// follows decibels: room noise reads empty and normal speech lands mid-bar.
/// A linear scale left ordinary speech in the bottom fifth.
public enum LevelMeterScale {
    /// Quieter than this reads as empty (room noise).
    public static let floorDBFS: Float = -55
    /// Louder than this reads as full.
    public static let ceilingDBFS: Float = -15

    /// 0...1 for an RMS level in 0...1.
    public static func fraction(rms: Float) -> Float {
        let dB = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (dB - floorDBFS) / (ceilingDBFS - floorDBFS)))
    }

    /// Whole decibels for logs; −100 for silence.
    public static func dBFS(rms: Float) -> Int {
        rms > 0 ? Int((20 * log10(rms)).rounded()) : -100
    }
}

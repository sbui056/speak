import Testing
@testable import SpeakCore

struct LevelMeterTests {
    @Test func silenceAndTheNoiseFloorShowEmpty() {
        #expect(LevelMeterScale.fraction(rms: 0) == 0)
        #expect(LevelMeterScale.fraction(rms: 0.001) == 0) // −60 dBFS, room noise
    }

    @Test func normalSpeechFillsAboutHalfToTwoThirds() {
        // Speaking normally into a laptop mic is roughly −35 to −25 dBFS RMS.
        #expect((0.4...0.75).contains(LevelMeterScale.fraction(rms: 0.03)))
        #expect(LevelMeterScale.fraction(rms: 0.02) < LevelMeterScale.fraction(rms: 0.05))
    }

    @Test func normalPeaksLeaveHeadroom() {
        // Normal-voice peaks of about −24 to −17 dBFS should stay short of full.
        #expect(LevelMeterScale.fraction(rms: 0.14) < 0.85) // −17 dBFS
        #expect(LevelMeterScale.fraction(rms: 0.063) > 0.6) // −24 dBFS
    }

    @Test func loudSpeechReachesFullAndClamps() {
        #expect(LevelMeterScale.fraction(rms: 0.32) > 0.95) // −10 dBFS
        #expect(LevelMeterScale.fraction(rms: 1) == 1)
        #expect(LevelMeterScale.fraction(rms: 4) == 1)
    }

    @Test func decibelsAreRoundedForLogs() {
        #expect(LevelMeterScale.dBFS(rms: 0.1) == -20)
        #expect(LevelMeterScale.dBFS(rms: 0) == -100)
    }
}

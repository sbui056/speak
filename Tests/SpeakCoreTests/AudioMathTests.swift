import Testing
@testable import SpeakCore

struct AudioMathTests {
    @Test func tailPadIsC_TAILPAD() {
        #expect(Constants.tailPad == .milliseconds(300))
    }

    @Test func tailPadFramesScaleWithTheSampleRate() {
        #expect(tailPadFrames(sampleRate: 16_000) == 4_800)
        #expect(tailPadFrames(sampleRate: 48_000) == 14_400)
    }
}

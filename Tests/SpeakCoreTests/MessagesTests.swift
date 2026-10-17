import Testing
@testable import SpeakCore

/// Pins the exact user-facing copy so a wording change is always deliberate.
struct MessagesTests {
    static let expected: [(Messages, String)] = [
        (.mic, "Microphone not granted — open Settings to allow"),
        (.micBusy, "Microphone unavailable — another app may be using it"),
        (.inputMonitoring, "Input Monitoring not granted — hotkey disabled"),
        (.inputMonitoringRelaunch, "Input Monitoring granted — relaunch Speak to enable the hotkey"),
        (.accessibility, "Accessibility not granted — copied to clipboard"),
        (.secure, "Secure input is on — copied to clipboard"),
        (.appChanged, "App changed — copied to clipboard"),
        (.noField, "No text field focused — copied to clipboard"),
        (.focusChanged, "Focus moved — copied to clipboard"),
        (.modifiers, "Release modifier keys — copied to clipboard"),
        (.modelDownloading(percent: 42), "Speech model not ready (downloading 42%)"),
        (.modelUnavailable(language: "English"), "Speech model unavailable for English"),
        (.device, "Audio device changed — dictation cancelled"),
        (.stt, "Transcription failed — try again"),
        (.finalize, "Transcription was slow — inserted partial text"),
        (.rewriteFallback(mode: "Polished"), "Polished unavailable — inserted literal"),
        (.tooLong, "Too long to rewrite — inserted literal"),
        (.busy, "Finish or cancel the preview first"),
        (.empty, "Didn't catch that"),
        (.inserted, "Inserted"),
        (.copied, "Copied to clipboard"),
        (.restart, "Speech engine stopped responding — restart Speak"),
        (.loginApprove, "Approve Speak in System Settings → General → Login Items"),
        (.typingTestPassed, "Speak can type into apps"),
        (.typingTestNotReceived, "The paste was sent, but the text didn't arrive"),
        (.typingTestFailed(reason: "No text field focused — copied to clipboard"),
         "Couldn't type: No text field focused — copied to clipboard"),
    ]

    @Test(arguments: expected)
    func exactText(message: Messages, text: String) {
        #expect(message.text == text)
    }

    @Test func typingTestVerdict() {
        #expect(Messages.typingTest(.inserted, landed: true) == .typingTestPassed)
        // ⌘V was sent but the field never changed.
        #expect(Messages.typingTest(.inserted, landed: false) == .typingTestNotReceived)
        #expect(Messages.typingTest(.copied(.accessibility), landed: false)
            == .typingTestFailed(reason: Messages.accessibility.text))
        #expect(Messages.typingTest(.empty, landed: false) == .typingTestNotReceived)
    }
}

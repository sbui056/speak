/// Every user-visible status and error string. UI code shows `text` and never
/// composes its own wording, so the copy stays consistent everywhere.
public enum Messages: Hashable, Sendable {
    case mic
    case micBusy
    case inputMonitoring
    case inputMonitoringRelaunch
    case accessibility
    case accessibilityMissing
    case secure
    case appChanged
    case noField
    case focusChanged
    case modifiers
    case modelDownloading(percent: Int)
    case modelUnavailable(language: String)
    case device
    case stt
    case finalize
    case rewriteFallback(mode: String)
    case tooLong
    case busy
    case empty
    case inserted
    case copied
    case restart
    case loginApprove
    case typingTestPassed
    case typingTestNotReceived
    case typingTestFailed(reason: String)

    public var text: String {
        switch self {
        case .mic: "Microphone not granted — open Settings to allow"
        case .micBusy: "Microphone unavailable — another app may be using it"
        case .inputMonitoring: "Input Monitoring not granted — hotkey disabled"
        case .inputMonitoringRelaunch: "Input Monitoring granted — relaunch Speak to enable the hotkey"
        case .accessibility: "Accessibility not granted — copied to clipboard"
        case .accessibilityMissing: "Accessibility not granted — open Settings to allow"
        case .secure: "Secure input is on — copied to clipboard"
        case .appChanged: "App changed — copied to clipboard"
        case .noField: "No text field focused — copied to clipboard"
        case .focusChanged: "Focus moved — copied to clipboard"
        case .modifiers: "Release modifier keys — copied to clipboard"
        case .modelDownloading(let percent): "Speech model not ready (downloading \(percent)%)"
        case .modelUnavailable(let language): "Speech model unavailable for \(language)"
        case .device: "Audio device changed — dictation cancelled"
        case .stt: "Transcription failed — try again"
        case .finalize: "Transcription was slow — inserted partial text"
        case .rewriteFallback(let mode): "\(mode) unavailable — inserted literal"
        case .tooLong: "Too long to rewrite — inserted literal"
        case .busy: "Finish or cancel the preview first"
        case .empty: "Didn't catch that"
        case .inserted: "Inserted"
        case .copied: "Copied to clipboard"
        case .restart: "Speech engine stopped responding — restart Speak"
        case .loginApprove: "Approve Speak in System Settings → General → Login Items"
        case .typingTestPassed: "Speak can type into apps"
        case .typingTestNotReceived: "The paste was sent, but the text didn't arrive"
        case .typingTestFailed(let reason): "Couldn't type: \(reason)"
        }
    }

    /// The Settings typing test's verdict. `landed` says whether the sample
    /// actually showed up in the test field, since a sent ⌘V can still go nowhere.
    public static func typingTest(_ outcome: DeliveryOutcome, landed: Bool) -> Messages {
        switch outcome {
        case .inserted: landed ? .typingTestPassed : .typingTestNotReceived
        case .copied(let reason): .typingTestFailed(reason: reason.text)
        case .empty: .typingTestNotReceived
        }
    }
}

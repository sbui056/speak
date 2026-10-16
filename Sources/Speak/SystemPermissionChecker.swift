import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import SpeakCore

/// Reads and requests the three permissions Speak needs.
final class SystemPermissionChecker: PermissionChecker {
    func isGranted(_ permission: Permission) async -> Bool {
        switch permission {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring: CGPreflightListenEventAccess()
        case .accessibility: AXIsProcessTrusted()
        }
    }

    func request(_ permission: Permission) async -> Bool {
        Log.perm.info("request \(String(describing: permission), privacy: .public)")
        switch permission {
        case .microphone:
            // The system only prompts once; after a denial the switch is in Settings.
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return false }
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return true
        case .inputMonitoring:
            // Adds Speak to the list (prompting the first time); the switch itself is in Settings.
            _ = CGRequestListenEventAccess()
            return false
        case .accessibility:
            // Shows the system alert, which has its own Open System Settings button.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return true
        }
    }

    func openSettings(_ permission: Permission) async {
        let pane = switch permission {
        case .microphone: "Privacy_Microphone"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .accessibility: "Privacy_Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}

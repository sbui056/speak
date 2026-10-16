import AppKit
import SwiftUI

/// Hosts the SwiftUI settings form in a regular window. An accessory app has to
/// activate itself explicitly, or the window opens behind the frontmost app.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Speak Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Without these, a menu-bar app's window opens on whichever Space it
            // last lived on (or the desktop behind a full-screen app), not the
            // one the user is looking at.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation is cooperative and can be declined; still put the window on top.
        window?.orderFrontRegardless()
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Text("Settings will appear here.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 240)
    }
}

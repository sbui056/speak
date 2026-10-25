import AppKit

/// Holds one of Speak's own windows only while it's open. A SwiftUI window costs
/// about 20 MB once drawn, and a menu-bar app runs for weeks, so the window is
/// rebuilt on each open (a few milliseconds) instead of kept hidden after close.
@MainActor
final class WindowSlot {
    private let name: String
    private var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?

    init(name: String) {
        self.name = name
    }

    /// Brings the window forward, building it with `make` if it isn't open.
    func show(_ make: () -> NSWindow) {
        if window == nil {
            let window = make()
            // Only this slot owns the window; AppKit's close must not free it a second time.
            window.isReleasedWhenClosed = false
            // Without these, a menu-bar app's window opens on whichever Space it
            // last lived on (or the desktop behind a full-screen app), not the
            // one the user is looking at.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed() }
            }
            self.window = window
            log("opened")
        }
        // An accessory app has to activate itself, or the window opens behind the frontmost app.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation is cooperative and can be declined; still put the window on top.
        window?.orderFrontRegardless()
    }

    private func closed() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        // AppKit keeps a closed window in its list until a later turn of the event
        // loop, which an idle menu-bar app may not get for a long time. Drop the
        // SwiftUI views now; the window is ordered out before it draws again.
        window?.contentViewController = nil
        window = nil
        log("closed")
    }

    /// Notice level, kept for days, so a step in `memory footprint` lines can be
    /// matched to a window. The footprint right after close still includes freed
    /// memory the allocator hasn't handed back yet.
    private func log(_ event: String) {
        let mb = physFootprintMB().map { String(format: "%.1f", $0) } ?? "?"
        Log.session.notice("window \(event, privacy: .public) name=\(self.name, privacy: .public) footprint=\(mb, privacy: .public)MB")
    }
}

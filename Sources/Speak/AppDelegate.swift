import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let app = AppModel()
    private var menuBar: MenuBarController?
    private var hud: HUDPanelController?
    private lazy var settings = SettingsWindowController(app: app)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = self.settings
        menuBar = MenuBarController(app: app, openSettings: { settings.show() })
        hud = HUDPanelController(controller: app.controller, openSettings: { settings.show() })
        Task {
            // Settings opens once per launch while anything is missing.
            if await app.start() { settings.show() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop the mic, keep any undelivered text, and put the clipboard back first.
        let controller = app.controller
        Task {
            await controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

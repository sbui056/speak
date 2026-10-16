import AppKit
import SpeakCore

/// Owns the status item: its icon follows the session, and the menu is rebuilt
/// each time it opens so it's always current.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let app: AppModel
    private let openSettings: () -> Void
    private var shownIcon: MenuIcon?

    init(app: AppModel, openSettings: @escaping () -> Void) {
        self.app = app
        self.openSettings = openSettings
        super.init()
        statusItem.button?.setAccessibilityLabel("Speak")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        app.onIconInputsChange = { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    private func updateIcon() {
        let icon = MenuIcon(phase: app.controller.state.phase, hasProblem: app.hasProblem)
        guard icon != shownIcon else { return }
        shownIcon = icon
        let image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: "Speak")
        image?.isTemplate = true
        statusItem.button?.image = image
        Log.session.info("menu icon \(icon.symbol, privacy: .public)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: app.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if app.permissions.needsRelaunch {
            menu.addItem(item("Relaunch Speak", #selector(relaunch)))
        }
        menu.addItem(.separator())

        let hasLast = app.controller.lastTranscript != nil
        let paste = item("Paste last transcript", #selector(pasteLast))
        paste.isEnabled = hasLast
        let copy = item("Copy last transcript", #selector(copyLast))
        copy.isEnabled = hasLast
        menu.addItem(paste)
        menu.addItem(copy)
        menu.addItem(.separator())

        let mode = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modes = NSMenu()
        let literal = NSMenuItem(title: "Literal", action: nil, keyEquivalent: "")
        literal.state = .on
        modes.addItem(literal)
        for name in ["Concise", "Polished"] {
            let rewrite = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            rewrite.isEnabled = false
            rewrite.toolTip = "Not available yet"
            modes.addItem(rewrite)
        }
        mode.submenu = modes
        menu.addItem(mode)
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(settingsClicked), key: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Speak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func pasteLast() {
        // Opening the menu doesn't activate Speak, so the user's app is still frontmost.
        Task { await app.controller.pasteLast() }
    }

    @objc private func copyLast() {
        Task { await app.controller.copyLast() }
    }

    @objc private func relaunch() { app.relaunch() }
    @objc private func settingsClicked() { openSettings() }
}

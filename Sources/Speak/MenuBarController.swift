import AppKit
import SpeakCore

/// Owns the status item: its icon follows the session, and the menu is rebuilt
/// each time it opens so it's always current.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let app: AppModel
    private let openSettings: () -> Void
    private let openDictionary: () -> Void
    private var shownIcon: MenuIcon?

    init(app: AppModel, openSettings: @escaping () -> Void, openDictionary: @escaping () -> Void) {
        self.app = app
        self.openSettings = openSettings
        self.openDictionary = openDictionary
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
        // Shown only once the check confirms the same app and field are still focused.
        let undo = item("Undo insert", #selector(undoInsert))
        undo.isHidden = true
        menu.addItem(undo)
        let controller = app.controller
        Task {
            let safe = await controller.undoIsSafe()
            undo.isHidden = !safe
            let why = await controller.undoDiagnostics()
            Log.insert.info("undo check safe=\(safe, privacy: .public) \(why, privacy: .public)")
        }
        menu.addItem(.separator())

        menu.addItem(modeItem())
        menu.addItem(item("Dictionary…", #selector(dictionaryClicked)))
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(settingsClicked), key: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Speak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func modeItem() -> NSMenuItem {
        let mode = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modes = NSMenu()
        let reason = app.rewriteAvailability.reason
        for choice in RewriteMode.allCases {
            let entry = item(choice.title, #selector(modeClicked(_:)))
            entry.representedObject = choice.rawValue
            entry.state = app.mode == choice ? .on : .off
            if choice != .literal, let reason {
                entry.isEnabled = false
                entry.toolTip = reason
            }
            modes.addItem(entry)
        }
        if let reason {
            modes.addItem(.separator())
            let why = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            why.isEnabled = false
            modes.addItem(why)
        }
        mode.submenu = modes
        return mode
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

    @objc private func undoInsert() {
        Task {
            let undone = await app.controller.undoLastInsert()
            Log.insert.info("undo insert sent=\(undone, privacy: .public)")
        }
    }

    @objc private func modeClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = RewriteMode(rawValue: raw) else { return }
        app.mode = mode
    }

    @objc private func dictionaryClicked() { openDictionary() }
    @objc private func relaunch() { app.relaunch() }
    @objc private func settingsClicked() { openSettings() }
}

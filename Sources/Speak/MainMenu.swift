import AppKit

/// Speak never shows a menu bar, but AppKit still routes ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z
/// through the main menu's key equivalents. Without an Edit menu those keys do
/// nothing in Speak's own text fields (Settings → Test, Dictionary, preview Edit).
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu() // AppKit treats the first item as the app menu.
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}

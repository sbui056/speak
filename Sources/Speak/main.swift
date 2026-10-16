import AppKit

// A menu-bar-only app: no Dock icon (LSUIElement), no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

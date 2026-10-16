import AppKit
import SpeakCore
import SwiftUI

/// Hosts the SwiftUI settings form in a regular window. An accessory app has to
/// activate itself explicitly, or the window opens behind the frontmost app.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(app: app)))
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
    @Bindable var app: AppModel

    var body: some View {
        Form {
            Section("Permissions") {
                ForEach(Permission.allCases, id: \.self) { permission in
                    PermissionRow(permission: permission, granted: app.permissions.granted[permission] == true,
                                  permissions: app.permissions)
                }
                if app.permissions.needsRelaunch {
                    HStack {
                        Text(Messages.inputMonitoringRelaunch.text)
                        Spacer()
                        Button("Relaunch") { app.relaunch() }
                    }
                }
            }

            Section("Shortcut") {
                Picker("Hold to dictate", selection: $app.hotkey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("On keyboards where Right Option is AltGr, choose Right Command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Speech") {
                if app.isFake {
                    Text("Fake mode: no microphone or speech engine is used.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Language", selection: $app.locale) {
                        ForEach(localeChoices, id: \.identifier) { locale in
                            Text(name(locale)).tag(locale)
                        }
                    }
                }
                LabeledContent("Speech model", value: modelText)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The supported languages, plus the current one even before they've loaded.
    private var localeChoices: [Locale] {
        let all = app.supportedLocales
        return all.contains(where: { $0.identifier == app.locale.identifier }) ? all : [app.locale] + all
    }

    private func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private var modelText: String {
        switch app.model {
        case .installed: "Installed"
        case .downloading(let percent): "Downloading \(percent)%"
        case .unavailable: "Unavailable"
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let granted: Bool
    let permissions: PermissionsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(granted ? "Granted" : "Not granted").foregroundStyle(.secondary)
            if !granted {
                Button("Request") { Task { await permissions.request(permission) } }
            }
            Button("Open System Settings") { Task { await permissions.openSettings(permission) } }
                .accessibilityLabel("Open System Settings for \(permission.title)")
        }
        .accessibilityElement(children: .contain)
    }
}

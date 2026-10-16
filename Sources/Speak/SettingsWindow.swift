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
    @State private var confirmDelete = false
    @State private var testText = ""
    @State private var copiedDiagnostics = false
    @FocusState private var testFocused: Bool

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

            Section("Rewriting") {
                HStack(alignment: .firstTextBaseline) {
                    let available = app.rewriteAvailability == .available
                    Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(available ? .green : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Intelligence")
                        Text(app.rewriteAvailability.reason ?? "Concise and Polished are available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(available ? "Available" : "Unavailable").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Picker("Show preview", selection: $app.previewPolicy) {
                    ForEach(PreviewPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Never: rewrites are typed straight in. Use Undo insert or Paste last transcript "
                     + "to get your original words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Picker("History", selection: $app.historyOn) {
                    Text("Off").tag(false)
                    Text("Last \(Constants.historyMax)").tag(true)
                }
                Text("Keeps the text of your recent dictations on this Mac, never audio. See it in the Dictionary window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(app.history.entries.isEmpty ? "No history saved" : "\(app.history.entries.count) saved")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete all history…") { confirmDelete = true }
                        .disabled(app.history.entries.isEmpty)
                }
                .confirmationDialog("Delete all \(app.history.entries.count) entries?", isPresented: $confirmDelete) {
                    Button("Delete all", role: .destructive) {
                        Log.session.info("history delete all entries=\(app.history.entries.count, privacy: .public)")
                        app.history.deleteAll()
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin },
                                                        set: { app.setLaunchAtLogin($0) }))
                if app.loginNeedsApproval {
                    HStack {
                        Text(Messages.loginApprove.text).font(.callout)
                        Spacer()
                        Button("Open Login Items") { app.openLoginItems() }
                    }
                }
                HStack {
                    Text("Diagnostics have versions, permissions, settings, and timings, but none of your text.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(copiedDiagnostics ? "Copied" : "Copy diagnostics") {
                        NSPasteboard.general.clearContents()
                        let report = app.diagnostics
                        NSPasteboard.general.setString(report, forType: .string)
                        Log.session.info("diagnostics copied lines=\(report.split(separator: "\n").count, privacy: .public)")
                        copiedDiagnostics = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copiedDiagnostics = false
                        }
                    }
                }
            }

            Section("Test") {
                TextField("Click Test dictation, or dictate here", text: $testText, axis: .vertical)
                    .lineLimit(2...4)
                    .focused($testFocused)
                HStack {
                    Text("Types a sample sentence here the same way Speak types into other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Test dictation") { runTest() }
                }
            }
        }
        .formStyle(.grouped)
        // Seven sections don't fit a small screen; the form scrolls.
        .frame(width: 480, height: 640)
    }

    private func runTest() {
        testFocused = true
        Task {
            // Let the field take focus before the paste looks for it.
            try? await Task.sleep(for: .milliseconds(150))
            let outcome = await app.controller.insert("Speak can type here.")
            Log.insert.info("test dictation \(String(describing: outcome), privacy: .public)")
        }
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

import AppKit
import ServiceManagement
import SpeakCore

/// What the menu and Settings report about the app as a whole, and the fixes
/// they offer for it.
extension AppModel {
    var statusLine: String {
        menuStatus(permissions: permissions.granted, needsRelaunch: permissions.needsRelaunch,
                   model: model, hotkey: hotkey)
    }

    var hasProblem: Bool {
        !permissions.allGranted || permissions.needsRelaunch || model != .installed
    }

    /// Versions, permissions, model, settings, and timings; never text.
    var diagnostics: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Diagnostics(
            appVersion: version,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            permissions: permissions.granted, model: model, rewrite: rewriteAvailability,
            settings: [("mode", mode.rawValue), ("previewPolicy", previewPolicy.rawValue),
                       ("hotkey", hotkey.rawValue), ("language", locale.identifier),
                       ("history", historyOn ? "last\(Constants.historyMax)" : "off"),
                       ("sounds", soundsOn ? "on" : "off"),
                       ("launchAtLogin", launchAtLogin ? (loginNeedsApproval ? "needsApproval" : "on") : "off"),
                       ("dictionaryTerms", String(dictionary.terms.count)), ("fake", String(isFake))],
            timings: timings
        ).report
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this instance to exit, then open a fresh one.
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        do {
            try task.run()
        } catch {
            // Quitting now would leave nothing running; stay up so the menu still offers Relaunch.
            let ns = error as NSError
            Log.perm.error("relaunch failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

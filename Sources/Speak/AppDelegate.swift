import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let app = AppModel()
    private var menuBar: MenuBarController?
    private var hud: HUDPanelController?
    private var preview: PreviewPanelController?
    private lazy var settings = SettingsWindowController(app: app, openHistory: { [unowned self] in dictionary.show(.history) })
    private lazy var dictionary = DictionaryWindowController(dictionary: app.dictionary, history: app.history)

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let corpus = Corpus(environment: ProcessInfo.processInfo.environment) {
            Task { await corpus.run(); exit(0) }
            return
        }
        if let lab = RecognizerLab(environment: ProcessInfo.processInfo.environment) {
            Task { await lab.run(); exit(0) }
            return
        }
        #endif
        MainMenu.install()
        let settings = self.settings
        let dictionary = self.dictionary
        menuBar = MenuBarController(app: app, openSettings: { settings.show() }, openDictionary: { dictionary.show() },
                                    openHistory: { dictionary.show(.history) })
        hud = HUDPanelController(controller: app.controller, openSettings: { settings.show() })
        preview = PreviewPanelController(controller: app.controller)
        Task {
            let missing = await app.start()
            #if DEBUG
            if let soak = app.soak { return await soak.run(app.controller) }
            if let cycle = WindowCycle(environment: ProcessInfo.processInfo.environment) {
                return await cycle.run(settings: { settings.show() }, dictionary: { dictionary.show() },
                                       history: { dictionary.show(.history) })
            }
            #endif
            // Settings opens once per launch while anything is missing.
            if missing { settings.show() }
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

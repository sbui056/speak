import AppKit
import Observation
import SpeakCore
import Speech

/// Builds the real (or fake) adapters, owns the settings, and connects system
/// notifications to the session. UI reads from here; decisions live in SpeakCore.
@MainActor
@Observable
final class AppModel {
    let controller: SessionController
    let permissions: PermissionsModel
    /// `SPEAK_FAKE=1`: canned audio and transcript, real hotkey and delivery.
    let isFake: Bool
    private(set) var model: SpeechModelStatus = .downloading(percent: 0)
    private(set) var supportedLocales: [Locale] = []

    var hotkey: HotkeyChoice {
        didSet {
            UserDefaults.standard.set(hotkey.rawValue, forKey: Keys.hotkey)
            controller.hotkeyChoice = hotkey
            startHotkey()
        }
    }

    /// Takes effect from the next dictation.
    var locale: Locale {
        didSet {
            UserDefaults.standard.set(locale.identifier, forKey: Keys.locale)
            transcriber?.setLocale(locale)
            Task { await refreshModel() }
        }
    }

    @ObservationIgnored private let hotkeySource: any HotkeySource
    @ObservationIgnored private let transcriber: SpeechAnalyzerTranscriber?
    @ObservationIgnored private let modelStore: (any SpeechModelStore)?
    @ObservationIgnored private var hotkeyTask: Task<Void, Never>?
    @ObservationIgnored private var installing = false
    /// Called when anything the menu-bar icon depends on changes.
    @ObservationIgnored var onIconInputsChange: (() -> Void)?

    private enum Keys {
        static let hotkey = "hotkey"
        static let locale = "language"
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let defaults = UserDefaults.standard
        let savedLocale = defaults.string(forKey: Keys.locale).map(Locale.init(identifier:)) ?? Locale.current
        hotkey = defaults.string(forKey: Keys.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? .rightOption
        locale = savedLocale
        isFake = environment["SPEAK_FAKE"] == "1"

        let clock = ContinuousClock()
        let hotkeySource = EventTapHotkey()
        let deliverer = Deliverer(env: SystemDeliveryEnvironment(), pasteboard: SystemPasteboard(), clock: clock)
        let audio: any AudioSource
        let stt: any Transcriber
        if isFake {
            var config = FakeTranscriber.Config()
            if let text = environment["SPEAK_FAKE_TEXT"] { config.text = text }
            audio = FakeAudioSource()
            stt = FakeTranscriber(config)
            transcriber = nil
            modelStore = nil
        } else {
            let real = SpeechAnalyzerTranscriber(locale: savedLocale)
            audio = EngineAudioSource(targetFormat: { await real.audioFormat() })
            stt = real
            transcriber = real
            modelStore = AssetModelStore(transcriber: real)
        }
        self.hotkeySource = hotkeySource
        controller = SessionController(audio: audio, transcriber: stt, deliverer: deliverer,
                                       hotkey: hotkeySource, clock: clock)
        permissions = PermissionsModel(checker: SystemPermissionChecker(), clock: clock)
        controller.hotkeyChoice = hotkey
    }

    /// Starts everything. Returns whether Settings should open (a permission is missing).
    func start() async -> Bool {
        controller.onTransition = { [weak self] from, to, id in
            self?.onIconInputsChange?()
            Log.session.info("\(String(describing: from), privacy: .public) → \(String(describing: to), privacy: .public) \(id?.description ?? "-", privacy: .public)")
        }
        let controller = self.controller
        permissions.onChange = { [weak self] permission, granted in
            self?.onIconInputsChange?()
            Log.perm.info("\(String(describing: permission), privacy: .public) granted=\(granted, privacy: .public)")
            if permission == .microphone { controller.send(.micPermission(granted: granted)) }
        }
        Task { await controller.run() }
        observeSystem()
        await permissions.refresh()
        startHotkey()
        Task { await refreshModel() }
        Task { await loadLocales() }
        return !permissions.allGranted
    }

    var statusLine: String {
        menuStatus(permissions: permissions.granted, needsRelaunch: permissions.needsRelaunch,
                   model: model, hotkey: hotkey)
    }

    var hasProblem: Bool {
        !permissions.allGranted || permissions.needsRelaunch || model != .installed
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this instance to exit, then open a fresh one.
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Private

    private func startHotkey() {
        hotkeyTask?.cancel()
        let keys = hotkeySource.start(hotkey)
        let controller = self.controller
        hotkeyTask = Task { await controller.listen(to: keys) }
    }

    private func refreshModel() async {
        guard let modelStore else { return setModel(.installed) }
        let status = await modelStore.status()
        setModel(status)
        guard case .downloading = status, !installing else { return }
        installing = true
        defer { installing = false }
        do {
            try await modelStore.install { percent in
                Task { @MainActor [weak self] in self?.setModel(.downloading(percent: percent)) }
            }
            setModel(await modelStore.status())
        } catch {
            let ns = error as NSError
            Log.stt.error("model install failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
            setModel(.unavailable(language: locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier))
        }
    }

    private func setModel(_ status: SpeechModelStatus) {
        // Progress callbacks can land after the install finished.
        if case .downloading = status, model == .installed { return }
        model = status
        controller.send(.modelStatus(status))
        onIconInputsChange?()
    }

    private func loadLocales() async {
        guard !isFake else { return }
        supportedLocales = await SpeechTranscriber.supportedLocales
            .sorted { $0.identifier < $1.identifier }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let controller = self.controller
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            controller.send(.systemSleep)
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The event tap doesn't survive sleep reliably; recreate it.
            MainActor.assumeIsolated { self?.startHotkey() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.permissions.refresh() }
            }
        }
    }
}

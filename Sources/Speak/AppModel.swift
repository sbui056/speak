import AppKit
import Observation
import ServiceManagement
import SpeakCore
import Speech

/// Builds the real (or fake) adapters, owns the settings, and connects system
/// notifications to the session. UI reads from here; decisions live in SpeakCore.
@MainActor
@Observable
final class AppModel {
    let controller: SessionController
    let permissions: PermissionsModel
    let dictionary: DictionaryModel
    let history: HistoryModel
    let usage: UsageModel
    /// `SPEAK_FAKE=1`: canned audio and transcript, real hotkey and delivery.
    let isFake: Bool
    #if DEBUG
    /// `SPEAK_SOAK=<n>` with fake mode: a fake hotkey and paste target too (`scripts/soak.sh`).
    let soak: Soak?
    #endif
    private(set) var model: SpeechModelStatus = .downloading(percent: 0)
    private(set) var supportedLocales: [Locale] = []
    /// Whether Concise and Polished can run, and why not.
    private(set) var rewriteAvailability: RewriteAvailability = .modelNotReady
    /// Mirrors `SMAppService.mainApp`; refreshed when Speak becomes active.
    private(set) var launchAtLogin = false
    /// Registered, but macOS wants the user to approve it in Login Items.
    private(set) var loginNeedsApproval = false
    /// Called when anything the menu-bar icon depends on changes.
    @ObservationIgnored var onIconInputsChange: (() -> Void)?
    @ObservationIgnored private(set) var timings = TimingLog()

    @ObservationIgnored private let hotkeySource: any HotkeySource
    @ObservationIgnored private let transcriber: SpeechAnalyzerTranscriber?
    @ObservationIgnored private let modelStore: (any SpeechModelStore)?
    @ObservationIgnored private let rewriter: any Rewriter
    @ObservationIgnored private let soundCues = SoundCues()
    @ObservationIgnored private var hotkeyTask: Task<Void, Never>?
    @ObservationIgnored private var installing = false
    /// Started at release; split into stages as the session reports them.
    @ObservationIgnored private var timer = DictationTimer()
    /// Logs the footprint once Speak has sat idle for a while after launch or a dictation.
    @ObservationIgnored private var idleSample: Task<Void, Never>?
    private static let idleSampleDelay: Duration = .seconds(300)

    // MARK: Settings

    var mode: RewriteMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            sendRewriteSettings()
            if mode != .literal { prewarm() }
        }
    }

    /// When a rewrite waits in the preview panel.
    var previewPolicy: PreviewPolicy {
        didSet {
            UserDefaults.standard.set(previewPolicy.rawValue, forKey: Keys.previewPolicy)
            sendRewriteSettings()
        }
    }

    /// Keep the last `Constants.historyMax` dictations (text only). Off by default.
    var historyOn: Bool {
        didSet {
            UserDefaults.standard.set(historyOn, forKey: Keys.history)
            history.isOn = historyOn
            Log.session.info("history on=\(self.historyOn, privacy: .public) entries=\(self.history.entries.count, privacy: .public)")
        }
    }

    /// Quiet start and stop sounds around listening. Off by default.
    var soundsOn: Bool {
        didSet {
            UserDefaults.standard.set(soundsOn, forKey: Keys.sounds)
            Log.session.info("sounds on=\(self.soundsOn, privacy: .public)")
        }
    }

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
            controller.language = locale.identifier
            Task { await refreshModel() }
        }
    }

    private enum Keys {
        static let hotkey = "hotkey"
        static let locale = "language"
        static let mode = "mode"
        static let previewPolicy = "previewPolicy"
        /// The older on/off setting that `previewPolicy` replaces; migrated once, then removed.
        static let alwaysPreview = "alwaysPreview"
        static let history = "history"
        static let sounds = "sounds"
    }

    // MARK: Lifecycle

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let defaults = UserDefaults.standard
        let savedLocale = defaults.string(forKey: Keys.locale).map(Locale.init(identifier:)) ?? Locale.current
        hotkey = defaults.string(forKey: Keys.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? .rightOption
        locale = savedLocale
        mode = defaults.string(forKey: Keys.mode).flatMap(RewriteMode.init(rawValue:)) ?? .literal
        let policy = PreviewPolicy.stored(defaults.string(forKey: Keys.previewPolicy),
                                          legacyAlwaysPreview: defaults.bool(forKey: Keys.alwaysPreview))
        previewPolicy = policy
        defaults.set(policy.rawValue, forKey: Keys.previewPolicy)
        defaults.removeObject(forKey: Keys.alwaysPreview)
        isFake = environment["SPEAK_FAKE"] == "1"
        let historyOn = defaults.bool(forKey: Keys.history)
        self.historyOn = historyOn
        history = HistoryModel(files: .standard, isOn: historyOn)
        usage = UsageModel(files: .standard)
        soundsOn = defaults.bool(forKey: Keys.sounds)

        let clock = ContinuousClock()
        var hotkeySource: any HotkeySource = EventTapHotkey()
        var deliverer = Deliverer(env: SystemDeliveryEnvironment(), pasteboard: SystemPasteboard(), clock: clock)
        #if DEBUG
        soak = Soak(environment: environment)
        if let soak {
            hotkeySource = soak.hotkey
            deliverer = Deliverer(env: soak.target, pasteboard: FakePasteboard(), clock: clock)
        }
        #endif
        let audio: any AudioSource
        let stt: any Transcriber
        if isFake {
            var config = FakeTranscriber.Config()
            if let text = environment["SPEAK_FAKE_TEXT"] { config.text = text }
            audio = FakeAudioSource()
            stt = FakeTranscriber(config)
            rewriter = FakeRewriter()
            transcriber = nil
            modelStore = nil
        } else {
            let real = SpeechAnalyzerTranscriber(locale: savedLocale)
            audio = EngineAudioSource(targetFormat: { await real.audioFormat() })
            stt = real
            rewriter = FoundationRewriter()
            transcriber = real
            modelStore = AssetModelStore(transcriber: real)
        }
        self.hotkeySource = hotkeySource
        controller = SessionController(audio: audio, transcriber: stt, deliverer: deliverer,
                                       rewriter: rewriter, spelling: SystemSpellChecker(),
                                       hotkey: hotkeySource, clock: clock)
        dictionary = DictionaryModel(files: .standard)
        permissions = PermissionsModel(checker: SystemPermissionChecker(), clock: clock)
        controller.hotkeyChoice = hotkey
        controller.language = savedLocale.identifier
        controller.terms = dictionary.terms
        controller.pairs = dictionary.pairs
        dictionary.onChange = { [controller] dictionary in
            controller.terms = dictionary.terms
            controller.pairs = dictionary.pairs
        }
    }

    /// Starts everything. Returns whether Settings should open (a permission is missing).
    func start() async -> Bool {
        controller.onTransition = { [weak self] from, to, id in
            self?.onIconInputsChange?()
            self?.measure(from: from, to: to)
            Log.session.info("\(String(describing: from), privacy: .public) → \(String(describing: to), privacy: .public) \(id?.description ?? "-", privacy: .public)")
        }
        controller.onStage = { [weak self] stage in
            guard let self, let line = timer.mark(stage, at: .now) else { return }
            record(line)
        }
        let controller = self.controller
        permissions.onChange = { [weak self] permission, granted in
            self?.onIconInputsChange?()
            Log.perm.info("\(String(describing: permission), privacy: .public) granted=\(granted, privacy: .public)")
            if permission == .microphone { controller.send(.micPermission(granted: granted)) }
        }
        controller.onDelivered = { outcome in
            Log.insert.info("delivery \(String(describing: outcome), privacy: .public)")
        }
        controller.onFinished = { [weak self] text in
            self?.finishTiming(previewed: false)
            self?.history.record(text)
            // Fake and soak dictations aren't the user's.
            if let self, !isFake { usage.record(text, spoken: controller.state.spoken) }
        }
        controller.onCue = { [weak self] cue in
            guard let self, soundsOn else { return }
            soundCues.play(cue)
            Log.session.info("sound cue \(String(describing: cue), privacy: .public)")
        }
        controller.onRewriteRejected = { mode, why in
            Log.rewrite.notice("rewrite rejected by the guard mode=\(mode.rawValue, privacy: .public) why=\(why.name, privacy: .public)")
        }
        controller.onRewriteSalvaged = { why in
            Log.rewrite.notice("rewrite salvaged by sentence why=\(why.name, privacy: .public)")
        }
        sendRewriteSettings()
        Task { await controller.run() }
        observeSystem()
        Task { await refreshRewriteAvailability() }
        await permissions.refresh()
        startHotkey()
        Task { await refreshModel() }
        Task { await loadLocales() }
        refreshLaunchAtLogin()
        logFootprint(after: "launch")
        return !permissions.allGranted
    }

    // MARK: Actions

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            let ns = error as NSError
            Log.perm.error("launch at login failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
        }
        refreshLaunchAtLogin()
    }

    /// Re-checked on launch and whenever Speak becomes active, since Apple
    /// Intelligence can be turned on or off in System Settings at any time.
    func refreshRewriteAvailability() async {
        let availability = await rewriter.availability()
        guard availability != rewriteAvailability else { return }
        rewriteAvailability = availability
        Log.rewrite.info("rewrite availability \(String(describing: availability), privacy: .public)")
        sendRewriteSettings()
        if availability == .available, mode != .literal { prewarm() }
    }

    // MARK: Private

    private func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        Log.perm.info("launch at login status=\(status.rawValue, privacy: .public)")
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }

    /// Release starts the clock; the preview opening or the text landing stops it.
    private func measure(from: Phase, to: Phase) {
        if from == .listening, to == .finalizing {
            timer.released(at: .now, mode: controller.state.sessionMode)
            // A number only, kept for days, to tune the meter's decibel range to real voices.
            let dB = LevelMeterScale.dBFS(rms: controller.loudestLevel)
            Log.session.notice("level loudest dBFS=\(dB, privacy: .public)")
        }
        if to == .awaitingAcceptance { finishTiming(previewed: true) }
        if to == .idle {
            timer.reset()
            logFootprint(after: "session")
        }
    }

    /// Notice level, kept for days: `latency.sh` reports idle, peak, and growth from it.
    private func logFootprint(after event: String) {
        if let mb = physFootprintMB() {
            Log.session.notice("memory footprint=\(String(format: "%.1f", mb), privacy: .public)MB after=\(event, privacy: .public)")
        }
        guard event != "idle" else { return }
        idleSample?.cancel()
        idleSample = Task { [weak self] in
            try? await Task.sleep(for: Self.idleSampleDelay)
            guard let self, !Task.isCancelled, controller.state.phase == .idle else { return }
            logFootprint(after: "idle")
        }
    }

    private func finishTiming(previewed: Bool) {
        guard let line = timer.finish(previewed: previewed, at: .now) else { return }
        record(line)
    }

    private func record(_ line: TimingLine) {
        timings.add(line)
        // Notice, not info: persisted for days, so README latency can be computed from everyday use.
        Log.session.notice("timing \(line.text, privacy: .public)")
    }

    /// The session uses Literal while rewrites are unavailable, whatever was chosen.
    private func sendRewriteSettings() {
        let effective = rewriteAvailability == .available ? mode : .literal
        controller.send(.rewriteSettings(mode: effective, preview: previewPolicy))
    }

    private func prewarm() {
        let instructions = rewriteInstructions(mode)
        let rewriter = self.rewriter
        Task { await rewriter.prewarm(instructions: instructions) }
    }

    private func startHotkey() {
        hotkeyTask?.cancel()
        let keys = hotkeySource.start(hotkey)
        let controller = self.controller
        hotkeyTask = Task { await controller.listen(to: keys) }
    }

    private func refreshModel() async {
        guard let modelStore else { return setModel(.installed) }
        // A language change during a download shows the new status now; if that
        // one needs a download too, the running loop below starts it next.
        guard !installing else { return setModel(await modelStore.status()) }
        installing = true
        defer { installing = false }
        while true {
            let requested = locale
            let status = await modelStore.status()
            setModel(status)
            guard case .downloading = status else { return }
            do {
                try await modelStore.install { [requested] percent in
                    Task { @MainActor [weak self] in
                        // Progress callbacks can land after the install finished,
                        // or belong to a language the user has since left.
                        guard let self, model != .installed, locale == requested else { return }
                        setModel(.downloading(percent: percent))
                    }
                }
            } catch {
                let ns = error as NSError
                Log.stt.error("model install failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
                if locale == requested {
                    return setModel(.unavailable(language: locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier))
                }
            }
            // The user picked another language mid-install: check that one next.
            guard locale != requested else { return setModel(await modelStore.status()) }
        }
    }

    private func setModel(_ status: SpeechModelStatus) {
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
            Log.session.notice("system sleep")
            controller.send(.systemSleep)
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The event tap doesn't survive sleep reliably; recreate it.
            Log.session.notice("system wake: hotkey restarted")
            MainActor.assumeIsolated { self?.startHotkey() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.permissions.refresh() }
                Task { await self.refreshRewriteAvailability() }
                self.refreshLaunchAtLogin()
            }
        }
    }
}

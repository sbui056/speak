/// Every tunable threshold in one place. Code reads these instead of literals so a
/// behavior change is a one-line edit with a test that notices.
public enum Constants {
    /// A shorter press is a tap and is discarded silently.
    public static let hold: Duration = .milliseconds(200)
    /// Shorter audio is discarded silently.
    public static let minAudio: Duration = .milliseconds(300)
    /// A whole-clip peak below this (dBFS) is treated as silence and discarded.
    public static let silenceDBFS: Double = -50
    /// Capture auto-stops and is processed after this long.
    public static let cap: Duration = .seconds(5 * 60)
    /// Finalize watchdog; on expiry the last volatile text is used.
    public static let finalize: Duration = .seconds(5)
    /// Key reported up while still listening for this long is treated as a release.
    public static let stuck: Duration = .milliseconds(300)
    /// Longest wait for modifiers to be released before posting ⌘V.
    public static let modWait: Duration = .milliseconds(500)
    /// The same wait after a choice in the preview panel, where ⌥⏎ puts a finger
    /// on Option by design.
    public static let handoffModWait: Duration = .seconds(2)
    /// If delivery hasn't finished by then (a hung app), copy the text instead.
    public static let deliver: Duration = .seconds(3)
    /// Longest wait for the original app to become frontmost again after the preview.
    public static let activate: Duration = .milliseconds(300)
    /// Delay before the pasteboard is restored after a paste.
    public static let restore: Duration = .milliseconds(600)
    /// Restore delay for apps that read the pasteboard slowly (see `slowPasteApps`).
    public static let restoreSlow: Duration = .milliseconds(1500)
    /// Remote-desktop, VM, and Citrix clients forward the pasteboard asynchronously.
    public static let slowPasteApps: Set<String> = [
        "com.microsoft.rdc.macos",
        "com.citrix.receiver.icaviewer.mac",
        "com.vmware.fusion",
        "com.parallels.desktop.console",
        "com.utmapp.UTM",
    ]
    /// Rewrite timeout.
    public static let rewriteTimeout: Duration = .milliseconds(2500)
    /// Timeout for the first rewrite after launch, used only if a cold start needs it.
    public static let rewriteTimeoutCold: Duration = .seconds(4)
    /// Transcriber start watchdog.
    public static let sttStart: Duration = .seconds(3)
    /// Maximum partial-text refresh rate in the HUD (Hz).
    public static let hudRate: Double = 15
    /// Fewer words skip the rewrite.
    public static let rewriteMinWords = 4
    /// More words skip the rewrite.
    public static let rewriteMaxWords = 600
    /// Allowed rewrite output/input length ratio (Polished).
    public static let ratio: ClosedRange<Double> = 0.5...1.6
    /// Allowed rewrite output/input length ratio (Concise).
    public static let ratioConcise: ClosedRange<Double> = 0.3...1.2
    /// Minimum share of output words found in the input plus dictionary.
    public static let overlap: Double = 0.6
    /// How long Undo insert stays available.
    public static let undo: Duration = .seconds(30)
    /// HUD display time for errors.
    public static let hudError: Duration = .seconds(4)
    /// HUD display time for results.
    public static let hudOK: Duration = .seconds(1)
    /// Identical errors within this window are shown once.
    public static let coalesce: Duration = .seconds(10)
    /// Allowed dictionary term length in characters.
    public static let dictTermLength: ClosedRange<Int> = 2...64
    /// Maximum number of dictionary entries.
    public static let dictMaxEntries = 200
    /// History cap when history is on.
    public static let historyMax = 50
}

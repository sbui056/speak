#if DEBUG
import AppKit

/// Debug builds only, for `scripts/window-memory.sh`: `SPEAK_FAKE=1 SPEAK_WINDOWS=<n>`
/// opens and closes Settings, Dictionary, and History n times each, and prints the
/// footprint before, while open, and after closing, plus whether the closed window
/// was freed. Closing goes through `performClose`, the same path as the close button.
@MainActor
struct WindowCycle {
    let count: Int

    init?(environment: [String: String]) {
        guard environment["SPEAK_FAKE"] == "1", let count = environment["SPEAK_WINDOWS"].flatMap(Int.init), count > 0
        else { return nil }
        self.count = count
    }

    func run(settings: @escaping () -> Void, dictionary: @escaping () -> Void, history: @escaping () -> Void) async {
        try? await Task.sleep(for: .seconds(2)) // let launch work settle
        report("baseline", "-", nil)
        let windows: [(String, String, () -> Void)] = [
            ("settings", "Speak Settings", settings),
            ("dictionary", "Speak Dictionary", dictionary),
            ("history", "Speak Dictionary", history),
        ]
        var closedWindows: [Weak] = []
        for round in 1...count {
            for (name, title, open) in windows {
                open()
                try? await Task.sleep(for: .seconds(1.5)) // let SwiftUI lay out and draw
                report("open", "\(name)#\(round)", nil)
                let window = NSApp.windows.first { $0.title == title && $0.isVisible }
                // The SwiftUI views are the expensive part; they must go as soon as the window closes.
                let views = Weak(window?.contentViewController)
                closedWindows.append(Weak(window))
                window?.performClose(nil)
                try? await Task.sleep(for: .seconds(1.5))
                report("closed", "\(name)#\(round)", views.object == nil)
            }
        }
        // AppKit keeps a closed window in its list until the event loop turns again;
        // a real app gets events all the time, this idle one needs a nudge.
        if let nudge = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(nudge, atStart: false)
        }
        try? await Task.sleep(for: .seconds(2))
        print("windows alive=\(closedWindows.filter { $0.object != nil }.count) of \(closedWindows.count)")
        print("windows done")
        fflush(stdout)
    }

    private struct Weak {
        weak var object: AnyObject?
        init(_ object: AnyObject?) { self.object = object }
    }

    private func report(_ event: String, _ which: String, _ freed: Bool?) {
        let mb = physFootprintMB() ?? 0
        let freedText = freed.map { " freed=\($0)" } ?? ""
        print(String(format: "windows %@ %@ footprint=%.1fMB", event, which, mb) + freedText)
        fflush(stdout)
    }
}
#endif

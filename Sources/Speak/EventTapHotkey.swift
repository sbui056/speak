import CoreGraphics
import Foundation
import SpeakCore
import Synchronization

/// Watches the hotkey with a listen-only event tap. Needs Input Monitoring.
///
/// The tap runs on its own thread and run loop so a busy main thread can never
/// delay (or drop) a key-up. The callback only decodes and yields; it doesn't log,
/// touch the main actor, or call Accessibility.
final class EventTapHotkey: HotkeySource {
    private let running = Mutex<TapContext?>(nil)

    func start(_ key: HotkeyChoice) -> AsyncStream<HotkeyEvent> {
        stop()
        // Unbounded: dropping a release would leave the mic open.
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream(bufferingPolicy: .unbounded)
        let context = TapContext(decoder: HotkeyDecoder(key: key), continuation: continuation)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            context.install()
            ready.signal()
            if context.tap != nil { CFRunLoopRun() }
        }
        thread.name = "Speak hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if context.tap == nil {
            Log.perm.error("event tap unavailable (Input Monitoring not granted?)")
            continuation.finish()
        } else {
            running.withLock { $0 = context }
        }
        return stream
    }

    func stop() {
        running.withLock { context in
            defer { context = nil }
            return context
        }?.uninstall()
    }

    /// For the stuck-key watchdog: is the hotkey possibly still held?
    func isKeyDown(_ key: HotkeyChoice) -> Bool { mayBeHeld(key) }

    func now() -> KeyTime { monotonicNow() }
}

/// Monotonic time, the same base the tap stamps events with.
private func monotonicNow() -> KeyTime {
    .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
}

/// `keyState` alone reports a held Right Option as up, so also accept the
/// modifier flag. Callers only need a reliable "definitely released".
private func mayBeHeld(_ key: HotkeyChoice) -> Bool {
    if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.keyCode)) { return true }
    return CGEventSource.flagsState(.combinedSessionState).rawValue & key.familyMask != 0
}

/// State shared with the C callback through its refcon pointer.
private final class TapContext: @unchecked Sendable {
    // Unchecked: `decoder` is only touched on the tap thread; `tap` and `runLoop`
    // are set once on that thread before `install()` returns, and afterwards only
    // read by `uninstall()`.
    var decoder: HotkeyDecoder
    let continuation: AsyncStream<HotkeyEvent>.Continuation
    var tap: CFMachPort?
    var runLoop: CFRunLoop?

    init(decoder: HotkeyDecoder, continuation: AsyncStream<HotkeyEvent>.Continuation) {
        self.decoder = decoder
        self.continuation = continuation
    }

    func install() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoop = loop
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        continuation.finish()
    }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        let now = monotonicNow()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            continuation.yield(decoder.resync(keyIsDown: mayBeHeld(decoder.key), at: now))
        case .flagsChanged, .keyDown, .keyUp:
            let kind: HotkeyDecoder.Kind = type == .flagsChanged ? .flagsChanged : type == .keyDown ? .keyDown : .keyUp
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if let decoded = decoder.decode(kind, keyCode: keyCode, flags: event.flags.rawValue,
                                            isRepeat: isRepeat, at: now) {
                continuation.yield(decoded)
            }
        default:
            break
        }
    }
}

/// A plain C function (no captures, nonisolated), as the tap API requires.
private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    if let refcon {
        Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    // Listen-only: the event always continues to the focused app.
    return Unmanaged.passUnretained(event)
}

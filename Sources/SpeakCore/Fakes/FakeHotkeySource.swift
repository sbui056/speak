import Synchronization

/// A hotkey the test presses by hand.
public final class FakeHotkeySource: HotkeySource {
    private struct State {
        var isDown = false
        var continuation: AsyncStream<HotkeyEvent>.Continuation?
    }

    private let state = Mutex(State())
    private let clock: @Sendable () -> KeyTime

    /// `clock` supplies key timestamps, so they line up with the test's clock.
    public init(clock: @escaping @Sendable () -> KeyTime) {
        self.clock = clock
    }

    public func start(_ key: HotkeyChoice) -> AsyncStream<HotkeyEvent> {
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream(bufferingPolicy: .unbounded)
        state.withLock { $0.continuation = continuation }
        return stream
    }

    public func stop() { state.withLock { $0.continuation }?.finish() }
    public func isKeyDown(_ key: HotkeyChoice) -> Bool { state.withLock { $0.isDown } }
    public func now() -> KeyTime { clock() }

    public func press() { set(down: true, .pressed(at: clock())) }
    public func release() { set(down: false, .released(at: clock())) }
    /// The key went up but the event never arrived.
    public func loseRelease() { state.withLock { $0.isDown = false } }
    public func emit(_ event: HotkeyEvent) { state.withLock { $0.continuation }?.yield(event) }

    private func set(down: Bool, _ event: HotkeyEvent) {
        let continuation = state.withLock { s in
            s.isDown = down
            return s.continuation
        }
        continuation?.yield(event)
    }
}

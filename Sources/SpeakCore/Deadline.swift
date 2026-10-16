/// A sleep whose deadline is fixed when it's created, not when the task that
/// runs it first gets scheduled. Timers started from the event loop would
/// otherwise drift later under load.
public struct Deadline: Sendable {
    private let wait: @Sendable () async throws -> Void

    public init(after duration: Duration, on clock: any Clock<Duration>) {
        wait = Self.make(clock, duration)
    }

    private static func make<C: Clock<Duration>>(_ clock: C, _ duration: Duration) -> @Sendable () async throws -> Void {
        let deadline = clock.now.advanced(by: duration)
        return { try await clock.sleep(until: deadline, tolerance: nil) }
    }

    /// True if the deadline passed; false if the waiting task was cancelled.
    public func reached() async -> Bool {
        (try? await wait()) != nil
    }
}

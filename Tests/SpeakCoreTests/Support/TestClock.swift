import Synchronization

/// A clock that only moves when the test advances it, so watchdogs and
/// timeouts measured in seconds run instantly.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        var cancelled: Set<Int> = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var elapsed: Duration { now.offset }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let id = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = state.withLock { s in
                    if s.cancelled.remove(id) != nil || deadline <= s.now { return true }
                    s.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { s -> Sleeper? in
                guard let sleeper = s.sleepers.removeValue(forKey: id) else {
                    s.cancelled.insert(id)
                    return nil
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }

    /// Moves time forward in small steps, letting woken tasks run at each step,
    /// so a timer started by another timer fires within the same advance.
    func advance(by duration: Duration, step: Duration = .milliseconds(10)) async {
        var remaining = duration
        while remaining > .zero {
            let delta = min(step, remaining)
            remaining -= delta
            let due = state.withLock { s -> [Sleeper] in
                s.now = s.now.advanced(by: delta)
                let due = s.sleepers.filter { $0.value.deadline <= s.now }
                due.keys.forEach { s.sleepers.removeValue(forKey: $0) }
                return due.sorted { $0.value.deadline < $1.value.deadline }.map(\.value)
            }
            due.forEach { $0.continuation.resume() }
            await settle()
        }
        await settle()
    }
}

/// Lets every ready task run until the system goes quiet.
func settle() async {
    for _ in 0..<200 { await Task.yield() }
}

/// Yields until `condition` holds. Tests run in parallel and share the thread
/// pool, so a long chain of hops may need more turns than `settle()` gives.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<20_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

extension TestClock {
    /// Advances in small steps until `task` finishes, so a sleep that registers
    /// late (under load) still gets woken. Gives up after `limit` of fake time.
    func drive<T: Sendable>(_ task: Task<T, Never>, step: Duration = .milliseconds(10),
                            limit: Duration = .seconds(30)) async -> T? {
        let result = Mutex<T?>(nil)
        let watcher = Task { let value = await task.value; result.withLock { $0 = value } }
        var driven: Duration = .zero
        while result.withLock({ $0 }) == nil, driven < limit {
            await advance(by: step, step: step)
            driven += step
        }
        _ = watcher
        return result.withLock { $0 }
    }
}

extension TestClock {
    /// Advances until `condition` holds. Under load an event can reach the state
    /// machine late, which starts its timers late, so a fixed advance with a small
    /// margin past a deadline is flaky. Callers assert the timing separately.
    @MainActor
    func advance(until condition: () -> Bool, step: Duration = .milliseconds(10),
                 limit: Duration = .seconds(30)) async -> Bool {
        var driven: Duration = .zero
        while !condition() {
            if driven >= limit { return false }
            await advance(by: step, step: step)
            driven += step
        }
        return true
    }
}

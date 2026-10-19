import Synchronization

/// Stands in for the mic. Used by the tests and by fake mode (`SPEAK_FAKE=1`).
public final class FakeAudioSource: AudioSource {
    public struct Config: Sendable {
        public var failure: AudioFailure?
        public var peakDBFS: Double = -20
        /// Start waits for `openGate()`, like a slow audio engine.
        public var gated = false
        public init() {}
    }

    private struct State {
        var config = Config()
        var isOpen = false
        var opens = 0
        var continuation: AsyncStream<AudioFrames>.Continuation?
        var onEvent: (@Sendable (AudioEvent) -> Void)?
        var gates: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init(_ config: Config = Config()) {
        state.withLock { $0.config = config }
    }

    public var isOpen: Bool { state.withLock { $0.isOpen } }
    public var opens: Int { state.withLock { $0.opens } }
    public func configure(_ change: (inout Config) -> Void) { state.withLock { change(&$0.config) } }

    /// Simulates the user unplugging a headset.
    public func unplug() {
        state.withLock { $0.onEvent }?(.deviceChanged)
    }

    /// Lets the oldest waiting gated start finish.
    public func openGate() {
        state.withLock { s in s.gates.isEmpty ? nil : s.gates.removeFirst() }?.resume()
    }

    /// Lets the most recent waiting gated start finish, out of order.
    public func openNewestGate() {
        state.withLock { s in s.gates.popLast() }?.resume()
    }

    public var waitingStarts: Int { state.withLock { $0.gates.count } }

    public func start(onEvent: @escaping @Sendable (AudioEvent) -> Void) async throws -> AsyncStream<AudioFrames> {
        let config = state.withLock { $0.config }
        if config.gated {
            await withCheckedContinuation { continuation in state.withLock { $0.gates.append(continuation) } }
        }
        if let failure = config.failure { throw failure }
        let (stream, continuation) = AsyncStream<AudioFrames>.makeStream()
        state.withLock {
            $0.isOpen = true
            $0.opens += 1
            $0.continuation = continuation
            $0.onEvent = onEvent
        }
        onEvent(.level(rms: 0.3, peakDBFS: config.peakDBFS))
        continuation.yield(AudioFrames(0))
        return stream
    }

    public func stop() async {
        let continuation = state.withLock { s -> AsyncStream<AudioFrames>.Continuation? in
            s.isOpen = false
            defer { s.continuation = nil; s.onEvent = nil }
            return s.continuation
        }
        continuation?.finish()
    }
}

/// Stands in for the speech engine: returns fixed text once the audio ends.
public final class FakeTranscriber: Transcriber {
    public struct Config: Sendable {
        public var text = "Hello world, this is a fake transcript."
        /// Never finish finalizing, to exercise the watchdog.
        public var hangOnFinalize = false
        /// Never report any activity, to exercise the start watchdog.
        public var silent = false
        public var failToStart = false
        public init() {}
    }

    private struct StartFailed: Error {}

    /// Shared with each session so cancels are counted across all of them.
    private final class Recorder: Sendable {
        let cancels = Mutex(0)
        let terms = Mutex<[[String]]>([])
    }

    private let config: Mutex<Config>
    private let recorder = Recorder()

    public init(_ config: Config = Config()) {
        self.config = Mutex(config)
    }

    public func configure(_ change: (inout Config) -> Void) { config.withLock { change(&$0) } }
    public var cancelCount: Int { recorder.cancels.withLock { $0 } }
    /// The dictionary terms each session was started with.
    public var terms: [[String]] { recorder.terms.withLock { $0 } }

    public func start(frames: AsyncStream<AudioFrames>, terms: [String],
                      onEvent: @escaping @Sendable (TranscriberEvent) -> Void) async throws -> any TranscriberSession {
        recorder.terms.withLock { $0.append(terms) }
        let config = self.config.withLock { $0 }
        if config.failToStart { throw StartFailed() }
        let session = Session(config: config, frames: frames, recorder: recorder)
        if !config.silent {
            onEvent(.active)
            onEvent(.partial(String(config.text.prefix(5))))
        }
        return session
    }

    private final class Session: TranscriberSession {
        let config: Config
        let frames: AsyncStream<AudioFrames>
        let recorder: Recorder

        init(config: Config, frames: AsyncStream<AudioFrames>, recorder: Recorder) {
            self.config = config
            self.frames = frames
            self.recorder = recorder
        }

        func finalize() async throws -> String {
            for await _ in frames {} // Ends when the mic closes.
            if config.hangOnFinalize {
                // Like a hung framework call: ignore cancellation and never return.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
            return config.text
        }

        func cancel() async {
            recorder.cancels.withLock { $0 += 1 }
        }
    }
}

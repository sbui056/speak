@preconcurrency import AVFoundation
import SpeakCore
import Synchronization

/// The microphone, via a fresh AVAudioEngine per session (so a changed input
/// device or format is picked up every time). Audio is converted to the
/// transcriber's format and streamed straight to it; nothing is kept or written.
final class EngineAudioSource: AudioSource, @unchecked Sendable {
    // Unchecked: all mutable state is behind `session`'s lock.
    private let targetFormat: @Sendable () async -> AVAudioFormat?
    private let session = Mutex<Session?>(nil)

    private struct Session {
        let engine: AVAudioEngine
        let tap: TapState
        let meter: DispatchSourceTimer
        let observer: NSObjectProtocol
    }

    /// `targetFormat` is what the transcriber wants (asked fresh each session).
    init(targetFormat: @escaping @Sendable () async -> AVAudioFormat?) {
        self.targetFormat = targetFormat
    }

    func start(onEvent: @escaping @Sendable (AudioEvent) -> Void) async throws -> AsyncStream<AudioFrames> {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioFailure.denied }
        guard let output = await targetFormat() else {
            Log.audio.error("no transcriber audio format")
            throw AudioFailure.busy
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, let converter = AVAudioConverter(from: native, to: output) else {
            Log.audio.error("no usable input format")
            throw AudioFailure.busy
        }
        // A multichannel mic is mixed down instead of feeding only its first channel.
        converter.downmix = true
        let (stream, continuation) = AsyncStream<AudioFrames>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let tap = TapState(converter: converter, output: output, continuation: continuation)
        installConvertingTap(on: input, format: native, state: tap)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            let ns = error as NSError
            Log.audio.error("engine start failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
            throw AudioFailure.busy
        }

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            Log.audio.info("audio configuration changed")
            onEvent(.deviceChanged)
        }
        // Levels are read off the audio thread and reported at about 20 Hz.
        let meter = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        meter.schedule(deadline: .now(), repeating: .milliseconds(50))
        meter.setEventHandler { onEvent(.level(rms: tap.rms, peakDBFS: tap.peakDBFS)) }
        meter.resume()

        let previous = session.withLock { s -> Session? in
            defer { s = Session(engine: engine, tap: tap, meter: meter, observer: observer) }
            return s
        }
        if let previous { Self.tearDown(previous) }
        Log.audio.info("mic open sr=\(native.sampleRate, privacy: .public) ch=\(native.channelCount, privacy: .public)")
        return stream
    }

    func stop() async {
        let current = session.withLock { s -> Session? in
            defer { s = nil }
            return s
        }
        guard let current else { return }
        Self.tearDown(current)
        let tap = current.tap
        let capturedMs = Int((Double(tap.capturedFrames.load(ordering: .relaxed)) / tap.output.sampleRate * 1000).rounded())
        Log.audio.notice("mic closed buffers=\(tap.yielded.load(ordering: .relaxed), privacy: .public) dropped=\(tap.dropped.load(ordering: .relaxed), privacy: .public) tap_frames=\(tap.tapFrames.load(ordering: .relaxed), privacy: .public) captured_ms=\(capturedMs, privacy: .public)")
    }

    private static func tearDown(_ s: Session) {
        s.meter.cancel()
        NotificationCenter.default.removeObserver(s.observer)
        s.engine.stop()
        s.engine.inputNode.removeTap(onBus: 0)
        // The tap no longer runs: hand over what the converter still holds.
        drainConverter(s.tap)
        s.tap.continuation.finish()
    }
}

/// What the real-time tap touches. Counters and levels are atomics so the audio
/// thread never takes a lock.
private final class TapState: Sendable {
    // The converter isn't thread-safe: the tap callback (serial, not the
    // real-time I/O thread) and the final drain take turns through `useConverter`.
    private let converter: AVAudioConverter
    private let converterClosed = Mutex<Bool>(false)
    let output: AVAudioFormat
    let continuation: AsyncStream<AudioFrames>.Continuation
    let yielded = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    /// Converted frames handed to the transcriber, for the captured-ms log.
    let capturedFrames = Atomic<Int>(0)
    /// Size of the last buffer the tap delivered (the engine may round the requested size up).
    let tapFrames = Atomic<Int>(0)
    private let rmsBits = Atomic<UInt32>(0)
    private let peakBits = Atomic<UInt64>((-Double.infinity).bitPattern)

    init(converter: AVAudioConverter, output: AVAudioFormat, continuation: AsyncStream<AudioFrames>.Continuation) {
        self.converter = converter
        self.output = output
        self.continuation = continuation
    }

    /// Runs `body` with the converter unless the final drain already ran.
    func useConverter(closing: Bool = false, _ body: (AVAudioConverter) -> Void) {
        converterClosed.withLock { closed in
            guard !closed else { return }
            if closing { closed = true }
            body(converter)
        }
    }

    var rms: Float { Float(bitPattern: rmsBits.load(ordering: .relaxed)) }
    var peakDBFS: Double { Double(bitPattern: peakBits.load(ordering: .relaxed)) }

    func send(_ converted: AVAudioPCMBuffer) {
        let frames = Int(converted.frameLength)
        // Handed off and never referenced again here.
        switch continuation.yield(AudioFrames(AnalyzerInputBox(converted))) {
        case .enqueued:
            yielded.add(1, ordering: .relaxed)
            capturedFrames.add(frames, ordering: .relaxed)
        case .dropped: dropped.add(1, ordering: .relaxed)
        case .terminated: break
        @unknown default: break
        }
    }

    func record(rms: Float, peak: Float) {
        rmsBits.store(rms.bitPattern, ordering: .relaxed)
        let dB = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
        if dB > peakDBFS { peakBits.store(dB.bitPattern, ordering: .relaxed) }
    }
}

/// Must stay nonisolated: a closure formed inside @MainActor code inherits that
/// isolation, and Swift traps when the real-time audio thread calls it.
private func installConvertingTap(on input: AVAudioInputNode, format native: AVAudioFormat, state: TapState) {
    // Small batches, so less audio is in flight when the engine stops.
    input.installTap(onBus: 0, bufferSize: 1024, format: native) { tapBuffer, _ in
        nonisolated(unsafe) let buffer = tapBuffer
        state.tapFrames.store(Int(buffer.frameLength), ordering: .relaxed)
        measure(buffer, into: state)
        let ratio = state.output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: state.output, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var fed = false
        // Converted and sent under the lock, so a callback that races the drain
        // either finishes first or does nothing.
        state.useConverter { converter in
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0 else { return }
            state.send(converted)
        }
    }
}

/// Flushes the samples the sample-rate converter keeps back for its filter.
/// Runs once, after the tap is removed; a tap callback still in flight after
/// this finds the converter closed.
private func drainConverter(_ state: TapState) {
    guard let converted = AVAudioPCMBuffer(pcmFormat: state.output, frameCapacity: 4096) else { return }
    state.useConverter(closing: true) { converter in
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        guard error == nil, converted.frameLength > 0 else { return }
        state.send(converted)
    }
}

/// Peak and RMS of the first channel, for the silence check and the HUD meter.
private func measure(_ buffer: AVAudioPCMBuffer, into state: TapState) {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
    var peak: Float = 0
    var sum: Float = 0
    for i in 0..<Int(buffer.frameLength) {
        let v = samples[i]
        peak = max(peak, abs(v))
        sum += v * v
    }
    state.record(rms: (sum / Float(buffer.frameLength)).squareRoot(), peak: peak)
}

/// The converted buffer, passed to the transcriber inside `AudioFrames`.
struct AnalyzerInputBox: @unchecked Sendable {
    // Unchecked: created on the audio thread and handed off once.
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

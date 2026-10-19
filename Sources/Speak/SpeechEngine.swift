@preconcurrency import AVFoundation
import Foundation
import SpeakCore
import Speech
import Synchronization

/// On-device transcription with SpeechAnalyzer. A new analyzer per session:
/// reusing a finished one isn't documented, and a fresh one prepares in well
/// under the hold time.
final class SpeechAnalyzerTranscriber: Transcriber {
    private let localeSetting: Mutex<Locale>

    init(locale: Locale) {
        localeSetting = Mutex(locale)
    }

    /// Takes effect from the next session.
    func setLocale(_ locale: Locale) { localeSetting.withLock { $0 = locale } }
    fileprivate var locale: Locale { localeSetting.withLock { $0 } }

    fileprivate func makeModule() -> SpeechTranscriber {
        // Alternatives cost nothing measurable and let dictionary terms pick
        // between readings (`rescore`); the recognizer ignores contextual strings.
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .alternativeTranscriptions], attributeOptions: [])
    }

    /// The audio format the analyzer wants; the audio source converts to it.
    func audioFormat() async -> AVAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeModule()])
    }

    func start(frames: AsyncStream<AudioFrames>, terms: [String],
               onEvent: @escaping @Sendable (TranscriberEvent) -> Void) async throws -> any TranscriberSession {
        let module = makeModule()
        // The user is waiting on the result; lingering keeps the model loaded
        // between dictations close together.
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let started = ContinuousClock.now
        try await analyzer.prepareToAnalyze(in: format)
        Log.stt.info("analyzer prepared in \(ContinuousClock.now - started, privacy: .public)")

        let transcript = Transcript(terms: terms)
        let (padded, feeder) = analyzerInput(frames, format: format)
        // `.active` means the analyzer took mic audio (the C-STT-START watchdog
        // waits on it), so it fires as the analyzer reads, not as the mic delivers.
        let sawAudio = Atomic<Bool>(false)
        let input = padded.map { @Sendable item -> AnalyzerInput in
            if item.fromMic, !sawAudio.exchange(true, ordering: .relaxed) { onEvent(.active) }
            return item.input
        }
        let results = Task {
            for try await result in module.results {
                // Converted here, off the main actor.
                let text = String(result.text.characters)
                // The first alternative is normally the top reading itself.
                let alternatives = result.isFinal ? result.alternatives.map { String($0.characters) }.filter { $0 != text } : []
                onEvent(.partial(transcript.add(text, alternatives: alternatives, isFinal: result.isFinal)))
            }
        }
        do {
            try await analyzer.start(inputSequence: input)
        } catch {
            feeder.cancel()
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return AnalyzerSession(analyzer: analyzer, results: results, feeder: feeder, transcript: transcript)
    }
}

private final class AnalyzerSession: TranscriberSession {
    private let analyzer: SpeechAnalyzer
    private let results: Task<Void, any Error>
    private let feeder: Task<Void, Never>
    private let transcript: Transcript

    init(analyzer: SpeechAnalyzer, results: Task<Void, any Error>, feeder: Task<Void, Never>, transcript: Transcript) {
        self.analyzer = analyzer
        self.results = results
        self.feeder = feeder
        self.transcript = transcript
    }

    func finalize() async throws -> String {
        // Returns once the audio stream has ended (the mic was closed).
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results.value
        return transcript.finalText
    }

    func cancel() async {
        feeder.cancel()
        await analyzer.cancelAndFinishNow()
        results.cancel()
    }
}

/// The mic audio for the analyzer, then C-TAILPAD of generated silence once the
/// mic closes, so a word cut off at release still gets finished. Must stay
/// nonisolated: the task it starts runs off the main actor.
private func analyzerInput(_ frames: AsyncStream<AudioFrames>, format: AVAudioFormat?)
    -> (AsyncStream<(input: AnalyzerInput, fromMic: Bool)>, Task<Void, Never>) {
    let (input, continuation) = AsyncStream<(input: AnalyzerInput, fromMic: Bool)>.makeStream()
    let feeder = Task.detached(priority: .userInitiated) {
        for await frames in frames {
            guard let box = frames.payload as? AnalyzerInputBox else { continue }
            continuation.yield((AnalyzerInput(buffer: box.buffer), true))
        }
        if !Task.isCancelled, let format, let silence = silence(format, frames: tailPadFrames(sampleRate: format.sampleRate)) {
            continuation.yield((AnalyzerInput(buffer: silence), false))
        }
        continuation.finish()
    }
    return (input, feeder)
}

private func silence(_ format: AVAudioFormat, frames: Int) -> AVAudioPCMBuffer? {
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
    }
    return buffer
}

/// Finished segments arrive while the user is still talking; the volatile tail
/// is everything after them, revised as recognition goes.
private final class Transcript: Sendable {
    private let terms: [String]
    private let state = Mutex<(finals: [RecognizedSegment], text: String, volatile: String)>(([], "", ""))

    init(terms: [String]) {
        self.terms = terms
    }

    /// Records a result and returns everything recognized so far (top readings).
    func add(_ text: String, alternatives: [String], isFinal: Bool) -> String {
        state.withLock { s in
            if isFinal {
                s.finals.append(RecognizedSegment(text: text, alternatives: alternatives))
                s.text = joinedTranscript(s.text, text)
                s.volatile = ""
            } else {
                s.volatile = text
            }
            return joinedTranscript(s.text, s.volatile)
        }
    }

    /// The finished transcript, rescored toward the dictionary terms.
    var finalText: String {
        state.withLock { s in
            rescore(s.finals + [RecognizedSegment(text: s.volatile, alternatives: [])], terms: terms)
        }
    }
}

/// The on-device speech model for the chosen language, via AssetInventory.
final class AssetModelStore: SpeechModelStore {
    private let transcriber: SpeechAnalyzerTranscriber

    init(transcriber: SpeechAnalyzerTranscriber) {
        self.transcriber = transcriber
    }

    func status() async -> SpeechModelStatus {
        let locale = transcriber.locale
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            return .unavailable(language: Self.name(locale))
        }
        switch await AssetInventory.status(forModules: [transcriber.makeModule()]) {
        case .installed: return .installed
        case .downloading, .supported: return .downloading(percent: 0)
        case .unsupported: return .unavailable(language: Self.name(locale))
        @unknown default: return .unavailable(language: Self.name(locale))
        }
    }

    func install(progress: @escaping @Sendable (Int) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber.makeModule()]) else {
            return // Already installed.
        }
        let watcher = Task {
            while !Task.isCancelled {
                progress(Int(request.progress.fractionCompleted * 100))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(100)
    }

    private static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

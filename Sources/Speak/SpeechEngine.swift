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
    var locale: Locale { localeSetting.withLock { $0 } }

    func makeModule() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                          attributeOptions: [])
    }

    /// The audio format the analyzer wants; the audio source converts to it.
    func audioFormat() async -> AVAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeModule()])
    }

    func start(frames: AsyncStream<AudioFrames>,
               onEvent: @escaping @Sendable (TranscriberEvent) -> Void) async throws -> any TranscriberSession {
        let module = makeModule()
        let analyzer = SpeechAnalyzer(modules: [module])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let started = ContinuousClock.now
        try await analyzer.prepareToAnalyze(in: format)
        Log.stt.info("analyzer prepared in \(ContinuousClock.now - started, privacy: .public)")

        let transcript = Transcript()
        let sawAudio = Atomic<Bool>(false)
        let input = frames.compactMap { @Sendable frames -> AnalyzerInput? in
            guard let box = frames.payload as? AnalyzerInputBox else { return nil }
            if !sawAudio.exchange(true, ordering: .relaxed) { onEvent(.active) }
            return AnalyzerInput(buffer: box.buffer)
        }
        let results = Task {
            for try await result in module.results {
                // Converted here, off the main actor.
                let text = String(result.text.characters)
                onEvent(.partial(transcript.add(text, isFinal: result.isFinal)))
            }
        }
        do {
            try await analyzer.start(inputSequence: input)
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return AnalyzerSession(analyzer: analyzer, results: results, transcript: transcript)
    }
}

private final class AnalyzerSession: TranscriberSession {
    let analyzer: SpeechAnalyzer
    let results: Task<Void, any Error>
    let transcript: Transcript

    init(analyzer: SpeechAnalyzer, results: Task<Void, any Error>, transcript: Transcript) {
        self.analyzer = analyzer
        self.results = results
        self.transcript = transcript
    }

    func finalize() async throws -> String {
        // Returns once the audio stream has ended (the mic was closed).
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results.value
        return transcript.finalText
    }

    func cancel() async {
        await analyzer.cancelAndFinishNow()
        results.cancel()
    }
}

/// Finished segments arrive while the user is still talking; the volatile tail
/// is everything after them, revised as recognition goes.
private final class Transcript: Sendable {
    private let state = Mutex<(finals: String, volatile: String)>(("", ""))

    /// Records a result and returns everything recognized so far.
    func add(_ text: String, isFinal: Bool) -> String {
        state.withLock { s in
            if isFinal {
                s.finals = joined(s.finals, text)
                s.volatile = ""
            } else {
                s.volatile = text
            }
            return joined(s.finals, s.volatile)
        }
    }

    var finalText: String {
        state.withLock { joined($0.finals, $0.volatile) }
    }
}

/// Joins segments, adding a space only where neither side has one.
func joined(_ a: String, _ b: String) -> String {
    guard let last = a.last, let first = b.first else { return a + b }
    return last.isWhitespace || first.isWhitespace ? a + b : a + " " + b
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
        case .downloading: return .downloading(percent: 0)
        case .supported: return .downloading(percent: 0)
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

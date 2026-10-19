#if DEBUG
@preconcurrency import AVFoundation
import Foundation
import SpeakCore

/// Debug builds only, for `scripts/lab-recognizer.sh`: `SPEAK_LAB=<sentences>`
/// speaks each sentence with the system voices into a temporary WAV (`say`,
/// on-device), runs it through the real transcriber and the Literal cleanup,
/// prints `voice rate sentence text` per run, and quits. No microphone; every
/// WAV is deleted after use.
struct RecognizerLab {
    static let voices = ["Samantha", "Daniel", "Karen", "Reed (English (US))"]
    static let rates = [170, 230]
    static let terms = ["pull request", "cache", "retry", "CI", "main", "created at", "meeting notes", "action items"]

    let sentences: [String]
    /// `SPEAK_LAB_TRIM=1`: cut each file right after the last sound, like a key
    /// released the moment the last word ends.
    let trim: Bool

    init?(environment: [String: String]) {
        guard let path = environment["SPEAK_LAB"], let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        trim = environment["SPEAK_LAB_TRIM"] == "1"
        // Same line format as scripts/accuracy.py: # comments, CONTROL: prefix, [[target]] marks.
        sentences = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                let plain = line.hasPrefix("CONTROL:") ? String(line.dropFirst("CONTROL:".count)) : line
                return plain.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    @MainActor
    func run() async {
        let transcriber = SpeechAnalyzerTranscriber(locale: Locale(identifier: "en-US"))
        guard let format = await transcriber.audioFormat() else { return print("lab: no audio format") }
        let spelling = SystemSpellChecker()
        for (index, sentence) in sentences.enumerated() {
            for voice in Self.voices {
                for rate in Self.rates {
                    let raw: String
                    do {
                        raw = try await Self.transcribe(sentence, voice: voice, rate: rate, format: format, trim: trim, transcriber)
                    } catch {
                        print("lab: \(voice) \(rate) \(index + 1) failed: \(error)")
                        continue
                    }
                    let text = makeLiteral(raw, terms: Self.terms, spelling: spelling, language: "en")
                    print("\(voice)\t\(rate)\t\(index + 1)\t\(text)")
                    fflush(stdout)
                }
            }
        }
    }

    private static func transcribe(_ sentence: String, voice: String, rate: Int, format: AVAudioFormat,
                                   trim: Bool, _ transcriber: SpeechAnalyzerTranscriber) async throws -> String {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("speak-lab-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-r", String(rate), "--file-format=WAVE", "--data-format=LEI16@16000",
                         "-o", wav.path, sentence]
        try say.run()
        say.waitUntilExit()
        let frames = try audioFrames(wav, format: format, trim: trim)
        let session = try await transcriber.start(frames: frames, terms: terms) { _ in }
        return try await session.finalize()
    }

    /// The whole file converted to the analyzer format, in 100 ms buffers, as a
    /// finished stream (the "mic" closes after the last buffer).
    private nonisolated static func audioFrames(_ url: URL, format: AVAudioFormat, trim: Bool) throws -> AsyncStream<AudioFrames> {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity:
                  AVAudioFrameCount(Double(file.length) * format.sampleRate / source.sampleRate) + 1024)
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: input)
        if trim, let samples = input.floatChannelData?[0],
           let last = (0..<Int(input.frameLength)).last(where: { abs(samples[$0]) > 0.003 }) { // ≈ −50 dBFS
            input.frameLength = AVAudioFrameCount(last + 1)
        }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }

        let (stream, continuation) = AsyncStream<AudioFrames>.makeStream()
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        var offset: AVAudioFrameCount = 0
        while offset < output.frameLength {
            let count = min(chunk, output.frameLength - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                  let from = output.audioBufferList.pointee.mBuffers.mData,
                  let to = buffer.audioBufferList.pointee.mBuffers.mData
            else { break }
            buffer.frameLength = count
            to.copyMemory(from: from.advanced(by: Int(offset) * bytesPerFrame), byteCount: Int(count) * bytesPerFrame)
            continuation.yield(AudioFrames(AnalyzerInputBox(buffer)))
            offset += count
        }
        continuation.finish()
        return stream
    }
}
#endif

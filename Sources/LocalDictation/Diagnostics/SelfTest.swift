import DictationCore
import AVFoundation
import DictationEngine
import Foundation
import TextProcessing

/// `--selftest`: runs every fixture through the real pipeline (pre-trimmed by voice activity, chunked, transcribed,
/// post-processed) and checks word error rate, behaviors and latency.
///
/// Fixtures are `<id>.wav` with `<id>.expected.txt`, named as the fixture recorder saves them (`01-quiet-short.wav`).
/// Thresholds: word error rate at most 8 % for quiet fixtures (01 to 06) and 15 % for noise and headset fixtures
/// (07 to 09); the same words as expected, ignoring case and punctuation, for the behaviors (10 to 12); end of audio to
/// final text within 1.5 s for audio up to 30 s. The test feeds audio up to 30 s in real time, so the latency is what a
/// user waits, and feeds longer fixtures at 20 times real time. A `SYNTHETIC` file in the directory marks every result
/// @weak: generated speech is not proof.
enum SelfTest {
    struct Result {
        let identifier: String
        let category: String
        let audioSeconds: Double
        let wordErrorRate: Double?
        let latency: Double?
        let passed: Bool
        let note: String
    }

    static func run(directory: URL) async -> Int32 {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            print("No fixtures directory at \(directory.path)")
            return 2
        }
        let identifiers = names.filter { $0.hasSuffix(".wav") }.map { String($0.dropLast(4)) }.sorted()
        guard !identifiers.isEmpty else {
            print("No fixtures in \(directory.path). Record them in Settings with Option held → Record fixture…")
            return 2
        }
        let isWeak = manager.fileExists(atPath: directory.appendingPathComponent("SYNTHETIC").path)
        let store = ModelStore(rootDirectory: ModelStore.defaultRootDirectory)
        guard store.isInstalled else {
            print("The speech model is not installed.")
            return 2
        }
        let transcriber = SpeechTranscriber(
            compiledDirectory: store.compiledDirectory, vocabularyURL: store.vocabularyURL, computeTarget: .neuralEngine)
        let voiceActivity: VoiceActivityDetector
        do {
            try await transcriber.load()
            voiceActivity = try VoiceActivityDetector(compiledModelURL: store.voiceActivityModelURL)
            _ = try await transcriber.transcribe([Float](repeating: 0, count: SpeechAudioFormat.sampleRate))
        } catch {
            print("The speech model could not be loaded: \(error.localizedDescription)")
            return 2
        }

        print("Self-test of \(identifiers.count) fixtures in \(directory.path)\(isWeak ? " (synthetic speech: results are @weak)" : "")\n")
        var results: [Result] = []
        for identifier in identifiers {
            let audioURL = directory.appendingPathComponent("\(identifier).wav")
            let expected = (try? String(contentsOf: directory.appendingPathComponent("\(identifier).expected.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let result = try await evaluate(
                    identifier: identifier, audioURL: audioURL, expected: expected, transcriber: transcriber,
                    voiceActivity: voiceActivity)
                results.append(result)
                print(line(result, weak: isWeak))
            } catch {
                let result = Result(
                    identifier: identifier, category: "error", audioSeconds: 0, wordErrorRate: nil, latency: nil, passed: false,
                    note: error.localizedDescription)
                results.append(result)
                print(line(result, weak: isWeak))
            }
        }
        let failed = results.filter { !$0.passed }
        print("\n\(results.count - failed.count) of \(results.count) passed\(isWeak ? " (@weak: synthetic fixtures)" : "")")
        return failed.isEmpty ? 0 : 1
    }

    private static func line(_ result: Result, weak: Bool) -> String {
        let rate = result.wordErrorRate.map { String(format: "WER %5.1f%%", $0 * 100) } ?? "          "
        let latency = result.latency.map { String(format: "latency %.2f s", $0) } ?? ""
        return String(
            format: "%@ %@  %-8@ %6.1f s  %@  %@  %@", result.passed ? "PASS" : "FAIL", weak ? "@weak" : "     ",
            result.category, result.audioSeconds, rate, latency, result.identifier + (result.note.isEmpty ? "" : " — \(result.note)"))
    }

    private static func category(of identifier: String) -> String {
        switch Int(identifier.prefix(2)) ?? 0 {
        case 1...6: return "quiet"
        case 7...8: return "noise"
        case 9: return "headset"
        case 10...12: return "behavior"
        default: return "other"
        }
    }

    private static func evaluate(
        identifier: String, audioURL: URL, expected: String?, transcriber: SpeechTranscriber, voiceActivity: VoiceActivityDetector
    ) async throws -> Result {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let sourceFrames = AVAudioFrameCount(file.length)
        guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sourceFrames) else { throw SelfTestError.unreadable }
        try file.read(into: source)
        let samples = try resampleToSpeechFormat(source)
        let audioSeconds = Double(samples.count) / Double(SpeechAudioFormat.sampleRate)
        let category = category(of: identifier)
        let number = Int(identifier.prefix(2)) ?? 0

        // The controller discards recordings shorter than 0.3 s before transcription.
        var text = ""
        var latency: Double?
        if audioSeconds >= DictationController.minimumRecordingDuration {
            let session = StreamingTranscription(transcriber: transcriber, voiceActivity: voiceActivity)
            let piece = SpeechAudioFormat.sampleRate / 50
            let realTime = audioSeconds <= 30
            var index = 0
            while index < samples.count {
                session.append(Array(samples[index..<min(index + piece, samples.count)]))
                index += piece
                try await Task.sleep(nanoseconds: realTime ? 20_000_000 : 1_000_000)
            }
            let end = Date()
            let result = try await session.finish()
            text = result.text
            // Spoken punctuation and "scratch that" are chat-profile behaviors; the rest is verbatim. Vocabulary
            // corrections are on throughout, as for a user who enabled them.
            let profile: TranscriptProfile = number == 3 || number == 10 ? .chat : .verbatim
            text = TranscriptProcessor().process(
                text, options: profile.defaultOptions(vocabularyCorrectionsEnabled: true), corrections: .seed)
            latency = Date().timeIntervalSince(end)
        }

        let actualPath = audioURL.deletingPathExtension().appendingPathExtension("actual.txt")
        try? (text + "\n").write(to: actualPath, atomically: true, encoding: .utf8)
        guard let expected else {
            return Result(
                identifier: identifier, category: category, audioSeconds: audioSeconds, wordErrorRate: nil, latency: latency,
                passed: false, note: "missing \(identifier).expected.txt")
        }
        let rate = wordErrorRate(reference: expected, hypothesis: text)
        let latencyPassed = audioSeconds > 30 || (latency ?? 0) <= 1.5
        let passed: Bool
        switch category {
        case "quiet": passed = rate <= 0.08 && latencyPassed
        case "noise", "headset": passed = rate <= 0.15 && latencyPassed
        default: passed = normalizedWords(expected) == normalizedWords(text) && latencyPassed
        }
        var note = latencyPassed ? "" : "latency above 1.5 s"
        if !passed && category == "behavior" { note = "got “\(text)”" }
        return Result(
            identifier: identifier, category: category, audioSeconds: audioSeconds, wordErrorRate: rate, latency: latency,
            passed: passed, note: note)
    }

    private static func resampleToSpeechFormat(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechAudioFormat.sampleRate), channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: buffer.format, to: target)
        else { throw SelfTestError.unreadable }
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Double(SpeechAudioFormat.sampleRate) / buffer.format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw SelfTestError.unreadable }
        // The converter calls the block synchronously, before convert returns.
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
    }

    /// Word-level Levenshtein distance divided by the reference length, case and punctuation ignored.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let reference = normalizedWords(reference)
        let hypothesis = normalizedWords(hypothesis)
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        var previous = Array(0...hypothesis.count)
        for (row, referenceWord) in reference.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: hypothesis.count)
            for (column, hypothesisWord) in hypothesis.enumerated() {
                current[column + 1] = min(
                    previous[column + 1] + 1, current[column] + 1, previous[column] + (referenceWord == hypothesisWord ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[hypothesis.count]) / Double(reference.count)
    }

    enum SelfTestError: LocalizedError {
        case unreadable
        var errorDescription: String? { "The audio file could not be read." }
    }
}

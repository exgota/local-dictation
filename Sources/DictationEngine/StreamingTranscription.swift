@preconcurrency import CoreML
import DictationCore
import FluidAudio
import Foundation
import os

/// Silero voice activity detection on 256 ms frames. It runs on the CPU only, so it does not use the Neural Engine or
/// GPU that the speech encoder runs on.
public actor VoiceActivityDetector {
    private let manager: VadManager

    public init(compiledModelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        manager = VadManager(config: VadConfig(computeUnits: .cpuOnly), vadModel: model)
    }

    public func initialState() async -> VadStreamState {
        await manager.makeStreamState()
    }

    /// Returns the speech probability of one 4096-sample frame and the recurrent state to pass with the next frame.
    public func speechProbability(of frame: [Float], state: VadStreamState) async throws -> (Float, VadStreamState) {
        let result = try await manager.processStreamingChunk(frame, state: state)
        return (result.probability, result.state)
    }
}

public struct StreamingTranscriptionResult: Sendable {
    public let text: String
    public let audioSeconds: Double
    /// Total model input, including overlapping samples.
    public let transcribedSeconds: Double
    public let chunkCount: Int
    /// Model time of the chunks that finished transcribing after the recording ended. This is the model's share of the
    /// wait after the user stops.
    public let processingSecondsAfterEnd: Double
}

/// Transcribes while recording using overlapping model windows. The capture stream retains every sample until the
/// worker consumes it. The window buffer retains only the overlap needed by the next decode.
public final class StreamingTranscription: Sendable {
    public struct Activity: Sendable {
        public let hasDetectedSpeech: Bool
        public let trailingSilence: TimeInterval
    }

    static let longFunctionWarmUpSamples = 5 * SpeechAudioFormat.sampleRate
    private let continuation: AsyncStream<[Float]>.Continuation
    private let ended = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)
    private let worker: Task<StreamingTranscriptionResult, Error>

    public init(
        transcriber: SpeechTranscriber, voiceActivity: VoiceActivityDetector,
        onActivity: @escaping @Sendable (Activity) -> Void = { _ in }
    ) {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        let ended = self.ended
        worker = Task.detached(priority: .userInitiated) {
            try await Self.run(
                stream: stream, transcriber: transcriber, voiceActivity: voiceActivity, ended: ended,
                onActivity: onActivity)
        }
    }

    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        continuation.yield(samples)
    }

    public func finish() async throws -> StreamingTranscriptionResult {
        ended.withLock { $0 = ProcessInfo.processInfo.systemUptime }
        continuation.finish()
        return try await worker.value
    }

    public func cancel() {
        continuation.finish()
        worker.cancel()
    }

    private static func run(
        stream: AsyncStream<[Float]>, transcriber: SpeechTranscriber, voiceActivity: VoiceActivityDetector,
        ended: OSAllocatedUnfairLock<TimeInterval?>,
        onActivity: @Sendable (Activity) -> Void
    ) async throws -> StreamingTranscriptionResult {
        let frameSize = 4096
        let sampleRate = SpeechAudioFormat.sampleRate
        var state = await voiceActivity.initialState()
        var pending: [Float] = []
        var buffer = SpeechWindowBuffer()
        var speechFrames: [Range<Int>] = []
        var processedSamples = 0
        var totalSamples = 0
        var framesSinceSpeech = 0
        var hasDetectedSpeech = false
        var merger = TranscriptOverlapMerger()
        var completedTexts: [String] = []
        var lastDecodedEnd = 0
        var transcribedSamples = 0
        var chunkCount = 0
        var processingAfterEnd = 0.0
        Task.detached(priority: .userInitiated) { await transcriber.warmUp(longFunction: false) }
        var warmedLongFunction = false

        func decode(_ samples: [Float]) async throws -> TranscriptionOutcome? {
            try Task.checkCancellation()
            guard !samples.isEmpty else { return nil }
            do {
                let outcome = try await transcriber.transcribe(samples)
                if ended.withLock({ $0 }) != nil { processingAfterEnd += outcome.processingSeconds }
                transcribedSamples += samples.count
                chunkCount += 1
                return outcome
            } catch TranscriptionError.audioTooShort { return nil }
        }

        func finishMergedText() {
            if !merger.text.isEmpty { completedTexts.append(merger.text) }
            merger = TranscriptOverlapMerger()
        }

        /// Returns true when the next window must start after this one, rather than overlap it.
        func transcribeWindow(_ samples: [Float], start: Int) async throws -> Bool {
            let end = start + samples.count
            let active = speechFrames.filter { $0.lowerBound < end && $0.upperBound > start }
            guard let first = active.first, let last = active.last else {
                finishMergedText()
                lastDecodedEnd = end
                return true
            }
            // The same VAD padding used by the released path limits hallucinations in extended silence.
            let firstSample = max(start, first.lowerBound - sampleRate * 512 / 1000)
            let lastSample = min(end, last.upperBound + sampleRate * 768 / 1000)
            let selected = Array(samples[(firstSample - start)..<(lastSample - start)])
            guard let outcome = try await decode(selected) else { return false }
            let offset = Double(firstSample) / Double(sampleRate) - 0.25
            let tokens = outcome.tokenTimings?.map {
                TranscriptOverlapMerger.Token(piece: $0.token, start: $0.startTime + offset, end: $0.endTime + offset)
            }
            if merger.append(text: outcome.text, tokens: tokens, windowStart: Double(start) / Double(sampleRate)) {
                lastDecodedEnd = end
                return false
            }
            // Without usable timings there is no reliable overlap boundary. Keep the previous result and decode only
            // the not-yet-covered audio, then restart on the next sample. No word is guessed or deduplicated by text.
            if lastDecodedEnd <= start || merger.text.isEmpty {
                finishMergedText()
                if !outcome.text.isEmpty { completedTexts.append(outcome.text) }
            } else {
                finishMergedText()
                let unseenStart = max(start, min(lastDecodedEnd, end))
                let unseenActivity = active.filter { $0.upperBound > unseenStart }
                if let firstUnseen = unseenActivity.first, let lastUnseen = unseenActivity.last {
                    let tailStart = max(unseenStart, firstUnseen.lowerBound - sampleRate * 512 / 1000)
                    let tailEnd = min(end, lastUnseen.upperBound + sampleRate * 768 / 1000)
                    if tailStart < tailEnd,
                       let tail = try await decode(Array(samples[(tailStart - start)..<(tailEnd - start)])), !tail.text.isEmpty {
                        completedTexts.append(tail.text)
                    }
                }
            }
            lastDecodedEnd = end
            return true
        }

        func process(frame: [Float], sampleCount: Int) async throws {
            try Task.checkCancellation()
            let (probability, nextState) = try await voiceActivity.speechProbability(of: frame, state: state)
            state = nextState
            let threshold: Float = hasDetectedSpeech && framesSinceSpeech <= 3 ? 0.35 : 0.5
            if probability >= threshold {
                speechFrames.append(processedSamples..<(processedSamples + sampleCount))
                framesSinceSpeech = 0
                hasDetectedSpeech = true
            } else { framesSinceSpeech += 1 }
            processedSamples += sampleCount
            buffer.append(contentsOf: frame.prefix(sampleCount))
            while buffer.hasFullWindow {
                let reset = try await transcribeWindow(buffer.window(), start: buffer.startSample)
                buffer.advance(reset: reset)
                speechFrames.removeAll { $0.upperBound + sampleRate < buffer.startSample }
            }
            onActivity(Activity(hasDetectedSpeech: hasDetectedSpeech, trailingSilence: Double(framesSinceSpeech * frameSize) / Double(sampleRate)))
        }

        for await samples in stream {
            try Task.checkCancellation()
            totalSamples += samples.count
            if !warmedLongFunction && totalSamples >= Self.longFunctionWarmUpSamples {
                warmedLongFunction = true
                Task.detached(priority: .userInitiated) { await transcriber.warmUp(longFunction: true) }
            }
            var index = 0
            while index < samples.count {
                let count = min(frameSize - pending.count, samples.count - index)
                pending.append(contentsOf: samples[index..<(index + count)])
                index += count
                if pending.count == frameSize {
                    try await process(frame: pending, sampleCount: frameSize)
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        try Task.checkCancellation()
        if !pending.isEmpty {
            try await process(frame: pending + [Float](repeating: 0, count: frameSize - pending.count), sampleCount: pending.count)
        }
        if buffer.needsFinalWindow {
            _ = try await transcribeWindow(buffer.window(), start: buffer.startSample)
        }
        finishMergedText()
        return StreamingTranscriptionResult(
            text: completedTexts.joined(separator: " "), audioSeconds: Double(totalSamples) / Double(sampleRate),
            transcribedSeconds: Double(transcribedSamples) / Double(sampleRate), chunkCount: chunkCount,
            processingSecondsAfterEnd: processingAfterEnd)
    }
}

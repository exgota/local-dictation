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
    public let transcribedSeconds: Double
    public let chunkCount: Int
    /// Model time of the chunks that finished transcribing after the recording ended. This is the model's share of the
    /// wait after the user stops.
    public let processingSecondsAfterEnd: Double
}

/// Transcribes while recording. The audio thread passes samples to `append`. One worker runs voice activity detection,
/// cuts chunks of at most 56 frames (14.336 s) at pauses, and transcribes each chunk as soon as it is cut. The worker
/// retains only the audio of the current chunk. Samples that arrive while a chunk is transcribed wait in an unbounded
/// stream, so memory stays flat however long the recording runs, provided transcription keeps pace with the audio. At
/// the end, only the last chunk remains to be transcribed.
public final class StreamingTranscription: Sendable {
    public struct Activity: Sendable {
        public let hasDetectedSpeech: Bool
        public let trailingSilence: TimeInterval
    }

    /// The last chunk can need `full15` only after about 8 s of audio, so its warm-up starts at 5 s.
    static let longFunctionWarmUpSamples = 5 * 16_000

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
                stream: stream, transcriber: transcriber, voiceActivity: voiceActivity, ended: ended, onActivity: onActivity)
        }
    }

    /// Thread-safe. The audio thread calls it with 16 kHz mono samples.
    public func append(_ samples: [Float]) {
        continuation.yield(samples)
    }

    /// Ends the recording and returns the full transcript once the last chunk is transcribed.
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
        ended: OSAllocatedUnfairLock<TimeInterval?>, onActivity: @Sendable (Activity) -> Void
    ) async throws -> StreamingTranscriptionResult {
        let frameSize = SpeechChunkPlanner.frameSampleCount
        var planner = SpeechChunkPlanner()
        var state = await voiceActivity.initialState()
        var pending: [Float] = []
        var retained: [Float] = []
        var texts: [String] = []
        var totalSamples = 0
        var transcribedSamples = 0
        var chunkCount = 0
        var processingAfterEnd = 0.0
        // While the user is still speaking, warm up the encoder function that the last chunk will most likely use:
        // `short8` at once, `full15` only when the recording is long enough to need it. Both warm-ups run in detached
        // tasks, so voice activity never waits for them.
        Task.detached(priority: .userInitiated) { await transcriber.warmUp(longFunction: false) }
        var warmedLongFunction = false

        func apply(_ commands: [SpeechChunkPlanner.Command]) async throws {
            for command in commands {
                switch command {
                case .emit(let frames):
                    let count = min(frames * frameSize, retained.count)
                    let chunk = Array(retained.prefix(count))
                    retained.removeFirst(count)
                    try Task.checkCancellation()
                    let outcome: TranscriptionOutcome
                    do {
                        outcome = try await transcriber.transcribe(chunk)
                    } catch TranscriptionError.audioTooShort {
                        // A sliver left after a cut holds no word. Skip it, because rethrowing would lose every earlier
                        // chunk.
                        continue
                    }
                    if ended.withLock({ $0 }) != nil { processingAfterEnd += outcome.processingSeconds }
                    chunkCount += 1
                    transcribedSamples += count
                    let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { texts.append(text) }
                case .discard(let frames):
                    retained.removeFirst(min(frames * frameSize, retained.count))
                }
            }
        }

        func process(frame: [Float], sampleCount: Int) async throws {
            let (probability, nextState) = try await voiceActivity.speechProbability(of: frame, state: state)
            state = nextState
            retained.append(contentsOf: frame.prefix(sampleCount))
            try await apply(planner.addFrame(speechProbability: probability))
            onActivity(Activity(hasDetectedSpeech: planner.hasDetectedSpeech, trailingSilence: planner.trailingSilenceDuration))
        }

        for await samples in stream {
            try Task.checkCancellation()
            totalSamples += samples.count
            if !warmedLongFunction && totalSamples >= Self.longFunctionWarmUpSamples {
                warmedLongFunction = true
                Task.detached(priority: .userInitiated) { await transcriber.warmUp(longFunction: true) }
            }
            pending.append(contentsOf: samples)
            while pending.count >= frameSize {
                let frame = Array(pending.prefix(frameSize))
                pending.removeFirst(frameSize)
                try await process(frame: frame, sampleCount: frameSize)
            }
        }
        try Task.checkCancellation()
        if !pending.isEmpty {
            // The final partial frame is padded with silence for voice activity only. Only its real samples are kept.
            try await process(frame: pending + [Float](repeating: 0, count: frameSize - pending.count), sampleCount: pending.count)
        }
        try await apply(planner.finish())
        return StreamingTranscriptionResult(
            text: texts.joined(separator: " "), audioSeconds: Double(totalSamples) / 16_000,
            transcribedSeconds: Double(transcribedSamples) / 16_000, chunkCount: chunkCount,
            processingSecondsAfterEnd: processingAfterEnd)
    }
}

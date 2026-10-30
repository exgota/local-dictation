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
/// cuts chunks at pauses and transcribes them with adjacent audio for context. Samples that arrive while a chunk is
/// transcribed wait in an unbounded stream, so memory stays flat provided transcription keeps pace with the audio. At
/// the end, only the last chunk remains to be transcribed.
public final class StreamingTranscription: Sendable {
    public struct Activity: Sendable {
        public let hasDetectedSpeech: Bool
        public let trailingSilence: TimeInterval
    }

    /// The last chunk can need `full15` only after about 8 s of audio, so its warm-up starts at 5 s.
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
        var retained = SpeechChunkBuffer(maximumChunkFrames: planner.configuration.maximumChunkFrames)
        var guardBands = SpeechGuardBandBuffer()
        var texts: [String] = []
        var previousSelection: TranscriptCoreSelector.Selection?
        var totalSamples = 0
        var transcribedSamples = 0
        var chunkCount = 0
        var processingAfterEnd = 0.0
        // While the user is still speaking, warm up the encoder function that the last chunk will most likely use:
        // `short8` at once, `full15` only when the recording is long enough to need it. Both warm-ups run in detached
        // tasks, so voice activity never waits for them.
        Task.detached(priority: .userInitiated) { await transcriber.warmUp(longFunction: false) }
        var warmedLongFunction = false

        func transcribe(_ chunk: SpeechGuardBandBuffer.Chunk) async throws {
            try Task.checkCancellation()
            let outcome: TranscriptionOutcome
            do {
                outcome = try await transcriber.transcribe(chunk.samples)
            } catch TranscriptionError.audioTooShort {
                // A sliver left after a cut holds no word. Skip it, because rethrowing would lose every earlier chunk.
                return
            }
            if ended.withLock({ $0 }) != nil { processingAfterEnd += outcome.processingSeconds }
            chunkCount += 1
            transcribedSamples += chunk.coreRange.count
            let sampleRate = Double(SpeechAudioFormat.sampleRate)
            let offset = Double(SpeechTranscriber.leadingSilenceSamples) / sampleRate
            // With no guard on a side, the core reaches the edge of the decoded audio. A word at the very start can be
            // timed inside the leading silence, and one at the very end past the last sample.
            let coreStart = chunk.coreRange.lowerBound == 0 ? 0 : offset + Double(chunk.coreRange.lowerBound) / sampleRate
            let coreEnd = chunk.coreRange.upperBound == chunk.samples.count
                ? TimeInterval.infinity : offset + Double(chunk.coreRange.upperBound) / sampleRate
            let core = coreStart..<coreEnd
            let tokens = outcome.tokenTimings?.map { TranscriptCoreSelector.Token(piece: $0.token, startTime: $0.startTime) }
            let selection = TranscriptCoreSelector.reconcilingSeam(
                TranscriptCoreSelector.select(text: outcome.text, tokens: tokens, core: core), after: previousSelection)
            let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            texts.append(text)
            previousSelection = selection
        }

        func apply(_ commands: [SpeechChunkPlanner.Command]) async throws {
            for command in commands {
                switch command {
                case .cut(let cut):
                    let selected = retained.cut(cut)
                    planner.completeCut(frameCount: selected.frameCount)
                    guardBands.schedule(core: selected.samples, following: retained.prefix(SpeechGuardBandBuffer.rightGuardSampleCount))
                case .emit(let frames):
                    try await transcribe(guardBands.finalChunk(core: retained.take(frameCount: frames)))
                case .discard(let frames):
                    guardBands.discard(retained.discard(frameCount: frames))
                }
            }
        }

        func process(frame: [Float], sampleCount: Int, allowCut: Bool = true) async throws {
            let (probability, nextState) = try await voiceActivity.speechProbability(of: frame, state: state)
            state = nextState
            let realSamples = frame.prefix(sampleCount)
            guardBands.appendFollowing(realSamples)
            retained.append(contentsOf: realSamples)
            try await apply(planner.addFrame(speechProbability: probability, allowCut: allowCut))
            if let ready = guardBands.takeReady() { try await transcribe(ready) }
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
            try await process(
                frame: pending + [Float](repeating: 0, count: frameSize - pending.count), sampleCount: pending.count,
                allowCut: false)
        }
        let finalCommands = planner.finish()
        if let final = guardBands.takeFinalPending() {
            try await transcribe(final)
            for command in finalCommands {
                switch command {
                case .emit(let frames), .discard(let frames): retained.discard(frameCount: frames)
                case .cut: preconditionFailure("Unexpected final cut")
                }
            }
        } else {
            try await apply(finalCommands)
        }
        return StreamingTranscriptionResult(
            text: texts.joined(separator: " "), audioSeconds: Double(totalSamples) / Double(SpeechAudioFormat.sampleRate),
            transcribedSeconds: Double(transcribedSamples) / Double(SpeechAudioFormat.sampleRate), chunkCount: chunkCount,
            processingSecondsAfterEnd: processingAfterEnd)
    }
}

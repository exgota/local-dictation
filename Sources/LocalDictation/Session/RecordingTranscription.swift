import DictationEngine
import Foundation
import os

protocol RecordingTranscriptionStream: Sendable {
    func append(_ samples: [Float])
    func finish() async throws -> StreamingTranscriptionResult
    func cancel()
}

extension StreamingTranscription: RecordingTranscriptionStream {}

/// Serializes buffered and live samples across the capture queue and model readiness on the main actor.
final class RecordingAudioBuffer: Sendable {
    private struct Storage {
        var chunks: [[Float]] = []
        var sampleCount = 0
        var acceptingSamples = true
        var stream: (any RecordingTranscriptionStream)?
    }
    private let storage = OSAllocatedUnfairLock(initialState: Storage())
    private let maximumSamples: Int
    private let onLimit: @Sendable () -> Void

    init(maximumSamples: Int, onLimit: @escaping @Sendable () -> Void) {
        self.maximumSamples = max(1, maximumSamples)
        self.onLimit = onLimit
    }

    var bufferedSampleCount: Int { storage.withLock { $0.chunks.reduce(0) { $0 + $1.count } } }

    func append(_ samples: [Float]) {
        let reachedLimit = storage.withLock { storage in
            guard storage.acceptingSamples, !samples.isEmpty else { return false }
            let accepted = Array(samples.prefix(maximumSamples - storage.sampleCount))
            storage.sampleCount += accepted.count
            if let stream = storage.stream { stream.append(accepted) }
            else { storage.chunks.append(accepted) }
            if storage.sampleCount == maximumSamples {
                storage.acceptingSamples = false
                return true
            }
            return false
        }
        if reachedLimit { onLimit() }
    }

    func attach(_ stream: any RecordingTranscriptionStream) {
        storage.withLock { storage in
            for samples in storage.chunks { stream.append(samples) }
            storage.chunks.removeAll()
            storage.stream = stream
        }
    }

    func stop() { storage.withLock { $0.acceptingSamples = false } }

    func cancel() {
        storage.withLock { storage in
            storage.acceptingSamples = false
            storage.chunks.removeAll()
            storage.stream?.cancel()
            storage.stream = nil
        }
    }
}

/// A recording may finish before its model is ready. Failed waits retain audio until readiness or explicit cancellation.
@MainActor final class RecordingTranscription {
    enum State: Equatable { case recording, waitingForModel, transcribing, retained, finished, cancelled }
    static let modelWaitTimeout: TimeInterval = 120
    nonisolated let audio: RecordingAudioBuffer
    let beganDuringLoading: Bool
    private(set) var state: State = .recording
    private(set) var requiresRecovery = false
    private var stream: (any RecordingTranscriptionStream)?
    private var waiter: CheckedContinuation<any RecordingTranscriptionStream, Error>?
    private var deadline: Task<Void, Never>?
    var onModelUnavailable: () -> Void = {}

    init(maximumSamples: Int, stream: (any RecordingTranscriptionStream)?,
         onLimit: @escaping @Sendable () -> Void, timeout: TimeInterval = modelWaitTimeout) {
        audio = RecordingAudioBuffer(maximumSamples: maximumSamples, onLimit: onLimit)
        beganDuringLoading = stream == nil
        self.stream = stream
        if let stream { audio.attach(stream) }
        else {
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self?.modelUnavailable()
            }
        }
    }

    func modelReady(_ stream: any RecordingTranscriptionStream) {
        guard self.stream == nil, state != .cancelled, state != .finished else { stream.cancel(); return }
        deadline?.cancel()
        deadline = nil
        audio.attach(stream)
        self.stream = stream
        if state != .recording { state = .transcribing }
        let continuation = waiter
        waiter = nil
        continuation?.resume(returning: stream)
    }

    func modelUnavailable() {
        guard stream == nil, !requiresRecovery, state != .cancelled, state != .finished else { return }
        deadline?.cancel()
        deadline = nil
        requiresRecovery = true
        if state != .recording { state = .retained }
        onModelUnavailable()
    }

    var needsModel: Bool { stream == nil && state != .cancelled && state != .finished }

    func stop() {
        guard state == .recording else { return }
        audio.stop()
        state = stream != nil ? .transcribing : requiresRecovery ? .retained : .waitingForModel
    }

    func finish() async throws -> StreamingTranscriptionResult {
        stop()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let readyStream: any RecordingTranscriptionStream
            if let stream { readyStream = stream }
            else {
                readyStream = try await withCheckedThrowingContinuation { continuation in
                    if state == .cancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiter = continuation }
                }
            }
            try Task.checkCancellation()
            let result = try await readyStream.finish()
            try Task.checkCancellation()
            guard state != .cancelled else { throw CancellationError() }
            state = .finished
            return result
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        guard state != .cancelled else { return }
        state = .cancelled
        deadline?.cancel()
        deadline = nil
        audio.cancel()
        stream = nil
        let continuation = waiter
        waiter = nil
        continuation?.resume(throwing: CancellationError())
    }
}

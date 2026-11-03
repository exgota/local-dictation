import DictationCore
import XCTest
import os
@testable import DictationEngine
@testable import LocalDictation

private final class RecordingStream: RecordingTranscriptionStream, Sendable {
    private struct Storage {
        var samples: [Float] = []
        var cancelled = false
        var finished = false
    }
    private let storage = OSAllocatedUnfairLock(initialState: Storage())
    var samples: [Float] { storage.withLock { $0.samples } }
    var cancelled: Bool { storage.withLock { $0.cancelled } }
    var finished: Bool { storage.withLock { $0.finished } }

    func append(_ samples: [Float]) { storage.withLock { $0.samples.append(contentsOf: samples) } }
    func cancel() { storage.withLock { $0.cancelled = true } }
    func finish() async throws -> StreamingTranscriptionResult {
        storage.withLock { $0.finished = true }
        if cancelled { throw CancellationError() }
        return StreamingTranscriptionResult(text: "Recorded words", audioSeconds: Double(samples.count) / 16_000,
                                            transcribedSeconds: 0, chunkCount: 1, processingSecondsAfterEnd: 0)
    }
}

final class RecordingTranscriptionTests: XCTestCase {
    @MainActor private func recording() -> RecordingTranscription {
        RecordingTranscription(maximumSamples: 16_000, stream: nil, onLimit: {})
    }

    @MainActor func testStartDuringLoadingAcceptsAudioImmediately() {
        let recording = recording()
        recording.audio.append([1, 2, 3])
        XCTAssertEqual(recording.state, .recording)
        XCTAssertTrue(recording.beganDuringLoading)
        XCTAssertTrue(recording.needsModel)
        XCTAssertEqual(recording.audio.bufferedSampleCount, 3)
        recording.cancel()
    }

    @MainActor func testStopBeforeReadyTranscribesEveryBufferedSampleOnce() async throws {
        let recording = recording()
        recording.audio.append([1, 2])
        recording.stop()
        recording.audio.append([99])
        XCTAssertEqual(recording.state, .waitingForModel)
        let result = Task { try await recording.finish() }
        await Task.yield()
        let stream = RecordingStream()
        recording.modelReady(stream)
        let transcript = try await result.value
        XCTAssertEqual(transcript.text, "Recorded words")
        XCTAssertEqual(stream.samples, [1, 2])
        XCTAssertTrue(stream.finished)
        XCTAssertEqual(recording.audio.bufferedSampleCount, 0)
        XCTAssertEqual(recording.state, .finished)
        XCTAssertFalse(recording.requiresRecovery)
    }

    @MainActor func testReadyBeforeStopJoinsBufferedAndLiveAudioInOrder() async throws {
        let recording = recording()
        recording.audio.append([1, 2])
        let stream = RecordingStream()
        recording.modelReady(stream)
        XCTAssertEqual(recording.state, .recording)
        recording.audio.append([3, 4])
        XCTAssertFalse(stream.finished)
        _ = try await recording.finish()
        XCTAssertEqual(stream.samples, [1, 2, 3, 4])
        XCTAssertEqual(recording.state, .finished)
    }

    @MainActor func testLoadFailureRetainsStoppedAudioAndMarksRecovery() async throws {
        let recording = recording()
        var failures = 0
        recording.onModelUnavailable = { failures += 1 }
        recording.audio.append([1, 2])
        recording.stop()
        recording.modelUnavailable()
        recording.modelUnavailable()
        XCTAssertEqual(recording.state, .retained)
        XCTAssertEqual(recording.audio.bufferedSampleCount, 2)
        XCTAssertEqual(failures, 1)
        let stream = RecordingStream()
        recording.modelReady(stream)
        _ = try await recording.finish()
        XCTAssertEqual(stream.samples, [1, 2])
        XCTAssertTrue(recording.requiresRecovery)
    }

    @MainActor func testLoadFailureWhileRecordingKeepsTheRemainingAudio() async throws {
        let recording = recording()
        recording.audio.append([1])
        recording.modelUnavailable()
        XCTAssertEqual(recording.state, .recording)
        recording.audio.append([2])
        recording.stop()
        XCTAssertEqual(recording.state, .retained)
        let stream = RecordingStream()
        recording.modelReady(stream)
        _ = try await recording.finish()
        XCTAssertEqual(stream.samples, [1, 2])
        XCTAssertTrue(recording.requiresRecovery)
    }

    @MainActor func testTimeoutEndsActiveWaitWithoutDiscardingAudio() async {
        let unavailable = expectation(description: "Model wait expired")
        let recording = RecordingTranscription(maximumSamples: 16_000, stream: nil, onLimit: {}, timeout: 0.01)
        recording.onModelUnavailable = { unavailable.fulfill() }
        recording.audio.append([1, 2])
        recording.stop()
        await fulfillment(of: [unavailable], timeout: 1)
        XCTAssertEqual(recording.state, .retained)
        XCTAssertEqual(recording.audio.bufferedSampleCount, 2)
        recording.cancel()
    }

    @MainActor func testCancelWhileWaitingNeverStartsTheLateModel() async {
        let recording = recording()
        recording.audio.append([1, 2])
        recording.stop()
        let result = Task { try await recording.finish() }
        await Task.yield()
        recording.cancel()
        let stream = RecordingStream()
        recording.modelReady(stream)
        do { _ = try await result.value; XCTFail("Cancelled recording returned a transcript") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(recording.state, .cancelled)
        XCTAssertEqual(recording.audio.bufferedSampleCount, 0)
        XCTAssertEqual(stream.samples, [])
        XCTAssertTrue(stream.cancelled)
    }

    @MainActor func testTaskCancellationResumesAWaitingDelivery() async {
        let recording = recording()
        recording.audio.append([1])
        let result = Task { try await recording.finish() }
        await Task.yield()
        result.cancel()
        do { _ = try await result.value; XCTFail("Cancelled task returned a transcript") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(recording.state, .cancelled)
        XCTAssertEqual(recording.audio.bufferedSampleCount, 0)
    }

    @MainActor func testRecordingLimitCapsSamplesAndSignalsOnce() async throws {
        let limitCount = OSAllocatedUnfairLock(initialState: 0)
        let recording = RecordingTranscription(maximumSamples: 3, stream: nil,
                                                onLimit: { limitCount.withLock { $0 += 1 } })
        recording.audio.append([1, 2])
        recording.audio.append([3, 4, 5])
        recording.audio.append([6])
        XCTAssertEqual(recording.audio.bufferedSampleCount, 3)
        XCTAssertEqual(limitCount.withLock { $0 }, 1)
        let stream = RecordingStream()
        recording.modelReady(stream)
        _ = try await recording.finish()
        XCTAssertEqual(stream.samples, [1, 2, 3])
    }

    @MainActor func testReadinessDuringCapturePreservesSampleOrder() async throws {
        let recording = recording()
        let capture = DispatchGroup()
        capture.enter()
        DispatchQueue.global().async {
            for sample in 0..<10_000 { recording.audio.append([Float(sample)]) }
            capture.leave()
        }
        let stream = RecordingStream()
        recording.modelReady(stream)
        XCTAssertEqual(capture.wait(timeout: .now() + 5), .success)
        _ = try await recording.finish()
        XCTAssertEqual(stream.samples, (0..<10_000).map(Float.init))
    }

    @MainActor func testSecondRecordingDoesNotReplaceAnEarlierWaitingRecording() async throws {
        let first = recording()
        first.audio.append([1])
        first.stop()
        let second = recording()
        second.audio.append([2])
        second.stop()
        second.cancel()
        let stream = RecordingStream()
        first.modelReady(stream)
        _ = try await first.finish()
        XCTAssertEqual(stream.samples, [1])
        XCTAssertEqual(second.state, .cancelled)
    }

    @MainActor func testAlreadyReadyUsesStreamingAndIgnoresLaterLoadFailure() async throws {
        let stream = RecordingStream()
        let recording = RecordingTranscription(maximumSamples: 16_000, stream: stream, onLimit: {})
        recording.audio.append([1, 2])
        recording.modelUnavailable()
        XCTAssertFalse(recording.beganDuringLoading)
        XCTAssertFalse(recording.requiresRecovery)
        XCTAssertEqual(stream.samples, [1, 2])
        _ = try await recording.finish()
        XCTAssertEqual(recording.state, .finished)
    }

    func testTranscribingMoonRemainsUntilDeliveryAndRestartsListening() {
        var animation = MoonAnimation()
        animation.listen(at: 0)
        animation.waitForTranscription(at: 1)
        animation.advance(to: 110)
        XCTAssertEqual(animation.state, .transcribing)
        animation.waitForTranscription(at: 111)
        XCTAssertEqual(animation.beganAt, 1)
        XCTAssertEqual(MoonAnimation.shaderTime(elapsed: 110, reduceMotion: true), 2)
        animation.listen(at: 112)
        XCTAssertEqual(animation.state, .listening)
        animation.waitForTranscription(at: 113)
        animation.dismiss(at: 114)
        animation.advance(to: 115)
        XCTAssertEqual(animation.state, .hidden)
    }
}

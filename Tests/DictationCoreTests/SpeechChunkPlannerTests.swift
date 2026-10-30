import XCTest

@testable import DictationCore

/// Voice activity boundaries: what is trimmed, where chunks are cut, and when nothing is produced.
final class SpeechChunkPlannerTests: XCTestCase {
    private let speech: Float = 0.9
    private let silence: Float = 0.05

    /// Feeds speech probabilities to the planner and returns its commands. After `finish`, it asserts that every frame
    /// was emitted or discarded exactly once.
    private func run(_ probabilities: [Float], finish: Bool = true, planner: inout SpeechChunkPlanner) -> [SpeechChunkPlanner.Command] {
        var commands: [SpeechChunkPlanner.Command] = []
        for probability in probabilities {
            for command in planner.addFrame(speechProbability: probability) {
                if case .cut(let cut) = command {
                    let count = (cut.searchFrames.lowerBound + cut.searchFrames.upperBound + 1) / 2
                    planner.completeCut(frameCount: count)
                    commands.append(.emit(frameCount: count))
                } else {
                    commands.append(command)
                }
            }
        }
        if finish { commands += planner.finish() }
        let accounted = commands.reduce(0) { total, command in
            switch command {
            case .emit(let count), .discard(let count): return total + count
            case .cut: XCTFail("unconfirmed cut"); return total
            }
        }
        if finish { XCTAssertEqual(accounted, probabilities.count, "every frame is emitted or discarded exactly once") }
        return commands
    }

    private func emitted(_ commands: [SpeechChunkPlanner.Command]) -> [Int] {
        commands.compactMap { if case .emit(let count) = $0 { return count } else { return nil } }
    }

    func testSilenceOnlyProducesNothing() {
        var planner = SpeechChunkPlanner()
        let commands = run(Array(repeating: silence, count: 20), planner: &planner)
        XCTAssertEqual(emitted(commands), [])
        XCTAssertFalse(planner.hasDetectedSpeech)
    }

    func testEmptyRecordingProducesNothing() {
        var planner = SpeechChunkPlanner()
        XCTAssertEqual(planner.finish(), [])
    }

    func testLeadingSilenceTrimmedToPadding() {
        var planner = SpeechChunkPlanner()
        let commands = run(Array(repeating: silence, count: 10) + Array(repeating: speech, count: 5), planner: &planner)
        XCTAssertEqual(commands.first, .discard(frameCount: 1))
        // Two padding frames survive before the first speech.
        XCTAssertEqual(emitted(commands), [7])
    }

    func testTrailingSilenceTrimmedToPadding() {
        var planner = SpeechChunkPlanner()
        let commands = run(Array(repeating: speech, count: 5) + Array(repeating: silence, count: 10), planner: &planner)
        XCTAssertEqual(commands, [.emit(frameCount: 8), .discard(frameCount: 7)])
    }

    func testSoftWordEndingCountsAsSpeechOnceStarted() {
        var planner = SpeechChunkPlanner()
        // 0.4 is below the start threshold but above the continuation threshold.
        let commands = run([0.4, speech, speech, 0.4, 0.4, silence, silence, silence, silence, silence], planner: &planner)
        XCTAssertEqual(commands, [.emit(frameCount: 8), .discard(frameCount: 2)])
    }

    func testShortPauseBeforeMinimumDoesNotCut() {
        var planner = SpeechChunkPlanner()
        let probabilities = Array(repeating: speech, count: 10) + [silence] + Array(repeating: speech, count: 10)
        let commands = run(probabilities, planner: &planner)
        XCTAssertEqual(emitted(commands), [21])
    }

    func testSingleQuietFrameAfterMinimumDoesNotCut() {
        var planner = SpeechChunkPlanner()
        let probabilities = Array(repeating: speech, count: 35) + [silence] + Array(repeating: speech, count: 10)
        let commands = run(probabilities, planner: &planner)
        XCTAssertEqual(emitted(commands), [46])
    }

    func testTwoQuietFramesAfterMinimumProposePause() {
        var planner = SpeechChunkPlanner()
        for _ in 0..<35 { XCTAssertEqual(planner.addFrame(speechProbability: speech), []) }
        XCTAssertEqual(planner.addFrame(speechProbability: silence), [])
        guard case .cut(let cut) = planner.addFrame(speechProbability: silence).first else {
            return XCTFail("expected a pause cut")
        }
        XCTAssertEqual(cut.searchFrames, 35..<37)
        planner.completeCut(frameCount: 36)
        XCTAssertEqual(planner.framesSinceSpeech, 2)
        _ = planner.addFrame(speechProbability: speech)
        XCTAssertEqual(planner.framesSinceSpeech, 0)
    }

    func testSingleQuietFrameLaterInChunkProposesPause() {
        var planner = SpeechChunkPlanner()
        for _ in 0..<42 { XCTAssertEqual(planner.addFrame(speechProbability: speech), []) }
        guard case .cut(let cut) = planner.addFrame(speechProbability: silence).first else {
            return XCTFail("expected a pause cut")
        }
        XCTAssertEqual(cut.searchFrames, 42..<43)
        planner.completeCut(frameCount: 43)
    }

    func testFinalPartialFrameDoesNotStartAnExtraChunk() {
        var planner = SpeechChunkPlanner()
        for _ in 0..<30 { _ = planner.addFrame(speechProbability: speech) }
        XCTAssertEqual(planner.addFrame(speechProbability: silence), [])
        XCTAssertEqual(planner.addFrame(speechProbability: silence, allowCut: false), [])
        XCTAssertEqual(planner.finish(), [.emit(frameCount: 32)])
    }

    func testForcedCutNeverExceedsMaximum() {
        var planner = SpeechChunkPlanner()
        var probabilities = Array(repeating: speech, count: 200)
        probabilities[43] = 0.6 // the least speech-like frame inside the search window
        let commands = run(probabilities, planner: &planner)
        let chunks = emitted(commands)
        XCTAssertTrue(chunks.allSatisfy { $0 <= SpeechChunkPlanner.Configuration.standard.maximumChunkFrames }, "\(chunks)")
        XCTAssertEqual(chunks.first, 44, "cut near the quietest recent frame")
        XCTAssertEqual(chunks.reduce(0, +), 200)
    }

    func testLongRecordingKeepsRetainedFramesBounded() {
        var planner = SpeechChunkPlanner()
        var retained = 0
        var maximumRetained = 0
        for index in 0..<(15 * 60 * 4) {
            // Speech with a pause every 24 frames (about 6 s), 3,600 frames in all: about 15 minutes of dictation.
            let probability = index % 24 == 23 ? silence : speech
            retained += 1
            for command in planner.addFrame(speechProbability: probability) {
                switch command {
                case .emit(let count), .discard(let count): retained -= count
                case .cut(let cut):
                    let count = (cut.searchFrames.lowerBound + cut.searchFrames.upperBound + 1) / 2
                    planner.completeCut(frameCount: count)
                    retained -= count
                }
            }
            maximumRetained = max(maximumRetained, retained)
        }
        XCTAssertLessThanOrEqual(maximumRetained, SpeechChunkPlanner.Configuration.standard.maximumChunkFrames)
    }

    func testTrailingSilenceDurationForAutoStop() {
        var planner = SpeechChunkPlanner()
        _ = run(Array(repeating: speech, count: 3) + Array(repeating: silence, count: 8), finish: false, planner: &planner)
        XCTAssertEqual(
            planner.trailingSilenceDuration, Double(8 * SpeechChunkPlanner.frameSampleCount) / 16_000, accuracy: 0.001)
        XCTAssertTrue(planner.hasDetectedSpeech)
    }
}

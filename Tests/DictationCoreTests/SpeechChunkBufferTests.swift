import XCTest

@testable import DictationCore

final class SpeechChunkBufferTests: XCTestCase {
    private let frameSize = SpeechChunkPlanner.frameSampleCount

    func testCutUsesQuietestWindowAndPreservesEverySample() {
        var buffer = SpeechChunkBuffer()
        var samples = [Float](repeating: 0.8, count: frameSize * 4)
        for index in (frameSize + 500)..<(frameSize + 900) { samples[index] = 0 }
        buffer.append(contentsOf: samples[...])
        let cut = SpeechChunkPlanner.Cut(searchFrames: 1..<3)
        let first = buffer.cut(cut)
        XCTAssertTrue((frameSize + 500...frameSize + 900).contains(first.samples.count))
        XCTAssertEqual(first.frameCount, 1)
        let second = buffer.take(frameCount: 3)
        XCTAssertEqual(first.samples + second, samples)
    }

    func testDiscardAccountsForTheRemainderOfTheCutFrame() {
        var buffer = SpeechChunkBuffer()
        var samples = [Float](repeating: 0.8, count: frameSize * 4)
        for index in (frameSize + 500)..<(frameSize + 900) { samples[index] = 0 }
        buffer.append(contentsOf: samples[...])
        let cut = SpeechChunkPlanner.Cut(searchFrames: 1..<3)
        let first = buffer.cut(cut)
        buffer.discard(frameCount: 2)
        XCTAssertEqual(buffer.take(frameCount: 1), Array(samples[(frameSize * 3)...]))
        XCTAssertLessThan(first.samples.count, frameSize * 2)
    }

    func testForcedCutRespectsMaximumWithCarriedSamples() {
        var buffer = SpeechChunkBuffer(maximumChunkFrames: 3)
        let samples = [Float](repeating: 0, count: frameSize * 6)
        buffer.append(contentsOf: samples[...])
        let first = buffer.cut(SpeechChunkPlanner.Cut(searchFrames: 0..<1))
        let second = buffer.cut(SpeechChunkPlanner.Cut(searchFrames: 2..<3))
        XCTAssertLessThanOrEqual(second.samples.count, 3 * frameSize)
        let remaining = buffer.take(frameCount: 6 - first.frameCount - second.frameCount)
        XCTAssertEqual(first.samples + second.samples + remaining, samples)
    }
    func testPlannerAndBufferPreserveSamplesAcrossManyCuts() {
        var planner = SpeechChunkPlanner()
        var buffer = SpeechChunkBuffer()
        var original: [Float] = []
        var emitted: [Float] = []
        for frameIndex in 0..<240 {
            let quiet = frameIndex % 41 == 39 || frameIndex % 41 == 40
            let frame = [Float](repeating: quiet ? 0 : Float(frameIndex + 1) / 241, count: frameSize)
            original.append(contentsOf: frame)
            buffer.append(contentsOf: frame[...])
            for command in planner.addFrame(speechProbability: quiet ? 0.05 : 0.9) {
                switch command {
                case .cut(let cut):
                    let chunk = buffer.cut(cut)
                    XCTAssertLessThanOrEqual(chunk.samples.count, SpeechChunkPlanner.Configuration.standard.maximumChunkFrames * frameSize)
                    planner.completeCut(frameCount: chunk.frameCount)
                    emitted.append(contentsOf: chunk.samples)
                case .emit(let count): emitted.append(contentsOf: buffer.take(frameCount: count))
                case .discard: XCTFail("unexpected discard")
                }
            }
        }
        for command in planner.finish() {
            switch command {
            case .emit(let count): emitted.append(contentsOf: buffer.take(frameCount: count))
            case .cut, .discard: XCTFail("unexpected final command")
            }
        }
        XCTAssertEqual(emitted, original)
    }

    func testSpeechInCutFrameSurvivesAnImmediateStop() {
        let configuration = SpeechChunkPlanner.Configuration(
            speechThreshold: 0.5, continuationThreshold: 0.35, paddingFrames: 2, trailingPaddingFrames: 3,
            minimumChunkFrames: 2, singleFramePauseChunkFrames: 3, maximumChunkFrames: 3, forcedCutSearchFrames: 2)
        var planner = SpeechChunkPlanner(configuration: configuration)
        var buffer = SpeechChunkBuffer(maximumChunkFrames: 3)
        var samples = [Float](repeating: 0.8, count: frameSize * 3)
        for index in (frameSize + 400)..<(frameSize + 1_040) { samples[index] = 0 }
        var first: [Float] = []
        for index in 0..<3 {
            buffer.append(contentsOf: samples[(index * frameSize)..<((index + 1) * frameSize)])
            for command in planner.addFrame(speechProbability: 0.9) {
                guard case .cut(let cut) = command else { return XCTFail("expected a forced cut") }
                let selected = buffer.cut(cut)
                first = selected.samples
                planner.completeCut(frameCount: selected.frameCount)
            }
        }
        let partial = [Float](repeating: 0.6, count: frameSize * 3 / 4)
        samples.append(contentsOf: partial)
        buffer.append(contentsOf: partial[...])
        XCTAssertEqual(planner.addFrame(speechProbability: 0.9, allowCut: false), [])
        guard case .emit(let count) = planner.finish().first else { return XCTFail("expected a final chunk") }
        let last = buffer.take(frameCount: count)
        XCTAssertLessThanOrEqual(last.count, 3 * frameSize)
        XCTAssertEqual(first + last, samples)
    }

}

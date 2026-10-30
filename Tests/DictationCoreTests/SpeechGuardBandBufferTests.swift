import XCTest

@testable import DictationCore

final class SpeechGuardBandBufferTests: XCTestCase {
    func testGuardsKeepContextAndCoreBoundaries() {
        var buffer = SpeechGuardBandBuffer()
        let leftCount = SpeechGuardBandBuffer.leftGuardSampleCount
        let rightCount = SpeechGuardBandBuffer.rightGuardSampleCount
        let firstCore = [Float](repeating: 1, count: leftCount + 100)
        let following = [Float](repeating: 2, count: 300)
        buffer.schedule(core: firstCore, following: following)
        XCTAssertNil(buffer.takeReady())
        let additional = [Float](repeating: 3, count: rightCount)
        buffer.appendFollowing(additional[...])
        guard let first = buffer.takeReady() else { return XCTFail("expected a complete right guard") }
        XCTAssertEqual(first.coreRange, 0..<firstCore.count)
        XCTAssertEqual(Array(first.samples.prefix(firstCore.count)), firstCore)
        XCTAssertEqual(Array(first.samples.suffix(rightCount)), following + additional.prefix(rightCount - following.count))

        let nextCore = [Float](repeating: 4, count: 500)
        let final = buffer.finalChunk(core: nextCore)
        XCTAssertEqual(final.coreRange, leftCount..<(leftCount + nextCore.count))
        XCTAssertEqual(Array(final.samples.prefix(leftCount)), Array(firstCore.suffix(leftCount)))
        XCTAssertEqual(Array(final.samples.suffix(nextCore.count)), nextCore)
    }

    func testDiscardedSilenceBecomesContextForNextCore() {
        var buffer = SpeechGuardBandBuffer()
        let firstCore = [Float](repeating: 1, count: 100)
        let following = [Float](repeating: 2, count: SpeechGuardBandBuffer.rightGuardSampleCount)
        buffer.schedule(core: firstCore, following: following)
        XCTAssertNotNil(buffer.takeReady())
        let discarded = [Float](repeating: 3, count: SpeechGuardBandBuffer.leftGuardSampleCount + 100)
        buffer.discard(discarded)
        let final = buffer.finalChunk(core: [4])
        XCTAssertEqual(final.coreRange, SpeechGuardBandBuffer.leftGuardSampleCount..<(SpeechGuardBandBuffer.leftGuardSampleCount + 1))
        XCTAssertEqual(Array(final.samples.dropLast()), Array(discarded.suffix(SpeechGuardBandBuffer.leftGuardSampleCount)))
    }

    func testStopExtendsPendingCoreWithoutWaitingForGuard() {
        var buffer = SpeechGuardBandBuffer()
        buffer.schedule(core: [1, 2], following: [3])
        buffer.appendFollowing([Float](arrayLiteral: 4, 5)[...])
        guard let final = buffer.takeFinalPending() else { return XCTFail("expected pending audio") }
        XCTAssertEqual(final.samples, [1, 2, 3, 4, 5])
        XCTAssertEqual(final.coreRange, 0..<5)
        XCTAssertNil(buffer.takeReady())
    }

    func testConfiguredWindowFitsModelIncludingLeadingSilence() {
        let core = SpeechChunkPlanner.Configuration.standard.maximumChunkFrames * SpeechChunkPlanner.frameSampleCount
        let padded = core + SpeechGuardBandBuffer.leftGuardSampleCount + SpeechGuardBandBuffer.rightGuardSampleCount
            + SpeechAudioFormat.sampleRate / 4
        XCTAssertLessThanOrEqual(padded, SpeechAudioFormat.sampleRate * 15)
    }
}

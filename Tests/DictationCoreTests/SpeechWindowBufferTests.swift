import XCTest

@testable import DictationCore

final class SpeechWindowBufferTests: XCTestCase {
    func testWindowsRetainAllSamplesAndOneBoundedTail() {
        var buffer = SpeechWindowBuffer()
        let window = SpeechWindowBuffer.windowSampleCount
        let hop = SpeechWindowBuffer.hopSampleCount
        let input = (0..<(window + hop + 100)).map(Float.init)
        buffer.append(contentsOf: input[...])
        XCTAssertEqual(buffer.window(), Array(input[..<window]))
        buffer.advance()
        XCTAssertEqual(buffer.startSample, hop)
        XCTAssertEqual(buffer.window(), Array(input[hop..<(hop + window)]))
        buffer.advance()
        XCTAssertTrue(buffer.needsFinalWindow)
        XCTAssertEqual(buffer.window(), Array(input[(2 * hop)...]))
        XCTAssertLessThan(buffer.count, window)
    }

    func testExactWindowHasNoRedundantTail() {
        var buffer = SpeechWindowBuffer()
        buffer.append(contentsOf: [Float](repeating: 1, count: SpeechWindowBuffer.windowSampleCount)[...])
        buffer.advance()
        XCTAssertFalse(buffer.needsFinalWindow)
    }

    func testTenMinutesStayCoveredWithAWindowSizedBuffer() {
        var buffer = SpeechWindowBuffer()
        let sampleCount = 10 * 60 * SpeechAudioFormat.sampleRate
        let frameSize = 4096
        var position = 0
        var coveredEnd = 0
        var maximumRetained = 0
        while position < sampleCount {
            let length = min(frameSize, sampleCount - position)
            let frame = (position..<(position + length)).map(Float.init)
            buffer.append(contentsOf: frame[...])
            position += length
            maximumRetained = max(maximumRetained, buffer.count)
            while buffer.hasFullWindow {
                let window = buffer.window()
                XCTAssertLessThanOrEqual(buffer.startSample, coveredEnd)
                XCTAssertEqual(window.first, Float(buffer.startSample))
                XCTAssertEqual(window.last, Float(buffer.startSample + window.count - 1))
                coveredEnd = buffer.startSample + window.count
                buffer.advance()
            }
        }
        if buffer.needsFinalWindow {
            let window = buffer.window()
            XCTAssertLessThanOrEqual(buffer.startSample, coveredEnd)
            XCTAssertEqual(window.last, Float(sampleCount - 1))
            coveredEnd = buffer.startSample + window.count
        }
        XCTAssertEqual(coveredEnd, sampleCount)
        XCTAssertLessThanOrEqual(maximumRetained, SpeechWindowBuffer.windowSampleCount + frameSize - 1)
    }

    func testResetDoesNotReplayInvalidWindow() {
        var buffer = SpeechWindowBuffer()
        let input = [Float](repeating: 1, count: SpeechWindowBuffer.windowSampleCount + 32)
        buffer.append(contentsOf: input[...])
        buffer.advance(reset: true)
        XCTAssertEqual(buffer.startSample, SpeechWindowBuffer.windowSampleCount)
        XCTAssertEqual(buffer.window().count, 32)
        XCTAssertTrue(buffer.needsFinalWindow)
    }
}

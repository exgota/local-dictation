import XCTest

@testable import DictationCore

final class TranscriptOverlapMergerTests: XCTestCase {
    private func tokens(_ words: [(String, Double)]) -> [TranscriptOverlapMerger.Token] {
        words.map { .init(piece: "▁" + $0.0, start: $0.1, end: $0.1 + 0.1) }
    }

    func testKeepsRepeatedWordsAcrossAnchor() {
        var merger = TranscriptOverlapMerger()
        XCTAssertTrue(merger.append(text: "it is very very good", tokens: tokens([("it", 0), ("is", 1), ("very", 2), ("very", 2.4), ("good", 3)]), windowStart: 0))
        XCTAssertTrue(merger.append(text: "very very good indeed", tokens: tokens([("very", 2.05), ("very", 2.45), ("good", 3.05), ("indeed", 4)]), windowStart: 1.8))
        XCTAssertEqual(merger.text, "it is very very good indeed")
    }

    func testAlignsTheLaterOccurrenceWhenTheNextWindowOmitsTheFirst() {
        var merger = TranscriptOverlapMerger()
        XCTAssertTrue(merger.append(text: "this is very very nice", tokens: tokens([("this", 0), ("is", 0.5), ("very", 1), ("very", 1.4), ("nice", 2)]), windowStart: 0))
        XCTAssertTrue(merger.append(text: "very wonderful", tokens: tokens([("very", 1.4), ("wonderful", 2.1)]), windowStart: 0.8))
        XCTAssertEqual(merger.text, "this is very very wonderful")
    }

    func testReplacesDisagreementAroundAnchorAndPreservesPunctuation() {
        var merger = TranscriptOverlapMerger()
        XCTAssertTrue(merger.append(text: "one wrong word here", tokens: tokens([("one", 0), ("wrong", 1), ("word", 2), ("here", 3)]), windowStart: 0))
        XCTAssertTrue(merger.append(text: "right word here now.", tokens: tokens([("right", 1), ("word", 2.1), ("here", 3.1), ("now.", 4)]), windowStart: 0.5))
        XCTAssertEqual(merger.text, "one wrong word here now.")
    }

    func testRejectsMissingEmptyAndNonmonotonicTimingsWithoutChangingText() {
        var merger = TranscriptOverlapMerger()
        XCTAssertTrue(merger.append(text: "one two", tokens: tokens([("one", 0), ("two", 1)]), windowStart: 0))
        XCTAssertFalse(merger.append(text: "three", tokens: nil, windowStart: 1))
        XCTAssertFalse(merger.append(text: "three", tokens: [], windowStart: 1))
        XCTAssertFalse(merger.append(text: "three four", tokens: tokens([("three", 3)]), windowStart: 1))
        XCTAssertFalse(merger.append(text: "three four", tokens: tokens([("three", 3), ("four", 2)]), windowStart: 1))
        XCTAssertEqual(merger.text, "one two")
        XCTAssertTrue(merger.append(text: "", tokens: [], windowStart: 1))
        XCTAssertEqual(merger.text, "one two")
    }

    func testUnknownMarkerCreatesWordBoundaryInPieces() {
        var merger = TranscriptOverlapMerger()
        let pieces: [TranscriptOverlapMerger.Token] = [.init(piece: "▁light<unk>this", start: 1, end: 1.2)]
        XCTAssertTrue(merger.append(text: "light this", tokens: pieces, windowStart: 0))
        XCTAssertEqual(merger.text, "light this")
    }
}

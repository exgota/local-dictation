import XCTest

@testable import DictationCore

final class TranscriptCoreSelectorTests: XCTestCase {
    func testKeepsWholeWordsByFirstTokenAndReconstructsPunctuation() {
        let tokens = [
            TranscriptCoreSelector.Token(piece: "▁before", startTime: 0.5),
            TranscriptCoreSelector.Token(piece: "▁win", startTime: 1.0),
            TranscriptCoreSelector.Token(piece: "dow", startTime: 2.1),
            TranscriptCoreSelector.Token(piece: ",", startTime: 2.2),
            TranscriptCoreSelector.Token(piece: " ▁after", startTime: 2.3),
        ]
        XCTAssertEqual(TranscriptCoreSelector.select(text: "unused", tokens: tokens, core: 1.0..<2.0).text, "window,")
    }

    func testNilTimingsUseEntireTranscript() {
        XCTAssertEqual(TranscriptCoreSelector.select(text: "One complete sentence.", tokens: nil, core: 1.0..<2.0).text,
                       "One complete sentence.")
    }

    func testIncludesOnlyWordsStartingInsideCore() {
        let tokens = [
            TranscriptCoreSelector.Token(piece: " outside", startTime: 0.9),
            TranscriptCoreSelector.Token(piece: " inside", startTime: 1.0),
            TranscriptCoreSelector.Token(piece: " core", startTime: 1.8),
            TranscriptCoreSelector.Token(piece: ".", startTime: 2.1),
            TranscriptCoreSelector.Token(piece: " beyond", startTime: 2.0),
        ]
        XCTAssertEqual(TranscriptCoreSelector.select(text: "unused", tokens: tokens, core: 1.0..<2.0).text, "inside core.")
    }

    func testRemovesWordPlacedOnBothSidesOfCut() {
        let previous = TranscriptCoreSelector.Selection(text: "the design. And", firstWordDelay: 0, lastWordLead: 0.1)
        let next = TranscriptCoreSelector.Selection(text: "and then we ship", firstWordDelay: 0.05, lastWordLead: 1)
        XCTAssertEqual(TranscriptCoreSelector.reconcilingSeam(next, after: previous).text, "then we ship")
    }

    func testKeepsRepeatedWordAwayFromCut() {
        let previous = TranscriptCoreSelector.Selection(text: "we should", firstWordDelay: 0, lastWordLead: 0.1)
        let next = TranscriptCoreSelector.Selection(text: "we should", firstWordDelay: 0.6, lastWordLead: 1)
        XCTAssertEqual(TranscriptCoreSelector.reconcilingSeam(next, after: previous).text, "we should")
    }

    func testKeepsTextWithoutTimings() {
        let previous = TranscriptCoreSelector.Selection(text: "one two")
        let next = TranscriptCoreSelector.Selection(text: "two three")
        XCTAssertEqual(TranscriptCoreSelector.reconcilingSeam(next, after: previous).text, "two three")
    }

    func testRestoresWordBothDecodesLeftOut() {
        var previous = TranscriptCoreSelector.Selection(text: "we ship", firstWordDelay: 0, lastWordLead: 1)
        previous.wordAfterCore = (text: "today", delay: 0.05)
        var next = TranscriptCoreSelector.Selection(text: "or tomorrow", firstWordDelay: 0.3, lastWordLead: 1)
        next.wordBeforeCore = (text: "today", lead: 0.04)
        XCTAssertEqual(TranscriptCoreSelector.reconcilingSeam(next, after: previous).text, "today or tomorrow")
    }

    func testDoesNotRestoreDifferentWords() {
        var previous = TranscriptCoreSelector.Selection(text: "we ship", firstWordDelay: 0, lastWordLead: 1)
        previous.wordAfterCore = (text: "today", delay: 0.05)
        var next = TranscriptCoreSelector.Selection(text: "or tomorrow", firstWordDelay: 0.3, lastWordLead: 1)
        next.wordBeforeCore = (text: "soon", lead: 0.04)
        XCTAssertEqual(TranscriptCoreSelector.reconcilingSeam(next, after: previous).text, "or tomorrow")
    }

    func testKeepsWordTimedInsideLeadingSilenceWhenCoreStartsAtZero() {
        let tokens = [TranscriptCoreSelector.Token(piece: "▁Please", startTime: 0.16), .init(piece: "▁go", startTime: 0.5)]
        XCTAssertEqual(TranscriptCoreSelector.select(text: "unused", tokens: tokens, core: 0..<TimeInterval.infinity).text, "Please go")
    }
}

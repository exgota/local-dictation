import XCTest

@testable import DictationCore

final class TranscriptUnknownMarkerTests: XCTestCase {
    func testRemovesMarkersWithoutJoiningWords() {
        XCTAssertEqual(TranscriptUnknownMarker.remove(from: "said Douglas. <unk>Not in any"), "said Douglas. Not in any")
        XCTAssertEqual(TranscriptUnknownMarker.remove(from: "eternal life and light<unk>this is the faith"), "eternal life and light this is the faith")
        XCTAssertEqual(TranscriptUnknownMarker.remove(from: "<unk>one  <unk>  <unk>two<unk>"), "one two")
        XCTAssertEqual(TranscriptUnknownMarker.remove(from: "already  spaced"), "already  spaced")
    }
}

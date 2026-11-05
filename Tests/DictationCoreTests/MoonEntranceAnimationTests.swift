import DictationCore
import XCTest

final class MoonEntranceAnimationTests: XCTestCase {
    func testEntranceRetainsReleasedFormationAndFadeTiming() {
        XCTAssertEqual(MoonEntranceAnimation.frame(after: -1).formation, 0.72)
        XCTAssertEqual(MoonEntranceAnimation.frame(after: 0).formation, 0.72)
        XCTAssertEqual(MoonEntranceAnimation.frame(after: 0.075).formation, 0.86, accuracy: 0.000001)
        XCTAssertEqual(MoonEntranceAnimation.frame(after: 0.15).formation, 1)
        XCTAssertEqual(MoonEntranceAnimation.frame(after: 2).formation, 1)
        XCTAssertEqual(MoonEntranceAnimation.frame(after: 0).opacity, 0, accuracy: 0.00001)
        XCTAssertEqual(MoonEntranceAnimation.frame(after: 0.15).opacity, 1, accuracy: 0.000001)
    }
}

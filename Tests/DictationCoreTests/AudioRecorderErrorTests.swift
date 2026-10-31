import DictationCore
import XCTest

final class AudioRecorderErrorTests: XCTestCase {
    func testUnavailableMicrophonesShowTheWarning() {
        XCTAssertTrue(AudioRecorderError.inputUnavailable.showsMicrophoneWarning)
        XCTAssertTrue(AudioRecorderError.selectedDeviceUnavailable.showsMicrophoneWarning)
    }

    func testConversionFailureDoesNotShowTheWarning() {
        XCTAssertFalse(AudioRecorderError.converterUnavailable.showsMicrophoneWarning)
    }
}

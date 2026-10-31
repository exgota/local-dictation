import DictationCore
import XCTest

final class MicrophoneSilenceMonitorTests: XCTestCase {
    func testNoAudioAtAllRaisesTheWarningAfterTheDelay() {
        let monitor = MicrophoneSilenceMonitor(startTime: 10)
        XCTAssertFalse(monitor.isSilent(at: 12.9))
        XCTAssertTrue(monitor.isSilent(at: 13))
    }

    func testFlatlineRaisesTheWarning() {
        var monitor = MicrophoneSilenceMonitor(startTime: 0)
        for time in stride(from: 0.0, to: 3.0, by: 0.02) { monitor.receive(decibels: -140, at: time) }
        XCTAssertTrue(monitor.isSilent(at: 3))
    }

    func testQuietRoomNeverRaisesTheWarning() {
        var monitor = MicrophoneSilenceMonitor(startTime: 0)
        for time in stride(from: 0.0, to: 60.0, by: 0.02) {
            monitor.receive(decibels: -62, at: time)
            XCTAssertFalse(monitor.isSilent(at: time))
        }
    }

    func testSoundReturningClearsTheWarning() {
        var monitor = MicrophoneSilenceMonitor(startTime: 0)
        XCTAssertTrue(monitor.isSilent(at: 4))
        monitor.receive(decibels: -40, at: 4)
        XCTAssertFalse(monitor.isSilent(at: 4.02))
        XCTAssertTrue(monitor.isSilent(at: 7))
    }
}

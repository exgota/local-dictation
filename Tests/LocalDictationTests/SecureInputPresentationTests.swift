import AppKit
import XCTest
@testable import LocalDictation

final class SecureInputPresentationTests: XCTestCase {
    @MainActor func testSecureInputNamesTheApplicationOrUsesTheGenericMessage() {
        XCTAssertEqual(SecureInputMonitor.Holder(processIdentifier: 123, applicationName: "Safari").statusDetail,
                       "Safari is using secure input")
        for name in ["Another app", "loginwindow", "", "  "] {
            XCTAssertEqual(SecureInputMonitor.Holder(processIdentifier: nil, applicationName: name).statusDetail,
                           "Another app is using secure input")
        }
    }

    @MainActor func testSecureInputKeepsTheMenuAvailableAndRestoresTheOrdinaryIcon() throws {
        for needsSetup in [false, true] {
            let blocked = StatusItemIcon(needsSetup: needsSetup, secureInputBlocked: true)
            XCTAssertEqual(blocked, .blocked)
            XCTAssertFalse(blocked.opensSetup)
            XCTAssertTrue(try XCTUnwrap(blocked.image).isTemplate)
            let released = StatusItemIcon(needsSetup: needsSetup, secureInputBlocked: false)
            XCTAssertEqual(released, needsSetup ? .error : .normal)
            XCTAssertEqual(released.opensSetup, needsSetup)
            XCTAssertTrue(try XCTUnwrap(released.image).isTemplate)
        }
    }
}

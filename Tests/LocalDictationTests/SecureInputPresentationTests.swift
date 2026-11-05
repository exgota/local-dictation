import AppKit
import XCTest
@testable import LocalDictation

final class SecureInputPresentationTests: XCTestCase {
    func testCurrentGraphicsSessionIdentifiesTheHolderBeforeRegistryFallback() {
        let session: [String: Any] = ["kCGSSessionSecureInputPID": NSNumber(value: 12345)]
        let registry: [[String: Any]] = [["kCGSSessionSecureInputPID": 9876,
            "kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501]]
        XCTAssertEqual(SecureInputMonitor.secureInputProcessIdentifier(currentSession: session,
                       consoleUsers: registry, userIdentifier: 501), 12345)
    }

    func testRegistryFallbackUsesOnlyTheCurrentConsoleUser() {
        let registry: [[String: Any]] = [
            ["kCGSSessionSecureInputPID": 111, "kCGSSessionOnConsoleKey": false, "kCGSSessionUserIDKey": 501],
            ["kCGSSessionSecureInputPID": 222, "kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 502],
            ["kCGSSessionSecureInputPID": 333, "kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501],
        ]
        XCTAssertEqual(SecureInputMonitor.secureInputProcessIdentifier(currentSession: [:],
                       consoleUsers: registry, userIdentifier: 501), 333)
        XCTAssertNil(SecureInputMonitor.secureInputProcessIdentifier(currentSession: nil,
                     consoleUsers: Array(registry.prefix(2)), userIdentifier: 501))
    }

    func testMissingInvalidOrUnavailableProcessIdentifiersStayUnknown() {
        let invalid: [Any] = [0, -1, Int64(Int32.max) + 1, 1.5, true, "12345"]
        for value in invalid {
            XCTAssertNil(SecureInputMonitor.secureInputProcessIdentifier(
                currentSession: ["kCGSSessionSecureInputPID": value], consoleUsers: [], userIdentifier: 501))
        }
        XCTAssertNil(SecureInputMonitor.secureInputProcessIdentifier(currentSession: nil,
                     consoleUsers: [], userIdentifier: 501))
    }

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

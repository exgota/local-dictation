import AppKit
import CryptoKit
import XCTest
@testable import LocalDictation

final class MenuHeaderTests: XCTestCase {
    @MainActor func testHeaderStateBitmapsMatchApprovedDrawing() throws {
        // SHA-256 of the original study's phaseCoin RGBA bytes, generated independently of this renderer.
        let expected: [(StatusMenu.HeaderState, String)] = [
            (.ready, "c89e5aa225bec739ad62f447a97e1eae44bfab3d5b0953e520bf9c434658f52c"),
            (.listening, "827606876d3fb7ed4bfff485d1a0e45aa14e533351d43b8c2eaf0b4b909f5cb5"),
            (.transcribing, "827606876d3fb7ed4bfff485d1a0e45aa14e533351d43b8c2eaf0b4b909f5cb5"),
            (.loading, "0127c4dc51fb54d916fe8813189dab3646b52e5ea649f24976eae19c79968e1c"),
            (.paused, "1036df7e9965fe92eb31d2e39ab8fa94ffddf6206c8d41b1ba3bbefbc7feecd5"),
            (.blocked, "1036df7e9965fe92eb31d2e39ab8fa94ffddf6206c8d41b1ba3bbefbc7feecd5"),
        ]
        XCTAssertEqual(expected.count, StatusMenu.HeaderState.allCases.count)
        for (state, hash) in expected {
            let bitmap = state.moonPhase.bitmap()
            XCTAssertEqual(bitmap.width, 60)
            XCTAssertEqual(bitmap.height, 60)
            XCTAssertFalse(try bitmap.image().shouldInterpolate)
            XCTAssertEqual(SHA256.hash(data: Data(bitmap.bytes)).map { String(format: "%02x", $0) }.joined(), hash, "\(state)")
        }
    }

    @MainActor func testExistingHeaderUpdatesItsCoinAndPreservesOneLineGeometry() throws {
        let header = MenuMoonHeaderView(title: "Ready", subtitle: "", phase: .full)
        let coin = try XCTUnwrap(header.subviews.compactMap { $0 as? NSImageView }.first)
        let ready = try XCTUnwrap(coin.image?.tiffRepresentation)
        header.update(title: "Loading speech model", subtitle: "", phase: .crescent)
        XCTAssertEqual(header.frame.height, 32)
        XCTAssertEqual(coin.frame, NSRect(x: 9, y: -3, width: 30, height: 30))
        XCTAssertEqual(coin.image?.size, NSSize(width: 30, height: 30))
        XCTAssertEqual(coin.imageScaling, .scaleNone)
        XCTAssertNotEqual(coin.image?.tiffRepresentation, ready)
        header.update(title: "Ready", subtitle: "A current problem", phase: .full)
        XCTAssertEqual(header.frame.height, 43)
        header.update(title: "Ready", subtitle: "", phase: .full)
        XCTAssertEqual(header.frame.height, 32)
        XCTAssertEqual(coin.image?.tiffRepresentation, ready)
    }
}

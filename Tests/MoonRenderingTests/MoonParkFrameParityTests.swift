import CryptoKit
import DictationCore
import Foundation
import XCTest
@testable import MoonRendering

final class MoonParkFrameParityTests: XCTestCase {
    private struct Capture: Decodable {
        let name: String
        let pixels: Int
        let sourceTime, sourceLevel: Float
        let smokeFraction, age: Double
        let reason: DictationMiss
        let departureAge: Double?
        let reduceMotion: Bool
        let bitmapSHA256: String
        let opacity: Double
    }

    private struct UnchangedCapture: Decodable {
        let name: String
        let pixels: Int
        let parameters: [String: Float]
        let smokeMilliseconds: Double?
        let bitmapSHA256: String
    }

    /// Captured at e018713 before the Park shader change: 286 warning and stop frames at 1x/2x.
    @MainActor func testPreMissAndWarningFramesRemainByteIdentical() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MoonPreMissFrameBaseline", withExtension: "json", subdirectory: "Fixtures"))
        let captures = try JSONDecoder().decode([UnchangedCapture].self, from: Data(contentsOf: url))
        XCTAssertEqual(captures.count, 286)
        let renderer = try MoonRenderer()
        for capture in captures {
            var frame = MoonFrame()
            frame.time = capture.parameters["time"] ?? 0
            frame.level = capture.parameters["level"] ?? 0
            frame.warning = capture.parameters["warn"] ?? 0
            var bitmap = try renderer.render(frame, pixels: capture.pixels)
            if let milliseconds = capture.smokeMilliseconds, milliseconds > 0 {
                bitmap = MoonSmoke(bitmap: bitmap).render(fraction: milliseconds / 450)
            }
            let digest = SHA256.hash(data: Data(bitmap.bytes)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, capture.bitmapSHA256, capture.name)
        }
    }

    /// Frozen shader morph and sent-exit frames from the production renderer.
    /// Covers 1×/2×, every morph frame at 60 fps, hold, early exits and no-copy reasons.
    @MainActor func testParkMatchesShaderMorphFrameBaseline() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ParkFrameBaseline", withExtension: "json", subdirectory: "Fixtures"))
        let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: url))
        XCTAssertEqual(captures.count, 2328)
        let renderer = try MoonRenderer()
        for capture in captures {
            var sourceFrame = MoonFrame()
            sourceFrame.time = capture.sourceTime
            sourceFrame.level = capture.sourceLevel
            let source = try renderer.render(sourceFrame, pixels: capture.pixels)
            let stopped = capture.smokeFraction > 0 ? MoonSmoke(bitmap: source).render(fraction: capture.smokeFraction) : source
            let motion = try MoonPark(source: stopped, shader: sourceFrame,
                                  opacity: MoonAnimation.smokeOpacity(after: capture.smokeFraction * MoonAnimation.smokeDuration))
            let result = try motion.render(age: capture.age, reason: capture.reason,
                departureAge: capture.departureAge, reduceMotion: capture.reduceMotion)
            let digest = SHA256.hash(data: Data(result.bitmap.bytes)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, capture.bitmapSHA256, capture.name)
            XCTAssertEqual(result.opacity, capture.opacity, accuracy: 0.000000001, capture.name)
        }
    }
}

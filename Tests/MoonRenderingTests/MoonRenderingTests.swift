import AppKit
import XCTest
@testable import MoonRendering

final class MoonRenderingTests: XCTestCase {
    @MainActor func testHiddenCanvasHasNoDisplayTimerOrDraws() {
        let view = MoonCanvasView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        view.drawing = { _ in XCTFail("A detached canvas must never request a frame"); return nil }
        view.setActive(true)
        view.redraw()
        XCTAssertFalse(view.timerIsRunning)
        XCTAssertEqual(view.renderedFrames, 0)
        view.setActive(false)
        XCTAssertFalse(view.timerIsRunning)
    }

    @MainActor func testRendererProducesBinaryHalfPointDots() throws {
        let bitmap = try MoonRenderer().render(MoonFrame(), pixels: 112)
        let alpha = stride(from: 3, to: bitmap.bytes.count, by: 4).map { bitmap.bytes[$0] }
        XCTAssertTrue(alpha.allSatisfy { $0 == 0 || $0 == 255 })
        XCTAssertGreaterThan(alpha.filter { $0 == 255 }.count, 300)
        XCTAssertLessThan(alpha.filter { $0 == 255 }.count, 2000)
    }

    func testSmokeKeepsStartingCoordinatesAndExpires() {
        var bytes = [UInt8](repeating: 0, count: 112 * 112 * 4)
        for column in 45..<65 { bytes[(56 * 112 + column) * 4 + 3] = 255 }
        let source = MoonBitmap(width: 112, height: 112, bytes: bytes)
        let smoke = MoonSmoke(bitmap: source)
        let initial = smoke.render(fraction: 0)
        for offset in stride(from: 3, to: bytes.count, by: 4) {
            XCTAssertEqual(initial.bytes[offset], bytes[offset])
        }
        XCTAssertTrue(smoke.render(fraction: 1).bytes.allSatisfy { $0 == 0 })
    }
}

final class MoonParkRenderingTests: XCTestCase {
    @MainActor func testReducedMotionKeepsDotsStationaryAndOnlyChangesOpacity() throws {
        let renderer = try MoonRenderer()
        var target = MoonFrame()
        target.time = 1.7
        let main = try renderer.render(target, pixels: 112)
        let satellite = try renderer.render(target, pixels: MoonPark.satellitePixels(for: 112))
        let motion = MoonPark(source: main, main: main, satellite: satellite, smokeFraction: 230 / 450)
        let arriving = motion.render(age: 0.075, reason: .focusMoved, reduceMotion: true)
        let resting = motion.render(age: 1.2, reason: .focusMoved, reduceMotion: true)
        XCTAssertEqual(arriving.bitmap.bytes, resting.bitmap.bytes)
        XCTAssertEqual(arriving.opacity, 0.5, accuracy: 0.000001)
        XCTAssertEqual(resting.opacity, 1)
        let departing = motion.render(age: 1.3, reason: .focusMoved, departure: .pasted, departureAge: 0.075, reduceMotion: true)
        XCTAssertEqual(departing.bitmap.bytes, resting.bitmap.bytes)
        XCTAssertEqual(departing.opacity, 0.5, accuracy: 0.000001)
        let secure = motion.render(age: 1.2, reason: .secureField, reduceMotion: true)
        XCTAssertLessThan(secure.bitmap.bytes.filter { $0 == 255 }.count, resting.bitmap.bytes.filter { $0 == 255 }.count)
    }
}

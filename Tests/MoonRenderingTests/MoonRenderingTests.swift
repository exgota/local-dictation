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

final class MoonSetupMotionTests: XCTestCase {
    @MainActor func testSetupFloatIsEnabledByDefaultAndReduceMotionRemovesIt() throws {
        let renderer = try MoonRenderer()
        for shape: Float in [0, 1, 2] {
            var frame = MoonFrame()
            frame.mode = 2
            frame.previousShape = shape
            frame.nextShape = shape
            frame.transition = 1
            frame.download = 0.52
            frame.time = 1.5
            let floating = try renderer.render(frame, pixels: 240)
            frame.reduceMotion = true
            XCTAssertNotEqual(try renderer.render(frame, pixels: 240).bytes, floating.bytes)
        }
    }

    @MainActor func testVoiceLevelStillChangesTheFormingMoon() throws {
        let renderer = try MoonRenderer()
        var frame = MoonFrame()
        frame.formation = 0.86
        let quiet = try renderer.render(frame, pixels: 112)
        frame.level = 0.9
        let speaking = try renderer.render(frame, pixels: 112)
        XCTAssertNotEqual(quiet.bytes, speaking.bytes)
    }
}

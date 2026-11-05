import DictationCore
import XCTest
@testable import MoonRendering

final class MoonParkCopyCueTests: XCTestCase {
    @MainActor func testMorphStartsAtTheDisplayedMoonAndUsesOneBinaryDither() throws {
        for pixels in [56, 112] {
            for level: Float in [0, 0.68, 1] {
                let shader = sourceFrame(level: level)
                let source = try MoonRenderer.shared.get().render(shader, pixels: pixels)
                let motion = try MoonPark(source: source, shader: shader)
                XCTAssertEqual(try motion.render(age: 0, reason: .focusMoved).bitmap.bytes, source.bytes)
                for index in 1...30 {
                    let frame = try motion.render(age: Double(index) / 60, reason: .focusMoved)
                    XCTAssertEqual(frame.opacity, 1)
                    XCTAssertEqual(frame.shader.level, level)
                    XCTAssertEqual(frame.shader.time, shader.time)
                    for offset in stride(from: 0, to: frame.bitmap.bytes.count, by: 4) {
                        let pixel = Array(frame.bitmap.bytes[offset..<(offset + 4)])
                        XCTAssertTrue(pixel == [0, 0, 0, 0] || pixel == [245, 245, 242, 255])
                    }
                }
            }
        }
    }

    @MainActor func testEveryReasonUsesCopyOnlyWhenTextWasCopied() throws {
        let shader = sourceFrame()
        let source = try MoonRenderer.shared.get().render(shader, pixels: 112)
        let motion = try MoonPark(source: source, shader: shader)
        var marked = shader
        marked.park = 1
        let copy = try MoonRenderer.shared.get().render(marked, pixels: 112)
        let copied: Set<DictationMiss> = [.focusMoved, .noTextField, .unconfirmed, .modelUnavailable, .microphoneDisconnected]
        for reason in DictationMiss.allCases {
            let result = try motion.render(age: 1.5, reason: reason)
            XCTAssertEqual(result.bitmap.bytes, copied.contains(reason) ? copy.bytes : source.bytes)
            XCTAssertEqual(result.opacity, reason == .secureField ? 0 : 1)
        }
    }

    @MainActor func testLateMissMorphsFrozenDotsWithoutRestoringAnEarlierMoon() throws {
        let shader = sourceFrame()
        let source = try MoonRenderer.shared.get().render(shader, pixels: 112)
        var target = shader
        target.park = 1
        let copy = try MoonRenderer.shared.get().render(target, pixels: 112)
        for stopAge in [0.1, 0.3, 0.4] {
            let displayed = MoonSmoke(bitmap: source).render(fraction: stopAge / MoonAnimation.smokeDuration)
            let opacity = MoonAnimation.smokeOpacity(after: stopAge)
            let motion = try MoonPark(source: displayed, shader: shader, opacity: opacity)
            let initial = try motion.render(age: 0, reason: .focusMoved)
            XCTAssertEqual(initial.bitmap.bytes, displayed.bytes)
            XCTAssertEqual(initial.opacity, opacity)
            // A signed-distance interpolation cannot create a third silhouette outside either endpoint.
            let endpoints = occupancy(displayed).union(occupancy(copy))
            let beginning = try motion.render(age: 1.0 / 60, reason: .focusMoved)
            XCTAssertTrue(occupancy(beginning.bitmap).isSubset(of: endpoints))
            XCTAssertNotEqual(beginning.bitmap.bytes, source.bytes)
            XCTAssertEqual(try motion.render(age: 1.5, reason: .focusMoved).bitmap.bytes, copy.bytes)
        }
    }

    @MainActor func testCopyGeometryKeepsThreeGroovesAndSeparatesItsBackPage() throws {
        var frame = sourceFrame()
        frame.park = 1
        let bitmap = try MoonRenderer.shared.get().render(frame, pixels: 112)
        func alpha(x: Double, y: Double) -> UInt8 {
            let column = Int(((x - 28.5) * 1.3 / 44 * 0.5 + 0.5) * 112)
            let row = Int(((y - 27.5) * 1.3 / 44 * 0.5 + 0.5) * 112)
            return bitmap.bytes[(row * 112 + column) * 4 + 3]
        }
        for y in [26.5, 30.5, 34.5] { XCTAssertEqual(alpha(x: 29, y: y), 0) }
        XCTAssertEqual(alpha(x: 34, y: 34.5), 255, "The third groove ends earlier")
        XCTAssertEqual(alpha(x: 21.8, y: 33), 0, "The back outline stops before the front page")
        XCTAssertEqual(alpha(x: 25, y: 22), 255, "The front page remains filled")
    }

    @MainActor func testMissDuringWarningPreservesItsDisplayedShape() throws {
        var shader = sourceFrame(level: 0)
        shader.warning = 0.8
        let source = try MoonRenderer.shared.get().render(shader, pixels: 112)
        let motion = try MoonPark(source: source, shader: shader)
        var target = shader
        target.warning = 0
        target.park = 1
        let copy = try MoonRenderer.shared.get().render(target, pixels: 112)
        XCTAssertEqual(try motion.render(age: 0, reason: .focusMoved).bitmap.bytes, source.bytes)
        let entry = try motion.render(age: 1.0 / 60, reason: .focusMoved)
        XCTAssertTrue(occupancy(entry.bitmap).isSubset(of: occupancy(source).union(occupancy(copy))))
        XCTAssertEqual(try motion.render(age: 1.5, reason: .focusMoved).bitmap.bytes, copy.bytes)
        let returned = try motion.render(age: 1.7, reason: .focusMoved, departureAge: 0.2)
        target.park = 0
        XCTAssertEqual(returned.bitmap.bytes, try MoonRenderer.shared.get().render(target, pixels: 112).bytes)
    }

    @MainActor func testSecureRefusalFadesTheFrozenMoonWithoutCopy() throws {
        let shader = sourceFrame()
        let source = try MoonRenderer.shared.get().render(shader, pixels: 112)
        let motion = try MoonPark(source: source, shader: shader, opacity: 0.6)
        for age in [0.0, 0.05, 0.125, 0.2, 0.25, 1.2] {
            let frame = try motion.render(age: age, reason: .secureField)
            XCTAssertEqual(frame.bitmap.bytes, source.bytes)
            XCTAssertLessThanOrEqual(frame.opacity, 0.6)
        }
        XCTAssertEqual(try motion.render(age: 0.125, reason: .secureField).opacity, 0.3, accuracy: 0.000001)
        XCTAssertEqual(try motion.render(age: 0.25, reason: .secureField).opacity, 0)
    }

    @MainActor func testReducedMotionBlendsTonesBeforeDitheringWithoutShapeInterpolation() throws {
        let renderer = try MoonRenderer(capturesTone: true)
        var frame = sourceFrame()
        let moon = try renderer.render(frame, pixels: 112)
        frame.park = 1
        let copy = try renderer.render(frame, pixels: 112)
        frame.park = 0.5
        frame.reduceMotion = true
        let middle = try renderer.render(frame, pixels: 112)
        for offset in stride(from: 0, to: middle.bytes.count, by: 4) {
            func tone(_ bitmap: MoonBitmap) -> Double {
                Double(Int(bitmap.bytes[offset]) | Int(bitmap.bytes[offset + 1]) << 8 | Int(bitmap.bytes[offset + 2]) << 16)
            }
            XCTAssertEqual(tone(middle), (tone(moon) + tone(copy)) / 2, accuracy: 2)
        }
        frame.reduceMotion = false
        XCTAssertNotEqual(try renderer.render(frame, pixels: 112).bytes, middle.bytes)
    }

    @MainActor func testReleaseReturnsToTheSameMoonThenUsesTheSuccessfulStopExit() throws {
        let shader = sourceFrame()
        let source = try MoonRenderer.shared.get().render(shader, pixels: 112)
        let motion = try MoonPark(source: source, shader: shader)
        for departureAt in [0.0, 0.1, 0.25, 1.5] {
            let initial = try motion.render(age: departureAt, reason: .focusMoved)
            let releasing = try motion.render(age: departureAt, reason: .focusMoved, departureAge: 0)
            XCTAssertEqual(releasing.bitmap.bytes, initial.bitmap.bytes)
            for reduced in [false, true] {
                for exitAge in [0.0, 0.1, 0.3, 0.45] {
                    let elapsed = MoonAnimation.parkReturnDuration + exitAge
                    let result = try motion.render(age: departureAt + elapsed, reason: .focusMoved,
                                                   departureAge: elapsed, reduceMotion: reduced)
                    let smoke = MoonSmoke(bitmap: source).render(fraction: exitAge / MoonAnimation.smokeDuration)
                    XCTAssertEqual(result.bitmap.bytes, smoke.bytes)
                    XCTAssertEqual(result.opacity, MoonAnimation.smokeOpacity(after: exitAge), accuracy: 0.000001)
                }
            }
        }
    }

    @MainActor func testInterruptedStopDoesNotJumpWhenReleasedDuringEntry() throws {
        let shader = sourceFrame()
        let source = try MoonRenderer.shared.get().render(shader, pixels: 112)
        let displayed = MoonSmoke(bitmap: source).render(fraction: 0.7)
        let motion = try MoonPark(source: displayed, shader: shader)
        for departureAt in [0.0, 0.05, 0.15] {
            let entry = try motion.render(age: departureAt, reason: .focusMoved)
            let release = try motion.render(age: departureAt, reason: .focusMoved, departureAge: 0)
            XCTAssertEqual(release.bitmap.bytes, entry.bitmap.bytes)
        }
    }

    private func sourceFrame(level: Float = 0.68) -> MoonFrame {
        var frame = MoonFrame()
        frame.time = 1.7
        frame.level = level
        return frame
    }

    private func occupancy(_ bitmap: MoonBitmap) -> Set<Int> {
        Set(stride(from: 3, to: bitmap.bytes.count, by: 4).filter { bitmap.bytes[$0] > 0 })
    }
}

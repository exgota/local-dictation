import XCTest
@testable import DictationCore

final class MoonAnimationTests: XCTestCase {
    func testTextCompletionCannotShortenSmokeOrRestartIt() {
        var animation = MoonAnimation()
        animation.listen(at: 0)
        animation.stop(at: 1)
        animation.dismiss(at: 1.1)
        animation.stop(at: 1.2)
        animation.advance(to: 1.449)
        XCTAssertEqual(animation.state, .smoke)
        XCTAssertEqual(animation.beganAt, 1)
        animation.advance(to: 1.45)
        XCTAssertEqual(animation.state, .hidden)
        animation.stop(at: 2)
        XCTAssertEqual(animation.state, .hidden)
    }

    func testNextRecordingInterruptsSmokeImmediately() {
        var animation = MoonAnimation()
        animation.listen(at: 0)
        animation.stop(at: 1)
        animation.listen(at: 1.2)
        animation.advance(to: 1.6)
        XCTAssertEqual(animation.state, .listening)
    }

    func testSilentStopFadesWithoutSmoke() {
        var animation = MoonAnimation()
        animation.listen(at: 0)
        animation.showSilence(at: 3)
        animation.stop(at: 4)
        XCTAssertEqual(animation.state, .fading)
        animation.advance(to: 4.121)
        XCTAssertEqual(animation.state, .hidden)
    }

    func testSecureFieldRefusalShakeKeepsItsDurationAndAmplitude() {
        XCTAssertEqual(MoonAnimation.refusalShake(after: 0.03), 0.07875, accuracy: 0.000001)
        XCTAssertEqual(MoonAnimation.refusalShake(after: 0.09), -0.05625, accuracy: 0.000001)
        XCTAssertEqual(MoonAnimation.refusalShake(after: 0.24), 0)
    }

    func testSetupTransitionAndSmokeFadeBoundaries() {
        XCTAssertEqual(MoonAnimation.setupTransition(after: 0), 0)
        XCTAssertEqual(MoonAnimation.setupTransition(after: 0.2375), 0.0625, accuracy: 0.000001)
        XCTAssertEqual(MoonAnimation.setupTransition(after: 0.475), 0.5, accuracy: 0.000001)
        XCTAssertEqual(MoonAnimation.setupTransition(after: 0.95), 1)
        XCTAssertEqual(MoonAnimation.smokeOpacity(after: 0.279), 1, accuracy: 0.000001)
        XCTAssertEqual(MoonAnimation.smokeOpacity(after: 0.45), 0, accuracy: 0.000001)
    }

    func testLevelAttackReleaseAndWarningUseElapsedTime() {
        var animation = MoonAnimation()
        animation.listen(at: 0)
        animation.advance(to: 0)
        animation.receive(decibels: -20)
        animation.advance(to: 0.025)
        XCTAssertEqual(animation.level, 1 - exp(-1), accuracy: 0.000001)
        animation.receive(decibels: -50)
        animation.advance(to: 0.065)
        XCTAssertEqual(animation.level, (1 - exp(-1)) * exp(-1), accuracy: 0.000001)
        animation.showSilence(at: 0.065)
        animation.advance(to: 0.105)
        XCTAssertEqual(animation.level, 0)
        XCTAssertEqual(animation.warning, 1 - exp(-0.04 / 0.075), accuracy: 0.000001)
    }

    func testReduceMotionFreezesOnlyTheShaderClock() {
        XCTAssertEqual(MoonAnimation.shaderTime(elapsed: 8, reduceMotion: true), 2)
        XCTAssertEqual(MoonAnimation.shaderTime(elapsed: 8, reduceMotion: false), 8)
        var animation = MoonAnimation()
        animation.listen(at: 0)
        animation.stop(at: 1)
        animation.advance(to: 1.45)
        XCTAssertEqual(animation.state, .hidden)
    }

    func testSetupCompletesTheMoonBeforeChangingToTheFunctionKey() {
        var animation = MoonSetupAnimation(shape: 0, ready: false)
        animation.update(shape: 0, progress: 0.5, ready: false, at: 1)
        XCTAssertEqual(animation.frame(at: 1).phase, 0.5)
        animation.update(shape: 2, progress: 1.5, ready: true, at: 2)
        XCTAssertEqual(animation.frame(at: 2).next, 0)
        XCTAssertEqual(animation.frame(at: 2.4).phase, 1.25, accuracy: 0.000001)
        XCTAssertEqual(animation.frame(at: 2.8).phase, 1.5, accuracy: 0.000001)
        XCTAssertEqual(animation.frame(at: 3.79).next, 0)
        XCTAssertEqual(animation.frame(at: 3.81).next, 2)
        XCTAssertEqual(animation.frame(at: 4.285).transition, 0.5, accuracy: 0.000001)
    }

    func testSetupStartsWithTheCorrectShapeAndResetsAfterPermissionRevocation() {
        var animation = MoonSetupAnimation(shape: 1, ready: false)
        XCTAssertEqual(animation.frame(at: 0).transition, 1)
        animation.update(shape: 2, progress: 0, ready: false, at: 1)
        XCTAssertEqual(animation.frame(at: 1).previous, 1)
        XCTAssertEqual(animation.frame(at: 1).next, 2)
        animation.update(shape: 0, progress: 0.99, ready: false, at: 2)
        animation.update(shape: 2, progress: 1.5, ready: true, at: 3)
        animation.update(shape: 1, progress: 1.5, ready: true, at: 4)
        XCTAssertEqual(animation.frame(at: 4).next, 1)
    }
}

import XCTest
@testable import DictationCore

final class MoonParkAnimationTests: XCTestCase {
    func testHoverPreservesRemainingHoldAndDoesNotDelayPaste() {
        var animation = MoonParkAnimation(reason: .focusMoved, at: 10)
        animation.setHovered(true, at: 11)
        animation.advance(to: 20)
        XCTAssertNil(animation.departure)
        animation.setHovered(false, at: 20)
        animation.advance(to: 21)
        XCTAssertNil(animation.departure)
        animation.leave(.pasted, at: 21)
        XCTAssertEqual(animation.departureAge(at: 21.2)!, 0.2, accuracy: 0.000001)
        XCTAssertFalse(animation.isFinished(at: 21.5, reduceMotion: false))
        XCTAssertTrue(animation.isFinished(at: 21.66, reduceMotion: false))
    }

    func testDelayedFrameDoesNotExtendDeadline() {
        var animation = MoonParkAnimation(reason: .clipboardChanged, at: 10)
        animation.advance(to: 13)
        XCTAssertEqual(animation.departedAt!, 12.72, accuracy: 0.000001)
        XCTAssertTrue(animation.isFinished(at: 14, reduceMotion: false))
    }

    func testEachNewMissStartsItsOwnLifetime() {
        var animation = MoonParkAnimation(reason: .focusMoved, at: 0)
        animation.leave(.pasted, at: 1)
        animation = MoonParkAnimation(reason: .microphoneDisconnected, at: 2)
        XCTAssertNil(animation.departure)
        XCTAssertEqual(animation.age(at: 2), 0)
    }

    func testReducedMotionKeepsReturnAndSentExitTiming() {
        var animation = MoonParkAnimation(reason: .focusMoved, at: 0)
        animation.leave(.timeout, at: 1)
        XCTAssertFalse(animation.isFinished(at: 1.1, reduceMotion: true))
        XCTAssertTrue(animation.isFinished(at: 1.66, reduceMotion: true))
    }

    func testEveryMissHasAnAnnouncementAndSecureTextIsNotOfferedForPaste() {
        for reason in DictationMiss.allCases { XCTAssertFalse(reason.announcement(pasteShortcut: nil).isEmpty) }
        XCTAssertFalse(DictationMiss.secureField.announcement(pasteShortcut: nil).contains("Press"))
        XCTAssertTrue(DictationMiss.clipboardChanged.announcement(pasteShortcut: nil).contains("menu"))
        XCTAssertTrue(DictationMiss.clipboardChanged.announcement(pasteShortcut: "Option Shift V").contains("Option Shift V"))
    }
}

final class ShortcutCaptureTests: XCTestCase {
    func testSuspensionPassesAllShortcutsToTheRecorderIncludingPauseAndEscape() {
        let state = EventTapSharedState()
        let pause = KeyChord(keyCode: 35, modifiers: [.command, .shift])
        state.publish(configuration: HotkeyConfiguration(trigger: .key(.init(keyCode: 2, modifiers: .command)),
                                                        mode: .toggle, repasteChord: .defaultRepaste, pauseChord: pause))
        state.publish(dictationActive: true, paused: false, suspended: true)
        for (key, flags) in [(UInt16(2), EventFlagBits.command), (UInt16(35), EventFlagBits.command | EventFlagBits.shift),
                             (VirtualKey.letterV, EventFlagBits.option | EventFlagBits.shift), (VirtualKey.escape, UInt64(0))] {
            XCTAssertFalse(state.shouldSwallow(.init(kind: .keyDown, keyCode: key, flags: flags, isRepeat: false, time: 0)))
            XCTAssertFalse(state.shouldSwallow(.init(kind: .keyUp, keyCode: key, flags: flags, isRepeat: false, time: 0)))
        }
        state.publish(dictationActive: false, paused: true)
        XCTAssertTrue(state.shouldSwallow(.init(kind: .keyDown, keyCode: 35, flags: EventFlagBits.command | EventFlagBits.shift,
                                               isRepeat: false, time: 1)))
    }
}

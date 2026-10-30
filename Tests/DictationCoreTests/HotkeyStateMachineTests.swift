import XCTest

@testable import DictationCore

/// Drives the state machine with synthetic flagsChanged and key events, as the event tap would deliver them.
final class HotkeyStateMachineTests: XCTestCase {
    private let functionDown = EventFlagBits.secondaryFunction
    private let rightOptionDown = EventFlagBits.option | 0x40
    private let leftOptionDown = EventFlagBits.option | 0x20
    private let leftCommandDown = EventFlagBits.command | 0x08

    private func machine(_ mode: TriggerMode, trigger: TriggerKey = .function) -> HotkeyStateMachine {
        HotkeyStateMachine(
            configuration: HotkeyConfiguration(
                trigger: trigger, mode: mode, repasteChord: .defaultRepaste,
                pauseChord: KeyChord(keyCode: 35, modifiers: [.option, .shift])))
    }

    private func fn(_ down: Bool, at time: TimeInterval, extra: UInt64 = 0) -> HotkeyInput {
        .flagsChanged(keyCode: VirtualKey.function, flags: (down ? functionDown : 0) | extra, time: time)
    }

    private func key(_ keyCode: UInt16, at time: TimeInterval, flags: UInt64 = 0, isRepeat: Bool = false) -> HotkeyInput {
        .keyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat, time: time)
    }

    // MARK: Toggle

    func testToggleFiresOnCleanRelease() {
        var machine = machine(.toggle)
        XCTAssertEqual(machine.handle(fn(true, at: 0)), [])
        XCTAssertEqual(machine.handle(fn(false, at: 0.1)), [.toggle])
        XCTAssertEqual(machine.handle(fn(true, at: 2)), [])
        XCTAssertEqual(machine.handle(fn(false, at: 2.1)), [.toggle])
    }

    func testToggleIgnoresFunctionKeyChord() {
        var machine = machine(.toggle)
        _ = machine.handle(fn(true, at: 0))
        XCTAssertEqual(machine.handle(key(123, at: 0.1, flags: functionDown)), [])
        XCTAssertEqual(machine.handle(fn(false, at: 0.2)), [])
    }

    func testToggleIgnoresPressWithModifierAlreadyHeld() {
        var machine = machine(.toggle)
        _ = machine.handle(.flagsChanged(keyCode: VirtualKey.command, flags: leftCommandDown, time: 0))
        _ = machine.handle(fn(true, at: 0.1, extra: leftCommandDown))
        XCTAssertEqual(machine.handle(fn(false, at: 0.2, extra: leftCommandDown)), [])
    }

    func testToggleIgnoresModifierAddedDuringPress() {
        var machine = machine(.toggle)
        _ = machine.handle(fn(true, at: 0))
        _ = machine.handle(.flagsChanged(keyCode: VirtualKey.shift, flags: functionDown | EventFlagBits.shift | 0x02, time: 0.1))
        XCTAssertEqual(machine.handle(fn(false, at: 0.2, extra: EventFlagBits.shift | 0x02)), [])
    }

    // MARK: Hold

    func testHoldBeginsOnPressAndEndsOnRelease() {
        var machine = machine(.hold)
        XCTAssertEqual(machine.handle(fn(true, at: 0)), [.holdBegan])
        XCTAssertEqual(machine.handle(fn(false, at: 3)), [.holdEnded])
    }

    func testHoldInterruptedByKey() {
        var machine = machine(.hold)
        _ = machine.handle(fn(true, at: 0))
        XCTAssertEqual(machine.handle(key(0, at: 0.5, flags: functionDown)), [.holdInterrupted])
        XCTAssertEqual(machine.handle(fn(false, at: 1)), [])
    }

    func testHoldShortTapStillReportsEndForControllerToDiscard() {
        var machine = machine(.hold)
        XCTAssertEqual(machine.handle(fn(true, at: 0)), [.holdBegan])
        XCTAssertEqual(machine.handle(fn(false, at: 0.05)), [.holdEnded])
    }

    func testHoldNotStartedWhileOtherModifierHeld() {
        var machine = machine(.hold)
        _ = machine.handle(.flagsChanged(keyCode: VirtualKey.option, flags: leftOptionDown, time: 0))
        XCTAssertEqual(machine.handle(fn(true, at: 0.1, extra: leftOptionDown)), [])
        XCTAssertEqual(machine.handle(fn(false, at: 1, extra: leftOptionDown)), [])
    }

    func testRightOptionDoesNotReactToLeftOption() {
        var machine = machine(.hold, trigger: .rightOption)
        XCTAssertEqual(machine.handle(.flagsChanged(keyCode: VirtualKey.option, flags: leftOptionDown, time: 0)), [])
        XCTAssertEqual(machine.handle(.flagsChanged(keyCode: VirtualKey.option, flags: 0, time: 0.2)), [])
        XCTAssertEqual(machine.handle(.flagsChanged(keyCode: VirtualKey.rightOption, flags: rightOptionDown, time: 1)), [.holdBegan])
        XCTAssertEqual(machine.handle(.flagsChanged(keyCode: VirtualKey.rightOption, flags: 0, time: 2)), [.holdEnded])
    }

    // MARK: Double-tap lock

    func testDoubleTapLocksAndNextTapEnds() {
        var machine = machine(.doubleTapLock)
        XCTAssertEqual(machine.handle(fn(true, at: 0)), [.holdBegan])
        XCTAssertEqual(machine.handle(fn(false, at: 0.1)), [.scheduleDeadline(0.1 + HotkeyStateMachine.doubleTapInterval)])
        XCTAssertEqual(machine.handle(fn(true, at: 0.3)), [.lockBegan])
        XCTAssertEqual(machine.handle(fn(false, at: 0.4)), [])
        XCTAssertEqual(machine.handle(.deadlineElapsed(time: 0.5)), [])
        XCTAssertEqual(machine.handle(fn(true, at: 20)), [])
        XCTAssertEqual(machine.handle(fn(false, at: 20.1)), [.lockEnded])
    }

    func testSingleTapEndsAtDeadline() {
        var machine = machine(.doubleTapLock)
        _ = machine.handle(fn(true, at: 0))
        _ = machine.handle(fn(false, at: 0.1))
        XCTAssertEqual(machine.handle(.deadlineElapsed(time: 0.2)), [])
        XCTAssertEqual(machine.handle(.deadlineElapsed(time: 0.45)), [.holdEnded])
    }

    func testSecondTapAfterDeadlineIsANewHold() {
        var machine = machine(.doubleTapLock)
        _ = machine.handle(fn(true, at: 0))
        _ = machine.handle(fn(false, at: 0.1))
        XCTAssertEqual(machine.handle(.deadlineElapsed(time: 0.5)), [.holdEnded])
        XCTAssertEqual(machine.handle(fn(true, at: 0.6)), [.holdBegan])
    }

    func testLongPressInDoubleTapModeIsAHold() {
        var machine = machine(.doubleTapLock)
        _ = machine.handle(fn(true, at: 0))
        XCTAssertEqual(machine.handle(fn(false, at: 2)), [.holdEnded])
    }

    func testTypingBetweenTapsCancelsDoubleTap() {
        var machine = machine(.doubleTapLock)
        _ = machine.handle(fn(true, at: 0))
        _ = machine.handle(fn(false, at: 0.1))
        XCTAssertEqual(machine.handle(key(0, at: 0.2)), [.holdEnded])
        XCTAssertEqual(machine.handle(.deadlineElapsed(time: 0.5)), [])
    }

    func testChordWhileLockedDoesNotEndLock() {
        var machine = machine(.doubleTapLock)
        _ = machine.handle(fn(true, at: 0))
        _ = machine.handle(fn(false, at: 0.1))
        _ = machine.handle(fn(true, at: 0.2))
        _ = machine.handle(fn(false, at: 0.3))
        _ = machine.handle(fn(true, at: 5))
        _ = machine.handle(key(123, at: 5.1, flags: functionDown))
        XCTAssertEqual(machine.handle(fn(false, at: 5.2)), [])
        XCTAssertEqual(machine.handle(fn(true, at: 8)), [])
        XCTAssertEqual(machine.handle(fn(false, at: 8.1)), [.lockEnded])
    }

    // MARK: Key triggers, Escape, chords, pause

    func testFunctionKeyTriggerHold() {
        let f13 = KeyChord(keyCode: 105, modifiers: [])
        var machine = machine(.hold, trigger: .key(f13))
        XCTAssertEqual(machine.handle(key(105, at: 0, flags: functionDown)), [.holdBegan])
        XCTAssertEqual(machine.handle(key(105, at: 0.5, flags: functionDown, isRepeat: true)), [])
        XCTAssertEqual(machine.handle(.keyUp(keyCode: 105, flags: 0, time: 2)), [.holdEnded])
    }

    func testKeyTriggerRequiresExactModifiers() {
        let chord = KeyChord(keyCode: 105, modifiers: [.command])
        var machine = machine(.toggle, trigger: .key(chord))
        _ = machine.handle(key(105, at: 0))
        XCTAssertEqual(machine.handle(.keyUp(keyCode: 105, flags: 0, time: 0.1)), [])
        _ = machine.handle(key(105, at: 1, flags: EventFlagBits.command))
        XCTAssertEqual(machine.handle(.keyUp(keyCode: 105, flags: EventFlagBits.command, time: 1.1)), [.toggle])
    }

    func testEscapeReported() {
        var machine = machine(.toggle)
        XCTAssertEqual(machine.handle(key(VirtualKey.escape, at: 0)), [.escapePressed])
        XCTAssertEqual(machine.handle(key(VirtualKey.escape, at: 0.1, isRepeat: true)), [])
    }

    func testEscapeDuringHoldInterruptsThenReportsEscape() {
        var machine = machine(.hold)
        _ = machine.handle(fn(true, at: 0))
        XCTAssertEqual(machine.handle(key(VirtualKey.escape, at: 1, flags: functionDown)), [.holdInterrupted, .escapePressed])
    }

    func testRepasteChord() {
        var machine = machine(.toggle)
        XCTAssertEqual(machine.handle(key(VirtualKey.letterV, at: 0, flags: EventFlagBits.option | EventFlagBits.shift)), [.repasteRequested])
        XCTAssertEqual(machine.handle(key(VirtualKey.letterV, at: 1, flags: EventFlagBits.option)), [])
    }

    func testPauseSuppressesTriggerButNotPauseChordOrEscape() {
        var machine = machine(.toggle)
        XCTAssertEqual(machine.handle(key(35, at: 0, flags: EventFlagBits.option | EventFlagBits.shift)), [.pauseToggled])
        machine.isPaused = true
        _ = machine.handle(fn(true, at: 1))
        XCTAssertEqual(machine.handle(fn(false, at: 1.1)), [])
        XCTAssertEqual(machine.handle(key(VirtualKey.letterV, at: 2, flags: EventFlagBits.option | EventFlagBits.shift)), [])
        XCTAssertEqual(machine.handle(key(VirtualKey.escape, at: 3)), [.escapePressed])
        XCTAssertEqual(machine.handle(key(35, at: 4, flags: EventFlagBits.option | EventFlagBits.shift)), [.pauseToggled])
    }

    func testResetSessionForgetsHold() {
        var machine = machine(.hold)
        _ = machine.handle(fn(true, at: 0))
        machine.resetSession()
        XCTAssertEqual(machine.handle(fn(false, at: 1)), [])
    }

    func testInterruptedPressDoesNotCarryCleanlinessOrTimingIntoNextPress() {
        var machine = machine(.doubleTapLock)
        XCTAssertEqual(machine.handle(fn(true, at: 0)), [.holdBegan])
        XCTAssertEqual(machine.handle(key(123, at: 1, flags: functionDown)), [.holdInterrupted])
        XCTAssertEqual(machine.handle(fn(false, at: 2)), [])
        XCTAssertEqual(machine.handle(fn(true, at: 3)), [.holdBegan])
        let releaseTime = 3.1
        XCTAssertEqual(machine.handle(fn(false, at: releaseTime)), [.scheduleDeadline(releaseTime + HotkeyStateMachine.doubleTapInterval)])
    }

    func testDuplicateKeyReleaseDoesNotReuseCompletedPress() {
        var machine = machine(.doubleTapLock, trigger: .key(KeyChord(keyCode: 105, modifiers: [])))
        XCTAssertEqual(machine.handle(key(105, at: 0)), [.holdBegan])
        let releaseTime = 0.1
        let deadline = releaseTime + HotkeyStateMachine.doubleTapInterval
        XCTAssertEqual(machine.handle(.keyUp(keyCode: 105, flags: 0, time: releaseTime)), [.scheduleDeadline(deadline)])
        XCTAssertEqual(machine.handle(.keyUp(keyCode: 105, flags: 0, time: 0.2)), [])
        XCTAssertEqual(machine.handle(.deadlineElapsed(time: deadline)), [.holdEnded])
    }

    func testChangingTriggerDiscardsPreviousPress() {
        var machine = machine(.doubleTapLock, trigger: .key(KeyChord(keyCode: 105, modifiers: [])))
        XCTAssertEqual(machine.handle(key(105, at: 0)), [.holdBegan])
        machine.configuration.trigger = .function
        XCTAssertEqual(machine.handle(.keyUp(keyCode: 105, flags: 0, time: 0.1)), [])
        XCTAssertEqual(machine.handle(fn(true, at: 0.2)), [.holdBegan])
        let releaseTime = 0.3
        XCTAssertEqual(machine.handle(fn(false, at: releaseTime)), [.scheduleDeadline(releaseTime + HotkeyStateMachine.doubleTapInterval)])
    }

    func testResetSessionPreservesHeldTriggerUntilRelease() {
        var machine = machine(.hold)
        XCTAssertEqual(machine.handle(fn(true, at: 0)), [.holdBegan])
        machine.resetSession()
        XCTAssertEqual(machine.handle(fn(true, at: 1)), [])
        XCTAssertEqual(machine.handle(fn(false, at: 2)), [])
        XCTAssertEqual(machine.handle(fn(true, at: 3)), [.holdBegan])
        XCTAssertEqual(machine.handle(fn(false, at: 4)), [.holdEnded])
    }
}

final class EventTapSharedStateTests: XCTestCase {
    private func event(_ kind: TappedKeyEvent.Kind, _ keyCode: UInt16, flags: UInt64 = 0, isRepeat: Bool = false) -> TappedKeyEvent {
        TappedKeyEvent(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat, time: 0)
    }

    private func state(trigger: TriggerKey = .function) -> EventTapSharedState {
        let state = EventTapSharedState()
        state.publish(configuration: HotkeyConfiguration(trigger: trigger, mode: .toggle, repasteChord: .defaultRepaste, pauseChord: nil))
        return state
    }

    func testEscapeSwallowedOnlyWhileActive() {
        let state = state()
        XCTAssertFalse(state.shouldSwallow(event(.keyDown, VirtualKey.escape)))
        XCTAssertFalse(state.shouldSwallow(event(.keyUp, VirtualKey.escape)))
        state.publish(dictationActive: true, paused: false)
        XCTAssertTrue(state.shouldSwallow(event(.keyDown, VirtualKey.escape)))
        state.publish(dictationActive: false, paused: false)
        // The key-up of a swallowed key-down is swallowed even after the dictation ended.
        XCTAssertTrue(state.shouldSwallow(event(.keyUp, VirtualKey.escape)))
        XCTAssertFalse(state.shouldSwallow(event(.keyUp, VirtualKey.escape)))
    }

    func testKeyTriggerSwallowedWithRepeatsAndKeyUp() {
        let state = state(trigger: .key(KeyChord(keyCode: 105, modifiers: [])))
        XCTAssertTrue(state.shouldSwallow(event(.keyDown, 105)))
        XCTAssertTrue(state.shouldSwallow(event(.keyDown, 105, isRepeat: true)))
        XCTAssertTrue(state.shouldSwallow(event(.keyUp, 105)))
        XCTAssertFalse(state.shouldSwallow(event(.keyDown, 106)))
    }

    func testModifiersNeverSwallowed() {
        let state = state()
        state.publish(dictationActive: true, paused: false)
        XCTAssertFalse(state.shouldSwallow(event(.flagsChanged, VirtualKey.function, flags: EventFlagBits.secondaryFunction)))
    }

    func testRepasteSwallowedUnlessPaused() {
        let state = state()
        let flags = EventFlagBits.option | EventFlagBits.shift
        XCTAssertTrue(state.shouldSwallow(event(.keyDown, VirtualKey.letterV, flags: flags)))
        XCTAssertTrue(state.shouldSwallow(event(.keyUp, VirtualKey.letterV, flags: flags)))
        state.publish(dictationActive: false, paused: true)
        XCTAssertFalse(state.shouldSwallow(event(.keyDown, VirtualKey.letterV, flags: flags)))
        XCTAssertFalse(state.shouldSwallow(event(.keyDown, VirtualKey.letterV)))
    }

    func testQueueIsFirstInFirstOutAndDropsWhenFull() {
        let queue = TappedKeyEventQueue(capacity: 4)
        for keyCode in 0..<3 { XCTAssertTrue(queue.push(event(.keyDown, UInt16(keyCode)))) }
        XCTAssertFalse(queue.push(event(.keyDown, 9)))
        XCTAssertEqual(queue.dropped, 1)
        XCTAssertEqual(queue.pop()?.keyCode, 0)
        XCTAssertEqual(queue.pop()?.keyCode, 1)
        XCTAssertTrue(queue.push(event(.keyDown, 7)))
        XCTAssertEqual(queue.pop()?.keyCode, 2)
        XCTAssertEqual(queue.pop()?.keyCode, 7)
        XCTAssertNil(queue.pop())
    }
}

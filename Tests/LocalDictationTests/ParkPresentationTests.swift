import AppKit
import DictationCore
import MoonRendering
import XCTest
@testable import LocalDictation

@MainActor final class ParkPresentationTests: XCTestCase {
    func testVisibleMissFreezesCurrentFrameInsteadOfRestoringStoppedMoon() throws {
        let stopped = try makeSource()
        let displayed = MoonSmoke(bitmap: stopped).render(fraction: 0.8)
        XCTAssertNotEqual(displayed.bytes, stopped.bytes)
        let motion = try HeadsUpDisplayController.parkMotion(displayed: displayed, opacity: 0.42, visible: true, stopped: stopped, shader: sourceFrame())
        let initial = try motion.render(age: 0, reason: .focusMoved)
        XCTAssertEqual(initial.bitmap.bytes, displayed.bytes)
        XCTAssertEqual(initial.opacity, 0.42)
        let noCopy = try motion.render(age: 0.25, reason: .clipboardChanged)
        XCTAssertEqual(noCopy.bitmap.bytes, displayed.bytes)
    }

    func testHiddenMissNeverFlashesTheStoppedMoonBeforeCopy() throws {
        let stopped = try makeSource()
        let motion = try HeadsUpDisplayController.parkMotion(displayed: stopped, opacity: 1, visible: false, stopped: stopped, shader: sourceFrame())
        XCTAssertEqual(try motion.render(age: 0, reason: .focusMoved).opacity, 0)
        let middle = try motion.render(age: 0.125, reason: .focusMoved)
        XCTAssertEqual(middle.opacity, 0.5, accuracy: 0.000001)
        XCTAssertNotEqual(middle.bitmap.bytes, try motion.render(age: 0.25, reason: .focusMoved).bitmap.bytes)
    }

    func testMatchingCommandPasteReleasesButNewerClipboardDoesNot() throws {
        let display = HeadsUpDisplayController(observesPasteEvents: false)
        display.beginPark(motion: try MoonPark(source: try makeSource(), shader: sourceFrame()), reason: .focusMoved, clipboardChangeCount: 42)
        _ = display.parkFrame(at: 0, hovered: false, reduceMotion: false)
        display.observePaste(clipboardChangeCount: 43, at: 1)
        XCTAssertEqual(try XCTUnwrap(display.parkFrame(at: 1.2, hovered: false, reduceMotion: false)).opacity, 1)
        display.observePaste(clipboardChangeCount: 42, at: 1.5)
        XCTAssertEqual(try XCTUnwrap(display.parkFrame(at: 1.56, hovered: false, reduceMotion: false)).opacity, 1, accuracy: 0.000001)
        XCTAssertLessThan(try XCTUnwrap(display.parkFrame(at: 2.14, hovered: false, reduceMotion: false)).opacity, 0.1)
        XCTAssertNil(display.parkFrame(at: 2.16, hovered: false, reduceMotion: false))
        XCTAssertFalse(display.isParked)
    }

    func testPasteLastTextCanReleaseWithNewerClipboardAndWhileHovered() throws {
        let display = HeadsUpDisplayController(observesPasteEvents: false)
        display.beginPark(motion: try MoonPark(source: try makeSource(), shader: sourceFrame()), reason: .clipboardChanged, clipboardChangeCount: nil)
        _ = display.parkFrame(at: 0, hovered: false, reduceMotion: false)
        _ = display.parkFrame(at: 0.5, hovered: true, reduceMotion: false)
        XCTAssertEqual(try XCTUnwrap(display.parkFrame(at: 20, hovered: true, reduceMotion: false)).opacity, 1)
        display.observePaste(clipboardChangeCount: 43, at: 20)
        XCTAssertEqual(try XCTUnwrap(display.parkFrame(at: 20.2, hovered: true, reduceMotion: false)).opacity, 1)
        display.releasePark(at: 20.3)
        XCTAssertLessThan(try XCTUnwrap(display.parkFrame(at: 20.74, hovered: true, reduceMotion: false)).opacity, 0.1)
    }

    func testTimeoutKeepsExistingDeadlineAndSecureRefusalDoesNotShowCopy() throws {
        let display = HeadsUpDisplayController(observesPasteEvents: false)
        let source = try makeSource()
        display.beginPark(motion: try MoonPark(source: source, shader: sourceFrame()), reason: .focusMoved, clipboardChangeCount: 42)
        _ = display.parkFrame(at: 0, hovered: false, reduceMotion: false)
        XCTAssertEqual(try XCTUnwrap(display.parkFrame(at: 2.22, hovered: false, reduceMotion: false)).opacity, 1)
        XCTAssertLessThan(try XCTUnwrap(display.parkFrame(at: 2.86, hovered: false, reduceMotion: false)).opacity, 0.1)
        display.beginPark(motion: try MoonPark(source: source, shader: sourceFrame()), reason: .secureField, clipboardChangeCount: nil)
        _ = display.parkFrame(at: 3, hovered: false, reduceMotion: false)
        display.releasePark(at: 3.05)
        let secure = try XCTUnwrap(display.parkFrame(at: 3.125, hovered: false, reduceMotion: false))
        XCTAssertEqual(secure.bitmap.bytes, source.bytes)
        XCTAssertEqual(secure.opacity, 0.5, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(display.parkFrame(at: 3.25, hovered: false, reduceMotion: false)).opacity, 0)
    }

    func testDelayedFirstVisibleDrawStartsAtZeroAfterHiddenPreparation() throws {
        let display = HeadsUpDisplayController(observesPasteEvents: false)
        let source = try makeSource()
        display.beginPark(motion: try MoonPark(source: source, shader: sourceFrame()), reason: .focusMoved, clipboardChangeCount: 42)
        for time in [4.0, 7.0] {
            let prepared = try XCTUnwrap(display.parkFrame(at: time, hovered: false, reduceMotion: false, startsPresentation: false))
            XCTAssertEqual(prepared.shader.park, 0)
            XCTAssertEqual(prepared.bitmap.bytes, source.bytes)
        }
        display.observePaste(clipboardChangeCount: 42, at: 8)
        let first = try XCTUnwrap(display.parkFrame(at: 10, hovered: false, reduceMotion: false))
        XCTAssertEqual(first.shader.park, 0)
        XCTAssertEqual(first.bitmap.bytes, source.bytes)
        let middle = try XCTUnwrap(display.parkFrame(at: 10.125, hovered: false, reduceMotion: false))
        XCTAssertEqual(middle.shader.park, 0.5, accuracy: 0.000001)
        let final = try XCTUnwrap(display.parkFrame(at: 10.25, hovered: false, reduceMotion: false))
        XCTAssertEqual(final.shader.park, 1)
        XCTAssertNotNil(display.parkFrame(at: 12.21, hovered: false, reduceMotion: false))
    }

    func testAppDeliveredCommandPasteReleasesRegardlessOfEventSourceOrMarker() throws {
        for state in [CGEventSourceStateID.hidSystemState, .combinedSessionState, .privateState] {
            for marker: Int64 in [0, HotkeyEventTap.syntheticEventMarker, 12345] {
                let display = HeadsUpDisplayController(observesPasteEvents: false)
                display.beginPark(motion: try MoonPark(source: try makeSource(), shader: sourceFrame()),
                                  reason: .focusMoved, clipboardChangeCount: 42)
                _ = display.parkFrame(at: 10, hovered: false, reduceMotion: false)
                let source = try XCTUnwrap(CGEventSource(stateID: state))
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: VirtualKey.letterV, keyDown: true))
                event.flags = .maskCommand
                event.timestamp = 0
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                event.setIntegerValueField(.keyboardEventAutorepeat, value: marker == 12345 ? 1 : 0)
                display.observePaste(try XCTUnwrap(NSEvent(cgEvent: event)), clipboardChangeCount: 42, at: 11)
                let returning = try XCTUnwrap(display.parkFrame(at: 11.1, hovered: false, reduceMotion: false))
                XCTAssertEqual(returning.shader.park, 0.5, accuracy: 0.000001)
                XCTAssertNil(display.parkFrame(at: 11.66, hovered: false, reduceMotion: false))
            }
        }
    }

    func testPasteObserverRejectsOtherShortcutsAndKeyUp() throws {
        let display = HeadsUpDisplayController(observesPasteEvents: false)
        display.beginPark(motion: try MoonPark(source: try makeSource(), shader: sourceFrame()),
                          reason: .focusMoved, clipboardChangeCount: 42)
        _ = display.parkFrame(at: 10, hovered: false, reduceMotion: false)
        for (time, code, flags, down, repeated) in [
            (11.0, VirtualKey.letterV, CGEventFlags([.maskCommand, .maskShift]), true, false),
            (11.0, UInt16(0), .maskCommand, true, false),
            (11.0, VirtualKey.letterV, .maskCommand, false, false),
        ] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
            event.flags = flags
            event.timestamp = UInt64(time * 1_000_000_000)
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
            display.observePaste(try XCTUnwrap(NSEvent(cgEvent: event)), clipboardChangeCount: 42, at: 11)
        }
        let held = try XCTUnwrap(display.parkFrame(at: 11.8, hovered: false, reduceMotion: false))
        XCTAssertEqual(held.shader.park, 1)
        XCTAssertEqual(held.opacity, 1)
    }

    func testNativeLocalPasteMonitorObservesWithoutConsumingAndStopsCleanly() throws {
        _ = NSApplication.shared
        var observed = 0
        var forwarded = 0
        let monitor = ParkPasteMonitor { event in
            if ParkPasteMonitor.isCommandPaste(event) { observed += 1 }
        }
        monitor.start()
        monitor.start()
        defer { monitor.stop() }
        let followingMonitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            forwarded += 1
            return event
        })
        defer { NSEvent.removeMonitor(followingMonitor) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: VirtualKey.letterV))
        // Dispatch inside the test process only. No system event is posted and no other app receives it.
        NSApp.sendEvent(event)
        XCTAssertEqual(observed, 1)
        XCTAssertEqual(forwarded, 1)
        monitor.stop()
        NSApp.sendEvent(event)
        XCTAssertEqual(observed, 1)
        XCTAssertEqual(forwarded, 2)
    }

    func testMenuAndConfiguredShortcutRecoveryReleaseOnlyAfterInsertion() async throws {
        let target = InsertionTarget(processIdentifier: getpid(), applicationName: "Test target",
                                     bundleIdentifier: nil, focusedElement: nil)
        // Both menu recovery and the configurable hotkey reach LastTranscriptPaste.perform.
        for (shortcut, flags) in [(KeyChord?.none, UInt64(0)),
            (.defaultRepaste, EventFlagBits.option | EventFlagBits.shift),
            (KeyChord(keyCode: 35, modifiers: [.control, .option]), EventFlagBits.control | EventFlagBits.option)] {
            if let shortcut {
                var hotkeys = HotkeyStateMachine(configuration: HotkeyConfiguration(trigger: .function, mode: .toggle,
                    repasteChord: shortcut, pauseChord: nil))
                XCTAssertEqual(hotkeys.handle(.keyDown(keyCode: shortcut.keyCode, flags: flags,
                    isRepeat: false, time: 1)), [.repasteRequested])
            }
            for outcome in [InjectionOutcome.inserted(.accessibilityInsertion), .inserted(.paste), .noEditableFocus, .targetChanged] {
                let display = HeadsUpDisplayController(observesPasteEvents: false)
                display.beginPark(motion: try MoonPark(source: try makeSource(), shader: sourceFrame()),
                                  reason: .clipboardChanged, clipboardChangeCount: nil)
                _ = display.parkFrame(at: 0, hovered: false, reduceMotion: false)
                _ = await LastTranscriptPaste.perform(text: "test dictation", target: target, insert: { _, _ in outcome },
                    copy: { _ in false }, onInserted: { display.releasePark(at: 1) }, log: { _ in })
                if case .inserted = outcome {
                    XCTAssertNil(display.parkFrame(at: 1.46, hovered: false, reduceMotion: false))
                } else {
                    XCTAssertNotNil(display.parkFrame(at: 1.46, hovered: false, reduceMotion: false))
                }
            }
        }
    }

    private func sourceFrame() -> MoonFrame {
        var frame = MoonFrame()
        frame.time = 1.7
        frame.level = 0.68
        return frame
    }

    private func makeSource() throws -> MoonBitmap {
        try MoonRenderer.shared.get().render(sourceFrame(), pixels: 112)
    }
}

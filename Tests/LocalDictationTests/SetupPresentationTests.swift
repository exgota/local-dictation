import AppKit
import DictationCore
import MoonRendering
import SwiftUI
import XCTest
@testable import LocalDictation

final class SetupPresentationTests: XCTestCase {
    @MainActor func testSetupPreparesItsRealTileBeforeTheWindowIsVisible() throws {
        let hosting = NSHostingController(rootView: SetupMoonView(shape: 1, progress: 0, ready: false)
            .frame(width: 240, height: 240))
        let window = NSWindow(contentViewController: hosting)
        window.layoutIfNeeded()
        hosting.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(OnboardingWindowController.prepareMoon(in: hosting.view))
        func canvas(in view: NSView) -> MoonCanvasView? {
            if let canvas = view as? MoonCanvasView { return canvas }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        let tile = try XCTUnwrap(canvas(in: hosting.view))
        let bitmap = try XCTUnwrap(tile.currentBitmap)
        XCTAssertGreaterThan(bitmap.bytes.filter { $0 == 255 }.count, 100)
        XCTAssertNotNil(tile.layer?.contents)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(tile.timerIsRunning)
    }

    @MainActor func testTryItAcceptsNativeInsertionThroughItsRealTextField() throws {
        var value = ""
        let hosting = NSHostingController(rootView: SetupContentView(
            presentation: .init(microphoneGranted: true, accessibilityGranted: true, model: .ready),
            text: Binding(get: { value }, set: { value = $0 })))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let descendants = descendants(of: hosting.view)
        let field = try XCTUnwrap(descendants.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == SetupTextInsertionTarget.fieldIdentifier
        })
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(window.makeFirstResponder(field))
        let target = try XCTUnwrap(SetupTextInsertionTarget(field: field, windowIsActive: { _ in true }))
        XCTAssertEqual(target.insert("Hello from Local Dictation."), .inserted(.accessibilityInsertion))
        XCTAssertEqual(value, "Hello from Local Dictation.")
        XCTAssertEqual(field.stringValue, value)
        XCTAssertEqual(target.insert("A second sentence."), .inserted(.accessibilityInsertion))
        XCTAssertEqual(value, "Hello from Local Dictation. A second sentence.")
        XCTAssertEqual(hosting.view.frame.width, 420)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testNativeSetupInsertionRefusesAChangedFieldOrInactiveWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = NSTextField(string: "Original")
        original.frame = NSRect(x: 10, y: 10, width: 280, height: 22)
        let other = NSTextField(string: "Other")
        other.frame = NSRect(x: 10, y: 40, width: 280, height: 22)
        window.contentView?.addSubview(original)
        window.contentView?.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(original))
        var active = true
        let target = try XCTUnwrap(SetupTextInsertionTarget(field: original, windowIsActive: { _ in active }))
        active = false
        XCTAssertEqual(target.insert("Must not arrive"), .targetChanged)
        active = true
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertEqual(target.insert("Must not arrive"), .targetChanged)
        XCTAssertEqual(original.stringValue, "Original")
        XCTAssertEqual(other.stringValue, "Other")
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testNativeSetupInsertionReplacesSelectionAndPreservesClipboard() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(string: "Replace this")
        field.frame = NSRect(x: 10, y: 10, width: 280, height: 22)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: field.stringValue.utf16.count))
        let target = try XCTUnwrap(SetupTextInsertionTarget(field: field, windowIsActive: { _ in true }))
        let changeCount = NSPasteboard.general.changeCount
        XCTAssertEqual(target.insert("Actual transcript"), .inserted(.accessibilityInsertion))
        XCTAssertEqual(field.stringValue, "Actual transcript")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 17, length: 0))
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
    }

    @MainActor func testAutomaticDownloadWaitsForPermissionsAndNeverRetriesFailureItself() {
        var presentation = SetupPresentation()
        XCTAssertFalse(presentation.shouldStartDownload)
        presentation.microphoneGranted = true
        XCTAssertFalse(presentation.shouldStartDownload)
        presentation.accessibilityGranted = true
        XCTAssertTrue(presentation.shouldStartDownload)
        for state: ModelController.State in [.installing(.downloading, fraction: 0.5), .loading, .ready, .failed("Offline")] {
            presentation.model = state
            XCTAssertFalse(presentation.shouldStartDownload)
        }
        presentation.accessibilityGranted = false
        XCTAssertEqual(presentation.step, .accessibility)
    }

    @MainActor private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

final class GuidedSetupCopyTests: XCTestCase {
    @MainActor func testHeadlinesStayFixedWhilePermissionAndDownloadStatusChanges() {
        var presentation = SetupPresentation()
        XCTAssertEqual(presentation.headline, "First, let it hear you.")
        presentation.microphoneDenied = true
        XCTAssertEqual(presentation.headline, "First, let it hear you.")
        XCTAssertEqual(presentation.detail, "Turn on Local Dictation in System Settings.")
        presentation.microphoneGranted = true
        XCTAssertEqual(presentation.headline, "Next, let it type for you.")
        presentation.waitingForAccessibility = true
        XCTAssertEqual(presentation.detail, "Switch on Local Dictation, then come back.")
        presentation.accessibilityGranted = true
        for state: ModelController.State in [.installing(.downloading, fraction: 0.25), .installing(.compiling, fraction: 1), .loading, .failed("Offline")] {
            presentation.model = state
            XCTAssertEqual(presentation.headline, "Last, the speech model.")
        }
        XCTAssertEqual(presentation.detail, "The download stopped.")
        presentation.model = .installing(.downloading, fraction: 0.5)
        XCTAssertEqual(presentation.detail, "Downloading 1.2 GB, 40%")
        presentation.model = .loading
        presentation.preparationElapsed = 0
        XCTAssertEqual(presentation.detail, "Preparing for this Mac, 80%")
    }

    @MainActor func testOneBarReachesOneHundredOnlyWhenTheModelIsUsable() {
        var presentation = SetupPresentation(microphoneGranted: true, accessibilityGranted: true)
        presentation.model = .installing(.downloading, fraction: 1)
        XCTAssertEqual(presentation.overallProgress, SetupPresentation.downloadShare, accuracy: 0.0001)
        XCTAssertEqual(presentation.detail, "Downloading 1.2 GB, 80%")
        presentation.model = .installing(.compiling, fraction: 1)
        // Measured on an M-series Mac mini: about 50 seconds from the last byte to a usable model. A Mac without a
        // Neural Engine took up to 80 seconds. Neither, nor a much slower Mac, may show 100% before the model is usable.
        var previous = 0.0
        for elapsed in stride(from: 0.0, through: 600, by: 5) {
            presentation.preparationElapsed = elapsed
            XCTAssertGreaterThanOrEqual(presentation.overallProgress, previous)
            XCTAssertLessThan(presentation.overallProgress, 0.99)
            XCTAssertLessThan(presentation.progress, 1)
            XCTAssertNotEqual(presentation.detail, "Ready, 100%")
            previous = presentation.overallProgress
        }
        presentation.preparationElapsed = 50
        XCTAssertEqual(presentation.detail, "Preparing for this Mac, 96%")
        presentation.preparationElapsed = 80
        XCTAssertEqual(presentation.detail, "Preparing for this Mac, 98%")
        presentation.model = .ready
        presentation.showsCompletion = true
        XCTAssertEqual(presentation.step, .download)
        XCTAssertEqual(presentation.detail, "Ready, 100%")
        XCTAssertTrue(presentation.moonReady)
        presentation.showsCompletion = false
        XCTAssertEqual(presentation.step, .tryIt)
        XCTAssertTrue(presentation.moonReady)
    }

    @MainActor func testProgressNeverMovesBackAfterAFailureAndTryAgain() {
        var presentation = SetupPresentation(microphoneGranted: true, accessibilityGranted: true)
        presentation.model = .installing(.downloading, fraction: 0.5)
        presentation.retainedProgress = presentation.overallProgress
        presentation.model = .failed("Offline")
        XCTAssertEqual(presentation.overallProgress, 0.4, accuracy: 0.0001)
        XCTAssertEqual(presentation.progress, 0.4, accuracy: 0.0001)
        // Try Again starts the transfer at zero before the resumed bytes are counted.
        presentation.model = .installing(.downloading, fraction: 0)
        XCTAssertEqual(presentation.detail, "Downloading 1.2 GB, 40%")
        presentation.model = .installing(.downloading, fraction: 0.75)
        XCTAssertEqual(presentation.detail, "Downloading 1.2 GB, 60%")
        XCTAssertFalse(presentation.moonReady)
    }

    @MainActor func testTryItUsesConfiguredTriggerAndKeepsListeningAndSuccessInSecondaryLine() {
        var presentation = SetupPresentation(microphoneGranted: true, accessibilityGranted: true, model: .ready)
        XCTAssertEqual(presentation.headline, "Now press fn and talk.")
        XCTAssertEqual(presentation.detail, "Press fn again to stop.")
        presentation.listening = true
        XCTAssertEqual(presentation.headline, "Now press fn and talk.")
        XCTAssertEqual(presentation.detail, "Listening…")
        presentation.listening = false
        presentation.transcribing = true
        XCTAssertEqual(presentation.detail, "Writing it down…")
        presentation.transcribing = false
        presentation.hasText = true
        XCTAssertEqual(presentation.detail, "That's it.")
        presentation.transcribing = true
        XCTAssertEqual(presentation.detail, "Writing it down…")
        presentation.transcribing = false
        presentation.trigger = .rightOption
        presentation.triggerMode = .hold
        presentation.hasText = false
        XCTAssertEqual(presentation.headline, "Now hold Right Option and talk.")
        XCTAssertEqual(presentation.detail, "Let go to stop.")
    }
}

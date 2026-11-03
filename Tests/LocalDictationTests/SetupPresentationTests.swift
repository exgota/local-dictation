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

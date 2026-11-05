import AppKit
import DictationCore
import XCTest
@testable import LocalDictation

@MainActor final class DictationClipboardRecoveryTests: XCTestCase {
    private let copiedReasons: [DictationMiss] = [.noTextField, .focusMoved, .unconfirmed, .modelUnavailable,
                                                 .microphoneDisconnected, .deliveryTimedOut]

    func testCopyBetweenStopAndEveryRecoveryPathPreservesNewerClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for reason in copiedReasons {
            pasteboard.clearContents()
            pasteboard.setString("before stop", forType: .string)
            let stoppedChangeCount = pasteboard.changeCount
            pasteboard.clearContents()
            pasteboard.setString("newer clipboard marker", forType: .string)
            pasteboard.setData(Data([1, 2, 3]), forType: .init("test.rich-text"))
            let newerChangeCount = pasteboard.changeCount
            let result = DictationClipboardRecovery.prepare("dictated sentence", reason: reason,
                clipboard: .writeIfUnchanged(changeCount: stoppedChangeCount),
                stoppedChangeCount: stoppedChangeCount, pasteboard: pasteboard)
            XCTAssertEqual(result.reason, .clipboardChanged, "\(reason)")
            XCTAssertNil(result.changeCount, "A newer clipboard must not get the copied cue")
            XCTAssertEqual(result.reason.announcement(pasteShortcut: nil),
                           "Your clipboard is newer, so the dictation was not copied. Choose Paste last text from the menu.")
            XCTAssertEqual(pasteboard.string(forType: .string), "newer clipboard marker")
            XCTAssertEqual(pasteboard.data(forType: .init("test.rich-text")), Data([1, 2, 3]))
            XCTAssertEqual(pasteboard.changeCount, newerChangeCount)
        }
    }

    func testUnchangedClipboardCopiesTextAndKeepsTheOriginalRecoveryReason() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for reason in copiedReasons {
            pasteboard.clearContents()
            pasteboard.setString("before stop", forType: .string)
            let stoppedChangeCount = pasteboard.changeCount
            let result = DictationClipboardRecovery.prepare("dictated sentence", reason: reason,
                clipboard: .writeIfUnchanged(changeCount: stoppedChangeCount),
                stoppedChangeCount: stoppedChangeCount, pasteboard: pasteboard)
            XCTAssertEqual(result.reason, reason)
            XCTAssertEqual(result.changeCount, pasteboard.changeCount)
            XCTAssertEqual(pasteboard.string(forType: .string), "dictated sentence")
        }
    }

    func testSameTextCopiedAgainIsStillANewerClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("dictated sentence", forType: .string)
        let stoppedChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("dictated sentence", forType: .string)
        let newerChangeCount = pasteboard.changeCount
        let result = DictationClipboardRecovery.prepare("dictated sentence", reason: .noTextField,
            clipboard: .writeIfUnchanged(changeCount: stoppedChangeCount),
            stoppedChangeCount: stoppedChangeCount, pasteboard: pasteboard)
        XCTAssertEqual(result.reason, .clipboardChanged)
        XCTAssertNil(result.changeCount)
        XCTAssertEqual(pasteboard.changeCount, newerChangeCount)
    }

    func testAccessibilityFallbackCannotReplaceTheStopBoundaryWithADeliveryBoundary() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let stoppedChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("newer clipboard marker", forType: .string)
        let result = DictationClipboardRecovery.prepare("dictated sentence", reason: .unconfirmed,
            clipboard: .writeIfUnchanged(changeCount: pasteboard.changeCount),
            stoppedChangeCount: stoppedChangeCount, pasteboard: pasteboard)
        XCTAssertEqual(result.reason, .clipboardChanged)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer clipboard marker")
    }

    func testPasteTransactionFallbackNeverRewritesTheClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let stoppedChangeCount = pasteboard.changeCount
        for value in ["dictated sentence", "newer clipboard marker"] {
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            let currentChangeCount = pasteboard.changeCount
            let result = DictationClipboardRecovery.prepare("dictated sentence", reason: .unconfirmed,
                clipboard: .preserve, stoppedChangeCount: stoppedChangeCount, pasteboard: pasteboard)
            XCTAssertEqual(result.reason, value == "dictated sentence" ? .unconfirmed : .clipboardChanged)
            XCTAssertEqual(pasteboard.changeCount, currentChangeCount)
            XCTAssertEqual(pasteboard.string(forType: .string), value)
        }
    }

    func testSecureFieldAndMissingTranscriptNeverCopyOrClaimACopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("clipboard marker", forType: .string)
        let stoppedChangeCount = pasteboard.changeCount
        for (text, reason) in [("secret", DictationMiss.secureField), ("", .transcriptionTimedOut)] {
            let result = DictationClipboardRecovery.prepare(text, reason: reason,
                clipboard: .writeIfUnchanged(changeCount: stoppedChangeCount),
                stoppedChangeCount: stoppedChangeCount, pasteboard: pasteboard)
            XCTAssertEqual(result.reason, reason)
            XCTAssertNil(result.changeCount)
            XCTAssertEqual(pasteboard.changeCount, stoppedChangeCount)
            XCTAssertEqual(pasteboard.string(forType: .string), "clipboard marker")
        }
    }

    func testExplicitRecoveryCanUseANewClipboardBoundary() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let stoppedChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("newer clipboard marker", forType: .string)
        let text = "retained dictated sentence"
        let result = DictationClipboardRecovery.prepare(text, reason: .noTextField,
            clipboard: .writeIfUnchanged(changeCount: stoppedChangeCount),
            stoppedChangeCount: stoppedChangeCount, pasteboard: pasteboard)
        XCTAssertEqual(result.reason, .clipboardChanged)
        let recoveryChangeCount = pasteboard.changeCount
        _ = await LastTranscriptPaste.perform(text: text, target: nil,
            copy: { TextInserter.placeOnClipboardIfUnchanged($0, since: recoveryChangeCount, pasteboard: pasteboard) },
            log: { _ in })
        XCTAssertEqual(pasteboard.string(forType: .string), text)
    }
}

import AppKit
import DictationCore
import XCTest
@testable import LocalDictation

final class DeliveryLifecycleTests: XCTestCase {
    @MainActor func testEachTerminalOutcomeLogsExactlyOnceAndReleasesOrdering() async {
        let outcomes: [DeliveryLifecycle.Outcome] = [
            .inserted(application: "Local Dictation", method: .accessibilityInsertion, profile: "verbatim"),
            .inserted(application: "Other application", method: .paste, profile: "verbatim"),
            .refused(DictationMiss.secureField.completionMessage),
            .refused("Dictation is turned off in this application."),
            .refused("Dictation was cancelled."),
        ] + DictationMiss.allCases.map { .parked($0) }
        for outcome in outcomes {
            var messages: [String] = []
            let lifecycle = DeliveryLifecycle { messages.append($0) }
            let waiting = Task { await lifecycle.waitUntilFinished() }
            await Task.yield()
            XCTAssertTrue(lifecycle.finish(outcome))
            XCTAssertFalse(lifecycle.finish(.refused("Late worker")))
            await waiting.value
            XCTAssertEqual(lifecycle.outcome, outcome)
            XCTAssertEqual(messages, [outcome.logMessage])
            XCTAssertFalse(messages[0].isEmpty)
        }
    }

    @MainActor func testWatchdogCompletesWithoutWaitingForStalledWorkerAndRejectsLateCompletion() async {
        var messages: [String] = []
        let lifecycle = DeliveryLifecycle { messages.append($0) }
        var workerContinuation: CheckedContinuation<Void, Never>?
        let worker = Task {
            await withCheckedContinuation { workerContinuation = $0 }
            return lifecycle.finish(.inserted(application: "Late application", method: .paste, profile: "verbatim"))
        }
        while workerContinuation == nil { await Task.yield() }
        lifecycle.armDeadline(after: .milliseconds(20)) { lifecycle.finish(.parked(.deliveryTimedOut)) }
        await lifecycle.waitUntilFinished()
        XCTAssertEqual(lifecycle.outcome, .parked(.deliveryTimedOut))
        XCTAssertEqual(messages.count, 1)
        workerContinuation?.resume()
        let accepted = await worker.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(messages.count, 1)
    }

    @MainActor func testTimedOutSuccessorCannotLetLaterDeliveryPassAnUnfinishedPredecessor() async {
        let first = DeliveryLifecycle(log: { _ in })
        let second = DeliveryLifecycle(predecessor: first, log: { _ in })
        second.finish(.parked(.deliveryTimedOut))
        var thirdCanInsert = false
        let third = Task {
            await second.waitUntilFinished()
            thirdCanInsert = true
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(thirdCanInsert)
        first.finish(.refused("Transcription timed out"))
        await third.value
        XCTAssertTrue(thirdCanInsert)
    }

    @MainActor func testCompletedDeliveryCannotExpireAndCancelledOrderingWaitExits() async {
        let lifecycle = DeliveryLifecycle(log: { _ in })
        lifecycle.armDeadline(after: .milliseconds(20)) { XCTFail("A completed delivery expired") }
        let waiting = Task { await lifecycle.waitUntilFinished() }
        await Task.yield()
        waiting.cancel()
        await waiting.value
        XCTAssertTrue(lifecycle.finish(.refused("Cancelled")))
        try? await Task.sleep(for: .milliseconds(30))
    }

    @MainActor func testExternalApplicationNeverCapturesVisibleSetupEditor() async throws {
        let (window, field) = makeSetupField()
        defer { window.close() }
        let editor = try XCTUnwrap(SetupTextInsertionTarget(field: field, windowIsActive: { _ in true }))
        var externalQueries = 0
        let target = InsertionTarget.capture(
            processIdentifier: getpid() + 1000, applicationName: "Other application", bundleIdentifier: nil, wasSecure: false,
            focusedElement: { externalQueries += 1; return nil },
            setupTextTarget: { XCTFail("Another application's dictation consulted setup"); return editor })
        XCTAssertEqual(externalQueries, 1)
        XCTAssertNil(target.setupTextTarget)
        let outcome = await TextInserter.insert("Other application's words", into: target)
        XCTAssertEqual(outcome, .noEditableFocus)
        XCTAssertEqual(field.stringValue, "")
    }

    @MainActor func testOwnApplicationWithoutSetupFocusNeverQueriesItselfThroughAccessibility() async {
        let target = InsertionTarget.capture(
            processIdentifier: getpid(), applicationName: "Local Dictation", bundleIdentifier: nil, wasSecure: false,
            focusedElement: { XCTFail("Synchronous AX query into this process"); return nil }, setupTextTarget: { nil })
        let outcome = await TextInserter.insert("No focused field", into: target)
        XCTAssertEqual(outcome, .noEditableFocus)
        XCTAssertNil(target.withFocusedElement())
    }

    @MainActor func testSetupInsertionAndFocusLossProduceExplicitOutcomes() async throws {
        let (window, field) = makeSetupField()
        defer { window.close() }
        var active = true
        let setup = try XCTUnwrap(SetupTextInsertionTarget(field: field, windowIsActive: { _ in active }))
        let target = InsertionTarget(processIdentifier: getpid(), applicationName: "Local Dictation", bundleIdentifier: nil,
                                     focusedElement: nil, setupTextTarget: setup)
        var landed = 0
        let inserted = await TextInserter.insert("Setup words", into: target) { landed += 1 }
        XCTAssertEqual(inserted, .inserted(.accessibilityInsertion))
        XCTAssertEqual(field.stringValue, "Setup words")
        XCTAssertEqual(landed, 1)
        var log: [String] = []
        let lifecycle = DeliveryLifecycle { log.append($0) }
        if case .inserted(let method) = inserted {
            lifecycle.finish(.inserted(application: target.applicationName, method: method, profile: "verbatim"))
        }
        XCTAssertEqual(log, ["inserted into Local Dictation by accessibilityInsertion with profile verbatim"])
        active = false
        let moved = await TextInserter.insert("Must not appear", into: target)
        XCTAssertEqual(moved, .targetChanged)
        XCTAssertEqual(field.stringValue, "Setup words")
    }

    @MainActor func testPasteLastTextWorksWhileAnotherDeliveryIsPendingAndLogsMissingInputs() async {
        let pending = DeliveryLifecycle(log: { _ in })
        let target = InsertionTarget(processIdentifier: getpid() + 1000, applicationName: "Other application",
                                     bundleIdentifier: nil, focusedElement: nil)
        var inserted: [String] = [], copied: [String] = [], messages: [String] = []
        let outcome = await LastTranscriptPaste.perform(text: "Previous words", target: target,
            insert: { text, _ in inserted.append(text); return .inserted(.paste) }, copy: { copied.append($0); return true }, log: { messages.append($0) })
        XCTAssertEqual(outcome, .inserted(.paste))
        XCTAssertEqual(inserted, ["Previous words"])
        XCTAssertNil(pending.outcome)
        _ = await LastTranscriptPaste.perform(text: "Previous words", target: nil, copy: { copied.append($0); return true }, log: { messages.append($0) })
        _ = await LastTranscriptPaste.perform(text: nil, target: target, copy: { copied.append($0); return true }, log: { messages.append($0) })
        XCTAssertEqual(copied, ["Previous words"])
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages[1].contains("no application has focus"))
        XCTAssertTrue(messages[2].contains("no transcript"))
        pending.finish(.refused("Cancelled"))
    }

    @MainActor private func makeSetupField() -> (NSWindow, NSTextField) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = SetupTextField(string: "")
        field.frame = NSRect(x: 10, y: 10, width: 280, height: 22)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        return (window, field)
    }
}

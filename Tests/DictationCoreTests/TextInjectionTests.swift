import XCTest

@testable import DictationCore

final class InjectionPlannerTests: XCTestCase {
    func testSecureFieldRefused() {
        let element = FocusedElementDescription(isSecure: true, isEditable: true, acceptsSelectedTextInsertion: true, isValueReadable: true)
        XCTAssertEqual(InjectionPlanner.decide(for: element), .refuseSecureField)
    }

    func testNoFocusedElement() {
        XCTAssertEqual(InjectionPlanner.decide(for: nil), .noEditableFocus)
    }

    func testNonEditableElement() {
        let element = FocusedElementDescription(isSecure: false, isEditable: false, acceptsSelectedTextInsertion: false, isValueReadable: true)
        XCTAssertEqual(InjectionPlanner.decide(for: element), .noEditableFocus)
    }

    func testAccessibilityInsertionFirstWhenSupported() {
        let element = FocusedElementDescription(isSecure: false, isEditable: true, acceptsSelectedTextInsertion: true, isValueReadable: true)
        XCTAssertEqual(InjectionPlanner.decide(for: element), .attempt([.accessibilityInsertion, .paste]))
    }

    func testPasteFirstWhenValueUnreadable() {
        let element = FocusedElementDescription(
            isSecure: false, isEditable: true, acceptsSelectedTextInsertion: true, isValueReadable: false)
        XCTAssertEqual(InjectionPlanner.decide(for: element), .attempt([.paste]))
    }

    func testPasteFirstWhereApplicationIgnoredAccessibilityInsertion() {
        let element = FocusedElementDescription(isSecure: false, isEditable: true, acceptsSelectedTextInsertion: true, isValueReadable: true)
        XCTAssertEqual(
            InjectionPlanner.decide(for: element, applicationIgnoresAccessibilityInsertion: true), .attempt([.paste]))
    }

    func testPasteFirstWithoutSelectedTextInsertion() {
        let element = FocusedElementDescription(isSecure: false, isEditable: true, acceptsSelectedTextInsertion: false, isValueReadable: true)
        XCTAssertEqual(InjectionPlanner.decide(for: element), .attempt([.paste]))
    }
}

@MainActor final class InjectionChainTests: XCTestCase {
    /// Records every call in order and answers with scripted results.
    final class SpyInjector: TextInjecting {
        var calls: [String] = []
        var focusChecks: [Bool] = []
        var accessibilityResult = InjectionAttempt.notDelivered
        var pasteResult = InjectionAttempt.notDelivered

        func isTargetStillFocused() -> Bool {
            calls.append("focus")
            return focusChecks.isEmpty ? true : focusChecks.removeFirst()
        }
        func insertViaAccessibility(_ text: String) async -> InjectionAttempt {
            calls.append("accessibility:\(text)")
            return accessibilityResult
        }
        func paste(_ text: String) async -> InjectionAttempt {
            calls.append("paste:\(text)")
            return pasteResult
        }
    }

    private let all: InjectionDecision = .attempt([.accessibilityInsertion, .paste])

    func testStopsAtFirstConfirmedMethod() async {
        let spy = SpyInjector()
        spy.accessibilityResult = .delivered
        let outcome = await InjectionChain.run("hello", decision: all, injector: spy)
        XCTAssertEqual(outcome, .inserted(.accessibilityInsertion))
        XCTAssertEqual(spy.calls, ["focus", "accessibility:hello"])
    }

    func testPasteLanded() async {
        let spy = SpyInjector()
        spy.pasteResult = .delivered
        let outcome = await InjectionChain.run("hello", decision: .attempt([.paste]), injector: spy)
        XCTAssertEqual(outcome, .inserted(.paste))
    }

    func testFocusLossStopsChainBeforeNextMethod() async {
        let spy = SpyInjector()
        spy.focusChecks = [true, false]
        let outcome = await InjectionChain.run("hello", decision: all, injector: spy)
        XCTAssertEqual(outcome, .targetChanged)
        XCTAssertEqual(spy.calls, ["focus", "accessibility:hello", "focus"])
    }

    func testRefusalsNeverTouchInjector() async {
        let spy = SpyInjector()
        let secure = await InjectionChain.run("hello", decision: .refuseSecureField, injector: spy)
        let unfocused = await InjectionChain.run("hello", decision: .noEditableFocus, injector: spy)
        XCTAssertEqual(secure, .refusedSecureField)
        XCTAssertEqual(unfocused, .noEditableFocus)
        XCTAssertEqual(spy.calls, [])
    }

    func testCancelledDeliveryInsertsNothing() async {
        let spy = SpyInjector()
        spy.accessibilityResult = .delivered
        let all = self.all
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await InjectionChain.run("hello", decision: all, injector: spy)
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(spy.calls, [])
    }

    func testFallsBackToPasteAfterAccessibilityProvablyFailed() async {
        let spy = SpyInjector()
        spy.pasteResult = .delivered
        let outcome = await InjectionChain.run("hello", decision: all, injector: spy)
        XCTAssertEqual(outcome, .inserted(.paste))
        XCTAssertEqual(spy.calls, ["focus", "accessibility:hello", "focus", "paste:hello"])
    }

    func testUncertainAccessibilityInsertionStopsBeforePaste() async {
        let spy = SpyInjector()
        spy.accessibilityResult = .uncertain
        let outcome = await InjectionChain.run("hello", decision: all, injector: spy)
        XCTAssertEqual(outcome, .unconfirmed)
        XCTAssertEqual(spy.calls, ["focus", "accessibility:hello"])
    }

    func testAllMethodsFailingIsUnconfirmed() async {
        let spy = SpyInjector()
        let outcome = await InjectionChain.run("hello", decision: all, injector: spy)
        XCTAssertEqual(outcome, .unconfirmed)
    }
}

@MainActor final class ClipboardPasteTransactionTests: XCTestCase {
    /// An in-memory clipboard. `contents` holds the plain items. Text written on demand is returned only by `read()`.
    /// As on macOS, only the first read runs the read callback; later reads get the clipboard's copy.
    final class FakePasteboard: PasteboardAccessing {
        var changeCount = 0
        var contents: [String] = ["original", "original-rich"]
        private var onDemandText: String?
        private var onRead: (@MainActor () -> Void)?

        func takeSnapshot() -> [String] { contents }
        func restore(_ snapshot: [String]) {
            changeCount += 1
            contents = snapshot
        }
        func writeOnDemand(_ text: String, onRead: @escaping @MainActor () -> Void) {
            changeCount += 1
            contents = ["(on demand)"]
            onDemandText = text
            self.onRead = onRead
        }
        func writePlainText(_ text: String) {
            changeCount += 1
            contents = [text]
            onDemandText = nil
        }
        /// What a process receives when it reads the clipboard. The first read of on-demand text runs the callback.
        func read() -> String? {
            guard let onDemandText else { return contents.first }
            onRead?()
            onRead = nil
            return onDemandText
        }
        /// Another application writing to the clipboard.
        func externalWrite(_ text: String) {
            changeCount += 1
            contents = [text]
            onDemandText = nil
        }
    }

    private func transaction(_ pasteboard: FakePasteboard) -> ClipboardPasteTransaction<FakePasteboard> {
        ClipboardPasteTransaction(
            pasteboard: pasteboard, timing: .init(readTimeout: 0.5, restoreDelay: 0.15, pollInterval: 0.005),
            clock: { ProcessInfo.processInfo.systemUptime })
    }

    func testRestoresOnlyAfterSlowTargetReads() async {
        let pasteboard = FakePasteboard()
        var pasted: String?
        var contentsBeforeRead: [String] = []
        let outcome = await transaction(pasteboard).paste("transcript") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                contentsBeforeRead = pasteboard.contents
                pasted = pasteboard.read()
            }
        }
        XCTAssertEqual(outcome, .landed)
        XCTAssertEqual(contentsBeforeRead, ["(on demand)"], "the clipboard must not be restored before the target reads")
        XCTAssertEqual(pasted, "transcript")
        XCTAssertEqual(pasteboard.contents, ["original", "original-rich"])
    }

    func testTranscriptKeptWhenNothingReads() async {
        let pasteboard = FakePasteboard()
        let outcome = await transaction(pasteboard).paste("transcript") {}
        XCTAssertEqual(outcome, .notRead)
        XCTAssertEqual(pasteboard.contents, ["transcript"])
    }

    func testNoRestoreWhenAnotherApplicationWroteMeanwhile() async {
        let pasteboard = FakePasteboard()
        let outcome = await transaction(pasteboard).paste("transcript") {
            _ = pasteboard.read()
            pasteboard.externalWrite("copied by the user")
        }
        XCTAssertEqual(outcome, .landed)
        XCTAssertEqual(pasteboard.contents, ["copied by the user"])
    }

    func testReportsLandingOnceBeforeRestoring() async {
        let pasteboard = FakePasteboard()
        var landings = 0
        var contentsAtLanding: [String] = []
        let outcome = await transaction(pasteboard).paste("transcript", postPasteShortcut: {
            _ = pasteboard.read()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000)
                _ = pasteboard.read()
            }
        }, onLanded: {
            landings += 1
            contentsAtLanding = pasteboard.contents
        })
        XCTAssertEqual(outcome, .landed)
        XCTAssertEqual(landings, 1, "landing is reported once, however often the target reads")
        XCTAssertEqual(contentsAtLanding, ["(on demand)"], "landing is reported before the clipboard is restored")
        XCTAssertEqual(pasteboard.contents, ["original", "original-rich"])
    }

    func testNoLandingWhenNothingReads() async {
        let pasteboard = FakePasteboard()
        var landed = false
        let outcome = await transaction(pasteboard).paste("transcript", postPasteShortcut: {}, onLanded: { landed = true })
        XCTAssertEqual(outcome, .notRead)
        XCTAssertFalse(landed)
    }

    func testClipboardManagerReadDoesNotCutShortSlowTarget() async {
        let pasteboard = FakePasteboard()
        var pasted: String?
        let outcome = await transaction(pasteboard).paste("transcript") {
            _ = pasteboard.read()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                pasted = pasteboard.read()
            }
        }
        XCTAssertEqual(outcome, .landed)
        XCTAssertEqual(pasted, "transcript", "a target that reads after a clipboard manager must still get the transcript")
        XCTAssertEqual(pasteboard.contents, ["original", "original-rich"])
    }

    func testRestoresAsSoonAsTargetShowsText() async {
        let pasteboard = FakePasteboard()
        let slow = ClipboardPasteTransaction(
            pasteboard: pasteboard, timing: .init(readTimeout: 0.5, restoreDelay: 5, pollInterval: 0.005),
            clock: { ProcessInfo.processInfo.systemUptime })
        var pasted: String?
        let start = ProcessInfo.processInfo.systemUptime
        let outcome = await slow.paste("transcript", postPasteShortcut: { pasted = pasteboard.read() }, showsText: {
            pasted != nil
        })
        XCTAssertEqual(outcome, .landed)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1, "a confirmed paste does not wait the full delay")
        XCTAssertEqual(pasteboard.contents, ["original", "original-rich"])
    }
}

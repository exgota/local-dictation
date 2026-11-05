import AppKit
import DictationCore

/// Explicit recovery is available during recording, transcription and an earlier delivery.
@MainActor enum LastTranscriptPaste {
    static func perform(
        text: String?, target: InsertionTarget?,
        insert: (@MainActor (String, InsertionTarget) async -> InjectionOutcome)? = nil,
        copy: (@MainActor (String) -> Bool)? = nil,
        onInserted: @MainActor () -> Void = {},
        log: @MainActor (String) -> Void = { dictationLog.notice($0) }
    ) async -> InjectionOutcome? {
        guard let text, !text.isEmpty else {
            log("re-paste refused: no transcript is available")
            return nil
        }
        // Explicit recovery starts a new clipboard boundary, so a parked transcript can be pasted later.
        let clipboardChangeCount = NSPasteboard.general.changeCount
        let insert = insert ?? { await TextInserter.insert($0, into: $1, clipboardChangeCount: clipboardChangeCount) }
        let copy = copy ?? { TextInserter.placeOnClipboardIfUnchanged($0, since: clipboardChangeCount) }
        guard let target else {
            let copied = copy(text)
            log("re-paste unavailable: no application has focus; " + (copied ? "the text was copied" : "the clipboard was preserved"))
            return .noEditableFocus
        }
        let result = await insert(text, target)
        if case .inserted = result { onInserted() }
        if result == .noEditableFocus || result == .targetChanged { _ = copy(text) }
        log("re-paste into \(target.applicationName): \(String(describing: result))")
        return result
    }
}

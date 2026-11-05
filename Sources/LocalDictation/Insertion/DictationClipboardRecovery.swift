import AppKit
import DictationCore

/// Resolves a miss against the clipboard captured at stop, before choosing Park's cue and announcement.
@MainActor enum DictationClipboardRecovery {
    struct Presentation {
        let reason: DictationMiss
        let changeCount: Int?
    }

    static func prepare(_ text: String, reason: DictationMiss, clipboard: ClipboardFallback,
                        stoppedChangeCount: Int, pasteboard: NSPasteboard = .general) -> Presentation {
        guard reason != .secureField, !text.isEmpty else { return Presentation(reason: reason, changeCount: nil) }
        if case .writeIfUnchanged(let changeCount) = clipboard {
            guard changeCount == stoppedChangeCount,
                  TextInserter.placeOnClipboardIfUnchanged(text, since: stoppedChangeCount, pasteboard: pasteboard)
            else { return Presentation(reason: .clipboardChanged, changeCount: nil) }
        }
        // A paste transaction may already own the clipboard. Reading it must not turn a newer copy into our cue.
        let changeCount = pasteboard.changeCount
        let copied = pasteboard.string(forType: .string) == text && pasteboard.changeCount == changeCount
        return Presentation(reason: !copied && reason == .unconfirmed ? .clipboardChanged : reason,
                            changeCount: copied ? changeCount : nil)
    }
}

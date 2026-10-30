import Foundation

public enum PasteOutcome: Equatable, Sendable {
    /// A process read the clipboard. The previous clipboard is restored, unless another process wrote
    /// to the clipboard in the meantime.
    case landed
    /// The transcript could not be written, so no paste shortcut was posted.
    case writeFailed
    /// No process read the clipboard within `readTimeout`. The transcript is left on the clipboard as plain text,
    /// unless another process wrote to the clipboard in the meantime.
    case notRead
}

/// The clipboard operations a paste needs. A test double implements them, so the transaction runs without the system
/// pasteboard.
@MainActor public protocol PasteboardAccessing: AnyObject {
    associatedtype Snapshot
    var changeCount: Int { get }
    /// Copies every item and type currently on the clipboard.
    func takeSnapshot() -> Snapshot
    func restore(_ snapshot: Snapshot)
    /// Puts `text` on the clipboard as data supplied on demand. `onRead` runs when a process first reads it.
    func writeOnDemand(_ text: String, onRead: @escaping @MainActor () -> Void) -> (succeeded: Bool, changeCount: Int)
    func writePlainText(_ text: String)
}

/// Pastes a transcript through the clipboard: takes a snapshot of the clipboard, writes the transcript, posts
/// Command-V, and restores the snapshot after a read, subject to the conditions below.
///
/// The transcript is offered as on-demand clipboard data. The first process to read it calls back into this process,
/// and that callback is the first sign of a paste. Later reads are served from the clipboard's copy without a callback,
/// so the callback cannot tell the target's read from a clipboard manager's read that came first. The previous
/// clipboard is therefore restored only once the target shows the text, or `restoreDelay` after the first read when it
/// does not, and only if no other process wrote to the clipboard in the meantime. If nothing reads the transcript
/// within `readTimeout`, the transcript is left on the clipboard as plain text for the user to paste, again only if no
/// other process wrote to the clipboard.
@MainActor public final class ClipboardPasteTransaction<Pasteboard: PasteboardAccessing> {
    public struct Timing: Sendable {
        /// Seconds to wait for the first read after Command-V.
        public var readTimeout: TimeInterval
        /// Seconds after the first read before the previous clipboard is restored, when the target does not show the
        /// text sooner. Long enough for a target that reads after a clipboard manager.
        public var restoreDelay: TimeInterval
        /// Seconds between checks for a read and for the text in the target.
        public var pollInterval: TimeInterval

        public init(readTimeout: TimeInterval = 1.5, restoreDelay: TimeInterval = 1.0, pollInterval: TimeInterval = 0.02) {
            self.readTimeout = readTimeout
            self.restoreDelay = restoreDelay
            self.pollInterval = pollInterval
        }
    }

    private let pasteboard: Pasteboard
    private let timing: Timing
    private let clock: () -> TimeInterval

    public init(pasteboard: Pasteboard, timing: Timing = Timing(), clock: @escaping () -> TimeInterval) {
        self.pasteboard = pasteboard
        self.timing = timing
        self.clock = clock
    }

    /// Runs the transaction. It calls `postPasteShortcut`, which posts Command-V, once the transcript is on the
    /// clipboard. `onLanded` runs once, at the first read, before the restore. `showsText` reports whether the target
    /// now shows the transcript; it returns false where the target cannot be read, and the restore then waits the full
    /// `restoreDelay`.
    public func paste(
        _ text: String, postPasteShortcut: () -> Void, onLanded: () -> Void = {}, showsText: () -> Bool = { false }
    ) async -> PasteOutcome {
        let snapshot = pasteboard.takeSnapshot()
        var firstRead: TimeInterval?
        let write = pasteboard.writeOnDemand(text) { [clock] in
            if firstRead == nil { firstRead = clock() }
        }
        let ownChangeCount = write.changeCount
        guard write.succeeded else {
            if pasteboard.changeCount == ownChangeCount { pasteboard.restore(snapshot) }
            return .writeFailed
        }
        let start = clock()
        postPasteShortcut()

        while firstRead == nil && clock() - start < timing.readTimeout {
            await sleep(timing.pollInterval)
        }
        let outcome: PasteOutcome
        if let firstRead {
            onLanded()
            while clock() - firstRead < timing.restoreDelay && !showsText() {
                await sleep(timing.pollInterval)
            }
            outcome = .landed
        } else {
            outcome = .notRead
        }
        if pasteboard.changeCount == ownChangeCount {
            switch outcome {
            case .landed: pasteboard.restore(snapshot)
            case .notRead: pasteboard.writePlainText(text)
            case .writeFailed: break
            }
        }
        return outcome
    }

    private func sleep(_ seconds: TimeInterval) async {
        await Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }.value
    }
}

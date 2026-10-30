import Foundation
import Synchronization

/// A keyboard event copied out of a `CGEvent` on the event tap thread.
public struct TappedKeyEvent: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case keyDown, keyUp, flagsChanged, tapDisabledByTimeout, tapDisabledByUserInput }

    public var kind: Kind
    public var keyCode: UInt16
    public var flags: UInt64
    public var isRepeat: Bool
    public var time: TimeInterval

    public init(kind: Kind, keyCode: UInt16, flags: UInt64, isRepeat: Bool, time: TimeInterval) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.isRepeat = isRepeat
        self.time = time
    }

    public var hotkeyInput: HotkeyInput? {
        switch kind {
        case .keyDown: return .keyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat, time: time)
        case .keyUp: return .keyUp(keyCode: keyCode, flags: flags, time: time)
        case .flagsChanged: return .flagsChanged(keyCode: keyCode, flags: flags, time: time)
        case .tapDisabledByTimeout, .tapDisabledByUserInput: return nil
        }
    }
}

/// A single-producer, single-consumer queue from the event tap thread to the main thread. The queue allocates its
/// storage once, and `push` neither allocates nor locks. The queue holds at most `capacity - 1` events. When it is
/// full, `push` drops the event and counts it in `dropped`.
public final class TappedKeyEventQueue: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<TappedKeyEvent>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let droppedCount = Atomic<Int>(0)

    public init(capacity: Int = 512) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: TappedKeyEvent(kind: .keyUp, keyCode: 0, flags: 0, isRepeat: false, time: 0), count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Producer side. Returns false, and counts a dropped event, when the queue is full.
    @discardableResult
    public func push(_ event: TappedKeyEvent) -> Bool {
        let currentTail = tail.load(ordering: .relaxed)
        let nextTail = (currentTail + 1) % capacity
        guard nextTail != head.load(ordering: .acquiring) else {
            droppedCount.add(1, ordering: .relaxed)
            return false
        }
        storage[currentTail] = event
        tail.store(nextTail, ordering: .releasing)
        return true
    }

    /// Consumer side. Returns nil when the queue is empty.
    public func pop() -> TappedKeyEvent? {
        let currentHead = head.load(ordering: .relaxed)
        guard currentHead != tail.load(ordering: .acquiring) else { return nil }
        let event = storage[currentHead]
        head.store((currentHead + 1) % capacity, ordering: .releasing)
        return event
    }

    public var dropped: Int { droppedCount.load(ordering: .relaxed) }
}

/// The state the event tap callback needs to decide, synchronously and without locks, whether to swallow a key.
/// The main thread publishes the configuration and the dictation state. The tap thread reads them and records which
/// key-downs it swallowed.
///
/// The tap swallows these key-downs: the trigger key when it is an ordinary key (a modifier-only trigger has no chord),
/// the re-paste chord, the pause chord, and Escape while a dictation is active. While paused, the trigger key and the
/// re-paste chord pass through. The tap also swallows the autorepeats and the key-up of every key-down it swallowed.
/// Modifier changes always pass through.
public final class EventTapSharedState: Sendable {
    private static let activeBit: UInt64 = 1 << 0
    private static let pausedBit: UInt64 = 1 << 1

    private let status = Atomic<UInt64>(0)
    private let triggerChord = Atomic<UInt64>(0)
    private let repasteChord = Atomic<UInt64>(0)
    private let pauseChord = Atomic<UInt64>(0)
    /// One bit per virtual key code, 0 to 63 in the low word and 64 to 127 in the high word. A set bit means the tap
    /// swallowed the key-down, so it must swallow the key-up too.
    private let swallowedKeysLow = Atomic<UInt64>(0)
    private let swallowedKeysHigh = Atomic<UInt64>(0)

    public init() {}

    // MARK: Main thread

    public func publish(configuration: HotkeyConfiguration) {
        triggerChord.store(configuration.trigger.chord?.packed ?? 0, ordering: .releasing)
        repasteChord.store(configuration.repasteChord?.packed ?? 0, ordering: .releasing)
        pauseChord.store(configuration.pauseChord?.packed ?? 0, ordering: .releasing)
    }

    public func publish(dictationActive: Bool, paused: Bool) {
        status.store((dictationActive ? Self.activeBit : 0) | (paused ? Self.pausedBit : 0), ordering: .releasing)
    }

    // MARK: Tap thread

    /// Decides whether the tap swallows `event`. Allocation-free and lock-free.
    public func shouldSwallow(_ event: TappedKeyEvent) -> Bool {
        switch event.kind {
        case .keyDown:
            if isSwallowed(event.keyCode) { return true }
            guard !event.isRepeat || matchesTrigger(event) else { return false }
            let current = status.load(ordering: .acquiring)
            let paused = current & Self.pausedBit != 0
            let swallow =
                (!paused && matchesTrigger(event))
                || (event.keyCode == VirtualKey.escape && current & Self.activeBit != 0)
                || (!paused && matches(repasteChord, event))
                || matches(pauseChord, event)
            if swallow { setSwallowed(event.keyCode, true) }
            return swallow
        case .keyUp:
            guard isSwallowed(event.keyCode) else { return false }
            setSwallowed(event.keyCode, false)
            return true
        case .flagsChanged, .tapDisabledByTimeout, .tapDisabledByUserInput:
            return false
        }
    }

    private func matchesTrigger(_ event: TappedKeyEvent) -> Bool { matches(triggerChord, event) }

    private func matches(_ chord: borrowing Atomic<UInt64>, _ event: TappedKeyEvent) -> Bool {
        guard let chord = KeyChord(packed: chord.load(ordering: .acquiring)) else { return false }
        return chord.matches(keyCode: event.keyCode, flags: event.flags)
    }

    private func isSwallowed(_ keyCode: UInt16) -> Bool {
        guard keyCode < 128 else { return false }
        let word = keyCode < 64 ? swallowedKeysLow.load(ordering: .acquiring) : swallowedKeysHigh.load(ordering: .acquiring)
        return word & (1 << UInt64(keyCode % 64)) != 0
    }

    private func setSwallowed(_ keyCode: UInt16, _ swallowed: Bool) {
        guard keyCode < 128 else { return }
        let bit: UInt64 = 1 << UInt64(keyCode % 64)
        if keyCode < 64 {
            if swallowed { swallowedKeysLow.bitwiseOr(bit, ordering: .acquiringAndReleasing) } else { swallowedKeysLow.bitwiseAnd(~bit, ordering: .acquiringAndReleasing) }
        } else {
            if swallowed { swallowedKeysHigh.bitwiseOr(bit, ordering: .acquiringAndReleasing) } else { swallowedKeysHigh.bitwiseAnd(~bit, ordering: .acquiringAndReleasing) }
        }
    }
}

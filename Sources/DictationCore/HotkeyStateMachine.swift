import Foundation

/// A keyboard event as seen by the event tap. Times are seconds on a monotonic clock.
public enum HotkeyInput: Equatable, Sendable {
    case flagsChanged(keyCode: UInt16, flags: UInt64, time: TimeInterval)
    case keyDown(keyCode: UInt16, flags: UInt64, isRepeat: Bool, time: TimeInterval)
    case keyUp(keyCode: UInt16, flags: UInt64, time: TimeInterval)
    /// A deadline requested with `HotkeyAction.scheduleDeadline` has passed.
    case deadlineElapsed(time: TimeInterval)
}

/// What the dictation controller should do in response to keyboard input.
public enum HotkeyAction: Equatable, Sendable {
    /// Toggle mode: a clean press and release of the trigger, however long the trigger was held.
    case toggle
    /// Hold and double-tap-lock modes: the trigger went down cleanly.
    case holdBegan
    /// Hold and double-tap-lock modes: the trigger was released. After a quick tap in double-tap-lock mode,
    /// `.holdEnded` instead comes when the deadline passes or another key goes down.
    case holdEnded
    /// Another key joined the held trigger, so the press is a keyboard chord. The controller discards the recording.
    case holdInterrupted
    /// Double-tap-lock mode: a second tap locked the running recording on.
    case lockBegan
    /// Double-tap-lock mode: a clean press and release of the trigger ended the locked recording.
    case lockEnded
    case escapePressed
    case repasteRequested
    case pauseToggled
    /// The caller feeds `.deadlineElapsed` at or after this time.
    case scheduleDeadline(TimeInterval)
}

public struct HotkeyConfiguration: Equatable, Sendable {
    public var trigger: TriggerKey
    public var mode: TriggerMode
    public var repasteChord: KeyChord?
    public var pauseChord: KeyChord?

    public init(trigger: TriggerKey, mode: TriggerMode, repasteChord: KeyChord?, pauseChord: KeyChord?) {
        self.trigger = trigger
        self.mode = mode
        self.repasteChord = repasteChord
        self.pauseChord = pauseChord
    }
}

/// Turns raw key events into dictation actions. The machine performs no I/O and takes every time from its input, so
/// synthetic events can drive it in tests.
///
/// A trigger press is clean when no other modifier is held as it goes down and no other key is pressed before it is
/// released. Only clean presses count, so the trigger's own shortcuts (Fn-arrow, Fn-F, Right Option-letter) keep working.
public struct HotkeyStateMachine: Sendable {
    /// Longest press that still counts as a tap for double-tap-lock.
    public static let tapDuration: TimeInterval = 0.3
    /// Longest gap between the two taps of a double tap.
    public static let doubleTapInterval: TimeInterval = 0.35

    public var configuration: HotkeyConfiguration {
        didSet { if configuration.trigger != oldValue.trigger || configuration.mode != oldValue.mode { resetTrigger() } }
    }
    /// While paused, only Escape and the pause chord produce actions.
    public var isPaused = false

    private enum Session: Equatable {
        case idle
        case holding
        case awaitingSecondTap(deadline: TimeInterval)
        /// `armed` becomes true once the press that locked the recording is released.
        case locked(armed: Bool)
    }

    private var pressedModifiers: Set<UInt16> = []
    private var triggerIsDown = false
    private var triggerPressIsClean = false
    private var triggerDownTime: TimeInterval = 0
    private var session: Session = .idle

    public init(configuration: HotkeyConfiguration) {
        self.configuration = configuration
    }

    /// Forgets any hold, lock or pending second tap, for when the controller ended the dictation by other means. The
    /// state of the physical keys is kept.
    public mutating func resetSession() {
        session = .idle
    }

    private mutating func resetTrigger() {
        session = .idle
        triggerIsDown = false
        triggerPressIsClean = false
    }

    public mutating func handle(_ input: HotkeyInput) -> [HotkeyAction] {
        switch input {
        case .flagsChanged(let keyCode, let flags, let time):
            return handleFlagsChanged(keyCode: keyCode, flags: flags, time: time)
        case .keyDown(let keyCode, let flags, let isRepeat, let time):
            return handleKeyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat, time: time)
        case .keyUp(let keyCode, _, let time):
            guard case .key(let chord) = configuration.trigger, keyCode == chord.keyCode, triggerIsDown else { return [] }
            return release(time: time)
        case .deadlineElapsed(let time):
            if case .awaitingSecondTap(let deadline) = session, time >= deadline {
                session = .idle
                return [.holdEnded]
            }
            return []
        }
    }

    // MARK: Events

    private mutating func handleFlagsChanged(keyCode: UInt16, flags: UInt64, time: TimeInterval) -> [HotkeyAction] {
        guard let isDown = EventFlagBits.isModifierDown(keyCode: keyCode, flags: flags) else { return [] }
        let otherModifiersHeld = !pressedModifiers.subtracting([keyCode]).isEmpty
        if isDown { pressedModifiers.insert(keyCode) } else { pressedModifiers.remove(keyCode) }

        if keyCode == configuration.trigger.modifierKeyCode {
            if isDown && !triggerIsDown { return press(time: time, clean: !otherModifiersHeld) }
            if !isDown && triggerIsDown { return release(time: time) }
            return []
        }
        // Another modifier went down while the trigger is held or a double tap is pending.
        return isDown ? interrupt() : []
    }

    private mutating func handleKeyDown(keyCode: UInt16, flags: UInt64, isRepeat: Bool, time: TimeInterval)
        -> [HotkeyAction]
    {
        if case .key(let chord) = configuration.trigger, keyCode == chord.keyCode {
            if isRepeat || triggerIsDown { return [] }
            if chord.matches(keyCode: keyCode, flags: flags) { return press(time: time, clean: true) }
        }
        var actions = interrupt()
        guard !isRepeat else { return actions }
        if keyCode == VirtualKey.escape {
            actions.append(.escapePressed)
        } else if configuration.pauseChord?.matches(keyCode: keyCode, flags: flags) == true {
            actions.append(.pauseToggled)
        } else if !isPaused && configuration.repasteChord?.matches(keyCode: keyCode, flags: flags) == true {
            actions.append(.repasteRequested)
        }
        return actions
    }

    // MARK: Trigger

    private mutating func press(time: TimeInterval, clean: Bool) -> [HotkeyAction] {
        triggerIsDown = true
        triggerPressIsClean = clean
        triggerDownTime = time
        guard !isPaused, clean else { return [] }
        switch configuration.mode {
        case .toggle:
            return []
        case .hold:
            session = .holding
            return [.holdBegan]
        case .doubleTapLock:
            switch session {
            case .awaitingSecondTap(let deadline) where time <= deadline:
                session = .locked(armed: false)
                return [.lockBegan]
            case .locked:
                return []
            default:
                session = .holding
                return [.holdBegan]
            }
        }
    }

    private mutating func release(time: TimeInterval) -> [HotkeyAction] {
        triggerIsDown = false
        let wasClean = triggerPressIsClean
        triggerPressIsClean = false
        guard !isPaused else { return [] }
        switch configuration.mode {
        case .toggle:
            return wasClean ? [.toggle] : []
        case .hold:
            guard session == .holding else { return [] }
            session = .idle
            return [.holdEnded]
        case .doubleTapLock:
            switch session {
            case .holding:
                if wasClean && time - triggerDownTime < Self.tapDuration {
                    let deadline = time + Self.doubleTapInterval
                    session = .awaitingSecondTap(deadline: deadline)
                    return [.scheduleDeadline(deadline)]
                }
                session = .idle
                return [.holdEnded]
            case .locked(armed: false):
                session = .locked(armed: true)
                return []
            case .locked(armed: true):
                guard wasClean else { return [] }
                session = .idle
                return [.lockEnded]
            default:
                return []
            }
        }
    }

    /// Another key went down. If the trigger is down, its press is no longer clean. A hold in progress ends with
    /// `.holdInterrupted`, and a pending second tap ends with `.holdEnded`.
    private mutating func interrupt() -> [HotkeyAction] {
        if triggerIsDown { triggerPressIsClean = false }
        switch session {
        case .holding where triggerIsDown:
            session = .idle
            return [.holdInterrupted]
        case .awaitingSecondTap:
            // Typing between the taps: the first tap was not the start of a double tap.
            session = .idle
            return [.holdEnded]
        default:
            return []
        }
    }
}

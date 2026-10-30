import AppKit
import DictationCore
import Synchronization

/// Monotonic clock shared by the tap thread and the main thread, in seconds. `clock_gettime_nsec_np` neither allocates
/// nor locks, so the tap callback can call it.
func monotonicSeconds() -> TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

/// A HID-level `CGEventTap` on a dedicated thread. The callback copies each key event into a preallocated queue,
/// decides from lock-free shared state whether to swallow it, and signals the main run loop. All interpretation
/// happens on the main thread in `onEvent`.
final class HotkeyEventTap: @unchecked Sendable {
    struct Health: Equatable {
        var isInstalled: Bool
        var isEnabled: Bool
        var disabledByTimeoutCount: Int
        var disabledByUserInputCount: Int
        var droppedEventCount: Int
    }

    let sharedState = EventTapSharedState()
    /// Main thread. Receives events in order.
    var onEvent: (TappedKeyEvent) -> Void = { _ in }

    private let queue = TappedKeyEventQueue()
    /// Written on the main thread before the tap thread starts and after `uninstall` has disabled the tap; read by the
    /// callback.
    fileprivate var machPort: CFMachPort?
    private var tapThread: Thread?
    private var tapThreadFinished: DispatchSemaphore?
    private var tapRunLoop: CFRunLoop?
    private var deliverySource: CFRunLoopSource?
    private let timeoutDisableCount = Atomic<Int>(0)
    private let userInputDisableCount = Atomic<Int>(0)

    /// Events this app posts itself carry this value in `eventSourceUserData` and pass straight through.
    static let syntheticEventMarker: Int64 = 0x4C_44_49_43_54

    init() {
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        context.perform = { info in
            guard let info else { return }
            Unmanaged<HotkeyEventTap>.fromOpaque(info).takeUnretainedValue().drain()
        }
        deliverySource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        CFRunLoopAddSource(CFRunLoopGetMain(), deliverySource, .commonModes)
    }

    var health: Health {
        Health(
            isInstalled: machPort != nil,
            isEnabled: machPort.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            disabledByTimeoutCount: timeoutDisableCount.load(ordering: .relaxed),
            disabledByUserInputCount: userInputDisableCount.load(ordering: .relaxed),
            droppedEventCount: queue.dropped)
    }

    /// Installs the tap. Fails until the process is trusted for Accessibility.
    @discardableResult
    func install() -> Bool {
        if machPort != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard
            let port = CGEvent.tapCreate(
                tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: hotkeyEventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        machPort = port
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            defer { finished.signal() }
            guard let self, let port = self.machPort else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Hotkey event tap"
        thread.qualityOfService = QualityOfService.userInteractive
        tapThread = thread
        tapThreadFinished = finished
        thread.start()
        ready.wait()
        return true
    }

    /// Removes the tap, so that `reinstall` can install it again after wake.
    func uninstall() {
        guard let port = machPort else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let tapRunLoop { CFRunLoopStop(tapRunLoop) }
        if let tapThreadFinished, tapThreadFinished.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
            dictationLog.error("event tap thread did not stop within 0.5 seconds")
        }
        tapRunLoop = nil
        tapThread = nil
        tapThreadFinished = nil
        machPort = nil
    }

    func reinstall() -> Bool {
        uninstall()
        return install()
    }

    // MARK: Tap thread

    fileprivate func receive(_ event: TappedKeyEvent) -> Bool {
        switch event.kind {
        case .tapDisabledByTimeout: _ = timeoutDisableCount.add(1, ordering: .relaxed)
        case .tapDisabledByUserInput: _ = userInputDisableCount.add(1, ordering: .relaxed)
        default: break
        }
        let swallow = sharedState.shouldSwallow(event)
        queue.push(event)
        if let deliverySource {
            CFRunLoopSourceSignal(deliverySource)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return swallow
    }

    // MARK: Main thread

    private func drain() {
        while let event = queue.pop() { onEvent(event) }
    }
}

private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    let kind: TappedKeyEvent.Kind
    switch type {
    case .keyDown: kind = .keyDown
    case .keyUp: kind = .keyUp
    case .flagsChanged: kind = .flagsChanged
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // Re-enable at once; the main thread logs it when it drains the queue.
        if let port = tap.machPort { CGEvent.tapEnable(tap: port, enable: true) }
        kind = type == .tapDisabledByTimeout ? .tapDisabledByTimeout : .tapDisabledByUserInput
        _ = tap.receive(TappedKeyEvent(kind: kind, keyCode: 0, flags: 0, isRepeat: false, time: monotonicSeconds()))
        return Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == HotkeyEventTap.syntheticEventMarker {
        return Unmanaged.passUnretained(event)
    }
    let tapped = TappedKeyEvent(
        kind: kind, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
        flags: event.flags.rawValue, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
        time: monotonicSeconds())
    return tap.receive(tapped) ? nil : Unmanaged.passUnretained(event)
}

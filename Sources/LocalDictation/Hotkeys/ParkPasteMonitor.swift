import AppKit
import DictationCore

/// Passive app-delivery observers cover physical keys, session/targeted synthetic events, and this app's windows.
/// They exist only while Park is displayed. No event is swallowed or filtered by its source or synthetic marker.
@MainActor final class ParkPasteMonitor {
    private let observe: (NSEvent) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(observe: @escaping (NSEvent) -> Void) { self.observe = observe }

    func start() {
        guard localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    isolated deinit { stop() }

    static func isCommandPaste(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == VirtualKey.letterV
            && ModifierSet(eventFlags: UInt64(event.modifierFlags.rawValue)) == .command
    }
}

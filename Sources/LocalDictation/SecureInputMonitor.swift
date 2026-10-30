import AppKit
import Carbon.HIToolbox
import IOKit

/// Polls once a second for Secure Event Input. While another application holds it, event taps receive no key events,
/// so the hotkeys cannot work until it is released.
@MainActor final class SecureInputMonitor: ObservableObject {
    struct Holder: Equatable {
        let processIdentifier: pid_t?
        let applicationName: String
    }

    /// The application holding secure input, or nil when it is off or held by this process.
    @Published private(set) var holder: Holder?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let current = Self.currentHolder()
        if current != holder { holder = current }
    }

    nonisolated static func currentHolder() -> Holder? {
        guard IsSecureEventInputEnabled() else { return nil }
        let processIdentifier = secureInputProcessIdentifier()
        if processIdentifier == ProcessInfo.processInfo.processIdentifier { return nil }
        let name = processIdentifier.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName ?? processName($0) }
        return Holder(processIdentifier: processIdentifier, applicationName: name ?? "Another application")
    }

    /// The executable name of a process that is not an application, such as `loginwindow` while the screen is locked.
    nonisolated private static func processName(_ processIdentifier: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// The process holding secure input, from the console user entry the window server publishes in the I/O Registry.
    nonisolated private static func secureInputProcessIdentifier() -> pid_t? {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/")
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard
            let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? NSNumber { return pid.int32Value }
        }
        return nil
    }
}

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import IOKit

/// Polls once a second for Secure Event Input. While another application holds it, event taps receive no key events,
/// so the hotkeys cannot work until it is released.
@MainActor final class SecureInputMonitor: ObservableObject {
    struct Holder: Equatable {
        let processIdentifier: pid_t?
        let applicationName: String

        var statusDetail: String {
            let name = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name.isEmpty || name.lowercased() == "loginwindow" ? "Another app" : name
            return "\(displayName) is using secure input"
        }
    }

    /// The application with secure input enabled, or nil when it is off or held by this process.
    @Published private(set) var holder: Holder?
    private var timer: Timer?

    init() {
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
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
        return Holder(processIdentifier: processIdentifier, applicationName: name ?? "Another app")
    }

    /// The executable name of a process that is not an application, such as `loginwindow` while the screen is locked.
    nonisolated private static func processName(_ processIdentifier: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// Prefer this graphics session; the registry fallback must use the root, not the IOService plane entry.
    nonisolated private static func secureInputProcessIdentifier() -> pid_t? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if let processIdentifier = processIdentifier(in: session) { return processIdentifier }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] ?? []
        return secureInputProcessIdentifier(currentSession: session, consoleUsers: users, userIdentifier: getuid())
    }

    nonisolated static func secureInputProcessIdentifier(currentSession: [String: Any]?, consoleUsers: [[String: Any]],
                                                         userIdentifier: uid_t) -> pid_t? {
        if let processIdentifier = processIdentifier(in: currentSession) { return processIdentifier }
        for user in consoleUsers where (user["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true
            && (user["kCGSSessionUserIDKey"] as? NSNumber)?.uint64Value == UInt64(userIdentifier) {
            if let processIdentifier = processIdentifier(in: user) { return processIdentifier }
        }
        return nil
    }

    nonisolated private static func processIdentifier(in session: [String: Any]?) -> pid_t? {
        guard let number = session?["kCGSSessionSecureInputPID"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let identifier = pid_t(exactly: number.int64Value), identifier > 0,
              number.doubleValue == Double(identifier) else { return nil }
        return identifier
    }
}

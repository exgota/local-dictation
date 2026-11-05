import AppKit
import Darwin
import Foundation

struct ApplicationRelocationDecision: Equatable {
    enum Action: Equatable {
        case continueLaunch
        case relaunchOriginal(URL)
        case offerMove(source: URL, destination: URL)
    }

    static func action(bundle: URL, original: URL?, userApplications: URL, systemApplicationsWritable: Bool,
                       applicationBundles: (URL) -> [URL] = installedBundles,
                       bundleIdentifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }) -> Action {
        guard bundle.pathExtension == "app" else { return .continueLaunch }
        let translocated = bundle.pathComponents.contains("AppTranslocation")
        guard !translocated || original != nil else { return .continueLaunch }
        let source = (original ?? bundle).standardizedFileURL
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let applicationDirectories = [systemApplications, userApplications.standardizedFileURL]
        if applicationDirectories.contains(where: { source.path.hasPrefix($0.path + "/") }) {
            return translocated ? .relaunchOriginal(source) : .continueLaunch
        }
        if let identifier = bundleIdentifier(source) {
            for directory in applicationDirectories {
                if let installed = applicationBundles(directory).first(where: { bundleIdentifier($0) == identifier }) {
                    return .offerMove(source: source, destination: installed)
                }
            }
        }
        let directory = systemApplicationsWritable ? systemApplications : userApplications
        return .offerMove(source: source, destination: directory.appendingPathComponent("Local Dictation.app", isDirectory: true))
    }

    private static func installedBundles(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return entries.filter { $0.pathExtension == "app" }.sorted { $0.path < $1.path }
    }
}

/// The path is a shell argument, never shell source, including spaces, quotes and command substitutions.
struct ApplicationRelaunchCommand {
    let executableURL = URL(fileURLWithPath: "/bin/sh")
    let arguments: [String]

    init(bundle: URL, processIdentifier: pid_t) {
        precondition(processIdentifier > 0)
        arguments = ["-c", #"trap '' HUP; while kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open "$2""#,
                     "LocalDictation", String(processIdentifier), bundle.path]
    }
}

/// Runs first in `applicationDidFinishLaunching`, before application services: the alert needs a finished launch for its
/// accessibility tree, which VoiceOver reads. Relaunch waits until this process leaves macOS's running-application list.
@MainActor enum ApplicationRelocation {
    static func relaunchIfNeeded() -> Bool {
        let manager = FileManager.default
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let original = originalBundleURL(bundle)?.resolvingSymlinksInPath()
        let decision = ApplicationRelocationDecision.action(
            bundle: bundle, original: original,
            userApplications: manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            systemApplicationsWritable: manager.isWritableFile(atPath: "/Applications"))
        do {
            switch decision {
            case .continueLaunch: return false
            case .relaunchOriginal(let original):
                try removeQuarantine(from: original)
                return try relaunch(original)
            case .offerMove(let source, let destination):
                let alert = makeMoveAlert()
                // A regular app while the alert is open, so it appears in the Dock and in Command-Tab.
                NSApplication.shared.setActivationPolicy(.regular)
                ApplicationPresence.activate()
                // After Not Now the app stays regular until launch decides whether a window opens.
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
                // A translocated app runs from a read-only copy outside Downloads. Copying that copy instead of the
                // original avoids macOS's prompt for access to the Downloads folder.
                try install(source: bundle.pathComponents.contains("AppTranslocation") ? bundle : source, destination: destination)
                guard try relaunch(destination) else { return false }
                // The downloaded original stays where it is: deleting anything in Downloads makes macOS ask for access
                // to the Downloads folder, a prompt the person never asked for.
                return true
            }
        } catch {
            return false
        }
    }

    static func makeMoveAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Move Local Dictation to Applications?"
        alert.informativeText = ""
        alert.addButton(withTitle: "Move to Applications").keyEquivalent = "\r"
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        return alert
    }

    private static func originalBundleURL(_ bundle: URL) -> URL? {
        guard bundle.pathExtension == "app",
              let library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(library) }
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let symbol = dlsym(library, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(symbol, to: OriginalPath.self)
        return function(bundle as CFURL, nil)?.takeRetainedValue() as URL?
    }

    private static func install(source: URL, destination: URL) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".LocalDictation-installation-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let stagedBundle = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try manager.copyItem(at: source, to: stagedBundle)
        try removeQuarantine(from: stagedBundle)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: stagedBundle)
        } else {
            try manager.moveItem(at: stagedBundle, to: destination)
        }
    }

    private static func removeQuarantine(from bundle: URL) throws {
        func remove(_ url: URL) throws {
            // Do not follow a bundle's symlinks into files outside that bundle.
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { return }
            if removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0, errno != ENOATTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        try remove(bundle)
        var enumerationError: Error?
        guard let entries = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let entry as URL in entries { try remove(entry) }
        if let enumerationError { throw enumerationError }
    }

    /// Quits and reopens this copy of the app, for a change macOS only reports to a new process.
    static func relaunchCurrentApplication() {
        guard (try? relaunch(Bundle.main.bundleURL)) == true else { return }
        exit(0)
    }

    private static func relaunch(_ bundle: URL) throws -> Bool {
        let command = ApplicationRelaunchCommand(bundle: bundle, processIdentifier: getpid())
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The relaunched copy has the same identifier. Yielding lets it take the front without a click.
        if let identifier = Bundle.main.bundleIdentifier {
            NSApplication.shared.yieldActivation(toApplicationWithBundleIdentifier: identifier)
        }
        // Do not wait: the detached helper must outlive us before it opens the installed bundle.
        return true
    }
}

import AVFoundation
import AppKit
import ApplicationServices
import DictationCore
import DictationEngine
import IOKit.hid

/// The `--doctor` report: every condition dictation depends on, each with a verdict.
struct DoctorReport: Codable {
    enum Status: String, Codable { case ok, warning, failure, unknown }

    struct Check: Codable {
        let name: String
        let status: Status
        let detail: String
    }

    /// State only the running app knows, supplied when it answers the `report` command.
    struct RuntimeState {
        let microphoneGranted: Bool
        let accessibilityGranted: Bool
        let tapHealth: HotkeyEventTap.Health
        let modelState: String
        let modelReady: Bool
        let trigger: TriggerKey
        let inputDeviceIdentifier: String?
    }

    var checks: [Check]

    var isClean: Bool { checks.allSatisfy { $0.status == .ok } }

    var text: String {
        let width = (checks.map(\.name.count).max() ?? 0) + 2
        let lines = checks.map { check in
            let marker: String
            switch check.status {
            case .ok: marker = "ok     "
            case .warning: marker = "warning"
            case .failure: marker = "FAILED "
            case .unknown: marker = "unknown"
            }
            return "\(marker)  \(check.name.padding(toLength: width, withPad: " ", startingAt: 0))\(check.detail)"
        }
        return (lines + ["", isClean ? "Result: clean" : "Result: needs attention"]).joined(separator: "\n")
    }

    /// Collects the report. Without `runtime` (the app is not running), checks that need the app are unknown.
    static func collect(runtime: RuntimeState?, configuration: DictationConfiguration) -> DoctorReport {
        var checks: [Check] = []
        let notRunning = "Local Dictation is not running"

        if let runtime {
            checks.append(Check(
                name: "Microphone permission", status: runtime.microphoneGranted ? .ok : .failure,
                detail: runtime.microphoneGranted ? "Granted" : "Not granted. Open System Settings → Privacy & Security → Microphone."))
            checks.append(Check(
                name: "Accessibility permission", status: runtime.accessibilityGranted ? .ok : .failure,
                detail: runtime.accessibilityGranted ? "Granted" : "Not granted. Needed to detect the key and insert text."))
            let health = runtime.tapHealth
            let tapStatus: Status = health.isInstalled && health.isEnabled ? .ok : .failure
            checks.append(Check(
                name: "Event tap", status: tapStatus,
                detail: "\(health.isInstalled ? "installed" : "not installed"), \(health.isEnabled ? "enabled" : "disabled"); "
                    + "re-enabled after \(health.disabledByTimeoutCount) timeouts and \(health.disabledByUserInputCount) user-input disables; "
                    + "\(health.droppedEventCount) events dropped"))
            checks.append(Check(
                name: "Speech model", status: runtime.modelReady ? .ok : .failure, detail: runtime.modelState))
        } else {
            for name in ["Microphone permission", "Accessibility permission", "Event tap", "Speech model"] {
                checks.append(Check(name: name, status: .unknown, detail: notRunning))
            }
        }

        let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        checks.append(Check(
            name: "Input Monitoring", status: .ok,
            detail: (inputMonitoring == kIOHIDAccessTypeGranted ? "Granted" : "Not granted")
                + "; not required, the event tap runs under Accessibility"))

        checks.append(functionKeyCheck(trigger: runtime?.trigger ?? configuration.trigger))

        if let holder = SecureInputMonitor.currentHolder() {
            checks.append(Check(
                name: "Secure input", status: .warning,
                detail: "Held by \(holder.applicationName) (pid \(holder.processIdentifier.map(String.init) ?? "unknown")); hotkeys cannot work until it is released"))
        } else {
            checks.append(Check(name: "Secure input", status: .ok, detail: "Not held"))
        }

        let selected = runtime?.inputDeviceIdentifier ?? configuration.inputDeviceIdentifier
        let devices = AudioInputDevice.all()
        if let selected {
            let device = devices.first { $0.identifier == selected }
            checks.append(Check(
                name: "Microphone", status: device == nil ? .failure : .ok,
                detail: device.map { "Selected: \($0.name)" } ?? "The selected microphone (\(selected)) is not connected"))
        } else {
            let name = AVCaptureDevice.default(for: .audio)?.localizedName
            checks.append(Check(
                name: "Microphone", status: name == nil ? .failure : .ok,
                detail: name.map { "System default: \($0)" } ?? "No input device is available"))
        }

        let store = ModelStore(rootDirectory: ModelStore.defaultRootDirectory)
        checks.append(Check(
            name: "Model cache", status: store.isInstalled ? .ok : .failure,
            detail: store.isInstalled
                ? "Compiled \(ModelManifest.displayName) \(ModelManifest.revision.prefix(7)) and Silero VAD \(VoiceActivityModelManifest.revision.prefix(7)) at \(store.rootDirectory.path)"
                : "Not installed. Download it in Settings → Speech model."))

        checks.append(contentsOf: InstallationCheck.current().doctorChecks)

        let recentErrors = EventLog.recentErrors(limit: 5).filter { line in
            guard let stamp = line.split(separator: " ").first,
                let date = ISO8601DateFormatter.withFractionalSeconds.date(from: String(stamp))
            else { return false }
            return Date().timeIntervalSince(date) < 24 * 60 * 60
        }
        checks.append(Check(
            name: "Recent errors", status: recentErrors.isEmpty ? .ok : .warning,
            detail: recentErrors.isEmpty ? "None in the last 24 hours" : recentErrors.joined(separator: "\n" + String(repeating: " ", count: 11))))
        return DoctorReport(checks: checks)
    }

    /// macOS can also act on Fn ("Press 🌐 key to"); with Fn as the trigger that must be "Do Nothing".
    private static func functionKeyCheck(trigger: TriggerKey) -> Check {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int ?? 0
        let actions = [0: "Do Nothing", 1: "Change Input Source", 2: "Show Emoji & Symbols", 3: "Start dictation"]
        let action = actions[value] ?? "setting \(value)"
        guard trigger == .function else {
            return Check(name: "Fn key mapping", status: .ok, detail: "Fn is not the trigger; macOS uses it for \(action)")
        }
        return Check(
            name: "Fn key mapping", status: value == 0 ? .ok : .warning,
            detail: value == 0
                ? "macOS Fn action is Do Nothing"
                : "macOS also runs \(action) on Fn. Set System Settings → Keyboard → Press 🌐 key to: Do Nothing.")
    }
}

extension ISO8601DateFormatter {
    /// ISO8601DateFormatter is thread-safe once configured.
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

import AVFoundation
import AppKit
import ApplicationServices

/// Microphone and Accessibility authorization, polled once a second. Requests happen only from explicit onboarding
/// actions.
@MainActor final class PermissionMonitor: ObservableObject {
    static let microphoneSettingsAnchor = "Privacy_Microphone"
    static let accessibilitySettingsAnchor = "Privacy_Accessibility"

    @Published private(set) var microphoneGranted = false
    @Published private(set) var microphoneDenied = false
    @Published private(set) var accessibilityGranted = false
    private var timer: Timer?
    static let microphoneAuthorizationArgument = "--microphone-authorization"
    /// True once a fresh process sees the microphone allowed while this process still reads the earlier denial.
    private(set) var microphoneAllowedInNewProcess = false
    private var checksSinceDenial = 0

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var allGranted: Bool { microphoneGranted && accessibilityGranted }

    func refresh() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneGranted != (status == .authorized) { microphoneGranted = status == .authorized }
        let denied = status == .denied || status == .restricted
        if microphoneDenied != denied { microphoneDenied = denied }
        let trusted = AXIsProcessTrusted()
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
        if denied {
            checksSinceDenial += 1
            if checksSinceDenial % 2 == 0 { checkMicrophoneInFreshProcess() }
        } else {
            checksSinceDenial = 0
        }
    }

    /// AVFoundation keeps a denial for the life of the process, so a child copy of this executable reads the
    /// current permission, which macOS attributes to this app.
    private func checkMicrophoneInFreshProcess() {
        guard let executable = Bundle.main.executableURL, !microphoneAllowedInNewProcess else { return }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [Self.microphoneAuthorizationArgument]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            let answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard answer.hasPrefix("authorized") else { return }
            Task { @MainActor in
                self?.microphoneAllowedInNewProcess = true
                if NSApp.isActive { ApplicationRelocation.relaunchCurrentApplication() }
            }
        }
        try? process.run()
    }

    /// `onAnswered` runs once the user answers the system prompt, which takes focus from this app.
    func requestMicrophone(onAnswered: @escaping @MainActor () -> Void) {
        if microphoneDenied {
            openSystemSettings(anchor: Self.microphoneSettingsAnchor)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in
                self.refresh()
                onAnswered()
            }
        }
    }

    private var askedForAccessibility = false

    /// The first request lists the app in System Settings, which also shows macOS's own alert. Later requests only
    /// open System Settings, so the alert does not compete with setup's guidance again.
    func requestAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 rejects as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": !askedForAccessibility] as CFDictionary
        askedForAccessibility = true
        if !AXIsProcessTrustedWithOptions(options) { openSystemSettings(anchor: Self.accessibilitySettingsAnchor) }
    }

    func openSystemSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

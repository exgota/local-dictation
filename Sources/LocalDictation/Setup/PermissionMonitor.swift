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

    func requestAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 rejects as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSystemSettings(anchor: Self.accessibilitySettingsAnchor) }
    }

    func openSystemSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

import AppKit
import DictationCore
import DictationEngine
import SwiftUI

/// The production presentation can be rendered without starting application services.
struct SetupPresentation {
    enum Step { case microphone, accessibility, download, tryIt }

    var microphoneGranted = false
    var microphoneDenied = false
    var accessibilityGranted = false
    var waitingForAccessibility = false
    var model: ModelController.State = .notInstalled
    var trigger: TriggerKey = .function
    var triggerMode: TriggerMode = .toggle
    var listening = false
    var hasText = false
    var retainedDownloadProgress = 0.0
    /// True for a moment after the last byte arrives, so "100%" is seen before "Almost ready…".
    var showsCompletedDownload = false

    var step: Step {
        if !microphoneGranted { return .microphone }
        if !accessibilityGranted { return .accessibility }
        return model == .ready ? .tryIt : .download
    }

    var shape: Int {
        switch step { case .microphone: return 1; case .accessibility: return 2; default: return 0 }
    }

    var progress: Double {
        switch model {
        case .installing(_, let fraction): return max(0, min(0.99, fraction))
        case .loading: return 0.99
        case .ready: return 1.5
        case .failed: return retainedDownloadProgress
        default: return 0
        }
    }

    var downloadFailed: Bool {
        if case .failed = model { return true }
        return false
    }

    /// Compiling and loading happen after the last byte arrives, so the percentage would sit at 99 for many seconds.
    var preparingModel: Bool {
        switch model {
        case .installing(.compiling, _), .loading: return true
        default: return false
        }
    }

    var shouldStartDownload: Bool { step == .download && model == .notInstalled }

    var headline: String {
        switch step {
        case .microphone: return "First, let it hear you."
        case .accessibility: return "Next, let it type for you."
        case .download: return "Last, the speech model."
        case .tryIt:
            return triggerMode == .toggle ? "Now press \(trigger.displayName) and talk." : "Now hold \(trigger.displayName) and talk."
        }
    }

    var detail: String {
        switch step {
        case .microphone: return microphoneDenied ? "Turn on Local Dictation in System Settings." : ""
        case .accessibility:
            return waitingForAccessibility ? "Switch on Local Dictation, then come back." : ""
        case .download:
            let bytes = ModelManifest.totalSize + VoiceActivityModelManifest.totalSize
            let size = (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(1))) + " GB"
            if downloadFailed { return "The download stopped." }
            if showsCompletedDownload, preparingModel { return "100% of \(size)" }
            if preparingModel { return "Almost ready…" }
            let fraction: Double
            if case .installing(_, let completed) = model { fraction = max(0, min(1, completed)) }
            else { fraction = progress }
            return "\(Int(fraction * 100))% of \(size)"
        case .tryIt:
            if listening { return "Listening…" }
            if hasText { return "That's it." }
            return triggerMode == .toggle ? "Press \(trigger.displayName) again to stop." : "Let go to stop."
        }
    }
}

struct OnboardingView: View {
    let bringForward: @MainActor () -> Void
    let finish: () -> Void
    @ObservedObject private var permissions: PermissionMonitor
    @ObservedObject private var model: ModelController
    @ObservedObject private var settings: DictationSettings
    @ObservedObject private var controller: DictationController
    @State private var waitingForAccessibility = false
    @State private var text = ""
    @State private var retainedDownloadProgress = 0.0
    @State private var showsCompletedDownload = false
    @State private var downloadFinished = false

    init(context: SettingsContext, bringForward: @escaping @MainActor () -> Void, finish: @escaping () -> Void) {
        self.bringForward = bringForward
        self.finish = finish
        permissions = context.permissions
        model = context.model
        settings = context.settings
        controller = context.controller
    }

    private var presentation: SetupPresentation {
        SetupPresentation(
            microphoneGranted: permissions.microphoneGranted, microphoneDenied: permissions.microphoneDenied,
            accessibilityGranted: permissions.accessibilityGranted, waitingForAccessibility: waitingForAccessibility,
            model: model.state, trigger: settings.configuration.trigger, triggerMode: settings.configuration.triggerMode,
            listening: controller.phase == .recording, hasText: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            retainedDownloadProgress: retainedDownloadProgress, showsCompletedDownload: showsCompletedDownload)
    }

    var body: some View {
        SetupContentView(presentation: presentation, text: $text, action: performAction)
            .task(id: presentation.shouldStartDownload) {
                if presentation.shouldStartDownload { model.install() }
            }
            .onChange(of: model.state, initial: true) { _, state in
                if case .installing(_, let fraction) = state { retainedDownloadProgress = max(0, min(0.99, fraction)) }
                if state == .loading { retainedDownloadProgress = 0.99 }
                // Hold the finished percentage briefly when the bytes are in, then show "Almost ready…".
                if case .installing(.downloading, _) = state { downloadFinished = false }
                if case .installing(.compiling, _) = state, !downloadFinished {
                    downloadFinished = true
                    showsCompletedDownload = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showsCompletedDownload = false }
                }
            }
            .onChange(of: permissions.accessibilityGranted) { _, granted in
                if granted { waitingForAccessibility = false; bringForward() }
            }
            .background(SetupWindowFocus {
                permissions.refresh()
                waitingForAccessibility = false
            })
    }

    private func performAction() {
        switch presentation.step {
        case .microphone:
            if permissions.microphoneDenied {
                permissions.openSystemSettings(anchor: PermissionMonitor.microphoneSettingsAnchor)
            } else {
                permissions.requestMicrophone(onAnswered: bringForward)
            }
        case .accessibility:
            waitingForAccessibility = true
            permissions.requestAccessibility()
        case .download: model.install()
        case .tryIt: finish()
        }
    }
}

struct SetupContentView: View {
    let presentation: SetupPresentation
    @Binding var text: String
    var action: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            SetupMoonView(shape: presentation.shape, progress: presentation.progress, ready: presentation.step == .tryIt)
                .frame(width: 240, height: 240)
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text(presentation.headline).font(.title3.weight(.semibold))
                Text(presentation.detail).foregroundStyle(.secondary).monospacedDigit()
                    .opacity(presentation.detail.isEmpty ? 0 : 1)
            }
            .multilineTextAlignment(.center)
            .id(presentation.step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)), removal: .opacity))
            .padding(.top, 6)
            actionView
                .padding(.top, 20)
                .frame(minHeight: 48, alignment: .top)
        }
        .padding(.horizontal, 40).padding(.bottom, 28)
        .frame(width: 420)
        // Under Reduce Motion the steps still cross-fade; only the rise is removed.
        .animation(.easeOut(duration: 0.3), value: presentation.step)
        .animation(.easeOut(duration: 0.3), value: presentation.microphoneDenied)
        .animation(.easeOut(duration: 0.3), value: presentation.downloadFailed)
    }

    @ViewBuilder private var actionView: some View {
        switch presentation.step {
        case .microphone:
            Button(presentation.microphoneDenied ? "Open System Settings" : "Allow Microphone", action: action)
                .controlSize(.large).keyboardShortcut(.defaultAction)
        case .accessibility:
            Button("Open System Settings", action: action)
                .controlSize(.large).keyboardShortcut(.defaultAction).disabled(presentation.waitingForAccessibility)
        case .download:
            if presentation.downloadFailed {
                Button("Try Again", action: action).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        case .tryIt:
            VStack(spacing: 14) {
                SetupDictationField(text: $text)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
                if presentation.hasText {
                    Button("Done", action: action).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// Re-enables the Accessibility action when this window returns, even if permission was not granted.
private struct SetupWindowFocus: NSViewRepresentable {
    let returned: () -> Void
    func makeNSView(context: Context) -> FocusObserver { FocusObserver(returned: returned) }
    func updateNSView(_ view: FocusObserver, context: Context) { view.returned = returned }

    final class FocusObserver: NSView {
        var returned: () -> Void
        private var observer: NSObjectProtocol?
        init(returned: @escaping () -> Void) { self.returned = returned; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.returned() }
            }
        }
        isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

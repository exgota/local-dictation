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
    var transcribing = false
    var hasText = false
    /// The highest progress shown so far, kept through a failure and a Try Again so the bar never moves back.
    var retainedProgress = 0.0
    /// Seconds since this window saw the model start preparing for this Mac. Nil before that.
    var preparationElapsed: TimeInterval?
    /// True for a moment after the model becomes usable, so "Ready, 100%" is seen before Try it.
    var showsCompletion = false

    /// The download fills the first 80% of the bar and preparing the model for this Mac fills the rest, so 100% means
    /// the model is ready to use.
    static let downloadShare = 0.8
    /// Core ML reports no progress while it compiles and specializes the model: about 50 seconds on a Mac with a Neural
    /// Engine, 64 to 80 seconds without one. That part of the bar follows the clock instead, slowing toward 99% without
    /// reaching it. With this time constant it shows 96% after 50 seconds and 98% after 80.
    static let preparationTimeConstant: TimeInterval = 25

    static func preparationProgress(after elapsed: TimeInterval) -> Double {
        downloadShare + (0.99 - downloadShare) * (1 - exp(-max(0, elapsed) / preparationTimeConstant))
    }

    var step: Step {
        if !microphoneGranted { return .microphone }
        if !accessibilityGranted { return .accessibility }
        return model == .ready && !showsCompletion ? .tryIt : .download
    }

    var shape: Int {
        switch step { case .microphone: return 1; case .accessibility: return 2; default: return 0 }
    }

    /// The whole installation from the first byte to a usable model, from 0 to 1. Only a usable model reaches 1.
    var overallProgress: Double {
        switch model {
        case .notInstalled: return retainedProgress
        case .installing(.compiling, _), .loading:
            return max(retainedProgress, Self.preparationProgress(after: preparationElapsed ?? 0))
        case .installing(_, let fraction): return max(retainedProgress, Self.downloadShare * max(0, min(1, fraction)))
        case .ready: return 1
        case .failed: return retainedProgress
        }
    }

    /// The moon's download phase: capped below complete until the model is usable, then the completion value.
    var progress: Double { model == .ready ? 1.5 : min(0.99, overallProgress) }

    /// The moon plays its completion while "Ready, 100%" is shown, then Try it follows.
    var moonReady: Bool { step == .tryIt || (step == .download && showsCompletion) }

    var downloadFailed: Bool {
        if case .failed = model { return true }
        return false
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
            let percent = "\(Int((overallProgress * 100).rounded(.down)))%"
            switch model {
            case .failed: return "The download stopped."
            case .ready: return "Ready, 100%"
            case .installing(.compiling, _), .loading: return "Preparing for this Mac, \(percent)"
            default: return "Downloading \(size), \(percent)"
            }
        case .tryIt:
            if listening { return "Listening…" }
            if transcribing { return "Writing it down…" }
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
    @State private var retainedProgress = 0.0
    @State private var preparationStartedAt: Date?
    @State private var showsCompletion = false

    init(context: SettingsContext, bringForward: @escaping @MainActor () -> Void, finish: @escaping () -> Void) {
        self.bringForward = bringForward
        self.finish = finish
        permissions = context.permissions
        model = context.model
        settings = context.settings
        controller = context.controller
    }

    private var presentation: SetupPresentation { presentation(at: Date()) }

    private func presentation(at date: Date) -> SetupPresentation {
        SetupPresentation(
            microphoneGranted: permissions.microphoneGranted, microphoneDenied: permissions.microphoneDenied,
            accessibilityGranted: permissions.accessibilityGranted, waitingForAccessibility: waitingForAccessibility,
            model: model.state, trigger: settings.configuration.trigger, triggerMode: settings.configuration.triggerMode,
            listening: controller.phase == .recording, transcribing: controller.phase == .transcribing,
            hasText: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, retainedProgress: retainedProgress,
            preparationElapsed: preparationStartedAt.map { date.timeIntervalSince($0) }, showsCompletion: showsCompletion)
    }

    var body: some View {
        // Redraws four times a second only while the model prepares, when the bar follows the clock.
        TimelineView(.animation(minimumInterval: 0.25, paused: preparationStartedAt == nil || model.state == .ready)) { context in
            SetupContentView(presentation: presentation(at: context.date), text: $text, action: performAction)
        }
            .task(id: presentation.shouldStartDownload) {
                if presentation.shouldStartDownload { model.install() }
            }
            .onChange(of: model.state, initial: true) { _, state in modelStateChanged(to: state) }
            .onChange(of: permissions.accessibilityGranted) { _, granted in
                if granted { waitingForAccessibility = false; bringForward() }
            }
            .background(SetupWindowFocus {
                permissions.refresh()
                waitingForAccessibility = false
            })
    }

    private func modelStateChanged(to state: ModelController.State) {
        if let preparationStartedAt {
            retainedProgress = max(retainedProgress, SetupPresentation.preparationProgress(
                after: Date().timeIntervalSince(preparationStartedAt)))
        }
        switch state {
        case .installing(.compiling, _), .loading:
            if preparationStartedAt == nil { preparationStartedAt = Date() }
        case .ready:
            // Only an installation watched in this window shows "Ready, 100%"; a model that was already usable goes
            // straight to Try it.
            if preparationStartedAt != nil {
                showsCompletion = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showsCompletion = false }
            }
            preparationStartedAt = nil
        case .installing, .failed, .notInstalled:
            preparationStartedAt = nil
        }
        retainedProgress = max(retainedProgress, min(0.99, presentation.overallProgress))
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
            SetupMoonView(shape: presentation.shape, progress: presentation.progress, ready: presentation.moonReady)
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

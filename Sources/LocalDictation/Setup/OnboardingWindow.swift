import AppKit
import DictationCore
import SwiftUI

/// Shown at first run and whenever something dictation depends on is missing: one window, one row per requirement,
/// each with its live status and the action that fixes it. Permission statuses refresh every second and the model
/// status follows its installation, so nothing needs a restart.
@MainActor final class OnboardingWindowController {
    private var window: NSWindow?

    func show(context: SettingsContext) {
        if window == nil {
            let hosting = NSHostingController(
                rootView: OnboardingView(
                    context: context, bringForward: { [weak self] in self?.bringForward() }, finish: { [weak self] in self?.close() }))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Set up Local Dictation"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        bringForward()
    }

    /// The app has no Dock icon, so a window it leaves behind others is hard to find. Called after each step that
    /// takes the user elsewhere.
    func bringForward() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    var isVisible: Bool { window?.isVisible == true }
}

struct OnboardingView: View {
    let context: SettingsContext
    let bringForward: @MainActor () -> Void
    let finish: () -> Void
    @ObservedObject private var permissions: PermissionMonitor
    @ObservedObject private var model: ModelController
    @ObservedObject private var settings: DictationSettings

    init(context: SettingsContext, bringForward: @escaping @MainActor () -> Void, finish: @escaping () -> Void) {
        self.context = context
        self.bringForward = bringForward
        self.finish = finish
        permissions = context.permissions
        model = context.model
        settings = context.settings
    }

    private var isComplete: Bool { permissions.allGranted && model.isReady }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            ForEach(InstallationCheck.current().warnings, id: \.self) { warning in
                InlineBanner(content: InlineBanner.Content(id: warning, message: warning))
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: SettingsLayout.labelControlGap, verticalSpacing: SettingsLayout.sectionSpacing) {
                requirement(
                    "Microphone", reason: "Hears what you say. Audio never leaves this Mac.", isGranted: permissions.microphoneGranted,
                    grantedText: "Allowed"
                ) {
                    if permissions.microphoneDenied || permissions.microphoneGranted {
                        Button("Open System Settings") { permissions.openSystemSettings(anchor: PermissionMonitor.microphoneSettingsAnchor) }
                    } else {
                        Button("Allow microphone") { permissions.requestMicrophone(onAnswered: bringForward) }
                    }
                }
                requirement(
                    "Accessibility", reason: "Detects the dictation key and inserts text where you type.",
                    isGranted: permissions.accessibilityGranted, grantedText: "Allowed"
                ) {
                    Button("Open System Settings") { permissions.requestAccessibility() }
                }
                requirement("Speech model", reason: modelReason, isGranted: model.isReady, grantedText: "Ready") {
                    switch model.state {
                    case .notInstalled, .failed:
                        Button("Download model") { model.install() }
                    case .installing(_, let fraction):
                        ProgressView(value: fraction).frame(width: 120)
                    case .loading:
                        ProgressView().controlSize(.small)
                    case .ready:
                        EmptyView()
                    }
                }
            }
            if isComplete {
                HStack(spacing: SettingsLayout.labelControlGap) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    Text(tryItText).font(.headline)
                    Spacer()
                    Button("Done", action: finish).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(SettingsLayout.windowPadding)
        .frame(width: SettingsLayout.textWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: permissions.accessibilityGranted) { _, isGranted in
            if isGranted { bringForward() }
        }
    }

    private var modelReason: String {
        if case .failed(let message) = model.state { return message }
        if case .installing(let phase, let fraction) = model.state {
            let step = phase.displayName
            return "\(step), \(Int(fraction * 100)) %. If the download stops, it resumes where it left off."
        }
        return "Recognizes speech on this Mac. A one-time download of about 1.23 GB."
    }

    private var tryItText: String {
        let key = settings.configuration.trigger.displayName
        switch settings.configuration.triggerMode {
        case .toggle: return "Try it: press \(key), say something, press \(key) again."
        case .hold, .doubleTapLock: return "Try it: hold \(key) and say something."
        }
    }

    private func requirement<Action: View>(
        _ name: String, reason: String, isGranted: Bool, grantedText: String, @ViewBuilder action: () -> Action
    ) -> some View {
        GridRow(alignment: .center) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isGranted ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: SettingsLayout.captionGap) {
                Text(name).font(.headline)
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if isGranted { Text(grantedText).foregroundStyle(.secondary) } else { action() }
            }
            .controlSize(.large)
        }
    }
}

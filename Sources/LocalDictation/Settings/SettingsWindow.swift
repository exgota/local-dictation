import AppKit
import SwiftUI

@MainActor struct SettingsContext {
    let settings: DictationSettings
    let permissions: PermissionMonitor
    let model: ModelController
    let controller: DictationController
}

@MainActor final class SettingsWindowController: NSWindowController {
    init(context: SettingsContext, showHistory: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: SettingsRootView(context: context, showHistory: showHistory))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.title = "Local Dictation Settings"
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        if window?.isVisible != true, let window {
            let frame = NSScreen.screenWithMouse().visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.maxY - window.frame.height - 120))
        }
        showWindow(nil)
        if let window { ApplicationPresence.shared.bringToFront(window) }
    }
}

private struct SettingsRootView: View {
    let context: SettingsContext
    let showHistory: () -> Void
    @ObservedObject var permissions: PermissionMonitor
    @ObservedObject var model: ModelController

    init(context: SettingsContext, showHistory: @escaping () -> Void) {
        self.context = context
        self.showHistory = showHistory
        permissions = context.permissions
        model = context.model
    }

    var body: some View {
        SettingsView(settings: context.settings,
                     notices: SettingsNotices(accessibilityOff: !permissions.accessibilityGranted,
                                              microphoneOff: !permissions.microphoneGranted, model: model.state),
                     showHistory: showHistory,
                     suspendShortcuts: { context.controller.setHotkeysSuspended($0, for: .shortcutCapture) },
                     previewSound: { context.controller.playStartCuePreview() },
                     openPermission: { permissions.openSystemSettings(anchor: $0) },
                     download: { model.install() }, cancelDownload: { model.cancelInstallation() })
    }
}

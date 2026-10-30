import AppKit
import SwiftUI

/// A small non-activating banner at the bottom center of the screen with the mouse pointer, for conditions that stop
/// the hotkeys from working. It never takes focus and ignores the mouse.
@MainActor final class NoticePanelController {
    private var panel: NSPanel?

    func show(_ message: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: NoticeView(message: message))
        panel.contentView = hosting
        let size = hosting.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 96, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

private struct NoticeView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "lock.fill")
            .font(.callout)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: Capsule())
            .fixedSize()
    }
}

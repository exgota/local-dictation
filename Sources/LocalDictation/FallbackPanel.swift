import AppKit
import SwiftUI

/// Shown when a transcript could not be inserted: the text, already on the clipboard unless it came from a password
/// field, with a Copy button and a Dismiss button. The panel does not activate the app. It stays until the user
/// dismisses it, copies the text, or starts the next dictation.
@MainActor final class FallbackPanelController {
    private var panel: FallbackPanel?

    func show(text: String, reason: String) {
        hide()
        let panel = FallbackPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = FallbackView(
            text: text, reason: reason,
            copy: { [weak self] in
                TextInserter.placeOnClipboard(text)
                self?.hide()
            },
            dismiss: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        let size = hosting.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(x: frame.midX - size.width / 2, y: frame.minY + 96, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Becomes key only when clicked, so the text can be selected, without activating the application.
private final class FallbackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct FallbackView: View {
    let text: String
    let reason: String
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reason).font(.headline)
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss", action: dismiss).controlSize(.large)
                Button("Copy", action: copy).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

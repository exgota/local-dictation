import AppKit
import DictationCore
import MoonRendering
import QuartzCore
import SwiftUI

/// The first-run flow also repairs missing permissions or an unavailable speech model.
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
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.backgroundColor = .windowBackgroundColor
            window.center()
            self.window = window
        }
        bringForward()
    }

    /// The app has no Dock icon, so a window it leaves behind others is hard to find. Called after each step that
    /// takes the user elsewhere.
    func bringForward() {
        guard let window else { return }
        if window.isVisible {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.layoutIfNeeded()
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        // Setup is also the repair path, so it opens even when the moon cannot be drawn.
        let moonIsReady = Self.prepareMoon(in: content)
        window.displayIfNeeded()
        CATransaction.flush()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !moonIsReady
        window.alphaValue = reduceMotion ? 1 : 0
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.22
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    /// SwiftUI lays out the tile before the window is ordered front. Its layer must already contain a frame.
    static func prepareMoon(in view: NSView) -> Bool {
        if let canvas = view as? MoonCanvasView { return canvas.prepareFrame() }
        return view.subviews.contains { prepareMoon(in: $0) }
    }

    func close() {
        window?.close()
    }

    var isVisible: Bool { window?.isVisible == true }
}

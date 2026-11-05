import AppKit
import DictationCore
import MoonRendering
import SwiftUI

struct SetupMoonView: NSViewRepresentable {
    let shape: Int
    let progress: Double
    let ready: Bool

    final class Coordinator {
        var animation: MoonSetupAnimation
        let origin = ProcessInfo.processInfo.systemUptime

        init(shape: Int, ready: Bool) { animation = MoonSetupAnimation(shape: shape, ready: ready) }

        func drawing(at time: TimeInterval) -> MoonCanvasView.Drawing {
            let state = animation.frame(at: time)
            var frame = MoonFrame()
            frame.mode = 2
            frame.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            frame.time = Float(MoonAnimation.shaderTime(elapsed: time - origin,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
            frame.previousShape = Float(state.previous)
            frame.nextShape = Float(state.next)
            frame.transition = Float(state.transition)
            frame.download = Float(state.phase)
            return .shader(frame)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(shape: shape, ready: ready) }

    func makeNSView(context: Context) -> MoonCanvasView {
        let view = MoonCanvasView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        view.drawing = { [coordinator = context.coordinator] time in coordinator.drawing(at: time) }
        return view
    }

    func updateNSView(_ view: MoonCanvasView, context: Context) {
        context.coordinator.animation.update(shape: shape, progress: progress, ready: ready,
                                             at: ProcessInfo.processInfo.systemUptime)
        view.setAccessibilityLabel(shape == 1 ? "Microphone permission" : shape == 2 ? "Function key" : "Speech model download")
        view.setActive(true)
    }

    static func dismantleNSView(_ view: MoonCanvasView, coordinator: Coordinator) { view.setActive(false) }
}

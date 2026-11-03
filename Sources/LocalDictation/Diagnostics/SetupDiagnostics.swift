#if DEBUG || MOON_DIAGNOSTICS
import AppKit
import MoonRendering
import SwiftUI

/// Uses the production content and its real shader drawing without permission, model or recording services.
@MainActor enum SetupDiagnostics {
    static func render(directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, SetupPresentation, String)] = [
            ("microphone", .init(), ""),
            ("microphone_denied", .init(microphoneDenied: true), ""),
            ("accessibility", .init(microphoneGranted: true), ""),
            ("accessibility_waiting", .init(microphoneGranted: true, waitingForAccessibility: true), ""),
        ] + [0, 25, 50, 75, 99].map { percent in
            ("download_\(percent)", SetupPresentation(microphoneGranted: true, accessibilityGranted: true,
                model: .installing(.downloading, fraction: Double(percent) / 100)), "")
        } + [
            ("download_failed", .init(microphoneGranted: true, accessibilityGranted: true, model: .failed("Fixture"), retainedDownloadProgress: 0.37), ""),
            ("try_it_empty", .init(microphoneGranted: true, accessibilityGranted: true, model: .ready), ""),
            ("try_it_listening", .init(microphoneGranted: true, accessibilityGranted: true, model: .ready, listening: true), ""),
            ("try_it_text", .init(microphoneGranted: true, accessibilityGranted: true, model: .ready), "Hello from Local Dictation."),
        ]
        for (name, presentation, text) in states {
            try capture(SetupContentView(presentation: presentation, text: .constant(text)), name: name, directory: directory)
        }
        let metadata = """
        Dark appearance, 2 pixels per point, hidden offscreen windows.
        Production SwiftUI content and MoonCanvasView drawing. No application services started.
        Moon shader time: 1.7 seconds. Shape transition: 1 (settled). Completion phase: 1.25 (400 ms into the ring). Failed download: 37%.
        Try-it text is a diagnostic fixture, not a measured dictation.
        """
        try metadata.write(to: directory.appendingPathComponent("render.txt"), atomically: true, encoding: .utf8)
        print("Rendered \(states.count) setup states without starting application services.")
    }

    private static func capture<Content: View>(_ content: Content, name: String, directory: URL) throws {
        let hosting = NSHostingController(rootView: content.transaction { $0.disablesAnimations = true })
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hosting.view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(nil)
        guard let canvas = canvas(in: hosting.view),
              case .shader(var frame) = canvas.drawing?(ProcessInfo.processInfo.systemUptime) else {
            throw MoonRenderingError.unavailable
        }
        // Pin the production drawing rather than substituting a separate moon implementation.
        frame.time = 1.7
        frame.previousShape = frame.nextShape
        frame.transition = 1
        if frame.download > 1 { frame.download = 1.25 }
        let bitmap = try MoonRenderer.shared.get().render(frame, pixels: 480)
        canvas.setActive(false)
        canvas.layer?.contentsScale = 2
        canvas.layer?.contents = try bitmap.image()
        CATransaction.flush()
        guard let view = window.contentView?.superview,
              let representation = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        representation.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        print("\(name): \(representation.pixelsWide) × \(representation.pixelsHigh)")
        window.close()
    }

    private static func canvas(in view: NSView) -> MoonCanvasView? {
        if let canvas = view as? MoonCanvasView { return canvas }
        return view.subviews.lazy.compactMap { canvas(in: $0) }.first
    }
}
#endif

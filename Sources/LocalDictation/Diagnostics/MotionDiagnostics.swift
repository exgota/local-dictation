#if DEBUG || MOON_DIAGNOSTICS
import AppKit
import DictationCore
import MoonRendering

/// Deterministic samples of the production Metal drawing and coin layers. No application services are constructed.
@MainActor enum MotionDiagnostics {
    static func renderParkWarning(directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let display = HeadsUpDisplayController(observesPasteEvents: false)
        var animation = MoonAnimation()
        animation.listen(at: 0)
        animation.advance(to: 0)
        animation.showSilence(at: 0)
        for index in 0...90 {
            let time = Double(index) / 60
            animation.advance(to: time)
            var frame = MoonFrame()
            frame.time = Float(1.7 + time)
            frame.warning = Float(animation.warning)
            let moon = try MoonRenderer.shared.get().render(frame, pixels: 112)
            let bitmap = try display.captureCoin(bitmap: moon, opacity: 1)
            try bitmap.write(to: directory.appendingPathComponent(String(format: "frame_%03d.png", index)))
        }
        print("Rendered 91 warning frames through MoonAnimation and the production coin layers")
    }

    static func renderParkMiss(directory: URL) throws { try renderPark(directory: directory, pasteFrame: nil) }

    static func renderParkRelease(directory: URL) throws { try renderPark(directory: directory, pasteFrame: 90) }

    private static func renderPark(directory: URL, pasteFrame: Int?) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sourceFrame = MoonFrame()
        sourceFrame.time = 1.7
        sourceFrame.level = 0.68
        let source = try MoonRenderer.shared.get().render(sourceFrame, pixels: 112)
        let smoke = MoonSmoke(bitmap: source)
        let display = HeadsUpDisplayController(observesPasteEvents: false)
        var previousBitmap = source
        var previousOpacity = 1.0
        var samples: [[String: Any]] = []
        for index in 0...240 {
            let time = Double(index) / 60
            let bitmap: MoonBitmap
            let opacity: Double
            var weight = 0.0
            if index < 30 {
                bitmap = source
                opacity = 1
            } else if index < 38 {
                let age = Double(index - 30) / 60
                bitmap = smoke.render(fraction: age / MoonAnimation.smokeDuration)
                opacity = MoonAnimation.smokeOpacity(after: age)
            } else {
                if index == 38 {
                    display.beginPark(motion: try HeadsUpDisplayController.parkMotion(displayed: previousBitmap,
                        opacity: previousOpacity, visible: true, stopped: source, shader: sourceFrame),
                        reason: .focusMoved, clipboardChangeCount: 42)
                }
                // Exercise app-event classification and release. Construct the event without posting it.
                if index == pasteFrame, let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                    characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: VirtualKey.letterV) {
                    display.observePaste(event, clipboardChangeCount: 42, at: time)
                }
                let frame = display.parkFrame(at: time, hovered: false, reduceMotion: false)
                bitmap = frame?.bitmap ?? source
                opacity = frame?.opacity ?? 0
                weight = Double(frame?.shader.park ?? 0)
            }
            samples.append(["frame": index, "seconds": time, "parkWeight": weight, "opacity": opacity,
                            "matchesPreviousBitmap": bitmap.bytes == previousBitmap.bytes])
            let captured = try display.captureCoin(bitmap: bitmap, opacity: opacity)
            try captured.write(to: directory.appendingPathComponent(String(format: "frame_%03d.png", index)))
            previousBitmap = bitmap
            previousOpacity = opacity
        }
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("timing.json"))
        try """
        Offscreen production coin layers, 56 pt coin in a 96 pt canvas at 2x, 192 x 192 pixels.
        241 frames at 60 fps. Normal stop starts at frame 30. Park starts at frame 38 from frame 37's exact bitmap.
        Park entry: 250 ms ease-in-out, frames 38 through 53. Return: 200 ms, then the normal 450 ms smoke exit.
        Command-V: \(pasteFrame.map { "frame \($0), 1.5 s, constructed NSEvent with timestamp 0" } ?? "none; automatic timeout").
        No events are posted. No clipboard, microphone or application services are used.
        These samples verify drawing and release routing, not operating-system event delivery or desktop presentation.
        """.write(to: directory.appendingPathComponent("render.txt"), atomically: true, encoding: .utf8)
        print("Rendered 241 Park frames; stop at frame 30, miss at frame 38, paste frame \(pasteFrame.map(String.init) ?? "none")")
    }

    static func renderShadow(directory: URL) throws {
        let renderer = try MoonRenderer.shared.get()
        let shapes: [(String, Float)] = [("microphone", 1), ("function_key", 2), ("downloading_moon", 0)]
        for (shape, identifier) in shapes {
            let destination = directory.appendingPathComponent(shape)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for index in 0..<90 {
                var frame = MoonFrame()
                frame.mode = 2
                frame.time = Float(index) / 30
                frame.previousShape = identifier
                frame.nextShape = identifier
                frame.transition = 1
                frame.download = identifier == 0 ? 0.52 : 0
                var bitmap = try renderer.render(frame, pixels: 480)
                compositeDarkBackground(&bitmap)
                try bitmap.write(to: destination.appendingPathComponent(String(format: "frame_%03d.png", index)))
            }
        }
        try """
        240 pt setup tiles at 2x, 480 x 480 pixels, dark background RGB 41/255.
        90 frames per shape, 30 fps, 3 seconds. Frame time is index / 30, from 0 through 89/30.
        Shapes: microphone, Function key, downloading moon at a fixed 52%.
        Centered radial shadow, radius 0.56, peak tone 0.16, cubic falloff.
        The shape rises 0.0372 world units over a 3-second cosine cycle; shadow radius falls to 0.47 and tone to 65%.
        Reduce Motion removes the vertical movement and holds the full-size shadow.
        These are offscreen drawing samples, not desktop interaction checks.
        """.write(to: directory.appendingPathComponent("render.txt"), atomically: true, encoding: .utf8)
        print("Rendered 270 shadow frames on \(renderer.device.name)")
    }

    static func renderEntrance(directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        var levels: [Double] = []
        var animation = MoonAnimation()
        animation.listen(at: 0)
        for index in 0..<72 {
            let age = Double(index) / 60
            // A shared synthetic microphone envelope, passed through the live attack/release smoothing.
            let energy = min(1, max(0, 0.52 + 0.32 * sin(age * 13) + 0.12 * sin(age * 31)))
            animation.receive(decibels: -50 + energy * 30)
            animation.advance(to: age)
            levels.append(animation.level)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let display = HeadsUpDisplayController(observesPasteEvents: false)
        for index in 0..<72 {
            let bitmap = try display.captureEntrance(after: Double(index) / 60, level: levels[index])
            try bitmap.write(to: directory.appendingPathComponent(String(format: "frame_%03d.png", index)))
        }
        try JSONEncoder().encode(levels).write(to: directory.appendingPathComponent("voice-levels.json"))
        try """
        Actual 56 pt coin and production layer tree in a 96 pt canvas, at 2x (192 x 192 pixels).
        72 frames, 60 fps, 1.2 seconds from the key press. Frame time is index / 60.
        The synthetic microphone envelope is smoothed by MoonAnimation; values are in voice-levels.json.
        The coin fades over 0.15 seconds; formation rises from 0.72 to 1 over 0.15 seconds.
        Scattered dots pull inward without formation rotation. Voice-level ripples retain their existing motion.
        No microphone or application services were started.
        """.write(to: directory.appendingPathComponent("render.txt"), atomically: true, encoding: .utf8)
        print("Rendered 72 entrance frames")
    }

    private static func compositeDarkBackground(_ bitmap: inout MoonBitmap) {
        for offset in stride(from: 0, to: bitmap.bytes.count, by: 4) {
            let alpha = Int(bitmap.bytes[offset + 3])
            for channel in 0..<3 {
                bitmap.bytes[offset + channel] = UInt8((Int(bitmap.bytes[offset + channel]) * alpha + 41 * (255 - alpha) + 127) / 255)
            }
            bitmap.bytes[offset + 3] = 255
        }
    }
}
#endif

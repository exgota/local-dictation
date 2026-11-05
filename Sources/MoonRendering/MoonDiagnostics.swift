import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import DictationCore
import Foundation
import ImageIO
import Metal

/// Developer-only entry points execute before any application or microphone services are constructed.
@MainActor public enum MoonDiagnostics {
    #if DEBUG || MOON_DIAGNOSTICS
    public static func measureStartup() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let renderer = try MoonRenderer.shared.get()
        let initialized = ProcessInfo.processInfo.systemUptime
        var frame = MoonFrame()
        frame.mode = 2
        frame.previousShape = 1
        frame.nextShape = 1
        frame.time = 2
        let bitmap = try renderer.render(frame, pixels: 416)
        _ = try bitmap.image()
        let finished = ProcessInfo.processInfo.systemUptime
        let report: [String: Any] = [
            "scope": "Fresh process, offscreen 208 pt setup tile at 2x, no application services",
            "renderer_initialization_milliseconds": (initialized - start) * 1000,
            "setup_frame_milliseconds": (finished - initialized) * 1000,
            "first_frame_ready_milliseconds": (finished - start) * 1000,
            "rendered_frames": renderer.submittedFrames,
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
    #endif

    public static func benchmark() throws {
        let renderer = try MoonRenderer.shared.get()
        let view = MoonCanvasView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        view.setActive(true)
        func processSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        func wait(seconds: TimeInterval) {
            let end = Date(timeIntervalSinceNow: seconds)
            let deadline = Timer(fire: end, interval: 0, repeats: false) { _ in }
            RunLoop.main.add(deadline, forMode: .default)
            RunLoop.main.run(until: end)
        }
        let idleStart = processSeconds()
        let idleTime = ProcessInfo.processInfo.systemUptime
        wait(seconds: 10)
        let idleElapsed = ProcessInfo.processInfo.systemUptime - idleTime
        let idleCPU = 100 * (processSeconds() - idleStart) / idleElapsed
        let idleFrames = view.renderedFrames
        let start = ProcessInfo.processInfo.systemUptime
        var durations: [Double] = []
        let activeStart = processSeconds()
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                var frame = MoonFrame()
                frame.time = Float(now - start)
                frame.level = Float(0.31 + 0.31 * sin((now - start) * 4.4))
                view.render(.shader(frame))
                durations.append((ProcessInfo.processInfo.systemUptime - now) * 1000)
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        wait(seconds: 10)
        timer.invalidate()
        let activeElapsed = ProcessInfo.processInfo.systemUptime - start
        let activeCPU = 100 * (processSeconds() - activeStart) / activeElapsed
        durations.sort()
        guard !durations.isEmpty else { throw MoonRenderingError.unavailable }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = [
            "device": renderer.device.name, "scope": "Offscreen display path, synthetic voice levels, no microphone or transcription",
            "idle_seconds": idleElapsed, "idle_cpu_percent": idleCPU, "idle_frames": idleFrames,
            "idle_timer_running": view.timerIsRunning,
            "drawing_seconds": activeElapsed, "drawing_cpu_percent": activeCPU,
            "drawing_frames": view.renderedFrames - idleFrames,
            "frame_median_milliseconds": durations[durations.count / 2],
            "frame_p95_milliseconds": durations[Int(Double(durations.count - 1) * 0.95)],
            "maximum_resident_bytes": usage.ru_maxrss,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private struct Capture: Decodable {
        let name: String
        let pixels: Int
        let parameters: [String: Float]
        let smokeMilliseconds: Double?

        var frame: MoonFrame {
            var frame = MoonFrame()
            frame.time = parameters["time"] ?? 0
            frame.level = parameters["level"] ?? 0
            frame.shake = parameters["shake"] ?? 0
            frame.warning = parameters["warn"] ?? 0
            frame.park = parameters["park"] ?? 0
            frame.formation = parameters["form"] ?? 1
            frame.transition = parameters["mix"] ?? 0
            frame.ditherRate = parameters["rate"] ?? 0
            frame.loading = parameters["loading"] ?? 0
            frame.download = parameters["phase"] ?? 0
            frame.mode = parameters["mode"] ?? 1
            frame.previousShape = parameters["a"] ?? 0
            frame.nextShape = parameters["b"] ?? frame.previousShape
            frame.reduceMotion = (parameters["reduceMotion"] ?? 0) > 0
            return frame
        }
    }

    public static func render(states: URL, directory: URL, capturesTone: Bool = false) throws {
        let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: states))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = try capturesTone ? MoonRenderer(capturesTone: true) : MoonRenderer.shared.get()
        for capture in captures {
            var bitmap = try renderer.render(capture.frame, pixels: capture.pixels)
            if !capturesTone, let milliseconds = capture.smokeMilliseconds, milliseconds > 0 {
                bitmap = MoonSmoke(bitmap: bitmap).render(fraction: milliseconds / 450)
            }
            try bitmap.write(to: directory.appendingPathComponent(capture.name + ".png"))
        }
        if !capturesTone { try generateIcon(directory: directory) }
        print("Rendered \(captures.count) states on \(renderer.device.name)")
        print("Resources: \(try MoonRenderer.resource("Moon", extension: "metal").path)")
    }

    #if DEBUG || MOON_DIAGNOSTICS
    private struct ParkCapture: Decodable {
        let name: String
        let pixels: Int
        let sourceTime: Float
        let sourceLevel: Float
        let smokeFraction: Double
        let age: Double
        let reason: DictationMiss
        let departureAge: Double?
        let reduceMotion: Bool?
        let stopAge: Double?
    }

    public static func renderPark(states: URL, directory: URL,
                                  composite: ((MoonBitmap, Double) throws -> MoonBitmap)? = nil) throws {
        let captures = try JSONDecoder().decode([ParkCapture].self, from: Data(contentsOf: states))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = try MoonRenderer.shared.get()
        var opacities: [String: Double] = [:]
        var checksums: [String: String] = [:]
        for capture in captures {
            var sourceFrame = MoonFrame()
            sourceFrame.time = capture.sourceTime
            sourceFrame.level = capture.sourceLevel
            let source = try renderer.render(sourceFrame, pixels: capture.pixels)
            let stopped = capture.smokeFraction > 0 ? MoonSmoke(bitmap: source).render(fraction: capture.smokeFraction) : source
            let motion = try MoonPark(source: stopped, shader: sourceFrame,
                                  opacity: MoonAnimation.smokeOpacity(after: capture.smokeFraction * MoonAnimation.smokeDuration))
            let result = try motion.render(age: capture.age, reason: capture.reason,
                departureAge: capture.departureAge,
                reduceMotion: capture.reduceMotion ?? false)
            let bitmap: MoonBitmap
            let opacity: Double
            if let stopAge = capture.stopAge {
                bitmap = MoonSmoke(bitmap: source).render(fraction: stopAge / MoonAnimation.smokeDuration)
                opacity = MoonAnimation.smokeOpacity(after: stopAge)
            } else {
                bitmap = result.bitmap
                opacity = result.opacity
            }
            let captured = try composite?(bitmap, opacity) ?? bitmap
            try captured.write(to: directory.appendingPathComponent(capture.name + ".png"))
            opacities[capture.name] = opacity
            checksums[capture.name] = SHA256.hash(data: Data(bitmap.bytes)).map { String(format: "%02x", $0) }.joined()
        }
        let data = try JSONSerialization.data(withJSONObject: opacities, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("opacities.json"))
        try JSONSerialization.data(withJSONObject: checksums, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("checksums.json"))
        print("Rendered \(captures.count) Park frames on \(renderer.device.name)")
    }

    #endif

    /// Writes the moon layer of the Icon Composer icon: a 64 × 64 dithered moon from the application renderer, each dot
    /// enlarged to 14 px without smoothing, centered on a transparent 1024 px canvas. The icon's fill is in its icon.json.
    public static func generateIcon(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var frame = MoonFrame()
        frame.level = 0.55
        frame.ditherRate = -1
        let dots = try MoonRenderer.shared.get().render(frame, pixels: 64)
        var bytes = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
        for row in 0..<64 {
            for column in 0..<64 {
                let sourceOffset = (row * 64 + column) * 4
                guard dots.bytes[sourceOffset + 3] != 0 else { continue }
                for vertical in 0..<14 {
                    for horizontal in 0..<14 {
                        let offset = ((64 + row * 14 + vertical) * 1024 + 64 + column * 14 + horizontal) * 4
                        bytes.replaceSubrange(offset..<(offset + 4), with: dots.bytes[sourceOffset..<(sourceOffset + 4)])
                    }
                }
            }
        }
        try MoonBitmap(width: 1024, height: 1024, bytes: bytes).write(to: directory.appendingPathComponent("moon.png"))
    }
}

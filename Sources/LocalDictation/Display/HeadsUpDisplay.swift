import AppKit
import DictationCore
import MoonRendering

/// A nonactivating 56 pt coin for recording, smoke, and a parked dictation.
@MainActor final class HeadsUpDisplayController {
    private static let bottomMargin: CGFloat = 32
    private let observesPasteEvents: Bool
    private let panel: NSPanel
    private let container = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
    private let coin = NSView(frame: NSRect(x: 20, y: 20, width: 56, height: 56))
    private let canvas = MoonCanvasView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
    struct StoppedAppearance {
        let bitmap: MoonBitmap
        let shader: MoonFrame
        let screen: NSScreen?
    }
    private struct ParkPresentation {
        let motion: MoonPark
        let reason: DictationMiss
        var animation: MoonParkAnimation?
        let clipboardChangeCount: Int?
    }
    private struct PendingPark {
        let reason: DictationMiss
        let announcement: String
        let appearance: StoppedAppearance?
        let clipboardChangeCount: Int?
    }
    var onParkVisibilityChanged: () -> Void = {}
    private var parked: ParkPresentation? { didSet {
        if parked == nil { pasteMonitor.stop() }
        if (parked == nil) != (oldValue == nil) { onParkVisibilityChanged() }
    } }
    private lazy var pasteMonitor = ParkPasteMonitor { [weak self] event in
        self?.observePaste(event, clipboardChangeCount: NSPasteboard.general.changeCount)
    }
    private var parkedShader: MoonFrame?
    private var pendingPark: PendingPark?
    private(set) var stoppedAppearance: StoppedAppearance?
    private var animation = MoonAnimation()
    private var smoke: MoonSmoke?
    private var isAwaitingResult = false
    private var screen: NSScreen?
    private let clockOrigin = ProcessInfo.processInfo.systemUptime
    private var appearedAt: TimeInterval = 0
    /// The entrance starts at the first frame drawn on screen, not when it was requested: preparing a hidden frame
    /// can take longer than the 150 ms entrance on a slow first draw, which made the pill appear fully formed.
    private var entranceStart: TimeInterval?

    init(observesPasteEvents: Bool = true) {
        self.observesPasteEvents = observesPasteEvents
        panel = HeadsUpDisplayPanel(contentRect: container.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        container.wantsLayer = true
        coin.wantsLayer = true
        coin.layer?.backgroundColor = CGColor(red: 20 / 255, green: 20 / 255, blue: 20 / 255, alpha: 0.94)
        coin.layer?.cornerRadius = 28
        coin.layer?.shadowColor = CGColor(gray: 0, alpha: 1)
        coin.layer?.shadowOpacity = 0.28
        coin.layer?.shadowOffset = CGSize(width: 0, height: -5)
        coin.layer?.shadowRadius = 8
        coin.layer?.shadowPath = CGPath(ellipseIn: coin.bounds, transform: nil)
        let edge = CAShapeLayer()
        edge.path = CGPath(ellipseIn: coin.bounds.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        edge.fillColor = nil
        edge.strokeColor = CGColor(gray: 1, alpha: 0.08)
        edge.lineWidth = 1
        coin.layer?.addSublayer(edge)
        coin.addSubview(canvas)
        container.addSubview(coin)
        panel.contentView = container
        canvas.drawing = { [weak self] time in self?.drawing(at: time) }
    }

    var isVisible: Bool { panel.isVisible }

    func showListening(on screen: NSScreen) {
        let now = ProcessInfo.processInfo.systemUptime
        parked = nil
        parkedShader = nil
        pendingPark = nil
        isAwaitingResult = false
        animation.listen(at: now)
        smoke = nil
        stoppedAppearance = nil
        present(on: screen, at: now, label: "Listening")
    }

    func resumeListening() { showListening(on: screen ?? NSScreen.screenWithMouse()) }

    func showTranscribing(waitingForResult: Bool = false) {
        isAwaitingResult = waitingForResult
        if animation.state == .listening || animation.state == .silentMicrophone, let bitmap = canvas.currentBitmap {
            smoke = MoonSmoke(bitmap: bitmap)
            stoppedAppearance = StoppedAppearance(bitmap: bitmap, shader: canvas.currentShader ?? MoonFrame(), screen: screen)
        }
        if waitingForResult { animation.waitForTranscription(at: ProcessInfo.processInfo.systemUptime) }
        else { animation.stop(at: ProcessInfo.processInfo.systemUptime) }
        canvas.setAccessibilityLabel(waitingForResult ? "Transcribing" : "Recording stopped")
        if waitingForResult, !panel.isVisible {
            present(on: screen ?? NSScreen.screenWithMouse(), at: ProcessInfo.processInfo.systemUptime, label: "Transcribing")
        }
        canvas.redraw()
    }

    func showSilentMicrophone() {
        let now = ProcessInfo.processInfo.systemUptime
        animation.showSilence(at: now)
        present(on: panel.isVisible ? (screen ?? NSScreen.screenWithMouse()) : NSScreen.screenWithMouse(), at: now,
                label: "No microphone sound")
    }

    func setLevel(_ decibels: Float) { animation.receive(decibels: Double(decibels)) }

    /// Text delivery can request dismissal, but smoke always completes its own 450 ms lifetime.
    func hide() {
        isAwaitingResult = false
        guard parked == nil else { return }
        animation.dismiss(at: ProcessInfo.processInfo.systemUptime)
        canvas.redraw()
    }

    var isParked: Bool { parked != nil }

    func showPark(reason: DictationMiss, appearance: StoppedAppearance?, clipboardChangeCount: Int?, pasteShortcut: String?) {
        let announcement = reason.announcement(pasteShortcut: pasteShortcut)
        NSAccessibility.post(element: canvas, notification: .announcementRequested, userInfo: [
            .announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        let pending = PendingPark(reason: reason, announcement: announcement, appearance: appearance, clipboardChangeCount: clipboardChangeCount)
        if animation.state == .listening || animation.state == .silentMicrophone {
            pendingPark = pending
            return
        }
        presentPark(pending, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Observe app-delivered events, including synthetic pastes that bypass the HID hotkey tap.
    func observePaste(_ event: NSEvent, clipboardChangeCount: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard ParkPasteMonitor.isCommandPaste(event) else { return }
        // Synthetic sources can supply zero or unrelated timestamps. Use our presentation clock.
        observePaste(clipboardChangeCount: clipboardChangeCount, at: time)
    }

    /// Only a paste of the displayed dictation releases Park.
    func observePaste(clipboardChangeCount: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let parked, parked.animation != nil, parked.clipboardChangeCount == clipboardChangeCount else { return }
        releasePark(at: time)
    }

    func releasePark(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard parked?.reason != .secureField else { return }
        parked?.animation?.leave(.pasted, at: time)
        canvas.redraw()
    }

    func dismissPark() {
        pendingPark = nil
        parked?.animation?.leave(.timeout, at: ProcessInfo.processInfo.systemUptime)
        canvas.redraw()
    }

    private func presentPark(_ pending: PendingPark, at time: TimeInterval) {
        do {
            let renderer = try MoonRenderer.shared.get()
            let pixels = pending.appearance?.bitmap.width ?? max(1, Int(56 * (panel.backingScaleFactor).rounded()))
            var frame = MoonFrame()
            frame.time = 1.7
            let main = try renderer.render(frame, pixels: pixels)
            let motion = try Self.parkMotion(displayed: canvas.currentBitmap, opacity: Double(coin.alphaValue),
                                         visible: panel.isVisible, stopped: pending.appearance?.bitmap ?? main,
                                         shader: panel.isVisible ? (parkedShader ?? canvas.currentShader ?? frame)
                                             : (pending.appearance?.shader ?? frame))
            smoke = nil
            beginPark(motion: motion, reason: pending.reason, clipboardChangeCount: pending.clipboardChangeCount)
            present(on: panel.isVisible ? (screen ?? NSScreen.screenWithMouse())
                    : (pending.appearance?.screen ?? screen ?? NSScreen.screenWithMouse()),
                    at: time, label: pending.announcement, reposition: !panel.isVisible)
        } catch {
            parked = nil
            dictationLog.error("Park could not be drawn: \(error.localizedDescription)")
        }
    }

    /// Preserve the displayed first frame and its shader inputs. A hidden coin starts at zero opacity.
    static func parkMotion(displayed: MoonBitmap?, opacity: Double, visible: Bool, stopped: MoonBitmap, shader: MoonFrame) throws -> MoonPark {
        try MoonPark(source: visible ? (displayed ?? stopped) : stopped, shader: shader, opacity: visible ? opacity : 0)
    }

    func beginPark(motion: MoonPark, reason: DictationMiss, clipboardChangeCount: Int?) {
        pasteMonitor.stop()
        parked = ParkPresentation(motion: motion, reason: reason, clipboardChangeCount: clipboardChangeCount)
        if observesPasteEvents { pasteMonitor.start() }
    }

    func parkFrame(at time: TimeInterval, hovered: Bool, reduceMotion: Bool, startsPresentation: Bool = true) -> MoonPark.Frame? {
        guard var presentation = parked else { return nil }
        // Source capture, shader work, window setup and hidden preparation consume no morph time.
        // The first visible draw owns the presentation clock, even after a delayed run-loop turn.
        var timing = presentation.animation ?? MoonParkAnimation(reason: presentation.reason, at: time)
        timing.setHovered(hovered, at: time)
        timing.advance(to: time)
        if timing.isFinished(at: time, reduceMotion: reduceMotion) {
            parked = nil
            parkedShader = nil
            animation = MoonAnimation()
            if isAwaitingResult { animation.waitForTranscription(at: time) }
            return nil
        }
        do {
            let frame = try presentation.motion.render(age: timing.age(at: time), reason: presentation.reason,
                departureAge: timing.departureAge(at: time), reduceMotion: reduceMotion)
            if startsPresentation {
                presentation.animation = timing
                parked = presentation
            }
            parkedShader = frame.shader
            return frame
        } catch {
            parked = nil
            parkedShader = nil
            animation = MoonAnimation()
            dictationLog.error("Park could not be drawn: \(error.localizedDescription)")
            return nil
        }
    }

    private func present(on screen: NSScreen, at time: TimeInterval, label: String, reposition: Bool = true) {
        self.screen = screen
        canvas.setAccessibilityLabel(label)
        let frame = screen.visibleFrame
        if reposition {
            panel.setFrameOrigin(NSPoint(x: (frame.midX - 48).rounded(), y: frame.minY + Self.bottomMargin - 20))
        }
        if !panel.isVisible {
            appearedAt = time
            entranceStart = nil
            coin.alphaValue = 0
            guard canvas.prepareFrame() else { return }
            panel.orderFrontRegardless()
        }
        canvas.setActive(true)
        canvas.redraw()
    }

    private func drawing(at time: TimeInterval) -> MoonCanvasView.Drawing? {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let frame = parkFrame(at: time,
            hovered: coin.convert(coin.bounds, to: nil).contains(panel.convertPoint(fromScreen: NSEvent.mouseLocation)),
            reduceMotion: reduceMotion, startsPresentation: !canvas.isPreparingFrame) {
            coin.alphaValue = frame.opacity
            return .bitmap(frame.bitmap)
        }
        animation.advance(to: time)
        let age = time - animation.beganAt
        if animation.state == .hidden {
            if let pending = pendingPark {
                pendingPark = nil
                presentPark(pending, at: time)
                if parked != nil { return drawing(at: time) }
            }
            canvas.setActive(false)
            panel.orderOut(nil)
            smoke = nil
            return nil
        }
        if entranceStart == nil, !canvas.isPreparingFrame { entranceStart = time }
        let shownAt = entranceStart ?? time
        let opacity: Double
        switch animation.state {
        case .smoke: opacity = MoonAnimation.smokeOpacity(after: age)
        case .fading: opacity = 1 - Self.bezier(min(1, age / 0.12), first: CGPoint(x: 0.42, y: 0), second: CGPoint(x: 1, y: 1))
        default: opacity = MoonEntranceAnimation.frame(after: time - max(appearedAt, shownAt)).opacity
        }
        coin.alphaValue = opacity
        if animation.state == .smoke, let smoke { return .bitmap(smoke.render(fraction: age / MoonAnimation.smokeDuration)) }
        var frame = MoonFrame()
        frame.time = Float(MoonAnimation.shaderTime(elapsed: time - clockOrigin, reduceMotion: reduceMotion))
        frame.level = Float(animation.level)
        frame.warning = Float(animation.warning)
        let entrance = MoonEntranceAnimation.frame(after: time - max(animation.beganAt, shownAt))
        frame.formation = animation.state == .listening ? Float(entrance.formation) : 1
        if animation.state == .transcribing { frame.loading = 3 }
        return .shader(frame)
    }

    #if DEBUG || MOON_DIAGNOSTICS
    /// Draws the actual coin layer tree at a fixed instant without ordering a window or starting app services.
    func captureEntrance(after age: Double, level: Double, reduceMotion: Bool = false) throws -> MoonBitmap {
        let entrance = MoonEntranceAnimation.frame(after: age)
        var frame = MoonFrame()
        frame.time = Float(MoonAnimation.shaderTime(elapsed: age, reduceMotion: reduceMotion))
        frame.level = Float(level)
        frame.formation = Float(entrance.formation)
        let bitmap = try MoonRenderer.shared.get().render(frame, pixels: 112)
        return try captureCoin(bitmap: bitmap, opacity: entrance.opacity)
    }

    /// Composites a diagnostic bitmap through the production coin layers at 2x.
    func captureCoin(bitmap: MoonBitmap, opacity: Double) throws -> MoonBitmap {
        container.wantsLayer = true
        guard let layer = container.layer, let coinLayer = coin.layer else { throw MoonRenderingError.imageCreation }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = 2
        coinLayer.contentsScale = 2
        canvas.layer?.contentsScale = 2
        canvas.layer?.contents = try bitmap.image()
        coinLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        coinLayer.position = CGPoint(x: 48, y: 48)
        coinLayer.setAffineTransform(.identity)
        coin.alphaValue = opacity
        CATransaction.commit()
        CATransaction.flush()
        panel.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()
        let pixels = 192
        guard let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { throw MoonRenderingError.imageCreation }
        representation.size = container.bounds.size
        container.cacheDisplay(in: container.bounds, to: representation)
        guard let captured = representation.cgImage else { throw MoonRenderingError.imageCreation }
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        try bytes.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: pixels, height: pixels,
                bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw MoonRenderingError.imageCreation }
            context.setFillColor(CGColor(srgbRed: 41.0 / 255, green: 41.0 / 255, blue: 41.0 / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            context.draw(captured, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        return MoonBitmap(width: pixels, height: pixels, bytes: bytes)
    }
    #endif

    private static func bezier(_ progress: Double, first: CGPoint, second: CGPoint) -> Double {
        func coordinate(_ fraction: Double, _ first: Double, _ second: Double) -> Double {
            let complement = 1 - fraction
            return 3 * complement * complement * fraction * first + 3 * complement * fraction * fraction * second + fraction * fraction * fraction
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<20 {
            let middle = (lower + upper) / 2
            if coordinate(middle, first.x, second.x) < progress { lower = middle } else { upper = middle }
        }
        return coordinate((lower + upper) / 2, first.y, second.y)
    }
}

private final class HeadsUpDisplayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

import AppKit
import DictationCore
import MoonRendering

/// A nonactivating 56 pt coin for recording, smoke, and a parked dictation.
@MainActor final class HeadsUpDisplayController {
    private static let bottomMargin: CGFloat = 32
    private let panel: NSPanel
    private let container = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
    private let coin = NSView(frame: NSRect(x: 20, y: 20, width: 56, height: 56))
    private let canvas = MoonCanvasView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
    struct StoppedAppearance {
        let bitmap: MoonBitmap
        let stoppedAt: TimeInterval
        let screen: NSScreen?
    }
    private struct ParkPresentation {
        let motion: MoonPark
        var animation: MoonParkAnimation
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
        if (parked == nil) != (oldValue == nil) { onParkVisibilityChanged() }
    } }
    private var pendingPark: PendingPark?
    private(set) var stoppedAppearance: StoppedAppearance?
    private var animation = MoonAnimation()
    private var smoke: MoonSmoke?
    private var isAwaitingResult = false
    private var screen: NSScreen?
    private let clockOrigin = ProcessInfo.processInfo.systemUptime
    private var appearedAt: TimeInterval = 0

    init() {
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
            stoppedAppearance = StoppedAppearance(bitmap: bitmap, stoppedAt: ProcessInfo.processInfo.systemUptime, screen: screen)
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

    /// Ordinary Command-V passes through the event tap. Only a paste of this dictation releases its satellite.
    func observePaste(clipboardChangeCount: Int) {
        guard let parked, parked.clipboardChangeCount == clipboardChangeCount else { return }
        releasePark()
    }

    func releasePark() {
        guard parked?.animation.reason != .secureField else { return }
        parked?.animation.leave(.pasted, at: ProcessInfo.processInfo.systemUptime)
        canvas.redraw()
    }

    func dismissPark() {
        pendingPark = nil
        parked?.animation.leave(.timeout, at: ProcessInfo.processInfo.systemUptime)
        canvas.redraw()
    }

    private func presentPark(_ pending: PendingPark, at time: TimeInterval) {
        do {
            let renderer = try MoonRenderer.shared.get()
            let pixels = pending.appearance?.bitmap.width ?? max(1, Int(56 * (panel.backingScaleFactor).rounded()))
            var frame = MoonFrame()
            frame.time = 1.7
            let main = try renderer.render(frame, pixels: pixels)
            let satellite = try renderer.render(frame, pixels: MoonPark.satellitePixels(for: pixels))
            let source = pending.appearance?.bitmap ?? main
            let fraction = pending.appearance.map { min(1, max(0, (time - $0.stoppedAt) / MoonAnimation.smokeDuration)) } ?? 1
            parked = ParkPresentation(motion: MoonPark(source: source, main: main, satellite: satellite, smokeFraction: fraction),
                                      animation: MoonParkAnimation(reason: pending.reason, at: time),
                                      clipboardChangeCount: pending.clipboardChangeCount)
            present(on: pending.appearance?.screen ?? screen ?? NSScreen.screenWithMouse(), at: time, label: pending.announcement)
        } catch {
            parked = nil
        }
    }

    private func present(on screen: NSScreen, at time: TimeInterval, label: String) {
        self.screen = screen
        canvas.setAccessibilityLabel(label)
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: (frame.midX - 48).rounded(), y: frame.minY + Self.bottomMargin - 20))
        if !panel.isVisible {
            appearedAt = time
            coin.alphaValue = 0
            guard canvas.prepareFrame() else { return }
            panel.orderFrontRegardless()
        }
        canvas.setActive(true)
        canvas.redraw()
    }

    private func drawing(at time: TimeInterval) -> MoonCanvasView.Drawing? {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if var presentation = parked {
            presentation.animation.setHovered(coin.convert(coin.bounds, to: nil).contains(panel.convertPoint(fromScreen: NSEvent.mouseLocation)), at: time)
            presentation.animation.advance(to: time)
            if presentation.animation.isFinished(at: time, reduceMotion: reduceMotion) {
                parked = nil
                animation = MoonAnimation()
                if isAwaitingResult { animation.waitForTranscription(at: time) }
            } else {
                parked = presentation
                let frame = presentation.motion.render(age: presentation.animation.age(at: time), reason: presentation.animation.reason,
                    departure: presentation.animation.departure, departureAge: presentation.animation.departureAge(at: time), reduceMotion: reduceMotion)
                coin.alphaValue = frame.opacity
                return .bitmap(frame.bitmap)
            }
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
        let opacity: Double
        switch animation.state {
        case .smoke: opacity = MoonAnimation.smokeOpacity(after: age)
        case .fading: opacity = 1 - Self.bezier(min(1, age / 0.12), first: CGPoint(x: 0.42, y: 0), second: CGPoint(x: 1, y: 1))
        default: opacity = Self.bezier(min(1, (time - appearedAt) / 0.15), first: CGPoint(x: 0.16, y: 1), second: CGPoint(x: 0.3, y: 1))
        }
        coin.alphaValue = opacity
        if animation.state == .smoke, let smoke { return .bitmap(smoke.render(fraction: age / MoonAnimation.smokeDuration)) }
        var frame = MoonFrame()
        frame.time = Float(MoonAnimation.shaderTime(elapsed: time - clockOrigin, reduceMotion: reduceMotion))
        frame.level = Float(animation.level)
        frame.warning = Float(animation.warning)
        frame.formation = animation.state == .listening ? Float(min(1, 0.72 + 0.28 * age / 0.15)) : 1
        if animation.state == .transcribing { frame.loading = 3 }
        return .shader(frame)
    }

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

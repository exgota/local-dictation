import AppKit
import Metal

/// A transparent native canvas. The display timer exists only while its window is visible and unoccluded.
@MainActor public final class MoonCanvasView: NSView {
    public enum Drawing {
        case shader(MoonFrame)
        case bitmap(MoonBitmap)
    }
    public var drawing: ((TimeInterval) -> Drawing?)?
    public private(set) var currentBitmap: MoonBitmap?
    public private(set) var renderedFrames = 0
    public private(set) var timerIsRunning = false
    private var requested = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var texture: MTLTexture?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.minificationFilter = .nearest
        layer?.magnificationFilter = .nearest
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateScheduling() } }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    isolated deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateScheduling() }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); texture = nil; redraw() }

    public func setActive(_ active: Bool) {
        requested = active
        updateScheduling()
    }

    private var drawingIsAllowed: Bool {
        requested && !isHiddenOrHasHiddenAncestor && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
    }

    private func updateScheduling() {
        if drawingIsAllowed {
            guard timer == nil else { return }
            redraw()
            guard drawingIsAllowed else { return }
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.redraw() }
            }
            self.timer = timer
            timerIsRunning = true
            RunLoop.main.add(timer, forMode: .common)
        } else {
            timer?.invalidate()
            timer = nil
            timerIsRunning = false
        }
    }

    public func redraw() {
        guard drawingIsAllowed else { updateScheduling(); return }
        guard let drawing = drawing?(ProcessInfo.processInfo.systemUptime) else { return }
        render(drawing)
    }

    /// Prepares the first visible content while the window is still hidden, without starting its display timer.
    @discardableResult public func prepareFrame() -> Bool {
        guard let drawing = drawing?(ProcessInfo.processInfo.systemUptime) else { return false }
        return render(drawing)
    }

    /// The offscreen performance check exercises this same submission and layer update path.
    @discardableResult func render(_ drawing: Drawing) -> Bool {
        do {
            let bitmap: MoonBitmap
            switch drawing {
            case .bitmap(let captured): bitmap = captured
            case .shader(let frame):
                let renderer = try MoonRenderer.shared.get()
                let pixels = max(1, Int(bounds.width * max(1, (window?.backingScaleFactor ?? 2).rounded())))
                if texture?.width != pixels { texture = try renderer.makeTexture(pixels: pixels) }
                try renderer.draw(frame, into: texture!)
                bitmap = renderer.bitmap(from: texture!)
            }
            currentBitmap = bitmap
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = CGFloat(bitmap.width) / max(1, bounds.width)
            layer?.contents = try bitmap.image()
            CATransaction.commit()
            renderedFrames += 1
            return true
        } catch {
            // A failed device is not retried sixty times per second.
            setActive(false)
            setAccessibilityLabel("Visual indicator unavailable")
            return false
        }
    }
}

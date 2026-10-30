import AppKit
import SwiftUI

/// What the heads-up display shows.
@MainActor final class HeadsUpDisplayModel: ObservableObject {
    enum State: Equatable {
        /// Live bars that follow the microphone.
        case listening
        /// The bars stop where they were when recording ended and dim until the text lands.
        case transcribing
        case message(String)
    }

    @Published var state: State = .listening
    /// Drives the scale-in over 150 ms and the scale-out over 120 ms; the panel fades its alpha alongside.
    @Published var isPresented = false
    let meter = LevelMeterAnimator()
}

/// Turns the microphone level into bar heights, one display frame at a time. All bars follow one smoothed loudness,
/// each scaled by a fixed offset, so the bars rise and fall in place instead of scrolling.
@MainActor final class LevelMeterAnimator {
    static let barCount = 20
    static let restingHeight: CGFloat = 4.5
    static let peakHeight: CGFloat = 28
    /// Per-bar height offsets (1.00 is the average). They give the uneven skyline its fixed shape.
    private static let barWeights: [Float] = [
        1.07, 0.99, 1.16, 1.12, 1.15, 0.93, 1.00, 1.06, 1.14, 0.88,
        0.87, 1.19, 1.16, 0.85, 0.86, 0.90, 0.86, 1.05, 0.88, 0.87,
    ]
    /// Levels below -50 dBFS count as room noise, and the bars rest instead of flickering. From there loudness rises
    /// linearly in decibels and reaches full height at -20 dBFS, a firm speaking voice at the built-in microphone.
    private static let floorDecibels: Float = -50
    private static let ceilingDecibels: Float = -20
    /// Each weight is divided by the tallest, so no bar exceeds the peak height at full loudness and the skyline keeps
    /// its shape however loud the voice is.
    private static let tallestWeight = barWeights.max()!
    /// Time constants of the smoothing: 25 ms rising and 40 ms falling. A step reaches 90 % in about 60 ms rising and
    /// about 90 ms falling.
    private static let attackSeconds: Float = 0.025
    private static let releaseSeconds: Float = 0.040
    /// Each bar wobbles up to 8% around its offset so the skyline breathes without losing its shape.
    private static let wobbleAmount: Float = 0.08
    private static let wobbleSeconds: Float = 0.06

    private(set) var heights = Array(repeating: restingHeight, count: barCount)
    private var energy: Float = 0
    private var level: Float = 0
    private var wobble = Array(repeating: Float(0), count: barCount)
    private var wobbleTargets = Array(repeating: Float(0), count: barCount)
    private var lastFrame: Date?

    /// A new microphone level in dBFS, about every 20 ms.
    func receive(_ decibels: Float) {
        energy = min(max((decibels - Self.floorDecibels) / (Self.ceilingDecibels - Self.floorDecibels), 0), 1)
        for index in wobbleTargets.indices { wobbleTargets[index] = .random(in: -1...1) }
    }

    func reset() {
        energy = 0
        level = 0
        wobble = Array(repeating: 0, count: Self.barCount)
        heights = Array(repeating: Self.restingHeight, count: Self.barCount)
        lastFrame = nil
    }

    /// Advances the smoothing to `date` and returns the heights to draw. When `advancing` is false the heights stay as
    /// they are, and the first frame after that does not jump.
    func heights(at date: Date, advancing: Bool) -> [CGFloat] {
        guard advancing else {
            lastFrame = nil
            return heights
        }
        let elapsed = Float(min(max(lastFrame.map { date.timeIntervalSince($0) } ?? 0, 0), 0.05))
        lastFrame = date
        let timeConstant = energy > level ? Self.attackSeconds : Self.releaseSeconds
        level += (energy - level) * (1 - exp(-elapsed / timeConstant))
        if level < 0.002 { level = 0 }
        let wobbleStep = 1 - exp(-elapsed / Self.wobbleSeconds)
        for index in heights.indices {
            wobble[index] += (wobbleTargets[index] - wobble[index]) * wobbleStep
            let weight = Self.barWeights[index] / Self.tallestWeight
            let scaled = level * weight * (1 + Self.wobbleAmount * wobble[index]) / (1 + Self.wobbleAmount)
            heights[index] = Self.restingHeight + (Self.peakHeight - Self.restingHeight) * CGFloat(min(max(scaled, 0), 1))
        }
        return heights
    }
}

/// A pill at the bottom center of the screen with the mouse pointer: 20 bars that move with the voice while
/// recording, frozen and dimmed while transcribing, and no words except for a rare message. It is a non-activating
/// panel that cannot become key and ignores the mouse, so it never takes focus from the application being dictated
/// into. It scales and fades in over 150 ms and out over 120 ms.
@MainActor final class HeadsUpDisplayController {
    private static let appearDuration: TimeInterval = 0.15
    private static let disappearDuration: TimeInterval = 0.12
    private static let bottomMargin: CGFloat = 32
    /// Exponential ease-out with control points (0.16, 1, 0.3, 1), used for the panel's fade-in. The SwiftUI scale-in
    /// uses the same control points.
    private static let easing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    private let model = HeadsUpDisplayModel()
    private let panel: NSPanel
    private let hosting: NSHostingView<HeadsUpDisplayView>
    private var screen: NSScreen?

    init() {
        hosting = NSHostingView(rootView: HeadsUpDisplayView(model: model))
        // The pill is dark in Light and Dark mode, so its blue and its message text resolve as on a dark surface.
        hosting.appearance = NSAppearance(named: .darkAqua)
        panel = HeadsUpDisplayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    /// Live bars. A dictation started while the previous one is still transcribing continues from the frozen bars
    /// without fading out and back in.
    func showListening(on screen: NSScreen) {
        if !panel.isVisible { model.meter.reset() }
        show(.listening, on: screen)
    }

    func showTranscribing() {
        show(.transcribing, on: screen ?? Self.screenWithMouse())
    }

    func showMessage(_ message: String, on screen: NSScreen) {
        show(.message(message), on: screen)
    }

    /// The microphone level in dBFS.
    func setLevel(_ decibels: Float) {
        guard model.state == .listening else { return }
        model.meter.receive(decibels)
    }

    func hide() {
        guard panel.isVisible else { return }
        withAnimation(.easeIn(duration: Self.disappearDuration)) { model.isPresented = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.disappearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        }
    }

    static func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func show(_ state: HeadsUpDisplayModel.State, on screen: NSScreen) {
        self.screen = screen
        let appearing = !panel.isVisible || panel.alphaValue < 1
        if !panel.isVisible { model.isPresented = false }
        model.state = state
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(x: (frame.midX - size.width / 2).rounded(), y: frame.minY + Self.bottomMargin, width: size.width, height: size.height),
            display: true)
        guard appearing else { return }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: Self.appearDuration)) { model.isPresented = true }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.appearDuration
            context.timingFunction = Self.easing
            panel.animator().alphaValue = 1
        }
    }
}

private final class HeadsUpDisplayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct HeadsUpDisplayView: View {
    static let size = CGSize(width: 124, height: 50)
    private static let fill = Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255).opacity(0.94)

    @ObservedObject var model: HeadsUpDisplayModel

    var body: some View {
        content
            .background(Self.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .scaleEffect(model.isPresented ? 1 : 0.94)
            .fixedSize()
            .padding(4)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .listening, .transcribing:
            LevelMeter(meter: model.meter, isLive: model.state == .listening && model.isPresented)
                .opacity(model.state == .transcribing ? 0.5 : 1)
                .animation(.easeOut(duration: 0.16), value: model.state)
                .frame(width: Self.size.width, height: Self.size.height)
        case .message(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .frame(height: Self.size.height)
        }
    }
}

/// Twenty bars, 2 pt wide at a pitch of 4.5 pt from one bar's start to the next, vertically centered and snapped to
/// device pixels, redrawn at the display's refresh rate while live.
private struct LevelMeter: View {
    private static let barWidth: CGFloat = 2
    private static let barPitch: CGFloat = 4.5

    let meter: LevelMeterAnimator
    let isLive: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isLive)) { timeline in
            let heights = meter.heights(at: timeline.date, advancing: isLive)
            let scale = displayScale
            Canvas { context, size in
                let stripWidth = CGFloat(heights.count - 1) * Self.barPitch + Self.barWidth
                let start = (size.width - stripWidth) / 2
                for (index, height) in heights.enumerated() {
                    let x = ((start + CGFloat(index) * Self.barPitch) * scale).rounded() / scale
                    let bar = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
                    context.fill(Path(roundedRect: bar, cornerRadius: Self.barWidth / 2), with: .color(Color(nsColor: .systemBlue)))
                }
            }
        }
    }
}

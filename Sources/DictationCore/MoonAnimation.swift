import Foundation

/// Timing for listening, transcribing, and the stop animation.
public struct MoonAnimation: Sendable {
    public enum State: Sendable { case hidden, listening, silentMicrophone, transcribing, smoke, fading }
    public static let smokeDuration = 0.450
    public static let refusalDuration = 0.240
    public static let setupTransitionDuration = 0.950
    public private(set) var state: State = .hidden
    public private(set) var beganAt: Double = 0
    public private(set) var level: Double = 0
    public private(set) var warning: Double = 0
    private var energy: Double = 0
    private var previousFrame: Double?

    public init() {}

    public mutating func receive(decibels: Double) {
        energy = min(max((decibels + 50) / 30, 0), 1)
    }

    public mutating func listen(at time: Double) {
        if state == .listening { return }
        if state == .hidden { level = 0; energy = 0; warning = 0; previousFrame = nil }
        state = .listening
        beganAt = time
    }

    public mutating func showSilence(at time: Double) {
        if state == .silentMicrophone { return }
        if state == .hidden { warning = 0; previousFrame = nil }
        level = 0
        state = .silentMicrophone
        beganAt = time
    }

    /// Retains the text-free orbit while a recording made during model loading awaits its result.
    public mutating func waitForTranscription(at time: Double) {
        guard state != .transcribing else { return }
        state = .transcribing
        beganAt = time
        level = 0
        warning = 0
    }

    /// Repeated delivery updates cannot restart smoke or bring an already hidden coin back.
    public mutating func stop(at time: Double) {
        guard state == .listening || state == .silentMicrophone else { return }
        state = state == .silentMicrophone ? .fading : .smoke
        beganAt = time
    }

    public mutating func dismiss(at time: Double) {
        guard state != .hidden, state != .smoke, state != .fading else { return }
        state = .fading
        beganAt = time
    }

    public mutating func advance(to time: Double) {
        let elapsed = min(0.05, max(0, previousFrame.map { time - $0 } ?? 0.016))
        previousFrame = time
        if state == .listening || state == .silentMicrophone {
            let target = state == .listening ? energy : 0
            level += (target - level) * (1 - exp(-elapsed / (target > level ? 0.025 : 0.040)))
            let targetWarning: Double = state == .silentMicrophone ? 1 : 0
            warning += (targetWarning - warning) * (1 - exp(-elapsed / 0.075))
        }
        if (state == .smoke && time >= beganAt + Self.smokeDuration) || (state == .fading && time >= beganAt + 0.120) {
            state = .hidden
        }
    }

    public static func refusalShake(after seconds: Double) -> Double {
        let fraction = min(1, max(0, seconds) / refusalDuration)
        return fraction < 1 ? 0.09 * sin(fraction * .pi * 4) * (1 - fraction) : 0
    }

    public static func smokeOpacity(after seconds: Double) -> Double {
        1 - min(1, max(0, (seconds / smokeDuration - 0.62) / 0.38))
    }

    public static func setupTransition(after seconds: Double) -> Double {
        let fraction = min(1, max(0, seconds / setupTransitionDuration))
        return fraction < 0.5 ? 4 * fraction * fraction * fraction : 1 - pow(-2 * fraction + 2, 3) / 2
    }

    /// Reduce Motion freezes the shader clock at two seconds, as in the approved drawing.
    public static func shaderTime(elapsed: Double, reduceMotion: Bool) -> Double { reduceMotion ? 2 : elapsed }
}

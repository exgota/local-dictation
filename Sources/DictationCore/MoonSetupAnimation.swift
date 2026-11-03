import Foundation

public struct MoonSetupAnimation: Sendable {
    public private(set) var previousShape: Int
    public private(set) var nextShape: Int
    private var transitionAt: Double = -.infinity
    private var completedAt: Double?
    private var wasReady: Bool
    private var progress: Double = 0

    public init(shape: Int, ready: Bool) {
        previousShape = shape
        nextShape = shape
        wasReady = ready
        progress = ready ? 1.5 : 0
    }

    public mutating func update(shape: Int, progress: Double, ready: Bool, at time: Double) {
        self.progress = progress
        if ready && !wasReady && nextShape == 0 { completedAt = time }
        if !ready || shape == 1 { completedAt = nil }
        wasReady = ready
        if completedAt == nil { aim(shape, at: time) }
    }

    public mutating func frame(at time: Double) -> (previous: Int, next: Int, transition: Double, phase: Double) {
        var phase = progress
        if let completedAt {
            phase = 1 + 0.5 * min(1, max(0, (time - completedAt) / 0.8))
            if time - completedAt > 1.8 { aim(2, at: time) }
        }
        return (previousShape, nextShape, MoonAnimation.setupTransition(after: time - transitionAt), phase)
    }

    private mutating func aim(_ shape: Int, at time: Double) {
        guard nextShape != shape else { return }
        previousShape = nextShape
        nextShape = shape
        transitionAt = time
    }
}

import Foundation

/// Tells a dead microphone from a quiet room. A working microphone always carries some noise, so only a level far below
/// any room counts as no signal, and it has to last long enough that a dropped buffer does not raise the warning.
public struct MicrophoneSilenceMonitor: Sendable {
    /// Treat an extremely low input level as a silent microphone.
    public static let silenceDecibels: Float = -100
    public static let warningDelay: TimeInterval = 3

    private var lastSignalTime: TimeInterval

    /// `startTime` counts as signal, so a microphone that never delivers audio raises the warning like a silent one.
    public init(startTime: TimeInterval) { lastSignalTime = startTime }

    public mutating func receive(decibels: Float, at time: TimeInterval) {
        if decibels > Self.silenceDecibels { lastSignalTime = max(lastSignalTime, time) }
    }

    public func isSilent(at time: TimeInterval) -> Bool { time - lastSignalTime >= Self.warningDelay }
}

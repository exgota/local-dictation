import Foundation

/// Holds one overlapping analysis window and advances by the hop after each decode.
public struct SpeechWindowBuffer: Sendable {
    public static let windowSampleCount = SpeechAudioFormat.sampleRate * 29 / 2
    public static let hopSampleCount = SpeechAudioFormat.sampleRate * 29 / 8

    private var samples: [Float] = []
    public private(set) var startSample = 0
    public private(set) var latestWindowEnd = 0

    public init() {}
    public var count: Int { samples.count }
    public var hasFullWindow: Bool { samples.count >= Self.windowSampleCount }
    public mutating func append(contentsOf samples: ArraySlice<Float>) { self.samples.append(contentsOf: samples) }
    public func window() -> [Float] { Array(samples.prefix(Self.windowSampleCount)) }

    /// A reset advances by the entire window after an unavailable timing or a long silence.
    public mutating func advance(reset: Bool = false) {
        let length = min(samples.count, Self.windowSampleCount)
        latestWindowEnd = startSample + length
        let consumed = reset ? length : min(Self.hopSampleCount, length)
        samples.removeFirst(consumed)
        startSample += consumed
    }

    /// The last window is needed only when there is audio beyond the last full window.
    public var needsFinalWindow: Bool { !samples.isEmpty && startSample + samples.count > latestWindowEnd }
}

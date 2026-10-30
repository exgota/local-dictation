import Foundation

/// Supplies each chunk with adjacent audio while keeping its core sample boundaries.
public struct SpeechGuardBandBuffer: Sendable {
    public struct Chunk: Sendable {
        public let samples: [Float]
        public let coreRange: Range<Int>
    }

    private struct Pending: Sendable {
        var left: [Float]
        var core: [Float]
        var right: [Float]
    }

    public static let leftGuardSampleCount = SpeechAudioFormat.sampleRate * 5 / 4
    public static let rightGuardSampleCount = SpeechAudioFormat.sampleRate * 5 / 4

    private var history: [Float] = []
    private var pending: Pending?
    private var hasPreviousChunk = false

    public init() {}

    public mutating func schedule(core: [Float], following: [Float]) {
        precondition(pending == nil)
        pending = Pending(left: history, core: core, right: Array(following.prefix(Self.rightGuardSampleCount)))
        hasPreviousChunk = true
        remember(core)
    }

    public mutating func appendFollowing(_ samples: ArraySlice<Float>) {
        guard let count = pending.map({ Self.rightGuardSampleCount - $0.right.count }), count > 0 else { return }
        pending?.right.append(contentsOf: samples.prefix(count))
    }

    public mutating func takeReady() -> Chunk? {
        guard let pending, pending.right.count == Self.rightGuardSampleCount else { return nil }
        self.pending = nil
        return Chunk(samples: pending.left + pending.core + pending.right,
                     coreRange: pending.left.count..<(pending.left.count + pending.core.count))
    }

    /// At stop, include all audio after an unfinished cut in the last core instead of waiting for a right guard.
    public mutating func takeFinalPending() -> Chunk? {
        guard let pending else { return nil }
        self.pending = nil
        return Chunk(samples: pending.left + pending.core + pending.right,
                     coreRange: pending.left.count..<(pending.left.count + pending.core.count + pending.right.count))
    }

    public func finalChunk(core: [Float]) -> Chunk {
        Chunk(samples: history + core, coreRange: history.count..<(history.count + core.count))
    }

    public mutating func discard(_ samples: [Float]) {
        if hasPreviousChunk { remember(samples) }
    }

    private mutating func remember(_ samples: [Float]) {
        history = Array((history + samples).suffix(Self.leftGuardSampleCount))
    }
}

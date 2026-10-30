import Foundation

/// Keeps sample boundaries aligned with the planner's frames when a cut falls inside a frame.
public struct SpeechChunkBuffer: Sendable {
    private var samples: [Float] = []
    /// Samples already removed from the beginning of the oldest retained frame.
    private var removedSampleCount = 0
    private let maximumChunkSamples: Int
    private static let energyWindowSamples = SpeechAudioFormat.sampleRate / 25

    public init(maximumChunkFrames: Int = SpeechChunkPlanner.Configuration.standard.maximumChunkFrames) {
        maximumChunkSamples = maximumChunkFrames * SpeechChunkPlanner.frameSampleCount
    }

    public mutating func append(contentsOf newSamples: ArraySlice<Float>) {
        samples.append(contentsOf: newSamples)
    }

    /// Returns the chunk and the number of complete frames before the cut. Later samples remain buffered.
    public mutating func cut(_ cut: SpeechChunkPlanner.Cut) -> (samples: [Float], frameCount: Int) {
        precondition(!samples.isEmpty)
        let frameSize = SpeechChunkPlanner.frameSampleCount
        let limit = min(samples.count, maximumChunkSamples)
        let start = min(max(0, cut.searchFrames.lowerBound * frameSize - removedSampleCount), limit - 1)
        let end = max(start + 1, min(cut.searchFrames.upperBound * frameSize - removedSampleCount, limit))
        let sampleCount = quietestSample(in: start..<end)
        let frameCount = (sampleCount + removedSampleCount) / frameSize
        removedSampleCount += sampleCount - frameCount * frameSize
        let chunk = Array(samples.prefix(sampleCount))
        samples.removeFirst(sampleCount)
        return (chunk, frameCount)
    }

    public mutating func take(frameCount: Int) -> [Float] {
        let count = min(max(0, frameCount * SpeechChunkPlanner.frameSampleCount - removedSampleCount), samples.count)
        let chunk = Array(samples.prefix(count))
        samples.removeFirst(count)
        removedSampleCount = 0
        return chunk
    }

    public func prefix(_ count: Int) -> [Float] {
        Array(samples.prefix(count))
    }

    @discardableResult
    public mutating func discard(frameCount: Int) -> [Float] {
        take(frameCount: frameCount)
    }

    private func quietestSample(in range: Range<Int>) -> Int {
        let window = min(Self.energyWindowSamples, range.count)
        let middle = (range.lowerBound + range.upperBound) / 2
        var energy = 0.0
        for index in range.lowerBound..<(range.lowerBound + window) {
            let sample = Double(samples[index])
            energy += sample * sample
        }
        var bestEnergy = energy
        var best = range.lowerBound + window / 2
        let lastStart = range.upperBound - window
        if lastStart > range.lowerBound {
            for start in (range.lowerBound + 1)...lastStart {
                let leaving = Double(samples[start - 1])
                let entering = Double(samples[start + window - 1])
                energy = max(0, energy + entering * entering - leaving * leaving)
                let candidate = start + window / 2
                if energy < bestEnergy || (energy == bestEnergy && abs(candidate - middle) < abs(best - middle)) {
                    bestEnergy = energy
                    best = candidate
                }
            }
        }
        return best
    }
}

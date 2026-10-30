import Foundation

/// Splits a live recording into chunks for the model's 15-second path, using voice activity per 256 ms frame.
///
/// Leading and trailing silence are trimmed to the configured padding. After the minimum chunk length, a pause can
/// propose a cut. At the maximum length, the least speech-like recent frame proposes a forced cut. The caller selects
/// a sample within the proposed frames and confirms how many complete frames precede that sample.
public struct SpeechChunkPlanner: Sendable {
    public struct Cut: Equatable, Sendable {
        /// Candidate frames, relative to the oldest retained frame. The upper bound is exclusive.
        public let searchFrames: Range<Int>
    }

    public enum Command: Equatable, Sendable {
        /// Select a sample within these frames, then call `completeCut(frameCount:)` before adding another frame.
        case cut(Cut)
        /// Transcribe the oldest `frameCount` retained frames, then drop them.
        case emit(frameCount: Int)
        /// Drop the oldest `frameCount` retained frames without transcribing.
        case discard(frameCount: Int)
    }

    public struct Configuration: Sendable {
        /// Probability at which speech starts.
        public var speechThreshold: Float
        /// Once speech has started, frames down to this probability still count as speech (hysteresis), so soft word
        /// endings are not trimmed.
        public var continuationThreshold: Float
        /// Frames kept before the first speech.
        public var paddingFrames: Int
        /// Frames kept after the last speech when the recording ends.
        public var trailingPaddingFrames: Int
        public var minimumChunkFrames: Int
        /// From this length, one non-speech frame is enough to propose a cut.
        public var singleFramePauseChunkFrames: Int
        public var maximumChunkFrames: Int
        /// How far back a forced cut may look for a quieter frame.
        public var forcedCutSearchFrames: Int

        /// 256 ms frames. From 31 frames (7.936 seconds), two quiet frames propose a cut, and from 42 frames (10.752
        /// seconds), one does. No core exceeds 47 frames (12.032 seconds), which leaves room for both guards in the
        /// model's window. The padding is 512 ms before speech and 768 ms after the last speech.
        public static let standard = Configuration(
            speechThreshold: 0.5, continuationThreshold: 0.35, paddingFrames: 2, trailingPaddingFrames: 3,
            minimumChunkFrames: 31, singleFramePauseChunkFrames: 42, maximumChunkFrames: 47, forcedCutSearchFrames: 12)

        public init(
            speechThreshold: Float, continuationThreshold: Float, paddingFrames: Int, trailingPaddingFrames: Int,
            minimumChunkFrames: Int, singleFramePauseChunkFrames: Int, maximumChunkFrames: Int, forcedCutSearchFrames: Int
        ) {
            self.speechThreshold = speechThreshold
            self.continuationThreshold = continuationThreshold
            self.paddingFrames = paddingFrames
            self.trailingPaddingFrames = trailingPaddingFrames
            self.minimumChunkFrames = minimumChunkFrames
            self.singleFramePauseChunkFrames = singleFramePauseChunkFrames
            self.maximumChunkFrames = maximumChunkFrames
            self.forcedCutSearchFrames = forcedCutSearchFrames
        }
    }

    public static let frameSampleCount = 4096
    public static let frameDuration: TimeInterval = Double(frameSampleCount) / Double(SpeechAudioFormat.sampleRate)

    public let configuration: Configuration
    /// Speech probabilities of the retained frames, oldest first.
    private var retained: [Float] = []
    private var lastSpeechIndex: Int?
    private var awaitingCut = false
    /// Frames since the most recent speech frame anywhere in the recording, or since the start before the first speech.
    /// Used for the optional silence auto-stop.
    public private(set) var framesSinceSpeech = 0
    public private(set) var hasDetectedSpeech = false

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    public var trailingSilenceDuration: TimeInterval { Double(framesSinceSpeech) * Self.frameDuration }

    public mutating func addFrame(speechProbability probability: Float, allowCut: Bool = true) -> [Command] {
        precondition(!awaitingCut)
        let isSpeech = probability >= (lastSpeechIndex == nil ? configuration.speechThreshold : configuration.continuationThreshold)
        retained.append(probability)
        let index = retained.count - 1
        if isSpeech {
            lastSpeechIndex = index
            framesSinceSpeech = 0
            hasDetectedSpeech = true
        } else {
            framesSinceSpeech += 1
        }

        guard lastSpeechIndex != nil else {
            let excess = retained.count - configuration.paddingFrames
            guard excess > 0 else { return [] }
            retained.removeFirst(excess)
            return [.discard(frameCount: excess)]
        }
        guard allowCut else { return [] }
        let requiredPauseFrames = retained.count >= configuration.singleFramePauseChunkFrames ? 1 : 2
        if !isSpeech && retained.count >= configuration.minimumChunkFrames && framesSinceSpeech >= requiredPauseFrames {
            let start = max(0, retained.count - framesSinceSpeech)
            awaitingCut = true
            return [.cut(Cut(searchFrames: start..<retained.count))]
        }
        if retained.count >= configuration.maximumChunkFrames {
            let searchStart = max(configuration.minimumChunkFrames / 2, retained.count - configuration.forcedCutSearchFrames)
            let quietest = (searchStart..<retained.count).min { retained[$0] < retained[$1] } ?? index
            let threshold = configuration.continuationThreshold
            var start = quietest
            var end = quietest + 1
            if retained[quietest] < threshold {
                while start > 0 && retained[start - 1] < threshold { start -= 1 }
                while end < retained.count && retained[end] < threshold { end += 1 }
            }
            let pauseFrames = retained[quietest] < threshold ? end - start : 0
            if pauseFrames == 0 {
                start = max(searchStart, start - 1)
                end = min(retained.count, end + 1)
            }
            awaitingCut = true
            return [.cut(Cut(searchFrames: start..<end))]
        }
        return []
    }

    /// Confirms the complete frames before the selected sample. The containing frame stays with the caller.
    public mutating func completeCut(frameCount: Int) {
        precondition(awaitingCut && frameCount >= 0 && frameCount <= retained.count)
        retained.removeFirst(frameCount)
        let threshold = configuration.continuationThreshold
        lastSpeechIndex = retained.lastIndex { $0 >= threshold }
        awaitingCut = false
    }

    /// The recording ended. Emits the final chunk trimmed of trailing silence, or discards it if it holds no speech.
    public mutating func finish() -> [Command] {
        precondition(!awaitingCut)
        defer {
            retained = []
            lastSpeechIndex = nil
        }
        guard !retained.isEmpty else { return [] }
        guard let lastSpeechIndex else { return [.discard(frameCount: retained.count)] }
        let keep = min(retained.count, lastSpeechIndex + 1 + configuration.trailingPaddingFrames)
        var commands: [Command] = [.emit(frameCount: keep)]
        if keep < retained.count { commands.append(.discard(frameCount: retained.count - keep)) }
        return commands
    }
}

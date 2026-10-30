import Foundation

/// Splits a live recording into chunks for the model's 15-second path, using voice activity per 256 ms frame.
///
/// - Leading silence beyond `paddingFrames` before the first speech is discarded.
/// - Once a chunk is at least `minimumChunkFrames` long, it is cut at the next non-speech frame, so words are not split.
/// - A chunk never exceeds `maximumChunkFrames`. Without a pause, it is cut at the least speech-like recent frame.
/// - At the end, trailing silence beyond `trailingPaddingFrames` after the last speech is dropped. A chunk without
///   speech is discarded entirely, so a press with no speech produces no text.
///
/// Commands always refer to the oldest retained frames. The caller keeps only the frames that have not yet been emitted
/// or discarded.
public struct SpeechChunkPlanner: Sendable {
    public enum Command: Equatable, Sendable {
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
        public var maximumChunkFrames: Int
        /// How far back a forced cut may look for a quieter frame.
        public var forcedCutSearchFrames: Int

        /// 256 ms frames. A pause cuts a chunk once it holds 31 frames (7.936 seconds). No chunk exceeds 56 frames
        /// (14.336 seconds). The padding is 512 ms before speech and 768 ms after the last speech.
        public static let standard = Configuration(
            speechThreshold: 0.5, continuationThreshold: 0.35, paddingFrames: 2, trailingPaddingFrames: 3,
            minimumChunkFrames: 31, maximumChunkFrames: 56, forcedCutSearchFrames: 12)

        public init(
            speechThreshold: Float, continuationThreshold: Float, paddingFrames: Int, trailingPaddingFrames: Int,
            minimumChunkFrames: Int, maximumChunkFrames: Int, forcedCutSearchFrames: Int
        ) {
            self.speechThreshold = speechThreshold
            self.continuationThreshold = continuationThreshold
            self.paddingFrames = paddingFrames
            self.trailingPaddingFrames = trailingPaddingFrames
            self.minimumChunkFrames = minimumChunkFrames
            self.maximumChunkFrames = maximumChunkFrames
            self.forcedCutSearchFrames = forcedCutSearchFrames
        }
    }

    public static let frameSampleCount = 4096
    public static let frameDuration: TimeInterval = 4096.0 / 16_000

    public let configuration: Configuration
    /// Speech probabilities of the retained frames, oldest first.
    private var retained: [Float] = []
    private var lastSpeechIndex: Int?
    /// Frames since the most recent speech frame anywhere in the recording, or since the start before the first speech.
    /// Used for the optional silence auto-stop.
    public private(set) var framesSinceSpeech = 0
    public private(set) var hasDetectedSpeech = false

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    public var trailingSilenceDuration: TimeInterval { Double(framesSinceSpeech) * Self.frameDuration }

    public mutating func addFrame(speechProbability probability: Float) -> [Command] {
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
            // Before any speech in this chunk, keep only the padding that may hold the onset of the first word.
            let excess = retained.count - configuration.paddingFrames
            guard excess > 0 else { return [] }
            retained.removeFirst(excess)
            return [.discard(frameCount: excess)]
        }
        if !isSpeech && retained.count >= configuration.minimumChunkFrames {
            return [cut(after: index)]
        }
        if retained.count >= configuration.maximumChunkFrames {
            let searchStart = max(configuration.minimumChunkFrames / 2, retained.count - configuration.forcedCutSearchFrames)
            let quietest = (searchStart..<retained.count).min { retained[$0] < retained[$1] } ?? index
            return [cut(after: quietest)]
        }
        return []
    }

    /// The recording ended. Emits the final chunk trimmed of trailing silence, or discards it if it holds no speech.
    public mutating func finish() -> [Command] {
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

    /// Emits frames up to and including `index`, keeping the rest as the start of the next chunk.
    private mutating func cut(after index: Int) -> Command {
        let count = index + 1
        retained.removeFirst(count)
        let threshold = configuration.continuationThreshold
        lastSpeechIndex = retained.lastIndex { $0 >= threshold }
        return .emit(frameCount: count)
    }
}

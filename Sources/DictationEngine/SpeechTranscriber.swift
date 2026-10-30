import CoreML
import DictationCore
import FluidAudio
import Foundation

public enum EncoderComputeTarget: String, CaseIterable, Sendable {
    case neuralEngine
    case graphicsProcessor

    var computeUnits: MLComputeUnits {
        switch self {
        case .neuralEngine: return .cpuAndNeuralEngine
        case .graphicsProcessor: return .cpuAndGPU
        }
    }
}

public enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case audioTooShort

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "The speech model is not loaded."
        case .audioTooShort: return "The recording is too short to transcribe."
        }
    }
}

public struct TranscriptionOutcome: Sendable {
    public let text: String
    public let tokenTimings: [TokenTiming]?
    public let encoderFunction: String
    public let audioSeconds: Double
    public let processingSeconds: Double
}

/// Loads the Bark 3.0 Pro Core ML components once and transcribes mono 16 kHz Float32 audio. It follows the official
/// runner (`runtime/coreml/Sources/main.swift` at the pinned model revision): 0.25 s of leading silence; the `short8`
/// encoder function for audio up to 8 s including that silence, otherwise `full15` with FluidAudio's long-audio
/// handling; the preprocessor, decoder and joint on the CPU; and greedy decoding with no biasing or language filtering.
/// The encoder runs on the compute units that `EncoderComputeTarget` selects.
public actor SpeechTranscriber {
    static let leadingSilenceSamples = SpeechAudioFormat.sampleRate / 4
    static let shortFunctionLimitSamples = SpeechAudioFormat.sampleRate * 8
    private static let shortFunctionName = "short8"
    private static let fullFunctionName = "full15"

    private let compiledDirectory: URL
    private let vocabularyURL: URL
    private let computeTarget: EncoderComputeTarget

    private var shortManager: AsrManager?
    private var fullManager: AsrManager?
    private var sharedComponents: (preprocessor: MLModel, decoder: MLModel, joint: MLModel, vocabulary: [Int: String])?

    public init(compiledDirectory: URL, vocabularyURL: URL, computeTarget: EncoderComputeTarget) {
        self.compiledDirectory = compiledDirectory
        self.vocabularyURL = vocabularyURL
        self.computeTarget = computeTarget
    }

    public var isLoaded: Bool { shortManager != nil && fullManager != nil }

    /// Loads all components, both encoder functions included, so that no dictation pays a load cost.
    public func load() throws {
        if isLoaded { return }
        let shared = try loadSharedComponents()
        shortManager = try makeManager(function: Self.shortFunctionName, shared: shared)
        fullManager = try makeManager(function: Self.fullFunctionName, shared: shared)
    }

    public func unload() {
        shortManager = nil
        fullManager = nil
        sharedComponents = nil
    }

    public func transcribe(_ samples: [Float]) async throws -> TranscriptionOutcome {
        guard let shortManager, let fullManager else { throw TranscriptionError.modelNotLoaded }
        var padded = [Float](repeating: 0, count: Self.leadingSilenceSamples)
        padded.reserveCapacity(samples.count + Self.leadingSilenceSamples)
        padded.append(contentsOf: samples)
        guard padded.count >= ASRConstants.minimumRequiredSamples(forSampleRate: SpeechAudioFormat.sampleRate) else {
            throw TranscriptionError.audioTooShort
        }
        let useShort = padded.count <= Self.shortFunctionLimitSamples
        let manager = useShort ? shortManager : fullManager
        let start = Date()
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(padded, decoderState: &state)
        return TranscriptionOutcome(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), tokenTimings: result.tokenTimings,
            encoderFunction: useShort ? Self.shortFunctionName : Self.fullFunctionName,
            audioSeconds: Double(samples.count) / Double(SpeechAudioFormat.sampleRate),
            processingSeconds: Date().timeIntervalSince(start))
    }

    /// Runs one prediction on silence so that the next real prediction is fast. After about 30 s idle, the Neural
    /// Engine path cools down and the next prediction takes up to 0.9 s instead of 0.15 s. A warm-up started when
    /// recording begins is done before the user stops. `longFunction` selects `full15` (10 s of silence) instead of
    /// `short8` (1 s of silence). Errors are ignored.
    public func warmUp(longFunction: Bool) async {
        let seconds = longFunction ? 10 : 1
        _ = try? await transcribe([Float](repeating: 0, count: SpeechAudioFormat.sampleRate * seconds))
    }

    private func loadSharedComponents() throws -> (preprocessor: MLModel, decoder: MLModel, joint: MLModel, vocabulary: [Int: String]) {
        if let sharedComponents { return sharedComponents }
        let raw = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: vocabularyURL))
        let vocabulary = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
        let components = (
            preprocessor: try loadModel("Preprocessor", units: .cpuOnly),
            decoder: try loadModel("Decoder", units: .cpuOnly),
            joint: try loadModel("JointDecisionv3", units: .cpuOnly),
            vocabulary: vocabulary
        )
        sharedComponents = components
        return components
    }

    private func makeManager(
        function: String, shared: (preprocessor: MLModel, decoder: MLModel, joint: MLModel, vocabulary: [Int: String])
    ) throws -> AsrManager {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let models = AsrModels(
            encoder: try loadModel("Encoder", units: computeTarget.computeUnits, function: function),
            preprocessor: shared.preprocessor, decoder: shared.decoder, joint: shared.joint,
            configuration: configuration, vocabulary: shared.vocabulary, version: .ultra)
        return AsrManager(models: models)
    }

    private func loadModel(_ name: String, units: MLComputeUnits, function: String? = nil) throws -> MLModel {
        let url = compiledDirectory.appendingPathComponent("\(name).mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ModelInstallationError.missingComponent(name)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        configuration.functionName = function
        return try MLModel(contentsOf: url, configuration: configuration)
    }
}

public enum ProcessMemory {
    /// Current physical footprint of this process in bytes, the figure Activity Monitor reports as Memory. Returns 0
    /// when the kernel call fails.
    public static func physicalFootprint() -> UInt64 {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &information) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? information.phys_footprint : 0
    }

    /// Peak physical footprint since process start, from the kernel's lifetime maximum. Returns 0 when the kernel call
    /// fails.
    public static func peakPhysicalFootprint() -> UInt64 {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &information) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(max(information.ledger_phys_footprint_peak, 0)) : 0
    }
}

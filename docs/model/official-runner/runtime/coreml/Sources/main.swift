import Foundation
import CoreML
import AVFoundation
import FluidAudio

@main struct BarkPro {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, ["gpu", "ane", "cpu"].contains(args[3]) else {
            throw Failure("Usage: bark-pro-coreml MODEL_DIR AUDIO.wav gpu|ane|cpu")
        }
        let root = URL(fileURLWithPath: args[1])
        let units: MLComputeUnits = args[3] == "gpu" ? .cpuAndGPU : (args[3] == "ane" ? .cpuAndNeuralEngine : .cpuOnly)
        var temporary: [URL] = []
        defer { for url in temporary { try? FileManager.default.removeItem(at: url) } }
        var compiled: [String: URL] = [:]
        func load(_ name: String, _ compute: MLComputeUnits, function: String? = nil) throws -> MLModel {
            let url: URL
            if let cached = compiled[name] { url = cached }
            else {
                let existing = root.appendingPathComponent(name + ".mlmodelc")
                if FileManager.default.fileExists(atPath: existing.path) { url = existing }
                else {
                    let package = root.appendingPathComponent(name + ".mlpackage")
                    guard FileManager.default.fileExists(atPath: package.path) else {
                        throw Failure("Missing model component: \(package.path)")
                    }
                    url = try MLModel.compileModel(at: package)
                    temporary.append(url)
                }
                compiled[name] = url
            }
            let config = MLModelConfiguration()
            config.computeUnits = compute
            config.functionName = function
            return try MLModel(contentsOf: url, configuration: config)
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
        guard file.processingFormat.sampleRate == 16000,
              file.processingFormat.channelCount == 1, file.length > 0,
              file.length <= AVAudioFramePosition(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure("Expected nonempty mono 16 kHz WAV. See the documented conversion command.")
        }
        try file.read(into: buffer)
        guard let ptr = buffer.floatChannelData?[0] else { throw Failure("Cannot read floating-point audio.") }
        let samples = Array(repeating: Float(0), count: 4000) + Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
        // Both functions share weights. Select the tested short path automatically.
        let function = samples.count <= 128000 ? "short8" : "full15"
        let raw = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: root.appendingPathComponent("parakeet_v3_vocab.json")))
        let vocabulary = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let models = try AsrModels(encoder: load("Encoder", units, function: function),
            preprocessor: load("Preprocessor", .cpuOnly), decoder: load("Decoder", .cpuOnly),
            joint: load("JointDecisionv3", .cpuOnly), configuration: config,
            vocabulary: vocabulary, version: .ultra)
        let manager = AsrManager(models: models)
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        print(result.text)
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

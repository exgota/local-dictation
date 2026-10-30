import AVFoundation
import CoreML
import DictationEngine
import Foundation

// Usage: TranscriptionBenchmark PACKAGE_DIR COMPILED_CACHE_DIR ane|gpu AUDIO.wav [AUDIO.wav ...]
// Compiles each package that has no compiled copy in the cache directory, loads the transcriber once and transcribes
// each file twice.

func megabytes(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

func readSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1, "Expected mono 16 kHz")
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

let arguments = CommandLine.arguments

// Usage: TranscriptionBenchmark stream COMPILED_DIR VOCABULARY.json VAD.mlmodelc AUDIO.wav [AUDIO.wav ...]
// Feeds each file through the streaming pipeline in 20 ms pieces at no more than 20 times real time. It reports the
// chunk count, the time from the last piece to the text, and memory, and writes the transcript beside the audio file.
if arguments.count >= 6, arguments[1] == "stream" {
    let transcriber = SpeechTranscriber(
        compiledDirectory: URL(fileURLWithPath: arguments[2]), vocabularyURL: URL(fileURLWithPath: arguments[3]),
        computeTarget: .neuralEngine)
    try await transcriber.load()
    let voiceActivity = try VoiceActivityDetector(compiledModelURL: URL(fileURLWithPath: arguments[4]))
    print("footprint after load: \(megabytes(ProcessMemory.physicalFootprint()))")
    for path in arguments[5...] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        precondition(format.sampleRate == 16_000 && format.channelCount == 1, "Expected mono 16 kHz")
        let session = StreamingTranscription(transcriber: transcriber, voiceActivity: voiceActivity)
        let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)!
        var maximumFootprint: UInt64 = 0
        var pieces = 0
        // The file is also read in pieces, so the measured footprint is the pipeline's and does not include a
        // whole-file array.
        while file.framePosition < file.length {
            try file.read(into: piece, frameCount: 320)
            session.append(Array(UnsafeBufferPointer(start: piece.floatChannelData![0], count: Int(piece.frameLength))))
            pieces += 1
            // One 20 ms piece per 1 ms sleep feeds audio at no more than 20 times real time, far faster than a
            // microphone delivers.
            try await Task.sleep(nanoseconds: 1_000_000)
            if pieces % 250 == 0 { maximumFootprint = max(maximumFootprint, ProcessMemory.physicalFootprint()) }
        }
        let end = Date()
        let result = try await session.finish()
        let transcriptURL = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("stream.transcript.txt")
        try (result.text + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        print(String(
            format: "%@: audio %.1f s, %d chunks, transcribed %.1f s, end to text %.2f s, footprint max %@ (sampled), now %@",
            URL(fileURLWithPath: path).lastPathComponent, result.audioSeconds, result.chunkCount, result.transcribedSeconds,
            Date().timeIntervalSince(end), megabytes(maximumFootprint), megabytes(ProcessMemory.physicalFootprint())))
    }
    exit(0)
}

guard arguments.count >= 5, let target = ["ane": EncoderComputeTarget.neuralEngine, "gpu": .graphicsProcessor][arguments[3]] else {
    print("Usage: TranscriptionBenchmark PACKAGE_DIR COMPILED_CACHE_DIR ane|gpu AUDIO.wav [AUDIO.wav ...]")
    exit(2)
}
let packages = URL(fileURLWithPath: arguments[1])
let compiled = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)

for name in ModelManifest.componentNames {
    let destination = compiled.appendingPathComponent("\(name).mlmodelc")
    if FileManager.default.fileExists(atPath: destination.path) { continue }
    let start = Date()
    let temporary = try MLModel.compileModel(at: packages.appendingPathComponent("\(name).mlpackage"))
    try FileManager.default.moveItem(at: temporary, to: destination)
    print(String(format: "compile %@: %.2f s", name, Date().timeIntervalSince(start)))
}

print("footprint before load: \(megabytes(ProcessMemory.physicalFootprint()))")
let transcriber = SpeechTranscriber(
    compiledDirectory: compiled, vocabularyURL: packages.appendingPathComponent(ModelManifest.vocabularyFileName),
    computeTarget: target)
let loadStart = Date()
try await transcriber.load()
print(String(format: "load (%@): %.2f s", arguments[3], Date().timeIntervalSince(loadStart)))
print("footprint after load: \(megabytes(ProcessMemory.physicalFootprint())), peak \(megabytes(ProcessMemory.peakPhysicalFootprint()))")

for path in arguments[4...] {
    let samples = try readSamples(URL(fileURLWithPath: path))
    for run in ["first", "repeat"] {
        let before = ProcessMemory.physicalFootprint()
        let outcome = try await transcriber.transcribe(samples)
        print(String(
            format: "%@ [%@] %@: audio %.1f s, processing %.2f s, RTF %.3f, footprint %@ -> %@, peak %@",
            URL(fileURLWithPath: path).lastPathComponent, outcome.encoderFunction, run, outcome.audioSeconds,
            outcome.processingSeconds, outcome.processingSeconds / max(outcome.audioSeconds, 0.001),
            megabytes(before), megabytes(ProcessMemory.physicalFootprint()), megabytes(ProcessMemory.peakPhysicalFootprint())))
        if run == "first" {
            let transcriptURL = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("\(arguments[3]).transcript.txt")
            try (outcome.text + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
    }
}

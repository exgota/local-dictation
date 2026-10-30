// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LocalDictation", targets: ["LocalDictation"]),
        .executable(name: "TranscriptionBenchmark", targets: ["TranscriptionBenchmark"]),
    ],
    dependencies: [
        // Pinned to the revision published with the Bark 3.0 Pro Core ML runner.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "a00964e1aa8eff99c4bce80bc9c8ff2d4dd1568d", traits: []),
    ],
    targets: [
        .target(
            name: "DictationEngine",
            dependencies: ["DictationCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(
            name: "TranscriptionBenchmark",
            dependencies: ["DictationEngine"]),
        // Platform-independent decision logic: hotkey state machine, injection chain, clipboard restoration.
        .target(name: "DictationCore"),
        // Deterministic transcript post-processing: corrections, spoken punctuation, profiles.
        .target(name: "TextProcessing"),
        // Opt-in transcript history in SQLite.
        .target(name: "TranscriptHistory", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "LocalDictation",
            dependencies: ["DictationEngine", "DictationCore", "TextProcessing", "TranscriptHistory"]),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
        .testTarget(name: "TextProcessingTests", dependencies: ["TextProcessing"]),
        .testTarget(name: "TranscriptHistoryTests", dependencies: ["TranscriptHistory"]),
    ],
    swiftLanguageModes: [.v6]
)

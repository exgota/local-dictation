import DictationEngine
import Foundation

/// Model readiness for the interface. Installation starts only on explicit request. The controller loads an installed
/// model at launch, after an installation and after a change of compute target, and reuses the loaded model for every
/// dictation.
@MainActor final class ModelController: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case installing(InstallationProgress.Phase, fraction: Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled
    let store = ModelStore(rootDirectory: ModelStore.defaultRootDirectory)
    private var transcriber: SpeechTranscriber?
    private var voiceActivity: VoiceActivityDetector?
    private var installation: Task<Void, Never>?
    private var computeTarget: EncoderComputeTarget

    init(computeTarget: EncoderComputeTarget) {
        self.computeTarget = computeTarget
        if store.isInstalled { load() }
    }

    var isReady: Bool { state == .ready }

    var statusDescription: String {
        switch state {
        case .notInstalled: return "Not installed"
        case .installing(let phase, let fraction): return "Installing (\(phase), \(Int(fraction * 100)) %)"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    func install() {
        guard installation == nil else { return }
        state = .installing(.downloading, fraction: 0)
        let store = store
        installation = Task {
            do {
                try await store.install { progress in
                    Task { @MainActor in
                        if case .installing = self.state {
                            self.state = .installing(progress.phase, fraction: progress.fraction)
                        }
                    }
                }
                installation = nil
                load()
            } catch {
                installation = nil
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelInstallation() {
        installation?.cancel()
    }

    func remove() {
        Task {
            await transcriber?.unload()
            transcriber = nil
            do {
                try store.remove()
                state = .notInstalled
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func setComputeTarget(_ target: EncoderComputeTarget) {
        guard target != computeTarget else { return }
        computeTarget = target
        if store.isInstalled { load() }
    }

    func load() {
        state = .loading
        let transcriber = SpeechTranscriber(
            compiledDirectory: store.compiledDirectory, vocabularyURL: store.vocabularyURL, computeTarget: computeTarget)
        self.transcriber = transcriber
        let voiceActivityModelURL = store.voiceActivityModelURL
        Task {
            do {
                try await transcriber.load()
                let voiceActivity = try VoiceActivityDetector(compiledModelURL: voiceActivityModelURL)
                // The first prediction of each encoder function is slower. These two calls, one per function, take that
                // cost now instead of in the first dictation.
                _ = try? await transcriber.transcribe([Float](repeating: 0, count: 16_000))
                _ = try? await transcriber.transcribe([Float](repeating: 0, count: 16_000 * 10))
                guard self.transcriber === transcriber else { return }
                self.voiceActivity = voiceActivity
                state = .ready
            } catch {
                guard self.transcriber === transcriber else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// A transcription that runs while recording. Nil until the model is ready.
    func makeStreamingTranscription(onActivity: @escaping @Sendable (StreamingTranscription.Activity) -> Void) -> StreamingTranscription? {
        guard state == .ready, let transcriber, let voiceActivity else { return nil }
        return StreamingTranscription(transcriber: transcriber, voiceActivity: voiceActivity, onActivity: onActivity)
    }
}

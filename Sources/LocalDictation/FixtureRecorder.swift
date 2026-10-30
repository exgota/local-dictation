import AVFoundation
import AppKit
import DictationEngine
import SwiftUI
import os

/// One scripted take of the self-test set.
struct FixturePrompt: Identifiable {
    let id: String
    let duration: String
    let instruction: String
    /// The expected transcript written next to the recording. Nil means unscripted: the model's transcript is
    /// written as a starting point for the user to correct.
    let expectedText: String?
}

enum FixtureScript {
    static let prompts: [FixturePrompt] = [
        FixturePrompt(id: "01-quiet-short", duration: "5 s", instruction: "Say: “Add a scroll bar fix to the settings window.”",
                      expectedText: "Add a scroll bar fix to the settings window."),
        FixturePrompt(id: "02-quiet-names", duration: "15 s",
                      instruction: "Say: “Ask Claude Code to check CLAUDE.md, then restart the MCP server and the SwiftUI preview.”",
                      expectedText: "Ask Claude Code to check CLAUDE.md, then restart the MCP server and the SwiftUI preview."),
        FixturePrompt(id: "03-quiet-punct", duration: "15 s",
                      instruction: "Say: “Hello comma this is a test period new paragraph is it working question mark”",
                      expectedText: "Hello, this is a test.\n\nIs it working?"),
        FixturePrompt(id: "04-quiet-fillers", duration: "30 s",
                      instruction: "Talk about anything for 30 seconds. Fillers like um and uh are welcome.", expectedText: nil),
        FixturePrompt(id: "05-quiet-pause", duration: "30 s",
                      instruction: "Start a sentence, stop for four seconds to think, then finish it.", expectedText: nil),
        FixturePrompt(id: "06-quiet-long", duration: "3 min", instruction: "Talk about anything for three minutes.", expectedText: nil),
        FixturePrompt(id: "07-noise-short", duration: "5 s",
                      instruction: "With background noise (a fan, café or train), say: “Add a scroll bar fix to the settings window.”",
                      expectedText: "Add a scroll bar fix to the settings window."),
        FixturePrompt(id: "08-noise-rant", duration: "45 s", instruction: "With background noise, talk about anything for 45 seconds.",
                      expectedText: nil),
        FixturePrompt(id: "09-headset-rant", duration: "30 s",
                      instruction: "Choose your Bluetooth or headset microphone in Settings → Audio, then talk for 30 seconds.",
                      expectedText: nil),
        FixturePrompt(id: "10-scratch-that", duration: "10 s",
                      instruction: "Say: “Let's send it tomorrow, scratch that, send it today.”", expectedText: "Send it today."),
        FixturePrompt(id: "11-empty-press", duration: "1 s", instruction: "Start, stay silent, and stop after about a second.",
                      expectedText: ""),
        FixturePrompt(id: "12-too-short", duration: "0.2 s", instruction: "Start and stop as quickly as you can.", expectedText: ""),
    ]
}

/// Records the self-test fixtures: mono 16 kHz WAV files plus editable expected transcripts, in the fixtures folder.
@MainActor final class FixtureRecorderModel: ObservableObject {
    @Published var recordingIdentifier: String?
    @Published var savedIdentifiers: Set<String> = []
    @Published var message: String?

    private let recorder = AudioRecorder()
    private let samples = OSAllocatedUnfairLock<[Float]>(initialState: [])
    private var context: SettingsContext?

    var directory: URL { ApplicationFiles.fixturesDirectory }

    func attach(_ context: SettingsContext) {
        self.context = context
        refreshSaved()
    }

    func refreshSaved() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        savedIdentifiers = Set(FixtureScript.prompts.map(\.id).filter { names.contains("\($0).wav") })
    }

    func start(_ prompt: FixturePrompt) {
        guard recordingIdentifier == nil, let context else { return }
        samples.withLock { $0.removeAll() }
        context.controller.suspendsHotkeys = true
        do {
            let samples = self.samples
            try recorder.start(
                deviceIdentifier: context.settings.configuration.inputDeviceIdentifier, maximumDuration: 10 * 60,
                consumer: { chunk in samples.withLock { $0.append(contentsOf: chunk) } }, onFirstAudio: {})
            recordingIdentifier = prompt.id
            message = nil
        } catch {
            context.controller.suspendsHotkeys = false
            message = error.localizedDescription
        }
    }

    func stop() {
        guard let identifier = recordingIdentifier, let prompt = FixtureScript.prompts.first(where: { $0.id == identifier }) else { return }
        recorder.finish()
        recordingIdentifier = nil
        context?.controller.suspendsHotkeys = false
        let recorded = samples.withLock { $0 }
        Task { await save(prompt, samples: recorded) }
    }

    private func save(_ prompt: FixturePrompt, samples: [Float]) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let audioURL = directory.appendingPathComponent("\(prompt.id).wav")
            try Self.writeWave(samples, to: audioURL)
            var expected = prompt.expectedText
            if expected == nil, let streaming = context?.model.makeStreamingTranscription(onActivity: { _ in }) {
                streaming.append(samples)
                expected = (try? await streaming.finish().text) ?? ""
            }
            try ((expected ?? "") + "\n").write(
                to: directory.appendingPathComponent("\(prompt.id).expected.txt"), atomically: true, encoding: .utf8)
            message = "Saved \(prompt.id): \(String(format: "%.1f", Double(samples.count) / 16_000)) s."
                + (prompt.expectedText == nil ? " Check its expected text against what you said." : "")
            refreshSaved()
        } catch {
            message = "\(prompt.id) could not be saved: \(error.localizedDescription)"
        }
    }

    private static func writeWave(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

@MainActor final class FixtureRecorderWindowController {
    static let shared = FixtureRecorderWindowController()
    private let model = FixtureRecorderModel()
    private var window: NSWindow?

    func show(context: SettingsContext) {
        model.attach(context)
        if window == nil {
            let hosting = NSHostingController(rootView: FixtureRecorderView(model: model))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Record fixtures"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct FixtureRecorderView: View {
    @ObservedObject var model: FixtureRecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
            Text("Each take is saved to the fixtures folder with an expected transcript you can edit.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: SettingsLayout.labelControlGap, verticalSpacing: SettingsLayout.rowSpacing) {
                ForEach(FixtureScript.prompts) { prompt in
                    GridRow {
                        Image(systemName: model.savedIdentifiers.contains(prompt.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.savedIdentifiers.contains(prompt.id) ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: SettingsLayout.captionGap) {
                            Text("\(prompt.id) · \(prompt.duration)").font(.headline)
                            Text(prompt.instruction).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if model.recordingIdentifier == prompt.id {
                            Button("Stop", action: model.stop).controlSize(.large).keyboardShortcut(.defaultAction)
                        } else {
                            Button("Record") { model.start(prompt) }.controlSize(.large).disabled(model.recordingIdentifier != nil)
                        }
                    }
                }
            }
            HStack(spacing: SettingsLayout.labelControlGap) {
                Text(model.message ?? model.directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: model.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([model.directory])
                }
                .controlSize(.large)
            }
        }
        .padding(SettingsLayout.windowPadding)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

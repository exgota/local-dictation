import DictationCore
import DictationEngine
import Foundation
import TextProcessing

extension EncoderComputeTarget: Codable {}

/// Settings for saving each transcript as a Markdown file in a dated folder, for reading by people and agents.
struct TranscriptFolderConfiguration: Codable, Equatable {
    var isEnabled = false
    /// A tilde is expanded to the home folder.
    var path = "~/Desktop/Transcripts"

    init() {}

    /// Each field falls back on its own, so one bad value does not reset the block.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TranscriptFolderConfiguration()
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? nil ?? defaults.isEnabled
        path = (try? container.decodeIfPresent(String.self, forKey: .path)) ?? nil ?? defaults.path
    }

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true) }
}

/// Every user setting, stored as `settings.json`. Missing keys take their defaults, so the file can be edited by hand
/// and keeps working across versions that add settings.
struct DictationConfiguration: Codable, Equatable {
    var trigger: TriggerKey = .function
    var triggerMode: TriggerMode = .toggle
    var repasteChord: KeyChord? = .defaultRepaste
    var pauseChord: KeyChord? = nil
    /// Recording stops and transcribes after this long, in case a key-up was missed.
    var maximumRecordingMinutes = 20
    /// Core Audio device UID; nil selects the system default input.
    var inputDeviceIdentifier: String? = nil
    var stopsAfterSilence = false
    var silenceStopSeconds = 3.0
    /// Linear gain for the start and stop sounds, from 0, which turns them off, to 1. The default is the slider's
    /// midpoint, 6 dB below the level of the bundled files.
    var cueVolume = 0.5
    var computeTarget: EncoderComputeTarget = .neuralEngine
    var profiles = ProfileResolver()
    var vocabularyCorrectionsEnabled = false
    var chatSubmitsWithReturn = false
    var keepsHistory = false
    var transcriptFolder = TranscriptFolderConfiguration()

    var hotkeyConfiguration: HotkeyConfiguration {
        HotkeyConfiguration(trigger: trigger, mode: triggerMode, repasteChord: repasteChord, pauseChord: pauseChord)
    }

    /// Keys present in the file whose values could not be read and were replaced by defaults.
    var invalidKeys: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DictationConfiguration()
        var invalid: [String] = []
        func value<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
            guard container.contains(key) else { return fallback }
            if let decoded = try? container.decode(Value.self, forKey: key) { return decoded }
            invalid.append(key.stringValue)
            return fallback
        }
        /// For optional settings an explicit null means "none"; only a missing key takes the default.
        func optional<Value: Decodable>(_ key: CodingKeys, _ fallback: Value?) -> Value? {
            guard container.contains(key) else { return fallback }
            if (try? container.decodeNil(forKey: key)) == true { return nil }
            if let decoded = try? container.decode(Value.self, forKey: key) { return decoded }
            invalid.append(key.stringValue)
            return fallback
        }
        trigger = value(.trigger, defaults.trigger)
        triggerMode = value(.triggerMode, defaults.triggerMode)
        repasteChord = optional(.repasteChord, defaults.repasteChord)
        pauseChord = optional(.pauseChord, defaults.pauseChord)
        maximumRecordingMinutes = min(1_440, max(1, value(.maximumRecordingMinutes, defaults.maximumRecordingMinutes)))
        inputDeviceIdentifier = optional(.inputDeviceIdentifier, defaults.inputDeviceIdentifier)
        stopsAfterSilence = value(.stopsAfterSilence, defaults.stopsAfterSilence)
        silenceStopSeconds = value(.silenceStopSeconds, defaults.silenceStopSeconds)
        cueVolume = min(max(value(.cueVolume, defaults.cueVolume), 0), 1)
        computeTarget = value(.computeTarget, defaults.computeTarget)
        profiles = value(.profiles, defaults.profiles)
        vocabularyCorrectionsEnabled = value(.vocabularyCorrectionsEnabled, defaults.vocabularyCorrectionsEnabled)
        chatSubmitsWithReturn = value(.chatSubmitsWithReturn, defaults.chatSubmitsWithReturn)
        keepsHistory = value(.keepsHistory, defaults.keepsHistory)
        transcriptFolder = value(.transcriptFolder, defaults.transcriptFolder)
        invalidKeys = invalid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(triggerMode, forKey: .triggerMode)
        try container.encode(repasteChord, forKey: .repasteChord)
        try container.encode(pauseChord, forKey: .pauseChord)
        try container.encode(maximumRecordingMinutes, forKey: .maximumRecordingMinutes)
        try container.encode(inputDeviceIdentifier, forKey: .inputDeviceIdentifier)
        try container.encode(stopsAfterSilence, forKey: .stopsAfterSilence)
        try container.encode(silenceStopSeconds, forKey: .silenceStopSeconds)
        try container.encode(cueVolume, forKey: .cueVolume)
        try container.encode(computeTarget, forKey: .computeTarget)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(vocabularyCorrectionsEnabled, forKey: .vocabularyCorrectionsEnabled)
        try container.encode(chatSubmitsWithReturn, forKey: .chatSubmitsWithReturn)
        try container.encode(keepsHistory, forKey: .keepsHistory)
        try container.encode(transcriptFolder, forKey: .transcriptFolder)
    }

    private enum CodingKeys: String, CodingKey {
        case trigger, triggerMode, repasteChord, pauseChord, maximumRecordingMinutes, inputDeviceIdentifier
        case stopsAfterSilence, silenceStopSeconds, cueVolume, computeTarget, profiles
        case vocabularyCorrectionsEnabled, chatSubmitsWithReturn, keepsHistory, transcriptFolder
    }
}

/// File locations under Application Support.
enum ApplicationFiles {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalDictation", isDirectory: true)
    }
    static var configurationURL: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var vocabularyURL: URL { supportDirectory.appendingPathComponent("vocabulary.json") }
    static var historyURL: URL { supportDirectory.appendingPathComponent("history.sqlite") }
    /// Where the fixture recorder saves and `--selftest` reads by default.
    static var fixturesDirectory: URL { supportDirectory.appendingPathComponent("Fixtures", isDirectory: true) }
}

/// The settings the interface binds to, backed by `settings.json`. Changes in the interface are written to the file;
/// edits to the file by hand are picked up while the app runs.
@MainActor final class DictationSettings: ObservableObject {
    @Published var configuration: DictationConfiguration {
        didSet { if configuration != oldValue && !isReloading { save() } }
    }
    @Published private(set) var lastFileError: String?

    private let fileURL: URL
    private var isReloading = false
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?

    init(fileURL: URL = ApplicationFiles.configurationURL) {
        self.fileURL = fileURL
        configuration = DictationConfiguration()
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) { reload() } else { save() }
        watchDirectory()
    }

    /// Reads the file without watching it, for command-line use. Returns the defaults when the file is missing or does
    /// not parse.
    nonisolated static func readConfiguration(fileURL: URL = ApplicationFiles.configurationURL) -> DictationConfiguration {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(DictationConfiguration.self, from: $0) }
            ?? DictationConfiguration()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: fileURL, options: .atomic)
            lastFileError = nil
        } catch {
            lastFileError = "Settings could not be saved: \(error.localizedDescription)"
        }
    }

    /// Reads the file. A file that does not parse is left alone and reported; the running settings stay in effect.
    func reload() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            var loaded = try JSONDecoder().decode(DictationConfiguration.self, from: data)
            let invalid = loaded.invalidKeys
            loaded.invalidKeys = []
            lastFileError = invalid.isEmpty
                ? nil : "settings.json has values that could not be read for \(invalid.joined(separator: ", ")); defaults are in use for those."
            if let lastFileError { dictationLog.error(lastFileError) }
            guard loaded != configuration else { return }
            isReloading = true
            configuration = loaded
            isReloading = false
            dictationLog.notice("settings reloaded from file")
        } catch {
            lastFileError = "settings.json could not be read: \(error.localizedDescription)"
        }
    }

    /// Editors either rewrite the file in place or replace it atomically. The file is watched for the first, the
    /// directory for the second; after a replacement the file watcher is re-attached to the new file.
    private func watchDirectory() {
        directoryWatcher = makeWatcher(path: fileURL.deletingLastPathComponent().path, events: [.write]) { [weak self] in
            self?.reload()
            self?.watchFile()
        }
        watchFile()
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = makeWatcher(path: fileURL.path, events: [.write, .extend, .delete, .rename]) { [weak self] in
            self?.reload()
            self?.watchFile()
        }
    }

    private func makeWatcher(path: String, events: DispatchSource.FileSystemEvent, handler: @escaping @MainActor () -> Void)
        -> DispatchSourceFileSystemObject?
    {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}

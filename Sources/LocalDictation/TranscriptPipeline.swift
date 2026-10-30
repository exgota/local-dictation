import Foundation
import TextProcessing
import TranscriptHistory

/// What happens to a raw transcript before insertion: the target application's profile and the opt-in deterministic
/// steps. Also writes the opt-in history and transcript files.
@MainActor final class TranscriptPipeline {
    struct Prepared {
        let profile: TranscriptProfile
        let finalText: String
        let submitsWithReturn: Bool
    }

    private let settings: DictationSettings
    private let processor = TranscriptProcessor()
    private var history: TranscriptHistoryStore?
    /// The parsed vocabulary file and the modification date it was read at, so a dictation parses the file only after
    /// it changes.
    private var cachedVocabulary: (modificationDate: Date, corrections: VocabularyCorrections)?

    init(settings: DictationSettings) {
        self.settings = settings
    }

    /// The vocabulary file, seeded only when it does not exist. A file that does not parse is never overwritten:
    /// dictation uses the built-in list and the error is logged, so a typo cannot wipe hand-made corrections.
    var vocabulary: VocabularyCorrections {
        do {
            return try loadVocabulary()
        } catch {
            dictationLog.error("vocabulary.json could not be read, using the built-in list: \(error.localizedDescription)")
            return .seed
        }
    }

    /// Loads the vocabulary file, creating it from the seed if it does not exist. Throws if it exists but is unreadable.
    func loadVocabulary() throws -> VocabularyCorrections {
        let url = ApplicationFiles.vocabularyURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            try? VocabularyCorrections.seed.save(to: url)
            return .seed
        }
        let modificationDate = attributes[.modificationDate] as? Date
        if let cachedVocabulary, cachedVocabulary.modificationDate == modificationDate { return cachedVocabulary.corrections }
        let corrections = try VocabularyCorrections.load(from: url)
        cachedVocabulary = modificationDate.map { ($0, corrections) }
        return corrections
    }

    func prepare(_ rawText: String, bundleIdentifier: String?) -> Prepared {
        let configuration = settings.configuration
        let profile = configuration.profiles.profile(forBundleIdentifier: bundleIdentifier)
        guard profile.producesText else { return Prepared(profile: profile, finalText: "", submitsWithReturn: false) }
        let text = processor.process(
            rawText, options: profile.defaultOptions(vocabularyCorrectionsEnabled: configuration.vocabularyCorrectionsEnabled),
            corrections: configuration.vocabularyCorrectionsEnabled ? vocabulary : VocabularyCorrections())
        return Prepared(
            profile: profile, finalText: text,
            submitsWithReturn: profile.submitsWithReturn(userPreference: configuration.chatSubmitsWithReturn))
    }

    /// Appends to the history and the transcript folder when they are turned on. Failures are logged and never block
    /// dictation.
    func record(
        rawText: String, finalText: String, durationSeconds: Double, applicationName: String?, bundleIdentifier: String?,
        style: TranscriptProfile
    ) async {
        let folder = settings.configuration.transcriptFolder
        if folder.isEnabled {
            do {
                _ = try TranscriptArchive.write(
                    rawText: rawText, finalText: finalText, date: Date(), durationSeconds: durationSeconds,
                    applicationName: applicationName, bundleIdentifier: bundleIdentifier, style: style.rawValue, folder: folder.url)
            } catch {
                dictationLog.error("transcript file not written: \(error.localizedDescription)")
            }
        }
        guard settings.configuration.keepsHistory else { return }
        do {
            let store = try historyStore()
            try await store.append(TranscriptHistoryEntry(
                timestamp: Date(), durationSeconds: durationSeconds, rawText: rawText, finalText: finalText,
                applicationBundleIdentifier: bundleIdentifier, applicationName: applicationName))
        } catch {
            dictationLog.error("history append failed: \(error.localizedDescription)")
        }
    }

    func historyStore() throws -> TranscriptHistoryStore {
        if let history { return history }
        let store = try TranscriptHistoryStore(databaseURL: ApplicationFiles.historyURL)
        history = store
        return store
    }

    /// "Fix this everywhere": adds a mishearing to the vocabulary file and turns corrections on.
    func addCorrection(canonical: String, mishearing: String) throws {
        // Strict load: an unreadable file is reported rather than replaced by the seed plus one entry.
        try loadVocabulary().adding(canonical: canonical, mishearing: mishearing).save(to: ApplicationFiles.vocabularyURL)
        settings.configuration.vocabularyCorrectionsEnabled = true
    }
}

import Foundation

/// Deterministic post-processing pipeline for verbatim transcripts.
public struct TranscriptProcessor: Sendable {
    public init() {}

    /// Runs the enabled steps in this fixed order: scratch that, spoken punctuation, filler removal, vocabulary
    /// corrections, capitalization, terminal punctuation. It then always normalizes whitespace: runs of spaces and tabs
    /// collapse to one space, spaces around a newline are removed, and leading and trailing whitespace is trimmed.
    /// Empty input gives empty output.
    public func process(_ rawText: String, options: ProcessingOptions, corrections: VocabularyCorrections) -> String {
        var text = rawText
        if options.scratchThat { text = ScratchThat.apply(to: text) }
        if options.spokenPunctuation { text = SpokenPunctuation.apply(to: text) }
        if options.fillerRemoval { text = FillerRemoval.apply(to: text) }
        if options.vocabularyCorrections { text = corrections.apply(to: text) }
        if options.capitalizeFirst { text = TextFormatting.capitalizeFirst(text) }
        if options.terminalPunctuation { text = TextFormatting.ensureTerminalPunctuation(text) }
        return Self.normalizeWhitespace(text)
    }

    static func normalizeWhitespace(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

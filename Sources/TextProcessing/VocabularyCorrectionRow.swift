import Foundation

/// An editable projection of one vocabulary entry. Untouched forms retain their original spelling and whitespace.
public struct VocabularyCorrectionRow: Identifiable {
    public let id = UUID()
    public var canonical: String
    public var mishearingsText: String
    private let original: VocabularyCorrections.Entry
    private let originalText: String

    public init(_ entry: VocabularyCorrections.Entry) {
        original = entry
        canonical = entry.canonical
        originalText = entry.mishearings.joined(separator: ", ")
        mishearingsText = originalText
    }

    public var entry: VocabularyCorrections.Entry {
        let forms = mishearingsText == originalText ? original.mishearings : mishearingsText
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return .init(canonical: canonical, mishearings: forms)
    }
}

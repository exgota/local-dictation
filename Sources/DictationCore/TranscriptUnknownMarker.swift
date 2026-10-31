import Foundation

/// Removes the model's unknown-token marker without guessing the punctuation it represents.
public enum TranscriptUnknownMarker {
    public static func remove(from text: String) -> String {
        guard text.contains("<unk>") else { return text }
        return text.replacingOccurrences(
            of: #"(?:\s*<unk>\s*)+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A word boundary remains in token pieces, even when the marker is between subword pieces.
    public static func remove(fromPiece piece: String) -> String {
        piece.replacingOccurrences(of: "<unk>", with: " ")
    }
}

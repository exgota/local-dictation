import Foundation

/// Handles the spoken "scratch that" command.
public enum ScratchThat {
    private static let commandPattern = try! NSRegularExpression(
        pattern: "\\bscratch\\s+that\\b[,.;:!?]*[ \\t]*", options: [.caseInsensitive])

    /// Deletes the text from the start of the current sentence through each "scratch that", including the punctuation
    /// and spaces after the command. When "scratch that" opens its own sentence (the model often ends the previous
    /// sentence with a period), the deletion starts at the previous sentence instead. When the deletion reaches the end
    /// of the text, the spaces and tabs before it are removed as well.
    ///
    /// A sentence starts at the beginning of the text or after a `.` followed by whitespace, a `?`, a `!` or a newline.
    /// Occurrences are handled in order.
    public static func apply(to text: String) -> String {
        var result = text
        while let match = commandPattern.firstMatch(
            in: result, range: NSRange(location: 0, length: (result as NSString).length)),
            let commandStart = Range(match.range, in: result)?.lowerBound,
            let commandEnd = Range(match.range, in: result)?.upperBound
        {
            var removalStart = sentenceStart(in: result, before: commandStart)
            if removalStart == commandStart && removalStart > result.startIndex {
                // Step back over the previous sentence's terminator and whitespace, then to that sentence's start.
                var cursor = removalStart
                while cursor > result.startIndex, result[result.index(before: cursor)].isWhitespace {
                    cursor = result.index(before: cursor)
                }
                if cursor > result.startIndex { cursor = result.index(before: cursor) }
                removalStart = sentenceStart(in: result, before: cursor)
            }
            let removalOffset = result.distance(from: result.startIndex, to: removalStart)
            result.removeSubrange(removalStart..<commandEnd)
            if removalOffset == result.count {
                while let last = result.last, last == " " || last == "\t" { result.removeLast() }
            }
        }
        return result
    }

    /// The start of the sentence containing the character before `index`, past any leading spaces.
    private static func sentenceStart(in text: String, before index: String.Index) -> String.Index {
        var start = index
        while start > text.startIndex {
            let previousIndex = text.index(before: start)
            let previous = text[previousIndex]
            let followedByWhitespace = start == text.endIndex || text[start].isWhitespace
            if previous == "\n" || previous == "?" || previous == "!" || (previous == "." && followedByWhitespace) { break }
            start = previousIndex
        }
        while start < index, text[start] == " " || text[start] == "\t" { start = text.index(after: start) }
        return start
    }
}

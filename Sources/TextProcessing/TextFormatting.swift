import Foundation

/// Sentence capitalization and terminal punctuation.
public enum TextFormatting {
    /// Uppercases the first letter of the text and of each sentence that follows a sentence end. A newline ends a
    /// sentence. A `.`, `?` or `!` ends a sentence only when whitespace follows it, so "3.5" and "notes.md" are
    /// untouched.
    ///
    /// Words that already contain an uppercase letter (such as "iOS") are left as they are. A word is the run of
    /// characters up to the next whitespace. A digit before the first letter of a sentence keeps that sentence
    /// lowercase.
    public static func capitalizeFirst(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var expectsSentenceStart = true
        for index in characters.indices {
            let character = characters[index]
            if expectsSentenceStart, character.isLetter {
                let tokenEnd = characters[index...].firstIndex { $0.isWhitespace } ?? characters.count
                let hasUppercase = characters[index..<tokenEnd].contains { $0.isUppercase }
                output += hasUppercase ? String(character) : character.uppercased()
                expectsSentenceStart = false
                continue
            }
            output.append(character)
            if character.isNumber {
                expectsSentenceStart = false
            } else if character == "\n" {
                expectsSentenceStart = true
            } else if character == "." || character == "?" || character == "!" {
                let isLast = index + 1 == characters.count
                if isLast || characters[index + 1].isWhitespace { expectsSentenceStart = true }
            }
        }
        return output
    }

    /// Inserts "." directly after the last non-whitespace character when that character is a letter or digit. Trailing
    /// whitespace stays after the period.
    public static func ensureTerminalPunctuation(_ text: String) -> String {
        guard let lastIndex = text.lastIndex(where: { !$0.isWhitespace }) else { return text }
        let last = text[lastIndex]
        guard last.isLetter || last.isNumber else { return text }
        var result = text
        result.insert(".", at: text.index(after: lastIndex))
        return result
    }
}

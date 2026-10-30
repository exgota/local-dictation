import Foundation

/// Converts spoken punctuation commands into symbols: "period" and "full stop" give ".", "comma" gives ",",
/// "question mark" gives "?", "exclamation mark" and "exclamation point" give "!", "colon" gives ":", "semicolon"
/// gives ";", "new line" gives a newline, and "new paragraph" gives two newlines.
public enum SpokenPunctuation {
    private static let symbols: [String: String] = [
        "period": ".", "full stop": ".", "comma": ",", "question mark": "?", "exclamation mark": "!",
        "exclamation point": "!", "colon": ":", "semicolon": ";", "new line": "\n", "new paragraph": "\n\n",
    ]

    /// A command directly after one of these words is treated as an ordinary noun ("the period", "a colon").
    private static let nounIntroducers: Set<String> = [
        "the", "a", "an", "this", "that", "my", "your", "his", "her", "its", "our", "their", "of",
    ]

    private static let commandPattern: NSRegularExpression = {
        let alternatives = symbols.keys.sorted { $0.count > $1.count }
            .map { $0.replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        let pattern = "(?:\\s*[,.])?\\s*\\b(\(alternatives))\\b(?:\\s*[,.])?"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Replaces each command with its symbol, attached to the previous word. Spaces after the command collapse to one
    /// space, or to none after a newline.
    ///
    /// A comma or period that the model placed right before or after a command is absorbed, except that a period before
    /// a newline command is kept, so sentence ends survive. A command directly after "the", "a", "an", "this", "that",
    /// "my", "your", "his", "her", "its", "our", "their" or "of" is left alone.
    public static func apply(to text: String) -> String {
        let source = text as NSString
        var output = ""
        var cursor = 0
        var converted = false
        for match in commandPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let commandRange = match.range(at: 1)
            if isNounUsage(before: commandRange.location, in: source) { continue }
            let normalizedCommand = source.substring(with: commandRange).lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard let symbol = symbols[normalizedCommand] else { continue }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if symbol.hasPrefix("\n") {
                let leadingRange = NSRange(location: match.range.location, length: commandRange.location - match.range.location)
                if source.substring(with: leadingRange).contains(".") { output += "." }
            }
            output += symbol
            cursor = match.range.location + match.range.length
            converted = true
        }
        guard converted else { return text }
        output += source.substring(from: cursor)
        return tidy(output)
    }

    private static func isNounUsage(before location: Int, in source: NSString) -> Bool {
        var end = location
        while end > 0, isInlineSpace(source.character(at: end - 1)) { end -= 1 }
        guard end < location else { return false }
        var start = end
        while start > 0, let scalar = Unicode.Scalar(source.character(at: start - 1)),
            CharacterSet.letters.contains(scalar)
        {
            start -= 1
        }
        let word = source.substring(with: NSRange(location: start, length: end - start)).lowercased()
        return nounIntroducers.contains(word)
    }

    private static func isInlineSpace(_ code: unichar) -> Bool { code == 0x20 || code == 0x09 }

    private static func tidy(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            ("[ \\t]+(?=[.,?!:;\\n])", ""),
            ("\\n[ \\t]+", "\n"),
            ("[ \\t]{2,}", " "),
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result
    }
}

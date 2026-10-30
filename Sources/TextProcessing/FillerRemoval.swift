import Foundation

/// Conservative removal of hesitation fillers.
public enum FillerRemoval {
    private static let hesitationPattern = try! NSRegularExpression(
        pattern: "(?<![\\w'’-])(?:um|uh|erm|uhm|hmm)(?![\\w'’-]),?[ \\t]*", options: [.caseInsensitive])
    private static let commaDelimitedLikePattern = try! NSRegularExpression(
        pattern: "(,[ \\t]*)like[ \\t]*,[ \\t]*", options: [.caseInsensitive])
    private static let sentenceStartLikePattern = try! NSRegularExpression(
        pattern: "((?:\\A|[.?!\\n])[ \\t]*)like[ \\t]*,[ \\t]*", options: [.caseInsensitive])

    /// Removes "um", "uh", "erm", "uhm" and "hmm", plus "like" only as ", like," or as "Like," opening a sentence. A
    /// comma directly after a hesitation filler is removed with it.
    ///
    /// This step does not recapitalize the word after a removed sentence-initial filler. Capitalization, when enabled,
    /// runs after this step. Doubled spaces and commas left behind are cleaned up. Text that contains no filler is
    /// returned unchanged.
    public static func apply(to text: String) -> String {
        var result = replace(hesitationPattern, in: text, with: "")
        var previous: String
        repeat {
            previous = result
            result = replace(commaDelimitedLikePattern, in: result, with: "$1")
            result = replace(sentenceStartLikePattern, in: result, with: "$1")
        } while result != previous
        guard result != text else { return text }
        return tidy(result)
    }

    private static func replace(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    private static func tidy(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            ("[ \\t]{2,}", " "),
            ("[ \\t]+(?=[,.?!:;])", ""),
            (",[ \\t]*(?=[,.?!])", ""),
            ("(?m)^[ \\t]*,[ \\t]*", ""),
            ("(?m)[ \\t]+$", ""),
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

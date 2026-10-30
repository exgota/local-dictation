import Foundation

/// Selects complete SentencePiece words whose first token starts within a chunk's core.
public enum TranscriptCoreSelector {
    public struct Token: Sendable {
        public let piece: String
        public let startTime: TimeInterval

        public init(piece: String, startTime: TimeInterval) {
            self.piece = piece
            self.startTime = startTime
        }
    }

    public struct Selection: Sendable {
        public var text: String
        /// Seconds from the start of the core to the first selected word. Nil without timings.
        public var firstWordDelay: TimeInterval?
        /// Seconds from the last selected word to the end of the core. Nil without timings.
        public var lastWordLead: TimeInterval?
        /// The nearest word before the core, with the seconds between it and the start of the core.
        public var wordBeforeCore: (text: String, lead: TimeInterval)?
        /// The nearest word after the core, with the seconds between the end of the core and it.
        public var wordAfterCore: (text: String, delay: TimeInterval)?

        public init(text: String, firstWordDelay: TimeInterval? = nil, lastWordLead: TimeInterval? = nil) {
            self.text = text
            self.firstWordDelay = firstWordDelay
            self.lastWordLead = lastWordLead
        }
    }

    /// Adjacent decodes can place one spoken word on opposite sides of a cut by a few encoder frames.
    static let seamWindow: TimeInterval = 0.32

    public static func select(text: String, tokens: [Token]?, core: Range<TimeInterval>) -> Selection {
        guard let tokens else { return Selection(text: text) }
        var selected = ""
        var word = ""
        var wordStart: TimeInterval = 0
        var firstWordDelay: TimeInterval?
        var lastWordLead: TimeInterval?
        var wordBeforeCore: (text: String, lead: TimeInterval)?
        var wordAfterCore: (text: String, delay: TimeInterval)?

        func appendWord() {
            if wordStart < core.lowerBound {
                wordBeforeCore = (word.trimmingCharacters(in: .whitespaces), core.lowerBound - wordStart)
            } else if wordStart >= core.upperBound {
                wordAfterCore = wordAfterCore ?? (word.trimmingCharacters(in: .whitespaces), wordStart - core.upperBound)
            } else {
                selected += word
                firstWordDelay = firstWordDelay ?? wordStart - core.lowerBound
                lastWordLead = core.upperBound - wordStart
            }
        }

        for token in tokens {
            let piece = token.piece.replacingOccurrences(of: "▁", with: " ")
            guard !piece.isEmpty else { continue }
            if piece.hasPrefix(" ") && !word.isEmpty {
                appendWord()
                word = ""
            }
            if word.isEmpty { wordStart = token.startTime }
            word += piece
        }
        if !word.isEmpty { appendWord() }
        var selection = Selection(
            text: selected.trimmingCharacters(in: .whitespaces), firstWordDelay: firstWordDelay, lastWordLead: lastWordLead)
        selection.wordBeforeCore = wordBeforeCore
        selection.wordAfterCore = wordAfterCore
        return selection
    }

    /// Resolves a word that adjacent decodes placed differently around the cut between them. A word both decodes kept
    /// is dropped from `next`, and a word both decodes left out is restored to it.
    public static func reconcilingSeam(_ next: Selection, after previous: Selection?) -> Selection {
        guard let previous else { return next }
        var result = next
        if let lead = previous.lastWordLead, let delay = next.firstWordDelay, lead <= seamWindow, delay <= seamWindow,
            let lastWord = previous.text.split(separator: " ").last, let firstWord = next.text.split(separator: " ").first,
            normalized(lastWord) == normalized(firstWord)
        {
            result.text = next.text.dropFirst(firstWord.count).trimmingCharacters(in: .whitespaces)
        } else if let after = previous.wordAfterCore, let before = next.wordBeforeCore, after.delay <= seamWindow,
            before.lead <= seamWindow, normalized(Substring(after.text)) == normalized(Substring(before.text))
        {
            result.text = (before.text + " " + next.text).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func normalized(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

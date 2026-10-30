import Foundation

/// Canonical terms, each with the mishearings that are rewritten to it.
///
/// Matching is one left-to-right pass. At each position the longest match wins, matches must sit on word boundaries,
/// and replaced text is never rescanned. A match sits on word boundaries when the characters just before and just after
/// it are not letters or digits. Matching ignores case, and any run of whitespace matches any other run of whitespace.
/// The JSON form is `{"corrections": [{"canonical": "Claude Code", "mishearings": ["cloud code"]}]}`.
public struct VocabularyCorrections: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var canonical: String
        public var mishearings: [String]

        public init(canonical: String, mishearings: [String]) {
            self.canonical = canonical
            self.mishearings = mishearings
        }
    }

    public var corrections: [Entry]

    public init(corrections: [Entry] = []) {
        self.corrections = corrections
    }

    /// Starting vocabulary for software-development dictation.
    public static let seed = VocabularyCorrections(corrections: [
        Entry(canonical: "Claude Code", mishearings: ["cloud code", "clawed code", "claud code", "clod code"]),
        Entry(canonical: "MCP", mishearings: ["m c p", "em see pee", "mcp"]),
        Entry(canonical: "SwiftUI", mishearings: ["swift ui", "swift you eye", "swift u i"]),
        Entry(canonical: "worktree", mishearings: ["work tree", "work-tree"]),
        Entry(
            canonical: "CLAUDE.md",
            mishearings: ["claude dot md", "claude dot m d", "cloud dot md", "claude md", "cloud md", "cloud.md", "claud md"]),
    ])

    /// Loads corrections from a JSON file.
    public static func load(from url: URL) throws -> VocabularyCorrections {
        try JSONDecoder().decode(VocabularyCorrections.self, from: Data(contentsOf: url))
    }

    /// Writes corrections to a JSON file atomically.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Returns a copy with `mishearing` added to the entry for `canonical`, creating the entry if none exists. Entries
    /// are matched on `canonical` ignoring case. Both strings are trimmed of surrounding whitespace first, and the copy
    /// is returned unchanged if either is then empty. A mishearing that equals an existing mishearing or the canonical,
    /// ignoring case, is not added.
    public func adding(canonical: String, mishearing: String) -> VocabularyCorrections {
        let canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let mishearing = mishearing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty, !mishearing.isEmpty else { return self }
        var result = self
        let index = result.corrections.firstIndex { $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame }
        guard let index else {
            let isCanonical = mishearing.caseInsensitiveCompare(canonical) == .orderedSame
            result.corrections.append(Entry(canonical: canonical, mishearings: isCanonical ? [] : [mishearing]))
            return result
        }
        let existing = result.corrections[index]
        let isKnown = existing.mishearings.contains { $0.caseInsensitiveCompare(mishearing) == .orderedSame }
            || existing.canonical.caseInsensitiveCompare(mishearing) == .orderedSame
        if !isKnown { result.corrections[index].mishearings.append(mishearing) }
        return result
    }

    /// Rewrites every recognized mishearing and miscased canonical in `text`. A canonical written entirely in
    /// lowercase, such as "worktree", takes the capitalization of the matched text: all capitals when the match has two
    /// or more letters and all of them are capitals, an initial capital when the match starts with a capital. Any other
    /// canonical is inserted as written.
    public func apply(to text: String) -> String {
        let patterns = makePatterns()
        guard !patterns.isEmpty else { return text }
        let characters = Array(text)
        var output = ""
        var position = 0
        while position < characters.count {
            if let match = longestMatch(at: position, in: characters, patterns: patterns) {
                let matched = String(characters[position..<(position + match.length)])
                output += Self.replacement(canonical: match.canonical, matchedText: matched)
                position += match.length
            } else {
                output.append(characters[position])
                position += 1
            }
        }
        return output
    }

    private struct Pattern {
        let tokens: [String]
        let canonical: String
    }

    private func makePatterns() -> [Pattern] {
        var patterns: [Pattern] = []
        for entry in corrections {
            for phrase in entry.mishearings + [entry.canonical] {
                var tokens: [String] = []
                for character in phrase.trimmingCharacters(in: .whitespacesAndNewlines) {
                    if character.isWhitespace {
                        if tokens.last != " " { tokens.append(" ") }
                    } else {
                        tokens.append(character.lowercased())
                    }
                }
                if !tokens.isEmpty { patterns.append(Pattern(tokens: tokens, canonical: entry.canonical)) }
            }
        }
        return patterns
    }

    private func longestMatch(
        at start: Int, in characters: [Character], patterns: [Pattern]
    ) -> (length: Int, canonical: String)? {
        if start > 0, Self.isWordCharacter(characters[start - 1]) { return nil }
        var best: (length: Int, canonical: String)?
        for pattern in patterns {
            guard let length = Self.matchLength(pattern.tokens, in: characters, at: start) else { continue }
            let end = start + length
            if end < characters.count, Self.isWordCharacter(characters[end]) { continue }
            if length > (best?.length ?? 0) { best = (length, pattern.canonical) }
        }
        return best
    }

    private static func matchLength(_ tokens: [String], in characters: [Character], at start: Int) -> Int? {
        var cursor = start
        for token in tokens {
            guard cursor < characters.count else { return nil }
            if token == " " {
                guard characters[cursor].isWhitespace else { return nil }
                while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            } else {
                guard characters[cursor].lowercased() == token else { return nil }
                cursor += 1
            }
        }
        return cursor - start
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func replacement(canonical: String, matchedText: String) -> String {
        guard canonical == canonical.lowercased(), canonical.contains(where: \.isLetter) else { return canonical }
        let letters = matchedText.filter(\.isLetter)
        if letters.count > 1, letters == letters.uppercased() { return canonical.uppercased() }
        if let first = letters.first, first.isUppercase {
            return canonical.prefix(1).uppercased() + canonical.dropFirst()
        }
        return canonical
    }
}

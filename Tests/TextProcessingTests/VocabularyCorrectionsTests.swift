import XCTest

@testable import TextProcessing

final class VocabularyCorrectionsTests: XCTestCase {
    private let seed = VocabularyCorrections.seed

    func testReplacesMishearingWithCanonical() {
        XCTAssertEqual(seed.apply(to: "open cloud code now"), "open Claude Code now")
    }

    func testCanonicalIsFixedIgnoringCase() {
        XCTAssertEqual(seed.apply(to: "claude code is here"), "Claude Code is here")
        XCTAssertEqual(seed.apply(to: "CLAUDE CODE"), "Claude Code")
    }

    func testDoesNotMatchInsideLargerWord() {
        XCTAssertEqual(seed.apply(to: "cloud codes"), "cloud codes")
        XCTAssertEqual(seed.apply(to: "the cloud coded it"), "the cloud coded it")
        XCTAssertEqual(seed.apply(to: "supercloud code"), "supercloud code")
    }

    func testMatchesBeforePunctuation() {
        XCTAssertEqual(seed.apply(to: "use cloud code."), "use Claude Code.")
        XCTAssertEqual(seed.apply(to: "(cloud code)"), "(Claude Code)")
    }

    func testLongestMatchWins() {
        let corrections = VocabularyCorrections(corrections: [
            .init(canonical: "Claude", mishearings: ["claude"]),
            .init(canonical: "CLAUDE.md", mishearings: ["claude dot md", "claude md"]),
        ])
        XCTAssertEqual(corrections.apply(to: "edit claude dot md please"), "edit CLAUDE.md please")
        XCTAssertEqual(corrections.apply(to: "edit claude please"), "edit Claude please")
        XCTAssertEqual(seed.apply(to: "update claude dot md"), "update CLAUDE.md")
        XCTAssertEqual(seed.apply(to: "update claude md"), "update CLAUDE.md")
    }

    func testLongerMishearingBeatsShorterAtSamePosition() {
        let corrections = VocabularyCorrections(corrections: [
            .init(canonical: "Short", mishearings: ["a b"]),
            .init(canonical: "Long", mishearings: ["a b c"]),
        ])
        XCTAssertEqual(corrections.apply(to: "x a b c y"), "x Long y")
        XCTAssertEqual(corrections.apply(to: "x a b y"), "x Short y")
    }

    func testToleratesInternalWhitespaceRuns() {
        XCTAssertEqual(seed.apply(to: "cloud    code and cloud\ncode"), "Claude Code and Claude Code")
    }

    func testLowercaseCanonicalPreservesCapitalizationPattern() {
        XCTAssertEqual(seed.apply(to: "make a work tree"), "make a worktree")
        XCTAssertEqual(seed.apply(to: "Work tree first"), "Worktree first")
        XCTAssertEqual(seed.apply(to: "WORK TREE"), "WORKTREE")
        XCTAssertEqual(seed.apply(to: "a work-tree"), "a worktree")
        XCTAssertEqual(seed.apply(to: "Worktree"), "Worktree")
    }

    func testMixedCaseCanonicalIsUsedExactly() {
        XCTAssertEqual(seed.apply(to: "swift ui and SWIFT UI"), "SwiftUI and SwiftUI")
        XCTAssertEqual(seed.apply(to: "the mcp server and M C P"), "the MCP server and MCP")
    }

    func testReplacedTextIsNotRescanned() {
        let corrections = VocabularyCorrections(corrections: [
            .init(canonical: "Beta", mishearings: ["alpha"]),
            .init(canonical: "Gamma", mishearings: ["beta"]),
        ])
        XCTAssertEqual(corrections.apply(to: "alpha"), "Beta")
        XCTAssertEqual(corrections.apply(to: "alpha alpha"), "Beta Beta")
        XCTAssertEqual(corrections.apply(to: "gamma"), "Gamma")
    }

    func testNumbersAndDotsInTerms() {
        let corrections = VocabularyCorrections(corrections: [
            .init(canonical: "Python 3.12", mishearings: ["python three point twelve", "python 3 .12"]),
            .init(canonical: "S3 Bucket", mishearings: ["s three bucket"]),
        ])
        XCTAssertEqual(corrections.apply(to: "try python three point twelve today"), "try Python 3.12 today")
        XCTAssertEqual(corrections.apply(to: "try python 3 .12 today"), "try Python 3.12 today")
        XCTAssertEqual(corrections.apply(to: "try Python 3.125"), "try Python 3.125")
        XCTAssertEqual(corrections.apply(to: "use s three bucket"), "use S3 Bucket")
    }

    func testSeedContainsExactlyTheExpectedCanonicals() {
        XCTAssertEqual(
            seed.corrections.map(\.canonical),
            ["Claude Code", "MCP", "SwiftUI", "worktree", "CLAUDE.md"])
        let claude = seed.corrections.first { $0.canonical == "Claude Code" }
        XCTAssertEqual(claude?.mishearings, ["cloud code", "clawed code", "claud code", "clod code"])
        let markdown = seed.corrections.first { $0.canonical == "CLAUDE.md" }
        XCTAssertEqual(
            markdown?.mishearings, ["claude dot md", "claude dot m d", "cloud dot md", "claude md", "cloud md", "cloud.md", "claud md"])
    }

    func testAddingCreatesNewEntry() {
        let result = VocabularyCorrections().adding(canonical: "Ollama", mishearing: "olama")
        XCTAssertEqual(result.corrections, [.init(canonical: "Ollama", mishearings: ["olama"])])
        XCTAssertEqual(result.apply(to: "run olama"), "run Ollama")
    }

    func testAddingMergesIntoExistingEntryIgnoringCase() {
        let result = seed.adding(canonical: "claude code", mishearing: "cloud coat")
        XCTAssertEqual(result.corrections.count, seed.corrections.count)
        XCTAssertEqual(
            result.corrections.first { $0.canonical == "Claude Code" }?.mishearings.last, "cloud coat")
    }

    func testAddingDeduplicatesIgnoringCase() {
        let result = seed.adding(canonical: "Claude Code", mishearing: "CLOUD CODE")
        XCTAssertEqual(result, seed)
        XCTAssertEqual(seed.adding(canonical: "Claude Code", mishearing: "claude code"), seed)
    }

    func testAddingIgnoresEmptyInput() {
        XCTAssertEqual(seed.adding(canonical: " ", mishearing: "x"), seed)
        XCTAssertEqual(seed.adding(canonical: "X", mishearing: "  "), seed)
    }

    func testJSONShape() throws {
        let corrections = VocabularyCorrections(corrections: [
            .init(canonical: "Claude Code", mishearings: ["cloud code", "clawed code"])
        ])
        let data = try JSONEncoder().encode(corrections)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["corrections"])
        let entries = try XCTUnwrap(object["corrections"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["canonical"] as? String, "Claude Code")
        XCTAssertEqual(entries[0]["mishearings"] as? [String], ["cloud code", "clawed code"])
    }

    func testLoadsAndSavesFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("corrections.json")
        try Data(#"{"corrections": [{"canonical": "Claude Code", "mishearings": ["cloud code"]}]}"#.utf8).write(to: url)
        let loaded = try VocabularyCorrections.load(from: url)
        XCTAssertEqual(loaded.corrections, [.init(canonical: "Claude Code", mishearings: ["cloud code"])])
        let saveURL = directory.appendingPathComponent("saved.json")
        try seed.save(to: saveURL)
        XCTAssertEqual(try VocabularyCorrections.load(from: saveURL), seed)
    }

    func testEmptyVocabularyAndTextAreNoOps() {
        XCTAssertEqual(VocabularyCorrections().apply(to: "hello"), "hello")
        XCTAssertEqual(seed.apply(to: ""), "")
    }

    func testSeedCoversModelSpellingsOfNames() {
        XCTAssertEqual(
            VocabularyCorrections.seed.apply(to: "running cloud code then check cloud md"), "running Claude Code then check CLAUDE.md")
    }
}

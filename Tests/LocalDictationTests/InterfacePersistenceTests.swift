import AppKit
import DictationCore
import TextProcessing
import XCTest
@testable import LocalDictation

final class InterfacePersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testHistoryRemainsOffForNewAndOlderConfigurations() throws {
        XCTAssertFalse(DictationConfiguration().keepsHistory)
        let decoded = try JSONDecoder().decode(DictationConfiguration.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.keepsHistory)
        XCTAssertEqual(decoded.profiles.defaultProfile, .verbatim)
    }

    @MainActor func testCorrectionsPreserveAllFormsWhenOnlyReplacementChanges() throws {
        let file = try directory().appendingPathComponent("vocabulary.json")
        let original = VocabularyCorrections(corrections: [
            .init(canonical: "Project", mishearings: ["project one", " project two ", "project, three"]),
            .init(canonical: "Another", mishearings: ["an other"]),
        ])
        try original.save(to: file)
        let document = CorrectionsDocument(fileURL: file)
        document.rows[0].canonical = "Project Name"
        XCTAssertTrue(document.save())
        let saved = try VocabularyCorrections.load(from: file)
        XCTAssertEqual(saved.corrections[0].canonical, "Project Name")
        XCTAssertEqual(saved.corrections[0].mishearings, original.corrections[0].mishearings)
        XCTAssertEqual(saved.corrections[1], original.corrections[1])
    }

    @MainActor func testCorrectionsRejectUnreadableFileWithoutOverwritingIt() throws {
        let file = try directory().appendingPathComponent("vocabulary.json")
        let contents = Data("not valid JSON".utf8)
        try contents.write(to: file)
        let document = CorrectionsDocument(fileURL: file)
        document.rows = [VocabularyCorrectionRow(.init(canonical: "Project", mishearings: ["pro ject"]))]
        XCTAssertFalse(document.save())
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    @MainActor func testCorrectionsDoNotOverwriteConcurrentEdits() throws {
        let file = try directory().appendingPathComponent("vocabulary.json")
        try VocabularyCorrections(corrections: [.init(canonical: "First", mishearings: ["first"])]).save(to: file)
        let document = CorrectionsDocument(fileURL: file)
        let external = VocabularyCorrections(corrections: [.init(canonical: "Second", mishearings: ["second"])] )
        try external.save(to: file)
        document.rows[0].canonical = "Changed"
        XCTAssertFalse(document.save())
        XCTAssertEqual(try VocabularyCorrections.load(from: file), external)
    }

    @MainActor func testMenuReflectsHistoryPauseRecordingAndLoginState() {
        let menu = NSMenu()
        StatusMenu.populate(menu, state: .init(recording: true, canPaste: true, keepsHistory: true, paused: true, opensAtLogin: true), target: nil)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "separator" : String($0.title.split(separator: "\t", omittingEmptySubsequences: false)[0]) }, [
            "Stop dictation", "Paste last text", "Show history", "Resume all shortcuts", "separator", "Open at login", "Settings…", "Quit Local Dictation",
        ])
        XCTAssertEqual(menu.items[5].state, .on)
        XCTAssertEqual(menu.items[6].keyEquivalent, ",")
        XCTAssertEqual(menu.items[7].keyEquivalent, "q")
        XCTAssertEqual(menu.items[0].keyEquivalent, "")
        XCTAssertNil(menu.items[0].attributedTitle)
        XCTAssertEqual(menu.items[1].keyEquivalent, "v")
        XCTAssertEqual(menu.items[1].keyEquivalentModifierMask, [.option, .shift])
        StatusMenu.populate(menu, state: .init(), target: nil)
        XCTAssertFalse(menu.items.contains { $0.title == "Show history" })
        XCTAssertFalse(menu.items.first {  $0.title.hasPrefix("Paste last text") }!.isEnabled)
    }
}

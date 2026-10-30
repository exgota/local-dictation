import SQLite3
import XCTest

@testable import TranscriptHistory

final class TranscriptHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent("history.sqlite") }

    private func makeEntry(
        _ text: String = "hello", at seconds: TimeInterval = 1_000, bundle: String? = "com.example.App",
        name: String? = "Example"
    ) -> TranscriptHistoryEntry {
        TranscriptHistoryEntry(
            timestamp: Date(timeIntervalSince1970: seconds), durationSeconds: 2.5, rawText: "raw " + text,
            finalText: "final " + text, applicationBundleIdentifier: bundle, applicationName: name)
    }

    func testAppendAndReadBack() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        let identifier = try await store.append(makeEntry())
        let entries = try await store.recentEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].identifier, identifier)
        XCTAssertEqual(entries[0].timestamp, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(entries[0].durationSeconds, 2.5)
        XCTAssertEqual(entries[0].rawText, "raw hello")
        XCTAssertEqual(entries[0].finalText, "final hello")
        XCTAssertEqual(entries[0].applicationBundleIdentifier, "com.example.App")
        XCTAssertEqual(entries[0].applicationName, "Example")
    }

    func testIdentifiersIncrease() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        let first = try await store.append(makeEntry("a"))
        let second = try await store.append(makeEntry("b"))
        XCTAssertGreaterThan(second, first)
    }

    func testNewestFirstOrderingAndLimit() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        try await store.append(makeEntry("middle", at: 2_000))
        try await store.append(makeEntry("oldest", at: 1_000))
        try await store.append(makeEntry("newest", at: 3_000))
        let all = try await store.recentEntries(limit: 10)
        XCTAssertEqual(all.map(\.finalText), ["final newest", "final middle", "final oldest"])
        let limited = try await store.recentEntries(limit: 2)
        XCTAssertEqual(limited.map(\.finalText), ["final newest", "final middle"])
        let none = try await store.recentEntries(limit: 0)
        XCTAssertTrue(none.isEmpty)
    }

    func testEqualTimestampsOrderByNewestInsertion() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        try await store.append(makeEntry("first", at: 5))
        try await store.append(makeEntry("second", at: 5))
        let entries = try await store.recentEntries(limit: 10)
        XCTAssertEqual(entries.map(\.finalText), ["final second", "final first"])
    }

    func testNilApplicationFieldsRoundTrip() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        try await store.append(makeEntry(bundle: nil, name: nil))
        let entry = try await store.recentEntries(limit: 1)[0]
        XCTAssertNil(entry.applicationBundleIdentifier)
        XCTAssertNil(entry.applicationName)
    }

    func testDeleteRemovesOnlyThatEntry() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        let first = try await store.append(makeEntry("a", at: 1))
        try await store.append(makeEntry("b", at: 2))
        try await store.delete(identifier: first)
        let entries = try await store.recentEntries(limit: 10)
        XCTAssertEqual(entries.map(\.finalText), ["final b"])
        try await store.delete(identifier: 9_999)
        let afterMissing = try await store.recentEntries(limit: 10)
        XCTAssertEqual(afterMissing.count, 1)
    }

    func testDeleteAll() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        try await store.append(makeEntry("a"))
        try await store.append(makeEntry("b"))
        try await store.deleteAll()
        let entries = try await store.recentEntries(limit: 10)
        XCTAssertTrue(entries.isEmpty)
    }

    func testPersistsAcrossReopen() async throws {
        do {
            let store = try TranscriptHistoryStore(databaseURL: databaseURL)
            try await store.append(makeEntry("kept"))
        }
        let reopened = try TranscriptHistoryStore(databaseURL: databaseURL)
        let entries = try await reopened.recentEntries(limit: 10)
        XCTAssertEqual(entries.map(\.finalText), ["final kept"])
    }

    func testBindsQuotesAndUnicodeAsData() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        let hostile = "Robert'); DROP TABLE transcript_history;-- \"quoted\" \u{1F600} caf\u{E9} \u{65E5}\u{672C}\u{8A9E}"
        var entry = makeEntry()
        entry.rawText = hostile
        entry.finalText = "it's \"fine\" %s ?"
        entry.applicationName = "O'Reilly \u{1F4D8}"
        try await store.append(entry)
        try await store.append(makeEntry("after", at: 2_000))
        let entries = try await store.recentEntries(limit: 10)
        XCTAssertEqual(entries.count, 2)
        let stored = try XCTUnwrap(entries.last)
        XCTAssertEqual(stored.rawText, hostile)
        XCTAssertEqual(stored.finalText, "it's \"fine\" %s ?")
        XCTAssertEqual(stored.applicationName, "O'Reilly \u{1F4D8}")
    }

    func testStoresEmbeddedNewlinesAndEmptyText() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        var entry = makeEntry()
        entry.rawText = ""
        entry.finalText = "line one\n\nline two"
        try await store.append(entry)
        let stored = try await store.recentEntries(limit: 1)[0]
        XCTAssertEqual(stored.rawText, "")
        XCTAssertEqual(stored.finalText, "line one\n\nline two")
    }

    func testFileIsPrivateAndUsesWriteAheadLoggingWithSchemaVersionOne() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        try await store.append(makeEntry())
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(try singleValue("PRAGMA journal_mode", in: handle), "wal")
        XCTAssertEqual(try singleValue("PRAGMA user_version", in: handle), "1")
        XCTAssertEqual(
            try singleValue("SELECT group_concat(name) FROM pragma_table_info('transcript_history')", in: handle),
            "id,timestamp,duration_seconds,raw_text,final_text,application_bundle_identifier,application_name")
    }

    func testRejectsNewerSchemaVersion() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        sqlite3_exec(handle, "PRAGMA user_version = 7", nil, nil, nil)
        sqlite3_close(handle)
        XCTAssertThrowsError(try TranscriptHistoryStore(databaseURL: databaseURL)) { error in
            XCTAssertEqual(error as? TranscriptHistoryError, .unsupportedSchemaVersion(7))
        }
    }

    func testCreatesMissingParentDirectories() async throws {
        let nested = directory.appendingPathComponent("a/b/history.sqlite")
        let store = try TranscriptHistoryStore(databaseURL: nested)
        try await store.append(makeEntry())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testConcurrentAppendsAreAllStored() async throws {
        let store = try TranscriptHistoryStore(databaseURL: databaseURL)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                let entry = makeEntry("n\(index)", at: Double(index))
                group.addTask { try await store.append(entry) }
            }
            try await group.waitForAll()
        }
        let entries = try await store.recentEntries(limit: 100)
        XCTAssertEqual(entries.count, 50)
    }

    private func singleValue(_ sql: String, in handle: OpaquePointer?) throws -> String {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return String(cString: sqlite3_column_text(statement, 0))
    }
}

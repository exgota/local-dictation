import Foundation
import SQLite3

/// One dictation, as stored in the history database.
public struct TranscriptHistoryEntry: Equatable, Sendable {
    /// Row identifier. `recentEntries` sets it. A new entry leaves it nil; `append` ignores it and returns the new
    /// identifier.
    public var identifier: Int64?
    public var timestamp: Date
    public var durationSeconds: Double
    public var rawText: String
    public var finalText: String
    public var applicationBundleIdentifier: String?
    public var applicationName: String?

    public init(
        identifier: Int64? = nil,
        timestamp: Date,
        durationSeconds: Double,
        rawText: String,
        finalText: String,
        applicationBundleIdentifier: String? = nil,
        applicationName: String? = nil
    ) {
        self.identifier = identifier
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.rawText = rawText
        self.finalText = finalText
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationName = applicationName
    }
}

public enum TranscriptHistoryError: LocalizedError, Equatable {
    case openFailed(String)
    case statementFailed(String)
    case unsupportedSchemaVersion(Int32)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "Could not open the transcript history database: \(message)"
        case .statementFailed(let message): return "Transcript history database error: \(message)"
        case .unsupportedSchemaVersion(let version):
            return "The transcript history database uses schema version \(version), which this build does not support."
        }
    }
}

/// Stores transcript history in SQLite: WAL journal, schema version in `user_version`, file mode 0600.
///
/// Every value from the caller reaches SQLite as a bound parameter. The actor serializes access to the single
/// connection.
public actor TranscriptHistoryStore {
    static let currentSchemaVersion: Int32 = 1

    /// Set once in `init`. Unsafe isolation lets `deinit` close it; no other reference to the actor remains by then.
    private nonisolated(unsafe) let database: OpaquePointer?

    /// Opens or creates the database at `databaseURL`, creating missing parent directories, and sets the file mode to
    /// 0600. Throws `unsupportedSchemaVersion` when the database was written by a newer schema version than this build
    /// supports.
    public init(databaseURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: databaseURL.path) {
            guard fileManager.createFile(atPath: databaseURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw TranscriptHistoryError.openFailed("cannot create \(databaseURL.path)") }
        } else {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw TranscriptHistoryError.openFailed(message)
        }
        do {
            try Self.configure(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        database = handle
    }

    deinit {
        sqlite3_close(database)
    }

    /// Stores `entry` (its `identifier` is ignored) and returns the new row identifier.
    @discardableResult
    public func append(_ entry: TranscriptHistoryEntry) throws -> Int64 {
        let sql = """
            INSERT INTO transcript_history
            (timestamp, duration_seconds, raw_text, final_text, application_bundle_identifier, application_name)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        let statement = try Self.prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, entry.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, entry.durationSeconds)
        Self.bind(entry.rawText, at: 3, in: statement)
        Self.bind(entry.finalText, at: 4, in: statement)
        Self.bind(entry.applicationBundleIdentifier, at: 5, in: statement)
        Self.bind(entry.applicationName, at: 6, in: statement)
        try Self.stepToCompletion(statement, on: database)
        return sqlite3_last_insert_rowid(database)
    }

    /// Returns up to `limit` entries, newest first. Entries with equal timestamps are ordered by identifier, highest
    /// first. A `limit` of zero or less returns no entries.
    public func recentEntries(limit: Int) throws -> [TranscriptHistoryEntry] {
        guard limit > 0 else { return [] }
        let sql = """
            SELECT id, timestamp, duration_seconds, raw_text, final_text, application_bundle_identifier, application_name
            FROM transcript_history ORDER BY timestamp DESC, id DESC LIMIT ?
            """
        let statement = try Self.prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        var entries: [TranscriptHistoryEntry] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TranscriptHistoryError.statementFailed(Self.message(of: database))
            }
            entries.append(
                TranscriptHistoryEntry(
                    identifier: sqlite3_column_int64(statement, 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    durationSeconds: sqlite3_column_double(statement, 2),
                    rawText: Self.text(at: 3, in: statement) ?? "",
                    finalText: Self.text(at: 4, in: statement) ?? "",
                    applicationBundleIdentifier: Self.text(at: 5, in: statement),
                    applicationName: Self.text(at: 6, in: statement)))
        }
        return entries
    }

    /// Deletes the entry with `identifier`; a missing identifier is not an error.
    public func delete(identifier: Int64) throws {
        let statement = try Self.prepare("DELETE FROM transcript_history WHERE id = ?", on: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, identifier)
        try Self.stepToCompletion(statement, on: database)
    }

    /// Deletes every entry.
    public func deleteAll() throws {
        let statement = try Self.prepare("DELETE FROM transcript_history", on: database)
        defer { sqlite3_finalize(statement) }
        try Self.stepToCompletion(statement, on: database)
    }

    // MARK: - SQLite helpers

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func configure(_ database: OpaquePointer?) throws {
        try execute("PRAGMA journal_mode = WAL", on: database)
        var version: Int32 = 0
        let statement = try prepare("PRAGMA user_version", on: database)
        if sqlite3_step(statement) == SQLITE_ROW { version = sqlite3_column_int(statement, 0) }
        sqlite3_finalize(statement)
        guard version <= currentSchemaVersion else { throw TranscriptHistoryError.unsupportedSchemaVersion(version) }
        if version < 1 {
            try execute("BEGIN IMMEDIATE", on: database)
            do {
                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS transcript_history (
                        id INTEGER PRIMARY KEY,
                        timestamp REAL NOT NULL,
                        duration_seconds REAL NOT NULL,
                        raw_text TEXT NOT NULL,
                        final_text TEXT NOT NULL,
                        application_bundle_identifier TEXT,
                        application_name TEXT
                    )
                    """, on: database)
                try execute(
                    "CREATE INDEX IF NOT EXISTS transcript_history_timestamp ON transcript_history (timestamp)",
                    on: database)
                try execute("PRAGMA user_version = 1", on: database)
                try execute("COMMIT", on: database)
            } catch {
                try? execute("ROLLBACK", on: database)
                throw error
            }
        }
    }

    private static func execute(_ sql: String, on database: OpaquePointer?) throws {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw TranscriptHistoryError.statementFailed(message(of: database)) }
    }

    private static func prepare(_ sql: String, on database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let failure = TranscriptHistoryError.statementFailed(message(of: database))
            sqlite3_finalize(statement)
            throw failure
        }
        return statement
    }

    private static func stepToCompletion(_ statement: OpaquePointer?, on database: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TranscriptHistoryError.statementFailed(message(of: database))
        }
    }

    private static func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transientDestructor)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func text(at column: Int32, in statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let bytes = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: bytes)
    }

    private static func message(of database: OpaquePointer?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }
}

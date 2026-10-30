import Darwin
import Foundation
import os

/// Events and timings, never transcript text. Written to the unified log and to `local-dictation.log` in
/// `~/Library/Logs/LocalDictation/`. The file is rotated when it exceeds 1 MB, and five files are kept: the current
/// file and four earlier generations.
final class EventLog: @unchecked Sendable {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LocalDictation", isDirectory: true)
    static let currentFileURL = directory.appendingPathComponent("local-dictation.log")
    private static let maximumFileBytes = 1_000_000
    private static let retainedGenerations = 5

    private let logger = Logger(subsystem: "com.exgota.LocalDictation", category: "dictation")
    private let queue = DispatchQueue(label: "LocalDictation.EventLog", qos: .utility)
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        append(level: "notice", message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append(level: "error", message)
    }

    /// The most recent error lines from the current log file, newest last.
    static func recentErrors(limit: Int = 10) -> [String] {
        guard let text = try? String(contentsOf: currentFileURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").filter { $0.contains(" error ") }.suffix(limit).map(String.init))
    }

    private func append(level: String, _ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) \(level) \(message)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let url = Self.currentFileURL
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maximumFileBytes {
                Self.rotate()
            }
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    private static func rotate() {
        let manager = FileManager.default
        let generation = { (index: Int) in directory.appendingPathComponent("local-dictation.\(index).log") }
        try? manager.removeItem(at: generation(retainedGenerations - 1))
        for index in stride(from: retainedGenerations - 2, through: 1, by: -1) {
            try? manager.moveItem(at: generation(index), to: generation(index + 1))
        }
        try? manager.moveItem(at: currentFileURL, to: generation(1))
    }
}

let dictationLog = EventLog()

/// Writes a crash report with a backtrace to `~/Library/Logs/LocalDictation/crash-<pid>.log` on fatal signals and
/// uncaught Objective-C exceptions. The signal handler uses the C functions `open` and `write`, not Foundation file
/// APIs. It still allocates a Swift string and an array, which is not async-signal-safe.
enum CrashReporter {
    /// Written once by `install` before the handlers are registered, then only read.
    nonisolated(unsafe) private static var crashPath: UnsafeMutablePointer<CChar>?

    static func install() {
        try? FileManager.default.createDirectory(at: EventLog.directory, withIntermediateDirectories: true)
        let path = EventLog.directory.appendingPathComponent("crash-\(getpid()).log").path
        crashPath = strdup(path)
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            signal(signalNumber, crashSignalHandler)
        }
        NSSetUncaughtExceptionHandler { exception in
            let report = "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n"
            if let path = CrashReporter.crashPath { try? report.write(toFile: String(cString: path), atomically: true, encoding: .utf8) }
        }
    }

    fileprivate static func writeReport(signal signalNumber: Int32) {
        guard let crashPath else { return }
        let descriptor = open(crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { return }
        let header = "Local Dictation terminated by signal \(signalNumber)\n"
        _ = header.withCString { write(descriptor, $0, strlen($0)) }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, 64)
        backtrace_symbols_fd(&frames, count, descriptor)
        close(descriptor)
    }
}

private func crashSignalHandler(_ signalNumber: Int32) {
    CrashReporter.writeReport(signal: signalNumber)
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

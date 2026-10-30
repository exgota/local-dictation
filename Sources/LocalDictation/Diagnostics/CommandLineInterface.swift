import AppKit
import Foundation

/// Flags on the bundled binary, `Local Dictation.app/Contents/MacOS/LocalDictation`:
///
///     --doctor                 permissions, Fn mapping, secure input, microphone, model cache, tap health, recent errors
///     --selftest [DIRECTORY]   fixtures through the real pipeline with word error rate and latency
///     --toggle-transcription   start or stop dictation in the running app
///     --cancel                 cancel dictation in the running app
///     --bundle-logs            zip of logs, crash reports and doctor output
///
/// Exit status 0 means success or, for `--doctor` and `--selftest`, a clean result. Status 1 means failure or an
/// unclean result. Status 2 means an unrecognized flag or, for `--selftest`, a run that could not start.
enum CommandLineInterface {
    static let usage = """
        Usage: LocalDictation [--doctor | --selftest [DIRECTORY] | --toggle-transcription | --cancel | --bundle-logs]
        """

    static func run(_ arguments: [String]) async -> Int32 {
        switch arguments.first {
        case "--doctor":
            let report = await doctorReport()
            print(report.text)
            return report.isClean ? 0 : 1
        case "--selftest":
            let directory = arguments.dropFirst().first.map { URL(fileURLWithPath: $0) } ?? ApplicationFiles.fixturesDirectory
            return await SelfTest.run(directory: directory)
        case "--toggle-transcription":
            return send(.toggleTranscription)
        case "--cancel":
            return send(.cancel)
        case "--bundle-logs":
            return await bundleLogs()
        default:
            print(usage)
            return 2
        }
    }

    private static func send(_ command: CommandChannel.Command) -> Int32 {
        guard CommandChannel.runningInstance != nil, CommandChannel.send(command) == "ok" else {
            print("Local Dictation is not running, or did not accept the command.")
            return 1
        }
        return 0
    }

    /// The running app supplies what only it knows: the permissions granted to it, the event tap health and the model
    /// state. When no app answers, those checks are reported as unknown.
    @MainActor static func doctorReport() async -> DoctorReport {
        if CommandChannel.runningInstance != nil, let reply = CommandChannel.send(.report),
            let report = try? JSONDecoder().decode(DoctorReport.self, from: Data(reply.utf8))
        {
            return report
        }
        return DoctorReport.collect(runtime: nil, configuration: DictationSettings.readConfiguration())
    }

    /// Logs carry events and timings only, never transcript text. Each file in the bundle has the home directory path
    /// shortened to `~`.
    @MainActor private static func bundleLogs() async -> Int32 {
        let manager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let staging = manager.temporaryDirectory.appendingPathComponent("LocalDictation-support-\(stamp)", isDirectory: true)
        let output = EventLog.directory.appendingPathComponent("support-bundle-\(stamp).zip")
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: staging) }
            let home = manager.homeDirectoryForCurrentUser.path
            let redact = { (text: String) in text.replacingOccurrences(of: home, with: "~") }
            for name in (try? manager.contentsOfDirectory(atPath: EventLog.directory.path)) ?? [] where name.hasSuffix(".log") {
                let text = (try? String(contentsOf: EventLog.directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
                try redact(text).write(to: staging.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let diagnostics = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
            for name in (try? manager.contentsOfDirectory(atPath: diagnostics.path)) ?? [] where name.hasPrefix("LocalDictation") {
                let text = (try? String(contentsOf: diagnostics.appendingPathComponent(name), encoding: .utf8)) ?? ""
                try redact(text).write(to: staging.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try redact(await doctorReport().text).write(to: staging.appendingPathComponent("doctor.txt"), atomically: true, encoding: .utf8)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zip.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", staging.path, output.path]
            try zip.run()
            zip.waitUntilExit()
            guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            print(output.path)
            return 0
        } catch {
            print("The log bundle could not be written: \(error.localizedDescription)")
            return 1
        }
    }
}

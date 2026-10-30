import Foundation

/// Writes each transcript to `<folder>/<yyyy-MM-dd>/<HH-mm-ss> <first words>.md`, with a small front matter block
/// so agents can filter by date, app or style without parsing prose. A file is never overwritten: when the name
/// exists, a numeric suffix starting at 2 is added.
enum TranscriptArchive {
    static func write(
        rawText: String, finalText: String, date: Date, durationSeconds: Double, applicationName: String?,
        bundleIdentifier: String?, style: String, folder: URL
    ) throws -> URL {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let time = String(format: "%02d-%02d-%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let directory = folder.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var url = directory.appendingPathComponent("\(time) \(titleWords(finalText)).md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(time) \(titleWords(finalText)) \(suffix).md")
            suffix += 1
        }

        let timestamp = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime])
        var lines = [
            "---",
            "date: \(timestamp)",
            "app: \(quoted(applicationName ?? "unknown"))",
            "bundle: \(bundleIdentifier ?? "unknown")",
            "duration_seconds: \(String(format: "%.1f", durationSeconds))",
            "style: \(style)",
            "---",
            "",
            finalText,
        ]
        if rawText != finalText { lines += ["", "## Raw transcript", "", rawText] }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Leading fillers carry no meaning in a file name.
    private static let fillers: Set<String> = ["um", "uh", "erm", "uhm", "hmm", "so", "okay", "ok", "like", "yeah", "well", "and"]

    /// Up to eight lowercase words from `text`, after any leading fillers. Characters other than letters, digits and
    /// apostrophes become word breaks, so the result is safe in a file name. Returns "untitled" when no word remains.
    static func titleWords(_ text: String) -> String {
        let words = text.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
            .drop { fillers.contains($0) }
            .prefix(8)
        return words.isEmpty ? "untitled" : words.joined(separator: " ")
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
    }
}

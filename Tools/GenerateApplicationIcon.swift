// Draws the moon layer of Packaging/AppIcon.icon with the application's Metal renderer. The icon's fill, shadow and
// layer settings live in Packaging/AppIcon.icon/icon.json, which Icon Composer opens and edits.
// Run from the repository: swift Tools/GenerateApplicationIcon.swift

import Foundation

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDictationIcon-" + UUID().uuidString, isDirectory: true)
defer { try? FileManager.default.removeItem(at: directory) }

func run(_ executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = repository
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("Command failed: \(executable), status \(process.terminationStatus)") }
}

// This builds a separate command-line executable. It does not assemble, sign or install the application.
try run("/usr/bin/xcrun", arguments: ["swift", "build", "--jobs", "1", "--product", "LocalDictation"])
try run(repository.appendingPathComponent(".build/debug/LocalDictation").path,
        arguments: ["--generate-application-icon", directory.path])
let output = repository.appendingPathComponent("Packaging/AppIcon.icon/Assets/moon.png")
try? FileManager.default.removeItem(at: output)
try FileManager.default.copyItem(at: directory.appendingPathComponent("moon.png"), to: output)
print("Wrote \(output.path)")

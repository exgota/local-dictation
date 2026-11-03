// Draws one 1024 px moon master with the application's Metal renderer, then scales that master for every icon size.
// Run from the repository: swift Tools/GenerateApplicationIcon.swift

import Foundation

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDictationIcon-" + UUID().uuidString, isDirectory: true)
let iconset = directory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
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
for points in [16, 32, 128, 256, 512] {
    try FileManager.default.copyItem(at: directory.appendingPathComponent("icon_\(points).png"),
                                     to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try FileManager.default.copyItem(at: directory.appendingPathComponent("icon_\(points * 2).png"),
                                     to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let output = repository.appendingPathComponent("Packaging/AppIcon.icns")
try run("/usr/bin/iconutil", arguments: ["--convert", "icns", "--output", output.path, iconset.path])
print("Wrote \(output.path)")

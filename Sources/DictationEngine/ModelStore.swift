import CoreML
import CryptoKit
import Foundation

public enum ModelInstallationError: LocalizedError {
    case httpStatus(path: String, status: Int)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case checksumMismatch(path: String)
    case missingComponent(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let path, let status): return "Download of \(path) failed with HTTP status \(status)."
        case .sizeMismatch(let path, let expected, let actual):
            return "\(path) has \(actual) bytes; expected \(expected)."
        case .checksumMismatch(let path): return "\(path) failed SHA-256 validation."
        case .missingComponent(let name): return "Model component \(name) is missing."
        case .cancelled: return "Model installation was cancelled."
        }
    }
}

public struct InstallationProgress: Sendable {
    public enum Phase: Sendable { case downloading, validating, compiling }
    public let phase: Phase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let currentFile: String

    public var fraction: Double { totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0 }
}

/// Owns the on-disk model. It downloads the pinned revision, validates the files, compiles each Core ML package once
/// and keeps the compiled models as a persistent cache.
///
/// Layout under `rootDirectory`:
/// - `<revision>/packages/`: the downloaded files exactly as published. After compilation only the license, the notice
///   and the vocabulary remain.
/// - `<revision>/compiled/<Component>.mlmodelc`: the persistent compiled models.
/// - `<revision>/installation.json`: written last.
/// - `silero-vad/<voice activity revision>/`: the precompiled voice activity model and its own `installation.json`,
///   which records the repository and revision.
///
/// `isInstalled` is true when `<revision>/installation.json` and the vocabulary file exist, every component has a
/// compiled model, and the voice activity `installation.json` exists.
public struct ModelStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalDictation/Models", isDirectory: true)
    }

    public var revisionDirectory: URL { rootDirectory.appendingPathComponent(ModelManifest.revision, isDirectory: true) }
    public var packagesDirectory: URL { revisionDirectory.appendingPathComponent("packages", isDirectory: true) }
    public var compiledDirectory: URL { revisionDirectory.appendingPathComponent("compiled", isDirectory: true) }
    var installationRecordURL: URL { revisionDirectory.appendingPathComponent("installation.json") }
    public var vocabularyURL: URL { packagesDirectory.appendingPathComponent(ModelManifest.vocabularyFileName) }
    public var noticeURL: URL { packagesDirectory.appendingPathComponent("NOTICE") }
    public var licenseURL: URL { packagesDirectory.appendingPathComponent("LICENSE") }
    public var voiceActivityDirectory: URL {
        rootDirectory.appendingPathComponent("silero-vad/\(VoiceActivityModelManifest.revision)", isDirectory: true)
    }
    public var voiceActivityModelURL: URL {
        voiceActivityDirectory.appendingPathComponent(VoiceActivityModelManifest.compiledModelName, isDirectory: true)
    }
    var voiceActivityRecordURL: URL { voiceActivityDirectory.appendingPathComponent("installation.json") }

    public var isInstalled: Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: installationRecordURL.path),
            manager.fileExists(atPath: vocabularyURL.path)
        else { return false }
        return ModelManifest.componentNames.allSatisfy {
            manager.fileExists(atPath: compiledDirectory.appendingPathComponent("\($0).mlmodelc").path)
        } && manager.fileExists(atPath: voiceActivityRecordURL.path)
    }

    /// Downloads every file of the pinned speech model revision and of the voice activity model that is not already
    /// present and valid, validates sizes and SHA-256 digests, compiles each Core ML package once and records the
    /// installation. Safe to call again after a failure: valid files are kept.
    public func install(progress: @escaping @Sendable (InstallationProgress) -> Void) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
        let total = ModelManifest.totalSize + VoiceActivityModelManifest.totalSize
        var completed: Int64 = 0

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let artifacts: [(files: [ModelFile], directory: URL, remoteURL: (ModelFile) -> URL)] = [
            (ModelManifest.files, packagesDirectory, ModelManifest.remoteURL(for:)),
            (VoiceActivityModelManifest.files, voiceActivityDirectory, VoiceActivityModelManifest.remoteURL(for:)),
        ]
        // This method deletes each source package once it is compiled, so a package whose compiled model exists is not
        // fetched again.
        let compiledComponents = Set(ModelManifest.componentNames.filter {
            manager.fileExists(atPath: compiledDirectory.appendingPathComponent("\($0).mlmodelc").path)
        })
        for artifact in artifacts {
            for file in artifact.files {
                try Task.checkCancellation()
                if let component = file.path.split(separator: "/").first?.replacingOccurrences(of: ".mlpackage", with: ""),
                    compiledComponents.contains(component)
                {
                    completed += file.size
                    continue
                }
                let destination = artifact.directory.appendingPathComponent(file.path)
                if manager.fileExists(atPath: destination.path) {
                    progress(InstallationProgress(phase: .validating, completedBytes: completed, totalBytes: total, currentFile: file.path))
                    if (try? Self.validate(fileAt: destination, against: file)) != nil {
                        completed += file.size
                        continue
                    }
                    try? manager.removeItem(at: destination)
                }
                let base = completed
                try await Self.retrying(attempts: 3) {
                    try await Self.download(from: artifact.remoteURL(file), file: file, to: destination, session: session) { received in
                        progress(InstallationProgress(
                            phase: .downloading, completedBytes: base + received, totalBytes: total, currentFile: file.path))
                    }
                }
                progress(InstallationProgress(phase: .validating, completedBytes: base + file.size, totalBytes: total, currentFile: file.path))
                do {
                    try Self.validate(fileAt: destination, against: file)
                } catch {
                    try? manager.removeItem(at: destination)
                    throw error
                }
                completed += file.size
            }
        }
        let voiceActivityRecord = try JSONSerialization.data(
            withJSONObject: ["repository": VoiceActivityModelManifest.repository, "revision": VoiceActivityModelManifest.revision],
            options: [.sortedKeys])
        try voiceActivityRecord.write(to: voiceActivityRecordURL, options: .atomic)

        try manager.createDirectory(at: compiledDirectory, withIntermediateDirectories: true)
        for name in ModelManifest.componentNames {
            try Task.checkCancellation()
            progress(InstallationProgress(phase: .compiling, completedBytes: total, totalBytes: total, currentFile: name))
            let package = packagesDirectory.appendingPathComponent("\(name).mlpackage")
            let destination = compiledDirectory.appendingPathComponent("\(name).mlmodelc")
            if manager.fileExists(atPath: destination.path) { continue }
            guard manager.fileExists(atPath: package.path) else { throw ModelInstallationError.missingComponent(name) }
            let temporary = try await MLModel.compileModel(at: package)
            try manager.moveItem(at: temporary, to: destination)
        }

        // The compiled models are now the installed copy. Keeping the source packages would only double the disk
        // footprint.
        for name in ModelManifest.componentNames {
            try? manager.removeItem(at: packagesDirectory.appendingPathComponent("\(name).mlpackage"))
        }
        let record: [String: String] = [
            "repository": ModelManifest.repository,
            "revision": ModelManifest.revision,
            "installedAt": ISO8601DateFormatter().string(from: Date()),
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: installationRecordURL, options: .atomic)
    }

    /// Removes the installed speech model and voice activity model, including downloaded and compiled files.
    public func remove() throws {
        for directory in [revisionDirectory, voiceActivityDirectory] where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func validate(fileAt url: URL, against file: ModelFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size == file.size else { throw ModelInstallationError.sizeMismatch(path: file.path, expected: file.size, actual: size) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else { throw ModelInstallationError.checksumMismatch(path: file.path) }
    }

    /// Downloads one file. When a download is interrupted or cancelled and URLSession supplies resume data, the resume
    /// data is written next to the destination as `<destination>.resume`. The next attempt, even after a relaunch,
    /// continues where the download stopped.
    static func download(
        from remoteURL: URL, file: ModelFile, to destination: URL, session: URLSession,
        received: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let resumeURL = destination.appendingPathExtension("resume")
        let observer = DownloadProgressObserver(received: received)
        let temporary: URL
        let response: URLResponse
        do {
            if let resumeData = try? Data(contentsOf: resumeURL) {
                // The resume file is removed first, so a resume that the server refuses starts over on the next
                // attempt.
                try? manager.removeItem(at: resumeURL)
                (temporary, response) = try await session.download(resumeFrom: resumeData, delegate: observer)
            } else {
                (temporary, response) = try await session.download(from: remoteURL, delegate: observer)
            }
        } catch {
            if let resumeData = (error as? URLError)?.downloadTaskResumeData { try? resumeData.write(to: resumeURL) }
            throw error
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? manager.removeItem(at: temporary)
            throw ModelInstallationError.httpStatus(path: file.path, status: http.statusCode)
        }
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: temporary, to: destination)
        received(file.size)
    }

    static func retrying(attempts: Int, _ operation: () async throws -> Void) async throws {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                try await operation()
                return
            } catch is CancellationError {
                throw ModelInstallationError.cancelled
            } catch {
                lastError = error
                if attempt + 1 < attempts {
                    try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
                }
            }
        }
        throw lastError!
    }
}

private final class DownloadProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let received: @Sendable (Int64) -> Void

    init(received: @escaping @Sendable (Int64) -> Void) {
        self.received = received
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        received(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

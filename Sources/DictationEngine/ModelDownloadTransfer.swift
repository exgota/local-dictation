import Foundation
import os

/// Explicit download tasks deliver streaming delegate callbacks. The async convenience API does not reliably do so.
final class ModelDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var task: URLSessionDownloadTask?
        var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        var cancelled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let received: @Sendable (Int64) -> Void
    // URLSession serializes delegate callbacks. Only cancellation and initial task publication need the lock.
    private var lastProgressTime: TimeInterval = -.infinity
    private var downloadResult: Result<(URL, URLResponse), Error>?

    init(received: @escaping @Sendable (Int64) -> Void) { self.received = received }

    func download(session: URLSession, remoteURL: URL, resumeData: Data?) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
                    guard !state.cancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: remoteURL)
                    state.continuation = continuation
                    state.task = task
                    task.delegate = self
                    task.resume()
                }
            }
        } onCancel: {
            let task = self.state.withLock { state in
                state.cancelled = true
                return state.task
            }
            // URLSession supplies its normal resume data on the cancellation error, just as for an interrupted task.
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        report(fileOffset)
    }

    private func report(_ bytes: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProgressTime >= 0.1 else { return }
        lastProgressTime = now
        received(bytes)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession deletes location when this callback returns. Keep it alive until ModelStore moves it into place.
        downloadResult = Result {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: temporary)
            return (temporary, response)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = state.withLock { state in
            defer { state.continuation = nil; state.task = nil }
            return state.continuation
        }
        if let error {
            if case .success(let value) = downloadResult { try? FileManager.default.removeItem(at: value.0) }
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(with: downloadResult ?? .failure(URLError(.unknown)))
        }
        downloadResult = nil
    }
}

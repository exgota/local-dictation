import Foundation
import XCTest
import os
@testable import DictationEngine

private final class StreamingDownloadProtocol: URLProtocol, @unchecked Sendable {
    static let chunkSize = 32_768
    static let chunkCount = 24
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let deliveryQueue = DispatchQueue(label: "ModelDownloadTests.StreamingResponse")

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "download.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        deliveryQueue.async { [self] in
            let status = request.url?.path == "/missing" ? 404 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(Self.chunkSize * Self.chunkCount)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            sendChunk(0)
        }
    }

    private func sendChunk(_ index: Int) {
        guard !cancelled.withLock({ $0 }) else { return }
        guard index < Self.chunkCount else { client?.urlProtocolDidFinishLoading(self); return }
        client?.urlProtocol(self, didLoad: Data(repeating: UInt8(index), count: Self.chunkSize))
        deliveryQueue.asyncAfter(deadline: .now() + 0.03) { [self] in sendChunk(index + 1) }
    }

    override func stopLoading() { cancelled.withLock { $0 = true } }
}

final class ModelDownloadTests: XCTestCase, @unchecked Sendable {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingDownloadProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testProgressArrivesBeforeCompletionAndIsThrottled() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("weights.bin")
        let size = Int64(StreamingDownloadProtocol.chunkSize * StreamingDownloadProtocol.chunkCount)
        let values = OSAllocatedUnfairLock(initialState: [(bytes: Int64, time: TimeInterval, exists: Bool)]())
        try await ModelStore.download(from: URL(string: "https://download.invalid/weights")!,
            file: ModelFile(path: "weights.bin", size: size, sha256: ""), to: destination, session: session) { bytes in
                values.withLock { $0.append((bytes, ProcessInfo.processInfo.systemUptime, FileManager.default.fileExists(atPath: destination.path))) }
            }
        let reports = values.withLock { $0 }
        let intermediate = reports.filter { $0.bytes > 0 && $0.bytes < size }
        XCTAssertGreaterThan(intermediate.count, 1)
        XCTAssertTrue(intermediate.allSatisfy { !$0.exists }, "Progress must arrive before the destination is completed")
        for (earlier, later) in zip(intermediate, intermediate.dropFirst()) {
            XCTAssertGreaterThan(later.bytes, earlier.bytes)
            XCTAssertGreaterThanOrEqual(later.time - earlier.time, 0.095)
        }
        XCTAssertEqual(reports.last?.bytes, size)
        XCTAssertEqual(try Data(contentsOf: destination).count, Int(size))
    }

    func testLostConnectionIsNotRetried() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        do {
            try await ModelStore.retrying(attempts: 3) {
                attempts.withLock { $0 += 1 }
                throw URLError(.timedOut)
            }
            XCTFail("expected the timeout to be thrown")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        XCTAssertTrue(ModelStore.shouldRetry(after: URLError(.badServerResponse)))
        XCTAssertFalse(ModelStore.shouldRetry(after: URLError(.notConnectedToInternet)))
    }

    func testHTTPFailureDoesNotCreateDestination() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("weights.bin")
        do {
            try await ModelStore.download(from: URL(string: "https://download.invalid/missing")!,
                file: ModelFile(path: "weights.bin", size: 1, sha256: ""), to: destination, session: session) { _ in }
            XCTFail("HTTP error accepted")
        } catch ModelInstallationError.httpStatus(_, let status) {
            XCTAssertEqual(status, 404)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancellationStopsTransferBeforeDestinationIsWritten() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("weights.bin")
        let arrived = expectation(description: "Partial bytes arrived")
        arrived.assertForOverFulfill = false
        let task = Task {
            try await ModelStore.download(from: URL(string: "https://download.invalid/weights")!,
                file: ModelFile(path: "weights.bin", size: 786_432, sha256: ""), to: destination, session: session) { bytes in
                    if bytes > 0 { arrived.fulfill() }
                }
        }
        await fulfillment(of: [arrived], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled download completed") }
        catch is CancellationError {}
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

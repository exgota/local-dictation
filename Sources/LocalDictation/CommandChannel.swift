import AppKit
import Darwin
import Security

/// Commands between processes of this app: a second launch hands off to the running instance, and the command-line
/// flags `--toggle-transcription`, `--cancel`, `--doctor` and `--bundle-logs` reach it the same way.
///
/// The channel is a Unix socket in the per-user temporary folder, accessible only to the user. The app accepts a
/// command only from a peer that runs as the same user and satisfies this app's own code-signing requirement. It
/// identifies the peer by the kernel's audit token for the connection, so another app, sandboxed or not, cannot start
/// a recording or read a report through the channel. The command line checks only that the listener runs as the same
/// user: verifying the app's signature fails while its bundle is being replaced, and a fake listener could only
/// receive commands.
enum CommandChannel {
    enum Command: String {
        case showSettings
        case showSetup
        case toggleTranscription
        case cancel
        /// The running instance answers with its doctor report as JSON.
        case report
    }

    static let bundleIdentifier = "com.exgota.LocalDictation"
    /// Located in the per-user temporary folder (`/var/folders/…/T/`), which is short enough for the 104-byte limit on
    /// Unix socket paths whatever the home folder path.
    static var socketPath: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let directory = length > 0 ? buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : NSTemporaryDirectory()
        return (directory as NSString).appendingPathComponent("com.exgota.LocalDictation.command")
    }

    static var runningInstance: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    /// Sends `command` to the running instance and returns its reply. Returns nil when the connection, the same-user
    /// check or the write fails, and when the reply is not valid UTF-8.
    static func send(_ command: Command, timeout: TimeInterval = 3) -> String? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        configure(descriptor, timeout: timeout)
        guard var address = socketAddress(),
            withUnsafePointer(to: &address, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }) == 0,
            peerIsSameUser(descriptor),
            writeAll(descriptor, command.rawValue + "\n")
        else { return nil }
        return readAll(descriptor)
    }

    // MARK: Shared

    static func peerIsSameUser(_ descriptor: Int32) -> Bool {
        var userIdentifier: uid_t = 0
        var groupIdentifier: gid_t = 0
        return getpeereid(descriptor, &userIdentifier, &groupIdentifier) == 0 && userIdentifier == getuid()
    }

    /// True when the connecting process runs as this user and satisfies this app's designated requirement.
    static func peerIsTrusted(_ descriptor: Int32) -> Bool {
        guard peerIsSameUser(descriptor) else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0, let requirement = ownRequirement else {
            return false
        }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &guest) == errSecSuccess,
            let guest
        else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    /// This executable's designated requirement: the signing certificate for a signed build, the code hash otherwise.
    /// A SecRequirement is immutable once created, so sharing it across threads is safe.
    nonisolated(unsafe) static let ownRequirement: SecRequirement? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }()

    static func socketAddress() -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        return address
    }

    static func configure(_ descriptor: Int32, timeout: TimeInterval) {
        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ descriptor: Int32, _ text: String) -> Bool {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard written > 0 else { return false }
            bytes = bytes.dropFirst(written)
        }
        return true
    }

    /// Reads until the peer closes or the data reaches 1 MiB.
    static func readAll(_ descriptor: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(data: data, encoding: .utf8)
    }

    /// Reads one line, which must be shorter than 256 bytes. Returns nil for a longer line, and when the connection
    /// closes or times out before the newline.
    static func readLine(_ descriptor: Int32) -> String? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < 256, read(descriptor, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { return String(data: line, encoding: .utf8) }
            line.append(byte)
        }
        return nil
    }
}

/// The running app's end of the channel. It accepts connections on a background queue and runs commands on the main
/// actor.
final class CommandServer: @unchecked Sendable {
    typealias Handler = @MainActor (CommandChannel.Command) -> String

    private let queue = DispatchQueue(label: "LocalDictation.CommandServer")
    private let handler: Handler
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws {
        let path = CommandChannel.socketPath
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard var address = CommandChannel.socketAddress() else {
            close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        // The socket file is created with owner-only permissions.
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        listener = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func acceptConnection() {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        CommandChannel.configure(connection, timeout: 2)
        guard CommandChannel.peerIsTrusted(connection),
            let line = CommandChannel.readLine(connection),
            let command = CommandChannel.Command(rawValue: line)
        else {
            dictationLog.error("command channel: rejected a connection from an untrusted or malformed peer")
            close(connection)
            return
        }
        let handler = self.handler
        DispatchQueue.main.async {
            let reply = MainActor.assumeIsolated { handler(command) }
            self.queue.async {
                _ = CommandChannel.writeAll(connection, reply)
                close(connection)
            }
        }
    }
}

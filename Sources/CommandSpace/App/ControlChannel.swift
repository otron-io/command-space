//
//  ControlChannel.swift
//  Command Space
//
//  A tiny local control channel: the running app listens on a Unix-domain socket and speaks
//  newline-delimited JSON, so its own binary can act as a command-line client
//  (`CommandSpace --computer-use "task"`). One request per connection; the app streams replies.
//  Every callback is delivered on the main actor, in order.
//

import Foundation
import OSLog

private let log = Logger(subsystem: "io.otron.commandspace", category: "control")

/// Where the running app listens.
enum ControlChannel {
    /// Tests and tools can point both ends at another socket path.
    static var socketPathOverride: String?

    /// ~/Library/Application Support/CommandSpace/control.sock, or /tmp/command-space-<uid>/control.sock when that path is too long for a socket address (sun_path is 104 bytes).
    static var socketPath: String {
        if let socketPathOverride { return socketPathOverride }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let path = support.appendingPathComponent("CommandSpace/control.sock").path
        return path.utf8.count < maxPathBytes ? path : "\(fallbackDirectory)/control.sock"
    }

    /// sun_path holds 104 bytes including the terminating NUL.
    fileprivate static let maxPathBytes = 104
    fileprivate static var fallbackDirectory: String { "/tmp/command-space-\(getuid())" }

    /// Creates the socket's directory (0700) if missing and checks that only this user can write to it.
    fileprivate static func prepareDirectory(for socketPath: String) -> Bool {
        let directory = (socketPath as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return false }
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            // Parent directories may be missing (first launch).
            guard (try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])) != nil else { return false }
        }
        var info = stat()
        // lstat so a symlink planted in /tmp is refused rather than followed.
        let result = directory.hasPrefix("/tmp/") ? lstat(directory, &info) : stat(directory, &info)
        guard result == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o022) == 0 else {
            log.error("Refusing control directory \(directory, privacy: .public): wrong owner or writable by others")
            return false
        }
        return true
    }
}

// MARK: - Socket plumbing

private enum Sock {
    /// Non-blocking, close-on-exec, and no SIGPIPE when the peer vanishes.
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configure(fd)
        return fd
    }

    /// Runs `body` with a sockaddr_un for `path`; nil when the path doesn't fit.
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = UInt8(bitPattern: byte) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    /// A connected, configured client socket, or nil if nothing is listening.
    static func connectClient(to path: String) -> Int32? {
        guard let fd = makeSocket() else { return nil }
        let result = withAddress(path) { address, length -> Int32 in
            while true {
                let status = connect(fd, address, length)
                if status == 0 || errno != EINTR { return status }
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Writes everything, waiting briefly for a slow reader; false if the peer is gone or stalled.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && errno == EAGAIN {
                    let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
                    guard remaining > 0 else { return false }
                    var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&wait, 1, remaining)
                    if ready < 0 && errno != EINTR { return false }
                    if ready == 0 { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }

    static func line(for message: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Reads once. nil means end of stream or a hard error; an empty array means nothing yet.
    static func readChunk(_ fd: Int32, into scratch: inout [UInt8]) -> Int? {
        while true {
            let count = scratch.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return count }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            return errno == EAGAIN ? 0 : nil
        }
    }
}

/// Splits a byte stream into JSON objects, one per line. Lines may be large and arrive in pieces.
private struct LineBuffer {
    private var bytes: [UInt8] = []
    private var scanned = 0
    private(set) var overflowed = false
    private static let limit = 64 * 1024 * 1024

    mutating func append(_ chunk: ArraySlice<UInt8>) -> [[String: Any]] {
        bytes.append(contentsOf: chunk)
        var messages: [[String: Any]] = []
        var lineStart = 0
        while let newline = bytes[max(scanned, lineStart)...].firstIndex(of: 0x0A) {
            if newline > lineStart,
               let message = try? JSONSerialization.jsonObject(with: Data(bytes[lineStart..<newline])) as? [String: Any] {
                messages.append(message)
            }
            lineStart = newline + 1
        }
        if lineStart > 0 { bytes.removeSubrange(0..<lineStart) }
        scanned = bytes.count
        if bytes.count > Self.limit { overflowed = true }
        return messages
    }

    mutating func reset() {
        bytes = []
        scanned = 0
    }
}

// MARK: - App side

/// One client connected to the app. All callbacks arrive on the main actor.
@MainActor
final class ControlConnection {
    /// The client went away (e.g. ⌃C in the terminal) before `close()` was called here.
    var onClose: (() -> Void)?

    private let fd: Int32
    private var source: DispatchSourceRead?
    private var lines = LineBuffer()
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)
    private var finished = false
    private var hasRequest = false
    private var onRequest: (([String: Any], ControlConnection) -> Void)?
    private var onFinished: ((ControlConnection) -> Void)?

    fileprivate init(fd: Int32, onRequest: @escaping ([String: Any], ControlConnection) -> Void,
                     onFinished: @escaping (ControlConnection) -> Void) {
        self.fd = fd
        self.onRequest = onRequest
        self.onFinished = onFinished
    }

    fileprivate func start() {
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readable() } }
        source.setCancelHandler { _ = Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    /// Sends one JSON object as a line. Safe to call after the peer has gone (it does nothing).
    func send(_ message: [String: Any]) {
        guard !finished, let data = Sock.line(for: message) else { return }
        if !Sock.writeAll(fd, data) {
            // The read side reports the disconnect; just stop writing.
            shutdown(fd, SHUT_WR)
        }
    }

    /// Flushes what was sent and closes. Idempotent.
    func close() {
        guard !finished else { return }
        // Sends are synchronous, so everything is already queued for the peer; closing keeps it readable.
        shutdown(fd, SHUT_WR)
        finish(notify: false)
    }

    private func readable() {
        guard !finished else { return }
        guard let count = Sock.readChunk(fd, into: &scratch) else {
            finish(notify: hasRequest)
            return
        }
        guard count > 0, !hasRequest else { return }
        let messages = lines.append(scratch[0..<count])
        if lines.overflowed {
            log.error("Dropping control connection: request line too large")
            finish(notify: false)
            return
        }
        if let request = messages.first {
            hasRequest = true
            lines.reset()
            onRequest?(request, self)
        }
    }

    private func finish(notify: Bool) {
        guard !finished else { return }
        finished = true
        source?.cancel()
        source = nil
        let callback = onClose
        onClose = nil
        onRequest = nil
        let done = onFinished
        onFinished = nil
        if notify { callback?() }
        done?(self)
    }
}

/// The app side. One request per connection: the client's first JSON line is the request; everything after is the app streaming replies.
@MainActor
final class ControlServer {
    static let shared = ControlServer()

    private var listener: DispatchSourceRead?
    private var handler: (@MainActor ([String: Any], ControlConnection) -> Void)?
    private var connections: [ObjectIdentifier: ControlConnection] = [:]
    private var ownedPath: String?
    private var ownedInode: ino_t = 0

    /// Starts listening (replacing a stale socket file left by a crashed app). Returns false if another live instance already owns the socket or the socket can't be created.
    @discardableResult
    func start(handler: @escaping @MainActor (_ request: [String: Any], _ connection: ControlConnection) -> Void) -> Bool {
        if listener != nil {
            self.handler = handler
            return true
        }
        let path = ControlChannel.socketPath
        guard ControlChannel.prepareDirectory(for: path) else { return false }

        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK else {
                log.error("Control path exists and is not a socket")
                return false
            }
            if let probe = Sock.connectClient(to: path) {
                close(probe)
                return false  // another instance is alive
            }
            unlink(path)
        }

        guard let fd = Sock.makeSocket() else { return false }
        let bound = Sock.withAddress(path) { address, length in bind(fd, address, length) }
        guard bound == 0 else {
            log.error("Control socket bind failed: errno \(errno)")
            close(fd)
            return false
        }
        // The directory is 0700 already; the file itself should not be reachable by others either.
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            unlink(path)
            close(fd)
            return false
        }
        var created = stat()
        if lstat(path, &created) == 0 { ownedInode = created.st_ino }
        ownedPath = path

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptPending(fd) } }
        source.setCancelHandler { _ = Darwin.close(fd) }
        listener = source
        self.handler = handler
        source.resume()
        return true
    }

    /// Stops listening, closes open connections and removes the socket file this instance created.
    func stop() {
        listener?.cancel()
        listener = nil
        handler = nil
        let open = Array(connections.values)
        connections.removeAll()
        for connection in open { connection.close() }
        if let path = ownedPath {
            var info = stat()
            if lstat(path, &info) == 0, info.st_ino == ownedInode { unlink(path) }
        }
        ownedPath = nil
    }

    private func acceptPending(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            Sock.configure(fd)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
                close(fd)
                continue
            }
            let connection = ControlConnection(
                fd: fd,
                onRequest: { [weak self] request, connection in self?.handler?(request, connection) },
                onFinished: { [weak self] connection in self?.connections[ObjectIdentifier(connection)] = nil })
            connections[ObjectIdentifier(connection)] = connection
            connection.start()
        }
    }
}

// MARK: - Command-line side

/// The command-line side.
enum ControlClient {
    struct NotRunning: Error {}

    @MainActor private static var current: ClientSession?

    /// Whether an app instance is listening right now (connects and immediately disconnects).
    static func isServerRunning() -> Bool {
        guard let fd = Sock.connectClient(to: ControlChannel.socketPath) else { return false }
        close(fd)
        return true
    }

    /// Connects, sends `request`, then delivers each JSON line the app sends until the app closes the connection. Throws `NotRunning` if nothing is listening.
    @MainActor
    static func run(_ request: [String: Any], onMessage: @escaping @MainActor ([String: Any]) -> Void) async throws {
        guard let data = Sock.line(for: request) else { throw CocoaError(.coderInvalidValue) }
        guard let fd = Sock.connectClient(to: ControlChannel.socketPath) else { throw NotRunning() }
        guard Sock.writeAll(fd, data) else {
            close(fd)
            throw NotRunning()
        }
        current?.finish()
        let session = ClientSession(fd: fd, onMessage: onMessage)
        current = session
        await withCheckedContinuation { continuation in session.begin(continuation) }
        if current === session { current = nil }
    }

    /// Closes the connection opened by the current `run` (if any), so the app sees the client leave. For ⌃C handlers.
    @MainActor
    static func disconnect() {
        current?.finish()
    }
}

@MainActor
private final class ClientSession {
    private let fd: Int32
    private let onMessage: @MainActor ([String: Any]) -> Void
    private var source: DispatchSourceRead?
    private var continuation: CheckedContinuation<Void, Never>?
    private var lines = LineBuffer()
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)
    private var done = false

    init(fd: Int32, onMessage: @escaping @MainActor ([String: Any]) -> Void) {
        self.fd = fd
        self.onMessage = onMessage
    }

    func begin(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readable() } }
        source.setCancelHandler { _ = Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    func finish() {
        guard !done else { return }
        done = true
        source?.cancel()
        source = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }

    private func readable() {
        guard !done else { return }
        guard let count = Sock.readChunk(fd, into: &scratch) else {
            finish()
            return
        }
        guard count > 0 else { return }
        for message in lines.append(scratch[0..<count]) {
            guard !done else { return }
            onMessage(message)
        }
        if lines.overflowed { finish() }
    }
}

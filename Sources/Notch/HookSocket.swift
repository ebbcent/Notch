import Foundation

/// Local Unix socket between the Claude Code hook and the app.
/// Only the current user can open it (directory 0700, socket 0600). Nothing goes on the network.
///
/// Protocol: the hook sends one line of compact JSON (the hook input). For a permission
/// request it then waits, connection open, for one line back: "allow" or "deny". If the
/// hook goes away (Esc or quit in Claude Code), the app sees the connection close and
/// drops the request.
enum HookSocket {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch", isDirectory: true)
    }

    static var path: String { directory.appendingPathComponent("notch.sock").path }

    /// How long a permission request waits for an answer in the island before
    /// handing it back to Claude Code's own prompt.
    static let answerTimeout: TimeInterval = 120

    static let maxMessage = 8 * 1024 * 1024

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) } // includes the trailing NUL
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    /// A write to a hook that already hung up must fail with EPIPE, not kill the process.
    static func ignoreBrokenPipes() {
        signal(SIGPIPE, SIG_IGN)
    }

    static func setTimeouts(_ fd: Int32, receive: TimeInterval, send: TimeInterval) {
        func tv(_ t: TimeInterval) -> timeval {
            timeval(tv_sec: Int(t), tv_usec: Int32((t - floor(t)) * 1_000_000))
        }
        var r = tv(receive), s = tv(send), one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &r, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &s, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Reads up to the first newline (excluded), EOF, timeout or `limit`.
    static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        let size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        while data.count < limit {
            let n = Darwin.read(fd, &buffer, size)
            if n <= 0 { break }
            if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
                data.append(buffer, count: newline)
                return data
            }
            data.append(buffer, count: n)
        }
        return data.isEmpty ? nil : data
    }
}

// MARK: - Hook side (runs as `Notch --hook`, launched by Claude Code)

/// Reads the hook JSON on stdin, forwards it to the app, and, for a permission
/// request, prints the user's answer. Always exits 0 and stays silent when the
/// app is not running, so Claude Code simply carries on with its own prompt.
enum HookClient {
    static func run() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let output = forward(input, to: HookSocket.path) {
            FileHandle.standardOutput.write(output)
        }
        return 0
    }

    /// Sends the hook JSON to the app; returns what the hook must print, if anything.
    static func forward(_ input: Data, to path: String, timeout: TimeInterval = HookSocket.answerTimeout) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let event = json["hook_event_name"] as? String,
              // Compact JSON never contains a raw newline, so one line = one message.
              var line = try? JSONSerialization.data(withJSONObject: json),
              var addr = HookSocket.address(path) else { return nil }
        line.append(0x0A)
        let waits = event == "PermissionRequest"
        HookSocket.ignoreBrokenPipes()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        HookSocket.setTimeouts(fd, receive: waits ? timeout + 5 : 2, send: 2)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, HookSocket.writeAll(fd, line), waits else { return nil }

        let reply = HookSocket.readLine(fd, limit: 1024).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return decision(for: reply.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The PermissionRequest hook output for "allow" / "deny"; nil lets Claude Code ask itself.
    static func decision(for reply: String) -> Data? {
        let decision: [String: Any]
        switch reply {
        case "allow":
            decision = ["behavior": "allow"]
        case "deny":
            decision = ["behavior": "deny", "message": "The user denied this from the Notch."]
        default:
            return nil
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                            "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }
}

// MARK: - App side

/// One connected hook. For a permission request it stays open until answered,
/// and reports when the hook goes away.
final class HookConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var open = true
    private var hangUpSource: DispatchSourceRead?

    init(fd: Int32) { self.fd = fd }

    /// Calls `handler` on the main queue if the hook closes the connection first.
    func onHangUp(_ handler: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            // Readable with nothing to read: the hook has gone.
            if recv(self.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0 {
                source.cancel()
                DispatchQueue.main.async(execute: handler)
            }
        }
        lock.lock()
        hangUpSource = source
        lock.unlock()
        source.resume()
    }

    /// Sends the answer ("allow" / "deny") and closes.
    func reply(_ answer: String) {
        finish(with: Data((answer + "\n").utf8))
    }

    /// Closes without an answer: the hook then prints nothing.
    func close() { finish(with: nil) }

    private func finish(with data: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard open else { return }
        open = false
        hangUpSource?.cancel()
        hangUpSource = nil
        if let data { _ = HookSocket.writeAll(fd, data) } // the hook may be gone: EPIPE, not a signal
        Darwin.close(fd)
    }

    deinit {
        hangUpSource?.cancel()
        if open { Darwin.close(fd) }
    }
}

final class HookServer: @unchecked Sendable {
    private let acceptQueue = DispatchQueue(label: "local.notch.hooks.accept")
    private var source: DispatchSourceRead?
    private var path = HookSocket.path
    private(set) var isListening = false
    private let onMessage: @Sendable ([String: Any], HookConnection) -> Void

    /// `onMessage` is called on the main queue.
    init(onMessage: @escaping @Sendable ([String: Any], HookConnection) -> Void) {
        self.onMessage = onMessage
    }

    func start(path: String = HookSocket.path) -> Bool {
        self.path = path
        HookSocket.ignoreBrokenPipes()
        let fm = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        unlink(path) // stale socket from a previous run
        guard var addr = HookSocket.address(path) else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0 else {
            close(fd)
            return false
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        isListening = true
        return true
    }

    func stop() {
        source?.cancel() // closes the listening socket in the cancel handler
        source = nil
        isListening = false
        unlink(path)
    }

    private func acceptAll(_ listenFD: Int32) {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            HookSocket.setTimeouts(client, receive: 2, send: 2)
            // Each hook is read on its own, so a slow one never holds up the others.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ fd: Int32) {
        let connection = HookConnection(fd: fd)
        guard let line = HookSocket.readLine(fd, limit: HookSocket.maxMessage),
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            connection.close()
            return
        }
        let box = UncheckedBox(json)
        DispatchQueue.main.async { [onMessage] in onMessage(box.value, connection) }
    }
}

/// Carries a JSON dictionary (immutable once parsed) to the main queue.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

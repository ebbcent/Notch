import Foundation

/// Local Unix socket between the Claude Code hook and the app.
/// Only the current user can open it (directory 0700, socket 0600). Nothing goes on the network.
enum HookSocket {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch", isDirectory: true)
    }

    static var path: String { directory.appendingPathComponent("notch.sock").path }

    /// How long a permission request waits for an answer in the island before
    /// handing it back to Claude Code's own prompt.
    static let answerTimeout: TimeInterval = 120

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

    static func readAll(_ fd: Int32, limit: Int) -> Data {
        var data = Data()
        let size = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        while data.count < limit {
            let n = Darwin.read(fd, &buffer, size)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
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
              var addr = HookSocket.address(path) else { return nil }
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
        guard connected == 0, HookSocket.writeAll(fd, input) else { return nil }
        shutdown(fd, SHUT_WR)
        guard waits else { return nil }

        let reply = String(decoding: HookSocket.readAll(fd, limit: 1024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decision(for: reply)
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

/// One connected hook. For a permission request it stays open until answered.
final class HookConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var open = true

    init(fd: Int32) { self.fd = fd }

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
        if let data { _ = HookSocket.writeAll(fd, data) } // the hook may be gone: EPIPE, not a signal
        Darwin.close(fd)
    }

    deinit { if open { Darwin.close(fd) } }
}

final class HookServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.notch.hooks")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let onMessage: @Sendable ([String: Any], HookConnection) -> Void

    /// `onMessage` is called on the main queue.
    init(onMessage: @escaping @Sendable ([String: Any], HookConnection) -> Void) {
        self.onMessage = onMessage
    }

    var isListening: Bool { listenFD >= 0 }

    private var path = HookSocket.path

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
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            return false
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptAll() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            HookSocket.setTimeouts(client, receive: 2, send: 2)
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ fd: Int32) {
        let connection = HookConnection(fd: fd)
        let data = HookSocket.readAll(fd, limit: 4 * 1024 * 1024)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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

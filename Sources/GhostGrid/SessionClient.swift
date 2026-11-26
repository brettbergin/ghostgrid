import Darwin
import Foundation
import GhostGridCore

/// One pane's connection to ghostgrid-sessiond: starts or reattaches its
/// shell, carries keystrokes in and output back. Callbacks run on main.
@MainActor
final class SessionClient {
    var onAttached: ((Data) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    /// sessiond answered with an error (e.g. the shell to reattach is gone).
    var onFailure: ((String) -> Void)?

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var decoder = SessionFrameDecoder()
    private var welcomed = false
    private var queued: [SessionMessage] = []
    /// A shell to start once the pane knows its size, so its first
    /// prompt is drawn at the size it will be replayed at.
    var pendingCreate: SessionLaunch?
    /// The pane's size, from its latest resize.
    private(set) var size: (columns: UInt16, rows: UInt16)?

    /// Connects (starting sessiond if needed) and sends `first`
    /// (an attach), if any. False when sessiond cannot be reached.
    func open(_ first: SessionMessage?) -> Bool {
        guard let fd = SessionDaemon.connect() else { return false }
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
        write(.hello(version: SessionMessage.protocolVersion))
        if let first { queued.append(first) }
        return true
    }

    /// The pane's new size; starts a pending shell at it.
    func resize(columns: UInt16, rows: UInt16, width: UInt16, height: UInt16) {
        size = (columns, rows)
        if pendingCreate != nil {
            startPending()
        } else {
            send(.resize(columns: columns, rows: rows, width: width, height: height))
        }
    }

    /// Starts the pending shell now, at the last known size if any.
    func startPending() {
        guard var launch = pendingCreate else { return }
        pendingCreate = nil
        if let size {
            launch.columns = size.columns
            launch.rows = size.rows
        }
        send(.create(launch))
    }

    func send(_ message: SessionMessage) {
        guard welcomed else {
            queued.append(message)
            return
        }
        write(message)
    }

    /// Detaches; the shell keeps running in sessiond.
    func close() {
        source?.cancel()
        source = nil
        fd = -1
    }

    private func write(_ message: SessionMessage) {
        guard fd >= 0 else { return }
        if !SessionDaemon.writeAll(fd, message.encoded()) { close() }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count <= 0 {
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            close()
            onFailure?("sessiond closed the connection")
            return
        }
        for message in decoder.append(Data(buffer[0..<count])) {
            handle(message)
        }
        if decoder.isBroken {
            close()
            onFailure?("malformed data from sessiond")
        }
    }

    private func handle(_ message: SessionMessage) {
        switch message {
        case .welcome:
            welcomed = true
            let pending = queued
            queued = []
            pending.forEach(write)
        case let .attached(_, replay): onAttached?(replay)
        case let .output(data): onOutput?(data)
        case let .exited(code): onExit?(code)
        case let .failure(reason): onFailure?(reason)
        default: break
        }
    }
}

/// Lets the terminal's write and resize callbacks, which may run on any
/// thread, reach a pane's client; only touched on main.
final class SessionPipe: @unchecked Sendable {
    weak var client: SessionClient?

    init(client: SessionClient) {
        self.client = client
    }
}

extension SessionClient {
    private static var ending: [SessionClient] = []

    /// Ends kept shells no pane will come back to (session restore off).
    static func terminate(_ ids: [String]) {
        for id in ids {
            let client = SessionClient()
            guard client.open(.attach(id: id)) else { return }
            client.send(.terminate)
            ending.append(client)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            ending.forEach { $0.close() }
            ending.removeAll()
        }
    }
}

/// ghostgrid's shell hook files (ShellHooks), written once per launch to
/// ~/Library/Application Support/ghostgrid/hooks; nil if that failed.
enum HookFiles {
    static let directory: String? = {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true,
        ) else { return nil }
        let path = base.appendingPathComponent("ghostgrid/hooks", isDirectory: true).path
        do {
            try ShellHooks.install(in: path)
            return path
        } catch {
            return nil
        }
    }()
}

/// Finding and starting ghostgrid-sessiond.
enum SessionDaemon {
    /// One socket per protocol version, so an app update never talks to an
    /// older helper it cannot understand; the older one keeps its shells.
    static var socketPath: String {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true,
        ).appendingPathComponent("ghostgrid", isDirectory: true).path) ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base + "/sessiond-v\(SessionMessage.protocolVersion).sock"
    }

    /// The helper next to the app's executable (Contents/MacOS).
    static var executable: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ghostgrid-sessiond").path
    }

    /// A connected, non-blocking socket to sessiond, starting it if needed.
    static func connect() -> Int32? {
        if let fd = tryConnect() { return fd }
        guard start() else { return nil }
        for _ in 0..<40 { // up to 2 s for it to listen
            usleep(50_000)
            if let fd = tryConnect() { return fd }
        }
        return nil
    }

    private static func tryConnect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in path.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    /// launchd's name for the helper job, one per protocol version.
    static let jobLabel = "com.brettbergin.ghostgrid.sessiond.v\(SessionMessage.protocolVersion)"

    /// Starts sessiond, logging to ~/Library/Logs/ghostgrid/sessiond.log.
    /// It runs as its own launchd job: macOS ends every process an app
    /// started when the app quits (SIGTERM), even one in its own session,
    /// and the helper must outlive the app. The job lives in memory only
    /// (gone after a restart); launchd restarts it only if it fails, so
    /// its idle exit stays an exit. Spawned directly if launchd refuses.
    private static func start() -> Bool {
        let path = executable
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let logs = NSHomeDirectory() + "/Library/Logs/ghostgrid"
        try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let log = logs + "/sessiond.log"
        // A job of the same name that already ended blocks a new submit.
        _ = launchctl(["remove", jobLabel])
        if launchctl(["submit", "-l", jobLabel, "-o", log, "-e", log, "--", path, "--socket", socketPath]) {
            return true
        }
        return spawn(path, log: log)
    }

    private static func launchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Fallback: in its own session (setsid). It then ends when the app quits.
    private static func spawn(_ path: String, log: String) -> Bool {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("--socket"), strdup(socketPath), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer {
            posix_spawn(&pid, path, &actions, &attributes, $0.baseAddress, environ)
        }
        return result == 0
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let written = Darwin.write(fd, pointer, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&poller, 1, 1000)
                        continue
                    }
                    return false
                }
                pointer += written
                left -= written
            }
            return true
        }
    }
}

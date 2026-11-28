// ghostgrid-sessiond: owns every ghostgrid pane's shell so the shells keep
// running when the app quits. ghostgrid starts it on demand (one per user,
// per protocol version) and talks to it over a Unix socket, one connection
// per pane (see SessionProtocol in GhostGridCore). It exits on its own once
// it has no shells and no connections for a while.
//
// Usage: ghostgrid-sessiond --socket <path> [--log <path>]
import AppKit
import Darwin
import Foundation
import GhostGridCore

setvbuf(stderr, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date()) sessiond: \(message)\n".utf8))
}

let arguments = CommandLine.arguments
guard let socketIndex = arguments.firstIndex(of: "--socket"), arguments.indices.contains(socketIndex + 1) else {
    log("usage: ghostgrid-sessiond --socket <path>")
    exit(64)
}
let socketPath = arguments[socketIndex + 1]
// Started as an app by LaunchServices, stderr goes nowhere: log here.
if let logIndex = arguments.firstIndex(of: "--log"), arguments.indices.contains(logIndex + 1) {
    _ = freopen(arguments[logIndex + 1], "a", stderr)
    setvbuf(stderr, nil, _IOLBF, 0)
}

/// Writes all of `data` to `fd`, retrying partial writes; false on error.
@discardableResult
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard var pointer = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let written = Darwin.write(fd, pointer, left)
            if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    // The pane is slow to read: wait briefly rather than drop output.
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

final class Connection {
    let fd: Int32
    var decoder = SessionFrameDecoder()
    var source: DispatchSourceRead?
    var greeted = false
    weak var session: Session?

    init(fd: Int32) {
        self.fd = fd
    }

    func send(_ message: SessionMessage) {
        if !writeAll(fd, message.encoded()) { close() }
    }

    func close() {
        guard let source else { return }
        self.source = nil
        source.cancel() // closes fd in the cancel handler
        if let session, session.client === self { session.client = nil }
        server.connectionClosed(self)
    }
}

final class Session {
    let id: String
    let pid: pid_t
    let master: Int32
    var history = OutputHistory()
    weak var client: Connection?
    var readSource: DispatchSourceRead?
    var exitSource: DispatchSourceProcess?
    var exitCode: Int32?
    /// Set on attach: the next resize also signals the foreground program,
    /// so full-screen apps and line editors redraw for the new pane even
    /// when its size did not change.
    var redrawOnResize = false

    init(id: String, pid: pid_t, master: Int32) {
        self.id = id
        self.pid = pid
        self.master = master
    }

    func attach(_ connection: Connection) {
        if let old = client, old !== connection {
            // A newer ghostgrid took this shell over: drop the stale pane.
            old.send(.failure("attached elsewhere"))
            old.close()
        }
        client = connection
        connection.session = self
        connection.send(.attached(id: id, replay: history.replay))
        redrawOnResize = true
    }

    func output(_ data: Data) {
        history.append(data)
        client?.send(.output(data))
    }

    func input(_ data: Data) {
        _ = writeAll(master, data)
    }

    func resize(columns: UInt16, rows: UInt16, width: UInt16, height: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: width, ws_ypixel: height)
        _ = ioctl(master, TIOCSWINSZ, &size) // the kernel sends SIGWINCH on a change
        if redrawOnResize {
            redrawOnResize = false
            let group = tcgetpgrp(master)
            if group > 0 { killpg(group, SIGWINCH) }
        }
    }

    func terminate() {
        // The shell's process group, then the shell itself; SIGKILL if it
        // ignores the hangup.
        let group = getpgid(pid)
        if group > 0 { killpg(group, SIGHUP) }
        kill(pid, SIGHUP)
        let pid = pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard self != nil else { return }
            kill(pid, SIGKILL)
        }
    }
}

final class Server {
    var sessions: [String: Session] = [:]
    var connections: [ObjectIdentifier: Connection] = [:]
    var listenSource: DispatchSourceRead?
    var idleSince: Date? = Date()

    func listen() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log("socket: \(errno)"); exit(1) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { log("socket path too long"); exit(1) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        unlink(socketPath)
        let previous = umask(0o077) // the socket is the user's only
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0, Darwin.listen(fd, 16) == 0 else { log("bind/listen \(socketPath): \(errno)"); exit(1) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.resume()
        listenSource = source
        log("listening on \(socketPath)")

        // Leave once there is nothing to keep: no shells, no panes.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, sessions.isEmpty, connections.isEmpty else {
                self?.idleSince = nil
                return
            }
            let since = idleSince ?? Date()
            idleSince = since
            if Date().timeIntervalSince(since) >= 30 {
                log("idle: exiting")
                unlink(socketPath)
                exit(0)
            }
        }
        timer.resume()
        idleTimer = timer
    }

    var idleTimer: DispatchSourceTimer?

    func accept(on listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            // Only the same user may talk to us.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(fd)
                continue
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let connection = Connection(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self, weak connection] in
                guard let connection else { return }
                self?.read(connection)
            }
            source.setCancelHandler { Darwin.close(fd) }
            connection.source = source
            connections[ObjectIdentifier(connection)] = connection
            source.resume()
        }
    }

    func read(_ connection: Connection) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(connection.fd, &buffer, buffer.count)
        if count <= 0 {
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            connection.close()
            return
        }
        for message in connection.decoder.append(Data(buffer[0..<count])) {
            handle(message, from: connection)
        }
        if connection.decoder.isBroken { connection.close() }
    }

    func handle(_ message: SessionMessage, from connection: Connection) {
        guard connection.greeted || message == .hello(version: SessionMessage.protocolVersion) else {
            if case .hello = message {
                connection.send(.failure("protocol version mismatch"))
            }
            connection.close()
            return
        }
        switch message {
        case .hello:
            connection.greeted = true
            connection.send(.welcome(version: SessionMessage.protocolVersion))
        case let .create(launch):
            if let existing = sessions[launch.id] {
                existing.attach(connection)
            } else if let session = spawn(launch) {
                sessions[launch.id] = session
                session.attach(connection)
            } else {
                connection.send(.failure("could not start \(launch.executable)"))
            }
        case let .attach(id):
            if let session = sessions[id] {
                session.attach(connection)
            } else {
                connection.send(.failure("no such session"))
            }
        case let .input(data):
            connection.session?.input(data)
        case let .resize(columns, rows, width, height):
            connection.session?.resize(columns: columns, rows: rows, width: width, height: height)
        case .terminate:
            connection.session?.terminate()
        case .welcome, .attached, .output, .exited, .failure:
            break
        }
    }

    func connectionClosed(_ connection: Connection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    func spawn(_ launch: SessionLaunch) -> Session? {
        // Everything the child needs is built before fork: after it, the
        // child only calls chdir and execve.
        let argv = launch.arguments.map { strdup($0) } + [nil]
        let envp = launch.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(launch.executable)
        let directory = launch.workingDirectory.map { strdup($0) }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(path)
            directory.map { free($0) }
        }
        var master: Int32 = 0
        var size = winsize(ws_row: launch.rows, ws_col: launch.columns, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            if let directory { _ = chdir(directory) }
            signal(SIGPIPE, SIG_DFL)
            signal(SIGHUP, SIG_DFL)
            argv.withUnsafeBufferPointer { argvBuffer in
                envp.withUnsafeBufferPointer { envpBuffer in
                    _ = execve(path, argvBuffer.baseAddress, envpBuffer.baseAddress)
                }
            }
            _exit(127)
        }
        guard pid > 0 else {
            log("forkpty: \(errno)")
            return nil
        }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let session = Session(id: launch.id, pid: pid, master: master)
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        read.setEventHandler { [weak self, weak session] in
            guard let session else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 {
                session.output(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                self?.reap(session) // EIO: the shell and everything on its tty is gone
            }
        }
        read.setCancelHandler { Darwin.close(master) }
        read.resume()
        session.readSource = read
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self, weak session] in
            guard let session else { return }
            // Let the last output drain first; EIO on the tty finishes it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.reap(session) }
        }
        exit.resume()
        session.exitSource = exit
        log("started \(launch.id) pid \(pid): \(launch.executable)")
        return session
    }

    func reap(_ session: Session) {
        guard sessions[session.id] === session else { return }
        var status: Int32 = 0
        let result = waitpid(session.pid, &status, WNOHANG)
        let code: Int32 = result == session.pid ? ((status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)) : 0
        sessions[session.id] = nil
        session.readSource?.cancel()
        session.exitSource?.cancel()
        session.client?.send(.exited(code: code))
        log("ended \(session.id) code \(code)")
    }
}

let server = Server()
server.listen()

/// What is known about the process `pid` now (it may have exited): its
/// executable and what started it.
func lookUpSender(_ pid: Int32?) -> QuitSender {
    guard let pid, pid > 0 else { return QuitSender(pid: nil, path: nil, parentPID: nil, parentPath: nil) }
    func executable(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }
    let path = executable(pid)
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let parent = path != nil && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? Int32(info.pbi_ppid) : nil
    return QuitSender(pid: pid, path: path, parentPID: parent, parentPath: parent.flatMap(executable))
}

/// The process that sent the last stopping signal: recorded by the signal
/// handler (which can do nothing else safely), read by the dispatch source
/// that runs after it.
var lastSignalSender: Int32 = 0

// Say why we stop, and who asked: a quiet death would look like lost shells.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT, SIGQUIT] {
    var action = sigaction()
    action.__sigaction_u.__sa_sigaction = { _, info, _ in
        lastSignalSender = info?.pointee.si_pid ?? 0
    }
    action.sa_flags = SA_SIGINFO
    sigemptyset(&action.sa_mask)
    sigaction(number, &action, nil)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        log("signal \(number) \(lookUpSender(lastSignalSender)): exiting, ending \(server.sessions.count) shells")
        unlink(socketPath)
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

/// A background-only app (LSBackgroundOnly) that answers Apple events, as
/// LaunchServices expects of an app it starts. Without that, opening it
/// waited for a reply that never came (ghostgrid's panes waited 5 s), and
/// the Quit that macOS sends it when ghostgrid quits went unanswered, so
/// it was ended with every shell in it. It declines that Quit and obeys
/// one for log out, restart or shut down (see HelperQuitPolicy).
final class HelperApp: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let keyword = AEKeyword(HelperQuitPolicy.reasonKeyword)
        let reason = (event?.attributeDescriptor(forKeyword: keyword) ?? event?.paramDescriptor(forKeyword: keyword))?.typeCodeValue
        let sender = lookUpSender(event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value)
        if HelperQuitPolicy.allowsQuit(reason: reason) {
            log("quitting for log out, restart or shut down \(sender): ending \(server.sessions.count) shells")
            unlink(socketPath)
            return .terminateNow
        }
        log("declined a request to quit \(sender) (\(server.sessions.count) shells kept)")
        return .terminateCancel
    }
}

let helperApp = HelperApp()
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
application.delegate = helperApp
application.run()

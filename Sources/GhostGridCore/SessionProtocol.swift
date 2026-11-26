import Foundation

/// The wire between ghostgrid and ghostgrid-sessiond, the helper that owns
/// every pane's shell so shells outlive the app. One Unix-socket connection
/// per pane carries one session. Frames are a 4-byte big-endian length, a
/// type byte, and a payload: raw bytes for terminal data, JSON otherwise.
public enum SessionMessage: Equatable, Sendable {
    // ghostgrid -> sessiond
    /// First message on a connection.
    case hello(version: Int)
    /// Start a shell and attach to it.
    case create(SessionLaunch)
    /// Attach to a running shell; answered with `attached` and its replay.
    case attach(id: String)
    /// Keystrokes and pastes from the terminal.
    case input(Data)
    case resize(columns: UInt16, rows: UInt16, width: UInt16, height: UInt16)
    /// End the shell (closing a pane, or quitting without keeping shells).
    case terminate

    // sessiond -> ghostgrid
    case welcome(version: Int)
    /// Attached; `replay` is the shell's recent output, to rebuild the screen.
    case attached(id: String, replay: Data)
    case output(Data)
    case exited(code: Int32)
    case failure(String)

    public static let protocolVersion = 1

    private enum Kind: UInt8 {
        case hello = 1, create, attach, input, resize, terminate
        case welcome = 101, attached, output, exited, failure
    }

    private struct Resize: Codable { var columns, rows, width, height: UInt16 }
    private struct Attached: Codable { var id: String }

    public func encoded() -> Data {
        let (kind, payload): (Kind, Data) = switch self {
        case let .hello(version): (.hello, Self.json(["version": version]))
        case let .create(launch): (.create, Self.json(launch))
        case let .attach(id): (.attach, Data(id.utf8))
        case let .input(data): (.input, data)
        case let .resize(columns, rows, width, height):
            (.resize, Self.json(Resize(columns: columns, rows: rows, width: width, height: height)))
        case .terminate: (.terminate, Data())
        case let .welcome(version): (.welcome, Self.json(["version": version]))
        case let .attached(id, replay):
            // id, a newline, then the replay bytes.
            (.attached, Data(id.utf8) + Data([0x0A]) + replay)
        case let .output(data): (.output, data)
        case let .exited(code): (.exited, Self.json(["code": Int(code)]))
        case let .failure(message): (.failure, Data(message.utf8))
        }
        var frame = Data(capacity: 5 + payload.count)
        var length = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(kind.rawValue)
        frame.append(payload)
        return frame
    }

    /// One message from a frame body (type byte + payload), nil if malformed.
    static func decode(body: Data) -> SessionMessage? {
        guard let first = body.first, let kind = Kind(rawValue: first) else { return nil }
        let payload = body.dropFirst()
        switch kind {
        case .hello: return (json(payload) as [String: Int]?)?["version"].map { .hello(version: $0) }
        case .create: return (json(payload) as SessionLaunch?).map { .create($0) }
        case .attach: return String(data: payload, encoding: .utf8).map { .attach(id: $0) }
        case .input: return .input(Data(payload))
        case .resize:
            return (json(payload) as Resize?).map { .resize(columns: $0.columns, rows: $0.rows, width: $0.width, height: $0.height) }
        case .terminate: return .terminate
        case .welcome: return (json(payload) as [String: Int]?)?["version"].map { .welcome(version: $0) }
        case .attached:
            guard let newline = payload.firstIndex(of: 0x0A),
                  let id = String(data: payload[payload.startIndex..<newline], encoding: .utf8)
            else { return nil }
            return .attached(id: id, replay: Data(payload[payload.index(after: newline)...]))
        case .output: return .output(Data(payload))
        case .exited: return (json(payload) as [String: Int]?)?["code"].map { .exited(code: Int32(truncatingIfNeeded: $0)) }
        case .failure: return .failure(String(decoding: payload, as: UTF8.self))
        }
    }

    private static func json(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func json<T: Decodable>(_ data: Data.SubSequence) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(data))
    }
}

/// Collects bytes from a socket and yields whole messages, however the
/// reads split them. A frame over `maximumFrame` (or a malformed one) marks
/// the stream broken: the connection should be closed.
public struct SessionFrameDecoder: Sendable {
    public static let maximumFrame = 64 << 20
    private var buffer = Data()
    public private(set) var isBroken = false

    public init() {}

    public mutating func append(_ data: Data) -> [SessionMessage] {
        guard !isBroken else { return [] }
        buffer.append(data)
        var messages: [SessionMessage] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= Self.maximumFrame else {
                isBroken = true
                return messages
            }
            guard buffer.count >= 4 + length else { break }
            let body = buffer[(start + 4)..<(start + 4 + length)]
            buffer = Data(buffer[(start + 4 + length)...])
            guard let message = SessionMessage.decode(body: Data(body)) else {
                isBroken = true
                return messages
            }
            messages.append(message)
        }
        return messages
    }
}

/// What a new pane asks sessiond to start.
public struct SessionLaunch: Codable, Equatable, Sendable {
    public var id: String
    public var executable: String
    /// argv, starting with argv[0] ("-zsh" for a login shell).
    public var arguments: [String]
    /// The whole environment of the shell.
    public var environment: [String: String]
    public var workingDirectory: String?
    public var columns: UInt16
    public var rows: UInt16

    public init(id: String, executable: String, arguments: [String], environment: [String: String],
                workingDirectory: String?, columns: UInt16 = 80, rows: UInt16 = 24) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
    }
}

/// A shell's recent output, kept by sessiond so a reattaching pane can be
/// brought back to the same screen. Bounded: the oldest bytes go first.
public struct OutputHistory: Sendable {
    public let capacity: Int
    private var bytes = Data()
    private var trimmed = false

    public init(capacity: Int = 4 << 20) {
        self.capacity = capacity
    }

    public mutating func append(_ data: Data) {
        bytes.append(data)
        if bytes.count > capacity {
            bytes = Data(bytes.suffix(capacity))
            trimmed = true
        }
    }

    /// What to replay. After a trim the first line may start inside an
    /// escape sequence or a UTF-8 character, so the replay starts after the
    /// first newline then; it always begins with a terminal reset (RIS) so
    /// the new screen starts clean.
    public var replay: Data {
        var body = bytes
        if trimmed, let newline = body.firstIndex(of: 0x0A) {
            body = Data(body[body.index(after: newline)...])
        }
        return Data("\u{1B}c".utf8) + body
    }
}

/// How sessiond starts each shell: a login shell (argv[0] starts with "-",
/// as Terminal and Ghostty do), with Ghostty's terminfo and, for zsh and
/// bash, Ghostty's shell integration injected the way Ghostty injects it.
public enum ShellLaunch {
    public struct Resources: Sendable {
        /// GHOSTTY_RESOURCES_DIR: holds shell-integration/.
        public var ghostty: String
        /// The compiled terminfo database (TERM=xterm-ghostty).
        public var terminfo: String
        /// shell-integration-features from the Ghostty config.
        public var features: String
        /// false when the config says shell-integration = none.
        public var integration: Bool
        /// ghostgrid's hook files (``ShellHooks``), which wrap Ghostty's
        /// integration; nil starts the shells with Ghostty's alone.
        public var hooks: String?

        public init(ghostty: String, terminfo: String, features: String, integration: Bool, hooks: String? = nil) {
            self.ghostty = ghostty
            self.terminfo = terminfo
            self.features = features
            self.integration = integration
            self.hooks = hooks
        }
    }

    /// Ghostty's shell-integration-features, in its order, with defaults.
    static let knownFeatures: [(name: String, enabled: Bool)] = [
        ("cursor", true), ("sudo", false), ("title", true), ("ssh-env", false), ("ssh-terminfo", false), ("path", true),
    ]

    /// GHOSTTY_SHELL_FEATURES for a `shell-integration-features` value:
    /// the enabled features, comma separated ("no-x" turns x off,
    /// "true"/"false" sets them all).
    public static func features(config: String?) -> String {
        var enabled = Dictionary(uniqueKeysWithValues: knownFeatures.map { ($0.name, $0.enabled) })
        for token in (config ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch token {
            case "true": enabled.keys.forEach { enabled[$0] = true }
            case "false": enabled.keys.forEach { enabled[$0] = false }
            case let name where name.hasPrefix("no-"): if enabled[String(name.dropFirst(3))] != nil { enabled[String(name.dropFirst(3))] = false }
            case let name: if enabled[name] != nil { enabled[name] = true }
            }
        }
        return knownFeatures.map(\.name).filter { enabled[$0] == true }.joined(separator: ",")
    }

    /// Whether to inject Ghostty's integration into `shell` (a ShellChoice
    /// name), given `shell-integration`: only for the shells whose scripts
    /// are bundled, and not when the config says none.
    public static func usesIntegration(shell: String, config: String?) -> Bool {
        ShellConfig.integratedShells.contains(shell) && config?.trimmingCharacters(in: .whitespaces).lowercased() != "none"
    }

    public static func launch(
        id: String, shell: ShellChoice, base: [String: String], resources: Resources, workingDirectory: String?,
    ) -> SessionLaunch? {
        guard let executable = shell.executable else { return nil }
        let name = (executable as NSString).lastPathComponent
        var environment = base
        environment["TERM"] = "xterm-ghostty"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "ghostty"
        environment["TERMINFO"] = resources.terminfo
        environment["GHOSTTY_RESOURCES_DIR"] = resources.ghostty
        environment["GHOSTTY_SHELL_FEATURES"] = resources.features
        environment["GHOSTGRID"] = "1"
        environment["GHOSTGRID_SHELL"] = shell.name
        environment["GHOSTGRID_SESSION"] = id
        // macOS bash 3.2 prints a "default shell is now zsh" notice otherwise.
        environment["BASH_SILENCE_DEPRECATION_WARNING"] = "1"
        if let workingDirectory { environment["PWD"] = workingDirectory }

        var arguments = ["-" + name]
        let integration = resources.integration
        switch name {
        case "zsh" where integration:
            // zsh reads $ZDOTDIR/.zshenv first; Ghostty's restores the user's
            // ZDOTDIR and loads the integration after .zshrc.
            if let original = base["ZDOTDIR"] { environment["GHOSTTY_ZSH_ZDOTDIR"] = original }
            environment["ZDOTDIR"] = resources.ghostty + "/shell-integration/zsh"
            if let hooks = resources.hooks {
                // ghostgrid's .zshenv runs Ghostty's, then adds its hook.
                environment["GHOSTGRID_GHOSTTY_ZDOTDIR"] = environment["ZDOTDIR"]
                environment["ZDOTDIR"] = hooks + "/zsh"
            }
        case "bash" where integration:
            // bash --posix reads $ENV; Ghostty's script turns posix mode off
            // and sources the user's startup files itself.
            arguments.append("--posix")
            if let original = base["ENV"] { environment["GHOSTTY_BASH_ENV"] = original }
            environment["ENV"] = resources.ghostty + "/shell-integration/bash/ghostty.bash"
            if let hooks = resources.hooks {
                environment["GHOSTGRID_GHOSTTY_ENV"] = environment["ENV"]
                environment["ENV"] = hooks + "/bash/ghostgrid.bash"
            }
            environment["GHOSTTY_BASH_INJECT"] = "1"
            if base["HISTFILE"] == nil {
                // posix mode defaults HISTFILE to ~/.sh_history.
                environment["HISTFILE"] = (base["HOME"] ?? NSHomeDirectory()) + "/.bash_history"
                environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
            }
        case "nu":
            // nushell has no "-nu" login convention: it takes -l.
            arguments = ["nu", "-l"]
        default:
            break
        }
        return SessionLaunch(id: id, executable: executable, arguments: arguments, environment: environment,
                             workingDirectory: workingDirectory)
    }
}

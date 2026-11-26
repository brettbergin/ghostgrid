import Foundation

/// One command run in a pane: what was typed, what it printed (as plain
/// text, colors and cursor tricks removed) and how it ended. Built from the
/// shell integration's OSC 133 prompt marks; the command line comes from
/// ghostgrid's own report (OSC 633;E, see ``CommandLineReport``).
public struct CommandBlock: Equatable, Sendable, Identifiable {
    public let id: Int
    /// nil when the shell did not report it (nushell's own marks).
    public var command: String?
    public var exitCode: Int?
    public var isFinished = false
    /// The oldest output was dropped to stay within the parser's limit.
    public var isTruncated = false
    public var startedAt: Date
    public var finishedAt: Date?

    /// Output bytes (UTF-8) and where the current line starts in them.
    fileprivate var bytes: [UInt8] = []
    fileprivate var lineStart = 0

    public init(id: Int, command: String?, startedAt: Date) {
        self.id = id
        self.command = command
        self.startedAt = startedAt
    }

    public var output: String { String(decoding: bytes, as: UTF8.self) }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }

    /// The command as typed after `prompt`, then its output.
    public func transcript(prompt: String = "$ ") -> String {
        var text = prompt + (command ?? "") + "\n" + output
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    /// "running", "ok", or "exit N".
    public var summary: String {
        guard isFinished else { return "running" }
        switch exitCode {
        case nil, 0: return "ok"
        case let code?: return "exit \(code)"
        }
    }
}

/// Reads a pane's output stream into ``CommandBlock``s, however the reads
/// split it. Keeps the newest `maximumBlocks` blocks and the last
/// `maximumOutput` bytes of each block's output.
public struct CommandBlockParser: Sendable {
    public private(set) var blocks: [CommandBlock] = []
    public let maximumBlocks: Int
    public let maximumOutput: Int

    private enum State: Sendable {
        case ground, escape, csi, osc, oscEscape, string, stringEscape, escapeIntermediate
    }

    private var state = State.ground
    private var oscBuffer: [UInt8] = []
    private var pendingCommand: String?
    private var pendingCarriageReturn = false
    /// The open block is collecting output (between 133;C and 133;D).
    private var capturing = false
    private var nextID = 0
    private let now: @Sendable () -> Date

    public init(maximumBlocks: Int = 200, maximumOutput: Int = 256 << 10,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.maximumBlocks = maximumBlocks
        self.maximumOutput = maximumOutput
        self.now = now
    }

    /// Forgets every block (the pane's screen was replaced by a replay).
    public mutating func reset() {
        blocks = []
        state = .ground
        oscBuffer = []
        pendingCommand = nil
        pendingCarriageReturn = false
        capturing = false
    }

    /// `replayed`: the bytes are a reattach's replay of earlier output,
    /// so the blocks they complete get no timing (it would be the
    /// replay's, not the commands').
    public mutating func feed(_ data: Data, replayed: Bool = false) {
        for byte in data {
            step(byte)
        }
        if replayed {
            for index in blocks.indices where blocks[index].isFinished {
                blocks[index].finishedAt = nil
            }
        }
    }

    private mutating func step(_ byte: UInt8) {
        switch state {
        case .ground:
            if byte == 0x1B {
                state = .escape
            } else if capturing {
                text(byte)
            }
        case .escape:
            switch byte {
            case UInt8(ascii: "["): state = .csi
            case UInt8(ascii: "]"):
                oscBuffer = []
                state = .osc
            case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"): state = .string
            case 0x20...0x2F: state = .escapeIntermediate // ESC ( B and friends
            case 0x1B: state = .escape
            default: state = .ground
            }
        case .escapeIntermediate:
            state = .ground
        case .csi:
            if (0x40...0x7E).contains(byte) { state = .ground }
        case .osc:
            switch byte {
            case 0x07:
                finishOSC()
            case 0x1B:
                state = .oscEscape
            default:
                if oscBuffer.count < 1 << 16 { oscBuffer.append(byte) }
            }
        case .oscEscape:
            finishOSC() // ESC \ ends it; anything else is malformed
            if byte != UInt8(ascii: "\\") { step(byte) }
        case .string:
            if byte == 0x1B { state = .stringEscape }
        case .stringEscape:
            state = byte == UInt8(ascii: "\\") ? .ground : .string
        }
    }

    /// A plain byte of the running command's output.
    private mutating func text(_ byte: UInt8) {
        guard var block = blocks.popLast() else { return }
        defer { blocks.append(block) }
        switch byte {
        case 0x0D:
            pendingCarriageReturn = true
        case 0x0A:
            pendingCarriageReturn = false
            block.bytes.append(byte)
            block.lineStart = block.bytes.count
        case 0x08:
            // Back over one character (and its UTF-8 continuation bytes).
            while block.bytes.count > block.lineStart {
                let removed = block.bytes.removeLast()
                if removed & 0xC0 != 0x80 { break }
            }
        case 0x09:
            append(byte, to: &block)
        case 0x00...0x1F, 0x7F:
            break
        default:
            append(byte, to: &block)
        }
    }

    private mutating func append(_ byte: UInt8, to block: inout CommandBlock) {
        if pendingCarriageReturn {
            // A carriage return without a newline: the line is redrawn
            // (progress bars, spinners); keep only the last version.
            pendingCarriageReturn = false
            block.bytes.removeSubrange(block.lineStart...)
        }
        block.bytes.append(byte)
        if block.bytes.count > maximumOutput {
            var drop = block.bytes.count - maximumOutput * 3 / 4
            // Do not start in the middle of a character.
            while drop < block.bytes.count, block.bytes[drop] & 0xC0 == 0x80 { drop += 1 }
            block.bytes.removeFirst(drop)
            block.lineStart = max(0, block.lineStart - drop)
            block.isTruncated = true
        }
    }

    private mutating func finishOSC() {
        state = .ground
        let payload = String(decoding: oscBuffer, as: UTF8.self)
        oscBuffer = []
        let fields = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let kind = fields.first else { return }
        let mark = fields.count > 1 ? fields[1] : ""
        switch kind {
        case "133" where mark.hasPrefix("C"):
            start()
        case "133" where mark.hasPrefix("D"):
            finish(code: fields.count > 2 ? Int(fields[2].prefix { $0 != ";" }) : nil)
        case "133" where mark.hasPrefix("A"):
            // A new prompt: whatever ran before it is over.
            if capturing { finish(code: nil) }
        case "633" where mark == "E":
            let report = fields.count > 2 ? fields[2] : ""
            let command = CommandLineReport.unescape(String(report.prefix { $0 != ";" }))
            if capturing, var block = blocks.popLast() {
                if block.command == nil { block.command = command }
                blocks.append(block)
            } else {
                pendingCommand = command
            }
        default:
            break
        }
    }

    private mutating func start() {
        if capturing { finish(code: nil) }
        blocks.append(CommandBlock(id: nextID, command: pendingCommand, startedAt: now()))
        nextID += 1
        pendingCommand = nil
        pendingCarriageReturn = false
        capturing = true
        if blocks.count > maximumBlocks { blocks.removeFirst(blocks.count - maximumBlocks) }
    }

    private mutating func finish(code: Int?) {
        guard capturing, var block = blocks.popLast() else { return }
        block.isFinished = true
        block.exitCode = code
        block.finishedAt = now()
        blocks.append(block)
        capturing = false
        pendingCarriageReturn = false
    }
}

/// How ghostgrid's shell hook reports each command line before it runs:
/// `OSC 633 ; E ; <command> BEL`, VS Code's convention, with `\` written
/// `\\`, and `;` and control characters written `\xNN`.
public enum CommandLineReport {
    public static func escape(_ command: String) -> String {
        var out = ""
        for scalar in command.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case ";": out += "\\x3b"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\x%02x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    public static func unescape(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var scalars = Substring(text).unicodeScalars
        while let scalar = scalars.popFirst() {
            guard scalar == "\\", let next = scalars.first else {
                out.append(scalar)
                continue
            }
            if next == "\\" {
                scalars.removeFirst()
                out.append("\\")
                continue
            }
            let hex = String(String.UnicodeScalarView(scalars.dropFirst().prefix(2)))
            if next == "x", hex.count == 2, let value = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(value) {
                scalars.removeFirst(3)
                out.append(decoded)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}

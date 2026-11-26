import Foundation

/// A command that failed, as sent to the local model (local "explain this").
public struct FailedCommand: Equatable, Sendable {
    public var command: String
    public var output: String
    public var exitCode: Int
    public var shell: String
    public var directory: String?

    public init(command: String, output: String, exitCode: Int, shell: String, directory: String?) {
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.shell = shell
        self.directory = directory
    }
}

/// Which finished commands get an explanation offered.
public enum ExplainPolicy {
    /// Exit statuses that mean the user stopped the command (Ctrl+C,
    /// SIGTERM, Ctrl+Z), not that it failed.
    static let interrupted: Set<Int> = [130, 143, 146, 148]

    public static func offers(exitCode: Int?, command: String?) -> Bool {
        guard let exitCode, exitCode != 0, !interrupted.contains(exitCode),
              let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// What the model is asked.
public enum ExplainPrompt {
    /// The end of the output is sent (errors are usually last), at most
    /// this many bytes, so a small local model answers quickly.
    public static let maximumOutput = 6000

    static let system = """
    You are a terminal assistant on macOS. A shell command failed. Explain the cause in one or two short \
    sentences, then give the single shell command that is most likely to fix it, for the user's shell. \
    Answer in exactly this format and nothing else:
    WHY: <the cause>
    FIX: <one command, or NONE if no command can fix it>
    Never suggest a command that deletes data, rewrites git history or uses sudo unless the output says \
    it is required. /no_think
    """

    public static func messages(for failure: FailedCommand) -> [ChatMessage] {
        var output = failure.output
        if output.utf8.count > maximumOutput {
            var tail = Substring(output).utf8.suffix(maximumOutput)
            // Start at a line boundary, and on a whole character.
            if let newline = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: newline)...] }
            output = "[... earlier output omitted ...]\n" + String(decoding: tail, as: UTF8.self)
        }
        let user = """
        Shell: \(failure.shell)
        Directory: \(failure.directory ?? "unknown")
        Command: \(failure.command)
        Exit status: \(failure.exitCode)
        Output:
        \(output.isEmpty ? "(no output)" : output)
        """
        return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)]
    }
}

/// The model's answer: why the command failed, and the fix to run.
public struct Explanation: Equatable, Sendable {
    public var why: String
    public var fix: String?

    public init(why: String, fix: String?) {
        self.why = why
        self.fix = fix
    }

    /// Reads an answer, complete or still streaming. Thinking (<think>)
    /// is dropped; without the WHY:/FIX: labels the whole text is the why.
    public static func parse(_ text: String) -> Explanation {
        var body = text
        while let open = body.range(of: "<think>") {
            if let close = body.range(of: "</think>", range: open.upperBound..<body.endIndex) {
                body.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                body.removeSubrange(open.lowerBound...)
            }
        }
        let why: String
        var fix: String?
        if let fixLabel = body.range(of: "FIX:") {
            why = section(body[..<fixLabel.lowerBound])
            fix = command(String(body[fixLabel.upperBound...]))
        } else {
            why = section(body[...])
        }
        return Explanation(why: why, fix: fix)
    }

    private static func section(_ text: Substring) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("WHY:") { text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
    }

    private static func command(_ text: String) -> String? {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        // A fenced block: the lines inside it.
        if let first = lines.first, first.hasPrefix("```") {
            lines.removeFirst()
            if let end = lines.firstIndex(where: { $0.hasPrefix("```") }) { lines = Array(lines[..<end]) }
        }
        var fix = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if fix.hasPrefix("`"), fix.hasSuffix("`"), fix.count >= 2 { fix = String(fix.dropFirst().dropLast()) }
        let bare = fix.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        if bare.isEmpty || bare == "none" || bare == "n/a" { return nil }
        return fix
    }
}

/// The OpenAI-style streaming chat API that LM Studio serves.
public enum ChatStream {
    public enum Event: Equatable, Sendable {
        case content(String), thinking, done, ignore, failure(String)
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                var content: String?
                var reasoning_content: String?
            }
            var delta: Delta?
        }

        struct Failure: Decodable { var message: String? }
        var choices: [Choice]?
        var error: Failure?
    }

    /// One server-sent-events line of the response.
    public static func event(_ line: String) -> Event {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { return .ignore }
        if let error = chunk.error { return .failure(error.message ?? "the model returned an error") }
        let delta = chunk.choices?.first?.delta
        if let content = delta?.content, !content.isEmpty { return .content(content) }
        if let thought = delta?.reasoning_content, !thought.isEmpty { return .thinking }
        return .ignore
    }

    /// The message in a non-streaming error response, if it has one.
    public static func serverError(_ body: Data) -> String? {
        struct Detailed: Decodable {
            struct Failure: Decodable { var message: String }
            var error: Failure
        }
        struct Plain: Decodable { var error: String }
        if let detailed = try? JSONDecoder().decode(Detailed.self, from: body) { return detailed.error.message }
        return (try? JSONDecoder().decode(Plain.self, from: body))?.error
    }

    public static func requestBody(model: String, messages: [ChatMessage]) throws -> Data {
        struct Body: Encodable {
            var model: String
            var messages: [ChatMessage]
            var stream = true
            var temperature = 0.2
            /// Thinking off where the server can turn it off (LM Studio does
            /// for models that declare it; other servers ignore the field).
            var reasoning_effort = "none"
            /// Room for a model that thinks anyway to finish and answer.
            var max_tokens = 4096
        }
        return try JSONEncoder().encode(Body(model: model, messages: messages))
    }
}

/// Which model to ask when Settings names none.
public enum ModelChoice {
    /// From LM Studio's GET /api/v1/models.
    /// A loaded chat model, preferring one whose thinking can be turned
    /// off; nil when none is loaded. Unloaded models are never picked:
    /// asking for one makes LM Studio try to load it, which can fail or
    /// take minutes.
    public static func pick(lmStudio data: Data) -> String? {
        struct Listing: Decodable {
            struct Model: Decodable {
                struct Instance: Decodable { var id: String }
                struct Capabilities: Decodable {
                    struct Reasoning: Decodable { var allowed_options: [String]? }
                    var reasoning: Reasoning?
                }
                var type: String
                var key: String
                var loaded_instances: [Instance]?
                var capabilities: Capabilities?
            }
            var models: [Model]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return nil }
        let loaded = listing.models.filter { $0.type == "llm" && !($0.loaded_instances ?? []).isEmpty }
        let quick = loaded.first { $0.capabilities?.reasoning?.allowed_options?.contains("off") == true }
        guard let model = quick ?? loaded.first else { return nil }
        return model.loaded_instances?.first?.id ?? model.key
    }

    /// From an OpenAI-style GET /v1/models: the first that is not an
    /// embedding model.
    public static func pick(openAI data: Data) -> String? {
        struct Listing: Decodable {
            struct Model: Decodable { var id: String }
            var data: [Model]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return nil }
        return listing.data.first { !$0.id.localizedCaseInsensitiveContains("embed") }?.id
    }
}

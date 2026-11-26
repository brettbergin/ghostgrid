import Foundation
import Testing
@testable import GhostGridCore

/// Contract for local "explain this" (PR 5): a failed command's output
/// goes to the local model with a prompt asking why it failed and for one
/// fix; the answer is read into an explanation and a runnable fix.
struct ExplainTests {
    let failure = FailedCommand(command: "git push", output: "fatal: no upstream\n", exitCode: 128, shell: "zsh",
                                directory: "/Users/me/code/app")

    @Test func failuresAreOfferedButInterruptionsAreNot() {
        #expect(ExplainPolicy.offers(exitCode: 1, command: "make"))
        #expect(ExplainPolicy.offers(exitCode: 128, command: "git push"))
        #expect(!ExplainPolicy.offers(exitCode: 0, command: "ls"), "success")
        #expect(!ExplainPolicy.offers(exitCode: nil, command: "ls"), "no exit status")
        #expect(!ExplainPolicy.offers(exitCode: 130, command: "sleep 9"), "Ctrl+C")
        #expect(!ExplainPolicy.offers(exitCode: 143, command: "sleep 9"), "terminated")
        #expect(!ExplainPolicy.offers(exitCode: 148, command: "vim"), "Ctrl+Z")
        #expect(!ExplainPolicy.offers(exitCode: 1, command: nil), "command unknown")
        #expect(!ExplainPolicy.offers(exitCode: 1, command: "   "), "empty command")
    }

    @Test func thePromptCarriesTheFailure() throws {
        let messages = ExplainPrompt.messages(for: failure)
        #expect(messages.map(\.role) == ["system", "user"])
        let user = try #require(messages.last?.content)
        for part in ["git push", "128", "zsh", "/Users/me/code/app", "fatal: no upstream"] {
            #expect(user.contains(part), "\(part)")
        }
        let system = try #require(messages.first?.content)
        #expect(system.contains("WHY:") && system.contains("FIX:"))
    }

    @Test func longOutputSendsItsEnd() throws {
        var long = failure
        long.output = (1...5000).map { "line \($0)" }.joined(separator: "\n")
        let user = try #require(ExplainPrompt.messages(for: long).last?.content)
        #expect(user.contains("line 5000"), "the end, where errors are")
        #expect(!user.contains("line 1\n"))
        #expect(user.utf8.count < ExplainPrompt.maximumOutput + 2000)
    }

    @Test func anAnswerSplitsIntoWhyAndFix() {
        let answer = Explanation.parse("WHY: The branch has no upstream.\nFIX: git push -u origin HEAD")
        #expect(answer.why == "The branch has no upstream.")
        #expect(answer.fix == "git push -u origin HEAD")
    }

    @Test func thinkingAndFencesAreDropped() {
        let answer = Explanation.parse("<think>hmm\nlet me see</think>\nWHY: Missing file.\nFIX:\n```bash\ntouch a.txt\n```\n")
        #expect(answer.why == "Missing file.")
        #expect(answer.fix == "touch a.txt")
        #expect(Explanation.parse("FIX: `ls -la`").fix == "ls -la")
    }

    @Test func noFixIsNoFix() {
        for none in ["NONE", "none", "None.", "", "N/A"] {
            #expect(Explanation.parse("WHY: Network is down.\nFIX: \(none)").fix == nil, "\(none)")
        }
    }

    @Test func aPartialAnswerShowsWhatIsThereSoFar() {
        #expect(Explanation.parse("<think>still thinking").why == "")
        #expect(Explanation.parse("WHY: The fi").why == "The fi")
        #expect(Explanation.parse("WHY: The fi").fix == nil)
        #expect(Explanation.parse("An answer without labels.").why == "An answer without labels.")
    }

    @Test func streamedChunksAreRead() {
        #expect(ChatStream.event(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#) == .content("Hel"))
        #expect(ChatStream.event("data: [DONE]") == .done)
        #expect(ChatStream.event(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == .ignore)
        #expect(ChatStream.event(": keep-alive") == .ignore)
        #expect(ChatStream.event("") == .ignore)
        #expect(ChatStream.event(#"data: {"error":{"message":"model not loaded"}}"#) == .failure("model not loaded"))
    }

    @Test func theRequestAsksForAStreamFromTheModel() throws {
        let body = try ChatStream.requestBody(model: "qwen", messages: ExplainPrompt.messages(for: failure))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "qwen")
        #expect(json["stream"] as? Bool == true)
        #expect((json["messages"] as? [[String: String]])?.count == 2)
    }
}

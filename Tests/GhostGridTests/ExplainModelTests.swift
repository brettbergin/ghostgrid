import Foundation
import Testing
@testable import GhostGridCore

/// Contract for picking and talking to the local model when Settings names
/// none: LM Studio lists every downloaded model, loaded or not, so asking
/// for the first one can make it try (and fail) to load a model that does
/// not fit. A loaded model is used, preferring one whose thinking can be
/// turned off, since a thinking model can spend minutes before answering.
struct ExplainModelTests {
    /// The shape of LM Studio's GET /api/v1/models.
    let lmStudio = Data("""
    {"models":[
      {"type":"llm","key":"qwen/qwen3-coder-next","loaded_instances":[],"capabilities":{}},
      {"type":"embedding","key":"nomic-embed","loaded_instances":[{"id":"nomic-embed"}]},
      {"type":"llm","key":"qwen3.8-27b-mlx","loaded_instances":[{"id":"qwen3.8-27b-mlx"}],"capabilities":{}},
      {"type":"llm","key":"google/gemma-4","loaded_instances":[{"id":"google/gemma-4"}],
       "capabilities":{"reasoning":{"allowed_options":["off","on"],"default":"on"}}}
    ]}
    """.utf8)

    @Test func aLoadedModelWhoseThinkingCanBeTurnedOffIsPreferred() {
        #expect(ModelChoice.pick(lmStudio: lmStudio) == "google/gemma-4")
    }

    @Test func otherwiseAnyLoadedChatModel() {
        let data = Data("""
        {"models":[
          {"type":"llm","key":"big","loaded_instances":[]},
          {"type":"embedding","key":"embed","loaded_instances":[{"id":"embed"}]},
          {"type":"llm","key":"qwen3.8-27b-mlx","loaded_instances":[{"id":"qwen3.8-27b-mlx"}]}
        ]}
        """.utf8)
        #expect(ModelChoice.pick(lmStudio: data) == "qwen3.8-27b-mlx")
    }

    @Test func aModelThatIsNotLoadedIsNeverPicked() {
        let data = Data("""
        {"models":[{"type":"llm","key":"big","loaded_instances":[],
          "capabilities":{"reasoning":{"allowed_options":["off","on"]}}}]}
        """.utf8)
        #expect(ModelChoice.pick(lmStudio: data) == nil)
        #expect(ModelChoice.pick(lmStudio: Data("<html>".utf8)) == nil)
    }

    @Test func otherServersGetTheirFirstChatModel() {
        let data = Data(#"{"data":[{"id":"text-embedding-nomic"},{"id":"llama3"},{"id":"mistral"}]}"#.utf8)
        #expect(ModelChoice.pick(openAI: data) == "llama3")
        #expect(ModelChoice.pick(openAI: Data(#"{"data":[{"id":"embed-only"}]}"#.utf8)) == nil)
    }

    @Test func thinkingIsShownAsThinkingNotAsTheAnswer() {
        #expect(ChatStream.event(#"data: {"choices":[{"delta":{"reasoning_content":"We need"}}]}"#) == .thinking)
        #expect(ChatStream.event(#"data: {"choices":[{"delta":{"content":"WHY"}}]}"#) == .content("WHY"))
    }

    @Test func theServersOwnErrorIsShown() {
        #expect(ChatStream.serverError(Data(#"{"error":{"message":"Failed to load model \"big\"."}}"#.utf8))
            == #"Failed to load model "big"."#)
        #expect(ChatStream.serverError(Data(#"{"error":"Model unloaded."}"#.utf8)) == "Model unloaded.")
        #expect(ChatStream.serverError(Data("<html>Internal Server Error</html>".utf8)) == nil)
    }

    @Test func theRequestTurnsThinkingOffAndLeavesRoomIfItCannot() throws {
        let body = try ChatStream.requestBody(model: "m", messages: [ChatMessage(role: "user", content: "x")])
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["reasoning_effort"] as? String == "none")
        #expect((json["max_tokens"] as? Int ?? 0) >= 2048)
    }
}

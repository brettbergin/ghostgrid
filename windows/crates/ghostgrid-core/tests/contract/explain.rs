//! Contract for local "explain this" (ExplainTests, ExplainModelTests): a
//! failed command's output goes to the local model with a prompt asking
//! why it failed and for one fix; the answer is read into an explanation
//! and a runnable fix. On Windows, Ctrl+C's status code is an interruption
//! too.

use ghostgrid_core::explain::{
    ChatEvent, ChatMessage, ChatStream, ExplainPolicy, ExplainPrompt, Explanation, FailedCommand,
    ModelChoice,
};

fn failure() -> FailedCommand {
    FailedCommand {
        command: "git push".into(),
        output: "fatal: no upstream\n".into(),
        exit_code: 128,
        shell: "pwsh".into(),
        directory: Some("C:\\Users\\me\\code\\app".into()),
    }
}

#[test]
fn failures_are_offered_but_interruptions_are_not() {
    assert!(ExplainPolicy::offers(Some(1), Some("make")));
    assert!(ExplainPolicy::offers(Some(128), Some("git push")));
    assert!(!ExplainPolicy::offers(Some(0), Some("ls")), "success");
    assert!(!ExplainPolicy::offers(None, Some("ls")), "no exit status");
    assert!(!ExplainPolicy::offers(Some(130), Some("sleep 9")), "Ctrl+C");
    assert!(
        !ExplainPolicy::offers(Some(143), Some("sleep 9")),
        "terminated"
    );
    assert!(!ExplainPolicy::offers(Some(146), Some("vim")), "stopped");
    assert!(!ExplainPolicy::offers(Some(148), Some("vim")), "Ctrl+Z");
    assert!(
        !ExplainPolicy::offers(Some(-1073741510), Some("ping -t x")),
        "STATUS_CONTROL_C_EXIT"
    );
    assert!(
        !ExplainPolicy::offers(Some(3221225786), Some("ping -t x")),
        "STATUS_CONTROL_C_EXIT unsigned"
    );
    assert!(!ExplainPolicy::offers(Some(1), None), "command unknown");
    assert!(
        !ExplainPolicy::offers(Some(1), Some("   ")),
        "empty command"
    );
}

#[test]
fn the_prompt_carries_the_failure() {
    let messages = ExplainPrompt::messages(&failure());
    assert_eq!(
        messages.iter().map(|m| m.role.as_str()).collect::<Vec<_>>(),
        ["system", "user"]
    );
    let user = &messages[1].content;
    for part in [
        "git push",
        "128",
        "pwsh",
        "C:\\Users\\me\\code\\app",
        "fatal: no upstream",
    ] {
        assert!(user.contains(part), "{part}");
    }
    let system = &messages[0].content;
    assert!(system.contains("WHY:") && system.contains("FIX:"));
    assert!(
        system.contains("Windows") && !system.contains("macOS"),
        "{system}"
    );
    assert!(system.contains("pwsh"), "names the shell: {system}");
}

#[test]
fn a_failure_without_output_or_folder_says_so() {
    let mut bare = failure();
    bare.output = String::new();
    bare.directory = None;
    let user = &ExplainPrompt::messages(&bare)[1].content;
    assert!(user.contains("Directory: unknown"));
    assert!(user.contains("(no output)"));
}

#[test]
fn long_output_sends_its_end() {
    let mut long = failure();
    long.output = (1..=5000)
        .map(|i| format!("line {i}"))
        .collect::<Vec<_>>()
        .join("\n");
    let user = ExplainPrompt::messages(&long).pop().unwrap().content;
    assert!(user.contains("line 5000"), "the end, where errors are");
    assert!(!user.contains("line 1\n"));
    assert!(user.len() < ExplainPrompt::MAX_OUTPUT + 2000);
    assert!(user.contains("[... earlier output omitted ...]"));
}

#[test]
fn long_output_without_newlines_starts_on_a_whole_character() {
    let mut long = failure();
    long.output = "\u{e9}".repeat(4000);
    let user = ExplainPrompt::messages(&long).pop().unwrap().content;
    assert!(!user.contains('\u{fffd}'));
}

#[test]
fn an_answer_splits_into_why_and_fix() {
    let answer =
        Explanation::parse("WHY: The branch has no upstream.\nFIX: git push -u origin HEAD");
    assert_eq!(answer.why, "The branch has no upstream.");
    assert_eq!(answer.fix.as_deref(), Some("git push -u origin HEAD"));
}

#[test]
fn thinking_and_fences_are_dropped() {
    let answer = Explanation::parse("<think>hmm\nlet me see</think>\nWHY: Missing file.\nFIX:\n```powershell\nNew-Item a.txt\n```\n");
    assert_eq!(answer.why, "Missing file.");
    assert_eq!(answer.fix.as_deref(), Some("New-Item a.txt"));
    assert_eq!(
        Explanation::parse("FIX: `ls -la`").fix.as_deref(),
        Some("ls -la")
    );
}

#[test]
fn no_fix_is_no_fix() {
    for none in ["NONE", "none", "None.", "", "N/A"] {
        assert_eq!(
            Explanation::parse(&format!("WHY: Network is down.\nFIX: {none}")).fix,
            None,
            "{none}"
        );
    }
}

#[test]
fn a_partial_answer_shows_what_is_there_so_far() {
    assert_eq!(Explanation::parse("<think>still thinking").why, "");
    assert_eq!(Explanation::parse("WHY: The fi").why, "The fi");
    assert_eq!(Explanation::parse("WHY: The fi").fix, None);
    assert_eq!(
        Explanation::parse("An answer without labels.").why,
        "An answer without labels."
    );
}

#[test]
fn streamed_chunks_are_read() {
    assert_eq!(
        ChatStream::event(r#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#),
        ChatEvent::Content("Hel".into())
    );
    assert_eq!(ChatStream::event("data: [DONE]"), ChatEvent::Done);
    assert_eq!(
        ChatStream::event("data: [DONE]\r"),
        ChatEvent::Done,
        "CRLF event streams"
    );
    assert_eq!(
        ChatStream::event(r#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#),
        ChatEvent::Ignore
    );
    assert_eq!(ChatStream::event(": keep-alive"), ChatEvent::Ignore);
    assert_eq!(ChatStream::event(""), ChatEvent::Ignore);
    assert_eq!(
        ChatStream::event(r#"data: {"error":{"message":"model not loaded"}}"#),
        ChatEvent::Failure("model not loaded".into())
    );
    assert_eq!(
        ChatStream::event(r#"data: {"error":{}}"#),
        ChatEvent::Failure("the model returned an error".into())
    );
}

#[test]
fn the_request_asks_for_a_stream_from_the_model() {
    let body = ChatStream::request_body("qwen", &ExplainPrompt::messages(&failure()));
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["model"], "qwen");
    assert_eq!(json["stream"], true);
    assert_eq!(json["messages"].as_array().unwrap().len(), 2);
    assert_eq!(json["messages"][0]["role"], "system");
}

// ExplainModelTests

const LM_STUDIO: &str = r#"{"models":[
  {"type":"llm","key":"qwen/qwen3-coder-next","loaded_instances":[],"capabilities":{}},
  {"type":"embedding","key":"nomic-embed","loaded_instances":[{"id":"nomic-embed"}]},
  {"type":"llm","key":"qwen3.8-27b-mlx","loaded_instances":[{"id":"qwen3.8-27b-mlx"}],"capabilities":{}},
  {"type":"llm","key":"google/gemma-4","loaded_instances":[{"id":"google/gemma-4"}],
   "capabilities":{"reasoning":{"allowed_options":["off","on"],"default":"on"}}}
]}"#;

#[test]
fn a_loaded_model_whose_thinking_can_be_turned_off_is_preferred() {
    assert_eq!(
        ModelChoice::pick_lm_studio(LM_STUDIO.as_bytes()).as_deref(),
        Some("google/gemma-4")
    );
}

#[test]
fn otherwise_any_loaded_chat_model() {
    let data = r#"{"models":[
      {"type":"llm","key":"big","loaded_instances":[]},
      {"type":"embedding","key":"embed","loaded_instances":[{"id":"embed"}]},
      {"type":"llm","key":"qwen3.8-27b-mlx","loaded_instances":[{"id":"qwen3.8-27b-mlx"}]}
    ]}"#;
    assert_eq!(
        ModelChoice::pick_lm_studio(data.as_bytes()).as_deref(),
        Some("qwen3.8-27b-mlx")
    );
}

#[test]
fn a_model_that_is_not_loaded_is_never_picked() {
    let data = r#"{"models":[{"type":"llm","key":"big","loaded_instances":[],
      "capabilities":{"reasoning":{"allowed_options":["off","on"]}}}]}"#;
    assert_eq!(ModelChoice::pick_lm_studio(data.as_bytes()), None);
    assert_eq!(ModelChoice::pick_lm_studio(b"<html>"), None);
}

#[test]
fn other_servers_get_their_first_chat_model() {
    let data = r#"{"data":[{"id":"text-embedding-nomic"},{"id":"llama3"},{"id":"mistral"}]}"#;
    assert_eq!(
        ModelChoice::pick_openai(data.as_bytes()).as_deref(),
        Some("llama3")
    );
    assert_eq!(
        ModelChoice::pick_openai(br#"{"data":[{"id":"EMBED-only"}]}"#),
        None
    );
}

#[test]
fn thinking_is_shown_as_thinking_not_as_the_answer() {
    assert_eq!(
        ChatStream::event(r#"data: {"choices":[{"delta":{"reasoning_content":"We need"}}]}"#),
        ChatEvent::Thinking
    );
    assert_eq!(
        ChatStream::event(r#"data: {"choices":[{"delta":{"content":"WHY"}}]}"#),
        ChatEvent::Content("WHY".into())
    );
}

#[test]
fn the_servers_own_error_is_shown() {
    assert_eq!(
        ChatStream::server_error(br#"{"error":{"message":"Failed to load model \"big\"."}}"#)
            .as_deref(),
        Some(r#"Failed to load model "big"."#)
    );
    assert_eq!(
        ChatStream::server_error(br#"{"error":"Model unloaded."}"#).as_deref(),
        Some("Model unloaded.")
    );
    assert_eq!(
        ChatStream::server_error(b"<html>Internal Server Error</html>"),
        None
    );
}

#[test]
fn the_request_turns_thinking_off_and_leaves_room_if_it_cannot() {
    let body = ChatStream::request_body(
        "m",
        &[ChatMessage {
            role: "user".into(),
            content: "x".into(),
        }],
    );
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["reasoning_effort"], "none");
    assert!(json["max_tokens"].as_i64().unwrap_or(0) >= 2048);
    assert_eq!(json["temperature"], 0.2);
}

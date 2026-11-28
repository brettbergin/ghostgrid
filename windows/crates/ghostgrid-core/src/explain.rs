//! Local "explain this": a failed command's output goes to a local model
//! (LM Studio by default) with a prompt asking why it failed and for one
//! fix; the streamed answer is read into an explanation and a runnable fix.

use serde::{Deserialize, Serialize};

/// A command that failed, as sent to the local model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailedCommand {
    pub command: String,
    pub output: String,
    /// i64 so a Windows status (an unsigned 32-bit NTSTATUS) fits as given.
    pub exit_code: i64,
    /// The ShellChoice name ("pwsh", "cmd", "gitbash", "wsl", ...).
    pub shell: String,
    pub directory: Option<String>,
}

/// Which finished commands get an explanation offered.
pub struct ExplainPolicy;

impl ExplainPolicy {
    /// Exit statuses that mean the user stopped the command (Ctrl+C,
    /// SIGTERM, Ctrl+Z), not that it failed: the POSIX ones, and Windows'
    /// STATUS_CONTROL_C_EXIT read signed and unsigned.
    pub const INTERRUPTED: [i64; 6] = [130, 143, 146, 148, -1073741510, 3221225786];

    pub fn offers(exit_code: Option<i64>, command: Option<&str>) -> bool {
        let Some(code) = exit_code else { return false };
        code != 0
            && !Self::INTERRUPTED.contains(&code)
            && command.is_some_and(|c| !c.trim().is_empty())
    }
}

/// One chat message, as the OpenAI-style API takes it.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

/// What the model is asked.
pub struct ExplainPrompt;

impl ExplainPrompt {
    /// The end of the output is sent (errors are usually last), at most
    /// this many bytes, so a small local model answers quickly.
    pub const MAX_OUTPUT: usize = 6000;

    fn system(shell: &str) -> String {
        format!(
            "You are a terminal assistant on Windows. A command failed in {shell}. Explain the cause in one or two short \
             sentences, then give the single command that is most likely to fix it, written for {shell}. \
             Answer in exactly this format and nothing else:\n\
             WHY: <the cause>\n\
             FIX: <one command, or NONE if no command can fix it>\n\
             Never suggest a command that deletes data, rewrites git history or needs an administrator unless the output \
             says it is required. /no_think"
        )
    }

    pub fn messages(failure: &FailedCommand) -> Vec<ChatMessage> {
        let mut output = failure.output.clone();
        if output.len() > Self::MAX_OUTPUT {
            let mut start = output.len() - Self::MAX_OUTPUT;
            // Start on a whole character, and at a line boundary.
            while !output.is_char_boundary(start) {
                start += 1;
            }
            let tail = &output[start..];
            let tail = tail.find('\n').map_or(tail, |newline| &tail[newline + 1..]);
            output = format!("[... earlier output omitted ...]\n{tail}");
        }
        let user = format!(
            "Shell: {}\nDirectory: {}\nCommand: {}\nExit status: {}\nOutput:\n{}",
            failure.shell,
            failure.directory.as_deref().unwrap_or("unknown"),
            failure.command,
            failure.exit_code,
            if output.is_empty() {
                "(no output)"
            } else {
                &output
            },
        );
        vec![
            ChatMessage {
                role: "system".into(),
                content: Self::system(&failure.shell),
            },
            ChatMessage {
                role: "user".into(),
                content: user,
            },
        ]
    }
}

/// The model's answer: why the command failed, and the fix to run.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Explanation {
    pub why: String,
    pub fix: Option<String>,
}

impl Explanation {
    /// Reads an answer, complete or still streaming. Thinking (`<think>`)
    /// is dropped; without the WHY:/FIX: labels the whole text is the why.
    pub fn parse(text: &str) -> Explanation {
        let mut body = text.to_string();
        while let Some(open) = body.find("<think>") {
            match body[open + 7..].find("</think>") {
                Some(close) => body.replace_range(open..open + 7 + close + 8, ""),
                None => body.truncate(open),
            }
        }
        match body.find("FIX:") {
            Some(label) => Explanation {
                why: section(&body[..label]),
                fix: command(&body[label + 4..]),
            },
            None => Explanation {
                why: section(&body),
                fix: None,
            },
        }
    }
}

fn section(text: &str) -> String {
    let text = text.trim();
    text.strip_prefix("WHY:")
        .map_or(text, str::trim)
        .to_string()
}

fn command(text: &str) -> Option<String> {
    let mut lines: Vec<&str> = text.trim().split('\n').collect();
    // A fenced block: the lines inside it.
    if lines.first().is_some_and(|l| l.starts_with("```")) {
        lines.remove(0);
        if let Some(end) = lines.iter().position(|l| l.starts_with("```")) {
            lines.truncate(end);
        }
    }
    let joined = lines.join("\n");
    let mut fix = joined.trim();
    if fix.len() >= 2 && fix.starts_with('`') && fix.ends_with('`') {
        fix = &fix[1..fix.len() - 1];
    }
    let bare = fix.trim_matches(|c| c == '.' || c == ' ').to_lowercase();
    if bare.is_empty() || bare == "none" || bare == "n/a" {
        return None;
    }
    Some(fix.to_string())
}

/// One line of the streamed answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChatEvent {
    /// More of the answer.
    Content(String),
    /// The model is thinking (shown as such, not as the answer).
    Thinking,
    Done,
    Ignore,
    Failure(String),
}

/// The OpenAI-style streaming chat API that LM Studio serves.
pub struct ChatStream;

#[derive(Deserialize)]
struct Chunk {
    choices: Option<Vec<Choice>>,
    error: Option<ChunkFailure>,
}

#[derive(Deserialize)]
struct Choice {
    delta: Option<Delta>,
}

#[derive(Deserialize)]
struct Delta {
    content: Option<String>,
    reasoning_content: Option<String>,
}

#[derive(Deserialize)]
struct ChunkFailure {
    message: Option<String>,
}

#[derive(Serialize)]
struct RequestBody<'a> {
    model: &'a str,
    messages: &'a [ChatMessage],
    stream: bool,
    temperature: f64,
    /// Thinking off where the server can turn it off (LM Studio does for
    /// models that declare it; other servers ignore the field).
    reasoning_effort: &'a str,
    /// Room for a model that thinks anyway to finish and answer.
    max_tokens: u32,
}

impl ChatStream {
    /// One server-sent-events line of the response.
    pub fn event(line: &str) -> ChatEvent {
        let Some(payload) = line.strip_prefix("data:") else {
            return ChatEvent::Ignore;
        };
        let payload = payload.trim();
        if payload == "[DONE]" {
            return ChatEvent::Done;
        }
        let Ok(chunk) = serde_json::from_str::<Chunk>(payload) else {
            return ChatEvent::Ignore;
        };
        if let Some(error) = chunk.error {
            return ChatEvent::Failure(
                error
                    .message
                    .unwrap_or_else(|| "the model returned an error".into()),
            );
        }
        let delta = chunk
            .choices
            .and_then(|c| c.into_iter().next())
            .and_then(|c| c.delta);
        if let Some(delta) = delta {
            if let Some(content) = delta.content.filter(|c| !c.is_empty()) {
                return ChatEvent::Content(content);
            }
            if delta.reasoning_content.is_some_and(|t| !t.is_empty()) {
                return ChatEvent::Thinking;
            }
        }
        ChatEvent::Ignore
    }

    /// The message in a non-streaming error response, if it has one.
    pub fn server_error(body: &[u8]) -> Option<String> {
        #[derive(Deserialize)]
        struct Detailed {
            error: DetailedFailure,
        }
        #[derive(Deserialize)]
        struct DetailedFailure {
            message: String,
        }
        #[derive(Deserialize)]
        struct Plain {
            error: String,
        }
        if let Ok(detailed) = serde_json::from_slice::<Detailed>(body) {
            return Some(detailed.error.message);
        }
        serde_json::from_slice::<Plain>(body).ok().map(|p| p.error)
    }

    pub fn request_body(model: &str, messages: &[ChatMessage]) -> Vec<u8> {
        let body = RequestBody {
            model,
            messages,
            stream: true,
            temperature: 0.2,
            reasoning_effort: "none",
            max_tokens: 4096,
        };
        serde_json::to_vec(&body).unwrap_or_default()
    }
}

/// Which model to ask when Settings names none.
pub struct ModelChoice;

#[derive(Deserialize)]
struct LmStudioListing {
    models: Vec<LmStudioModel>,
}

#[derive(Deserialize)]
struct LmStudioModel {
    #[serde(rename = "type")]
    kind: String,
    key: String,
    loaded_instances: Option<Vec<LmStudioInstance>>,
    capabilities: Option<LmStudioCapabilities>,
}

#[derive(Deserialize)]
struct LmStudioInstance {
    id: String,
}

#[derive(Deserialize)]
struct LmStudioCapabilities {
    reasoning: Option<LmStudioReasoning>,
}

#[derive(Deserialize)]
struct LmStudioReasoning {
    allowed_options: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct OpenAiListing {
    data: Vec<OpenAiModel>,
}

#[derive(Deserialize)]
struct OpenAiModel {
    id: String,
}

impl ModelChoice {
    /// From LM Studio's GET /api/v1/models: a loaded chat model, preferring
    /// one whose thinking can be turned off; None when none is loaded.
    /// Unloaded models are never picked: asking for one makes LM Studio try
    /// to load it, which can fail or take minutes.
    pub fn pick_lm_studio(data: &[u8]) -> Option<String> {
        let listing: LmStudioListing = serde_json::from_slice(data).ok()?;
        let loaded: Vec<&LmStudioModel> = listing
            .models
            .iter()
            .filter(|m| {
                m.kind == "llm" && m.loaded_instances.as_ref().is_some_and(|i| !i.is_empty())
            })
            .collect();
        let quick = loaded.iter().find(|m| {
            m.capabilities
                .as_ref()
                .and_then(|c| c.reasoning.as_ref())
                .and_then(|r| r.allowed_options.as_ref())
                .is_some_and(|options| options.iter().any(|o| o == "off"))
        });
        let model = quick.or(loaded.first())?;
        Some(
            model
                .loaded_instances
                .as_ref()
                .and_then(|i| i.first())
                .map_or_else(|| model.key.clone(), |instance| instance.id.clone()),
        )
    }

    /// From an OpenAI-style GET /v1/models: the first that is not an
    /// embedding model.
    pub fn pick_openai(data: &[u8]) -> Option<String> {
        let listing: OpenAiListing = serde_json::from_slice(data).ok()?;
        listing
            .data
            .into_iter()
            .find(|m| !m.id.to_lowercase().contains("embed"))
            .map(|m| m.id)
    }
}

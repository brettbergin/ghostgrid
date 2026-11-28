//! Explain failures: asks a local OpenAI-style model (LM Studio by default)
//! why a command failed and how to fix it, streaming the answer into the
//! pane's panel as it is written.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ghostgrid_core::explain::{ChatStream, ChatEvent, Explanation, ExplainPrompt, FailedCommand, ModelChoice};
use serde_json::json;
use tauri::ipc::Channel;

#[derive(Default)]
pub struct Explainer {
    running: Mutex<HashMap<String, Arc<AtomicBool>>>,
}

fn agent(timeout: Option<Duration>) -> ureq::Agent {
    use ureq::tls::{TlsConfig, TlsProvider};
    ureq::Agent::config_builder()
        .tls_config(TlsConfig::builder().provider(TlsProvider::NativeTls).build())
        .http_status_as_error(false)
        .timeout_connect(Some(Duration::from_secs(3)))
        .timeout_global(timeout)
        .build()
        .into()
}

/// The model to ask: the one Settings names, else one the server already
/// has loaded (LM Studio's own listing first, then the OpenAI one).
fn pick_model(endpoint: &str, configured: &str) -> Result<String, String> {
    if !configured.trim().is_empty() {
        return Ok(configured.trim().to_string());
    }
    let agent = agent(Some(Duration::from_secs(5)));
    let base = endpoint.trim_end_matches('/');
    let origin = base.strip_suffix("/v1").unwrap_or(base);
    let get = |url: String| -> Option<Vec<u8>> {
        let mut response = agent.get(&url).call().ok()?;
        if response.status() != 200 {
            return None;
        }
        response.body_mut().read_to_vec().ok()
    };
    if let Some(model) = get(format!("{origin}/api/v1/models")).and_then(|d| ModelChoice::pick_lm_studio(&d)) {
        return Ok(model);
    }
    if let Some(model) = get(format!("{base}/models")).and_then(|d| ModelChoice::pick_openai(&d)) {
        return Ok(model);
    }
    Err(format!("no model is loaded at {base} (load one in LM Studio, or name one in Settings)"))
}

impl Explainer {
    /// Explains `failure`, sending `{why, fix, done, error}` updates on
    /// `channel` until the answer is complete. Starting another for the
    /// same pane stops this one.
    pub fn start(&self, pane: String, failure: FailedCommand, endpoint: String, model: String, channel: Channel<serde_json::Value>) {
        let stop = Arc::new(AtomicBool::new(false));
        if let Some(old) = self.running.lock().unwrap().insert(pane, stop.clone()) {
            old.store(true, Ordering::SeqCst);
        }
        std::thread::spawn(move || {
            let send = |value: serde_json::Value| {
                let _ = channel.send(value);
            };
            let result = (|| -> Result<(), String> {
                let model = pick_model(&endpoint, &model)?;
                send(json!({ "model": model, "why": "", "fix": null, "done": false }));
                let body = ChatStream::request_body(&model, &ExplainPrompt::messages(&failure));
                let url = format!("{}/chat/completions", endpoint.trim_end_matches('/'));
                let mut response = agent(Some(Duration::from_secs(300)))
                    .post(&url)
                    .header("Content-Type", "application/json")
                    .send(&body[..])
                    .map_err(|e| format!("cannot reach the model server at {endpoint}: {e}"))?;
                if response.status() != 200 {
                    let data = response.body_mut().read_to_vec().unwrap_or_default();
                    return Err(ChatStream::server_error(&data).unwrap_or_else(|| format!("the model server answered {}", response.status())));
                }
                let reader = BufReader::new(response.body_mut().as_reader());
                let mut text = String::new();
                for line in reader.lines() {
                    if stop.load(Ordering::SeqCst) {
                        return Ok(());
                    }
                    let line = line.map_err(|e| e.to_string())?;
                    match ChatStream::event(&line) {
                        ChatEvent::Content(chunk) => {
                            text.push_str(&chunk);
                            let answer = Explanation::parse(&text);
                            send(json!({ "why": answer.why, "fix": answer.fix, "done": false }));
                        }
                        ChatEvent::Thinking => send(json!({ "thinking": true, "done": false })),
                        ChatEvent::Failure(message) => return Err(message),
                        ChatEvent::Done => break,
                        ChatEvent::Ignore => {}
                    }
                }
                let answer = Explanation::parse(&text);
                send(json!({ "why": answer.why, "fix": answer.fix, "done": true }));
                Ok(())
            })();
            if let Err(error) = result {
                if !stop.load(Ordering::SeqCst) {
                    send(json!({ "error": error, "done": true }));
                }
            }
        });
    }

    pub fn cancel(&self, pane: &str) {
        if let Some(stop) = self.running.lock().unwrap().remove(pane) {
            stop.store(true, Ordering::SeqCst);
        }
    }
}

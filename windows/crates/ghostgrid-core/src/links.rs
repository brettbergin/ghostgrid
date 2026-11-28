//! Decides what a Ctrl-clicked link in a terminal opens.
//!
//! The text a terminal hands over is untrusted: a program can print or
//! OSC 8-link anything. Only web, mail and file links open; other schemes
//! (custom app handlers, `javascript:`, `ms-settings:`, ...) are refused.
//! A bare path opens as a file when it exists, relative paths resolving
//! against the pane's working directory.

use crate::paths;

/// What to open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Link {
    /// An http, https or mailto URL, as written.
    Url(String),
    /// A file or folder (from a path, or a `file://` URL).
    File(String),
}

const ALLOWED_SCHEMES: [&str; 4] = ["http", "https", "mailto", "file"];

/// The scheme of `text` (RFC 3986: a letter, then letters, digits, `+`,
/// `-`, `.`, then `:`), when it has one longer than a character, so a
/// drive letter (`C:\x`) is a path.
fn scheme(text: &str) -> Option<&str> {
    let colon = text.find(':')?;
    let scheme = &text[..colon];
    let mut chars = scheme.chars();
    let first = chars.next()?;
    let valid = first.is_ascii_alphabetic()
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    (valid && scheme.len() > 1).then_some(scheme)
}

/// What `raw` opens, or None. `cwd` is the pane's folder (None when the
/// shell has not reported one); `exists` checks a path on disk.
pub fn resolve(
    raw: &str,
    cwd: Option<&str>,
    home: &str,
    exists: &dyn Fn(&str) -> bool,
) -> Option<Link> {
    let text = raw.trim();
    if text.is_empty() {
        return None;
    }

    if let Some(scheme) = scheme(text) {
        let scheme = scheme.to_ascii_lowercase();
        if !ALLOWED_SCHEMES.contains(&scheme.as_str()) {
            return None;
        }
        if scheme == "file" {
            if let Some(path) = paths::file_url_to_path(text) {
                return Some(Link::File(path));
            }
        }
        return Some(Link::Url(text.to_string()));
    }

    let path = if let Some(expanded) = paths::expand_home(text, home) {
        expanded
    } else if paths::is_absolute(text) {
        text.to_string()
    } else {
        paths::join(cwd?, text)
    };
    let path = paths::normalize(&path);
    exists(&path).then_some(Link::File(path))
}

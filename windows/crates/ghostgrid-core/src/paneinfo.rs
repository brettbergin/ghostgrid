//! What a pane header shows: the git branch, the folder, and the badge for
//! something that happened while you were not looking.

use crate::paths;
use std::path::{Path, PathBuf};

/// The git branch for a folder, read from the repository's HEAD file
/// without running git (a header updates on every prompt). Walks up to
/// the nearest `.git`, which may be a folder or, in a worktree or
/// submodule, a file pointing at the real git dir.
pub struct GitBranch;

impl GitBranch {
    pub fn read(
        directory: &str,
        exists: &dyn Fn(&Path) -> bool,
        is_dir: &dyn Fn(&Path) -> bool,
        read_file: &dyn Fn(&Path) -> Option<String>,
    ) -> Option<String> {
        let start = PathBuf::from(paths::normalize(directory));
        let mut current: &Path = &start;
        loop {
            let dot_git = current.join(".git");
            if exists(&dot_git) {
                let git_dir = Self::resolve_git_dir(&dot_git, is_dir, read_file)?;
                let head = read_file(&git_dir.join("HEAD"))?;
                return Self::branch_from_head(&head);
            }
            current = current.parent()?;
        }
    }

    /// "ref: refs/heads/main" -> "main"; a detached HEAD -> its short hash.
    pub fn branch_from_head(head: &str) -> Option<String> {
        let text = head.trim();
        if let Some(reference) = text.strip_prefix("ref:") {
            let reference = reference.trim();
            return Some(
                reference
                    .strip_prefix("refs/heads/")
                    .unwrap_or(reference)
                    .to_string(),
            );
        }
        let is_hash = text.len() >= 7 && text.bytes().all(|b| b.is_ascii_hexdigit());
        is_hash.then(|| text[..7].to_string())
    }

    fn resolve_git_dir(
        dot_git: &Path,
        is_dir: &dyn Fn(&Path) -> bool,
        read_file: &dyn Fn(&Path) -> Option<String>,
    ) -> Option<PathBuf> {
        if is_dir(dot_git) {
            return Some(dot_git.to_path_buf());
        }
        let contents = read_file(dot_git)?;
        let line = contents.lines().find(|line| line.starts_with("gitdir:"))?;
        let path = line["gitdir:".len()..].trim();
        // Git for Windows writes `C:/...`; a WSL repository `/home/...`.
        if paths::is_absolute(path) {
            return Some(PathBuf::from(paths::normalize(path)));
        }
        let base = dot_git.parent()?.display().to_string();
        Some(PathBuf::from(paths::join(&base, path)))
    }
}

/// A folder as a header shows it: the home folder as "~", and long paths
/// trimmed from the left so the end (the part you care about) stays.
pub struct PathDisplay;

impl PathDisplay {
    pub const DEFAULT_MAX_LENGTH: usize = 48;

    /// Windows paths match the home folder without case (and with either
    /// separator); WSL paths match exactly.
    pub fn short(path: &str, home: &str, max_length: usize) -> String {
        let trim = |p: &'_ str| -> String {
            let trimmed = p.trim_end_matches(paths::is_separator);
            if trimmed.is_empty() || trimmed.ends_with(':') {
                p.to_string()
            } else {
                trimmed.to_string()
            }
        };
        let path_t = trim(path);
        let home_t = trim(home);
        let windows = !home_t.starts_with('/');
        let same = |a: &str, b: &str| {
            if windows {
                a.len() == b.len()
                    && a.chars().zip(b.chars()).all(|(x, y)| {
                        x.eq_ignore_ascii_case(&y)
                            || (paths::is_separator(x) && paths::is_separator(y))
                    })
            } else {
                a == b
            }
        };
        let mut text = path_t.clone();
        if !home_t.is_empty() {
            if same(&path_t, &home_t) {
                text = "~".into();
            } else if path_t.len() > home_t.len()
                && path_t.is_char_boundary(home_t.len())
                && same(&path_t[..home_t.len()], &home_t)
                && path_t[home_t.len()..].starts_with(paths::is_separator)
            {
                text = format!("~{}", &path_t[home_t.len()..]);
            }
        }
        let count = text.chars().count();
        if count <= max_length || max_length <= 1 {
            return text;
        }
        let tail: String = text.chars().skip(count - (max_length - 1)).collect();
        format!("\u{2026}{tail}")
    }
}

/// Something that happened in a pane while you were not looking at it.
#[derive(Debug, Clone, PartialEq)]
pub enum PaneActivity {
    Bell,
    Finished {
        exit_code: Option<i32>,
        seconds: f64,
    },
}

impl PaneActivity {
    /// Commands shorter than this do not badge: quick commands finish
    /// before you would have looked away.
    pub const MINIMUM_SECONDS: f64 = 5.0;

    pub fn failed(&self) -> bool {
        matches!(self, PaneActivity::Finished { exit_code: Some(code), .. } if *code != 0)
    }

    /// The badge for a finished command, or None when it should not show:
    /// the pane is focused, or the command was quick.
    pub fn for_finished_command(
        exit_code: Option<i32>,
        duration_nanos: u64,
        pane_focused: bool,
    ) -> Option<PaneActivity> {
        let seconds = duration_nanos as f64 / 1_000_000_000.0;
        (!pane_focused && seconds >= Self::MINIMUM_SECONDS)
            .then_some(PaneActivity::Finished { exit_code, seconds })
    }

    /// Short text for the badge: "bell", "12s", "1m 05s", "exit 2".
    pub fn label(&self) -> String {
        match self {
            PaneActivity::Bell => "bell".into(),
            PaneActivity::Finished {
                exit_code: Some(code),
                ..
            } if *code != 0 => format!("exit {code}"),
            PaneActivity::Finished { seconds, .. } => {
                let total = seconds.round() as i64;
                if total < 60 {
                    format!("{total}s")
                } else {
                    format!("{}m {:02}s", total / 60, total % 60)
                }
            }
        }
    }
}

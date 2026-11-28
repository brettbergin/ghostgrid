//! Contract for what a pane header shows (PaneInfoTests): the git branch
//! read from the repository without running git, the folder as "~", and
//! activity badges.

use ghostgrid_core::paneinfo::{GitBranch, PaneActivity, PathDisplay};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// A fake file system: directories and file contents by path.
#[derive(Default)]
struct Fs {
    dirs: HashSet<PathBuf>,
    files: HashMap<PathBuf, String>,
}

impl Fs {
    fn new(dirs: &[&str], files: &[(&str, &str)]) -> Fs {
        Fs {
            dirs: dirs.iter().map(PathBuf::from).collect(),
            files: files
                .iter()
                .map(|(p, c)| (PathBuf::from(p), c.to_string()))
                .collect(),
        }
    }

    fn branch(&self, from: &str) -> Option<String> {
        GitBranch::read(
            from,
            &|p: &Path| self.dirs.contains(p) || self.files.contains_key(p),
            &|p: &Path| self.dirs.contains(p),
            &|p: &Path| self.files.get(p).cloned(),
        )
    }
}

#[test]
fn reads_the_branch_from_the_nearest_repository() {
    let fs = Fs::new(
        &["C:\\r\\.git"],
        &[("C:\\r\\.git\\HEAD", "ref: refs/heads/main\n")],
    );
    assert_eq!(fs.branch("C:\\r").as_deref(), Some("main"));
    assert_eq!(fs.branch("C:\\r\\src\\deep").as_deref(), Some("main"));
    assert_eq!(fs.branch("C:\\r\\src\\..\\src").as_deref(), Some("main"));
    assert_eq!(fs.branch("C:\\elsewhere"), None);
    assert_eq!(fs.branch("C:\\"), None);
}

#[test]
fn follows_worktree_git_files() {
    let fs = Fs::new(
        &["C:\\main\\.git\\worktrees\\feat"],
        &[
            ("C:\\wt\\.git", "gitdir: C:/main/.git/worktrees/feat\r\n"),
            (
                "C:\\main\\.git\\worktrees\\feat\\HEAD",
                "ref: refs/heads/brettbergin/feat\n",
            ),
        ],
    );
    assert_eq!(fs.branch("C:\\wt").as_deref(), Some("brettbergin/feat"));
}

#[test]
fn relative_gitdir_resolves_against_the_repo() {
    let fs = Fs::new(
        &["C:\\super\\.git\\modules\\sub"],
        &[
            ("C:\\super\\sub\\.git", "gitdir: ../.git/modules/sub"),
            ("C:\\super\\.git\\modules\\sub\\HEAD", "ref: refs/heads/dev"),
        ],
    );
    assert_eq!(fs.branch("C:\\super\\sub").as_deref(), Some("dev"));
}

#[test]
fn head_parsing() {
    assert_eq!(
        GitBranch::branch_from_head("ref: refs/heads/a/b").as_deref(),
        Some("a/b")
    );
    assert_eq!(
        GitBranch::branch_from_head("ref: refs/remotes/x").as_deref(),
        Some("refs/remotes/x")
    );
    assert_eq!(
        GitBranch::branch_from_head("0123456789abcdef0123456789abcdef01234567").as_deref(),
        Some("0123456")
    );
    assert_eq!(GitBranch::branch_from_head("garbage"), None);
}

#[test]
fn home_becomes_tilde() {
    let home = "C:\\Users\\me";
    assert_eq!(PathDisplay::short("C:\\Users\\me", home, 48), "~");
    assert_eq!(
        PathDisplay::short("C:\\Users\\me\\code\\x", home, 48),
        "~\\code\\x"
    );
    assert_eq!(
        PathDisplay::short("C:\\Users\\meow", home, 48),
        "C:\\Users\\meow"
    );
    assert_eq!(
        PathDisplay::short("c:\\users\\ME\\code", home, 48),
        "~\\code",
        "Windows paths match without case"
    );
    assert_eq!(PathDisplay::short("C:\\Users\\me\\", home, 48), "~");
    assert_eq!(
        PathDisplay::short("/home/me/src", "/home/me", 48),
        "~/src",
        "WSL folders too"
    );
}

#[test]
fn long_paths_keep_their_end() {
    let short = PathDisplay::short(
        "C:\\Users\\me\\a\\very\\long\\path\\to\\some\\project\\src",
        "C:\\Users\\me",
        20,
    );
    assert_eq!(short.chars().count(), 20);
    assert!(short.starts_with('\u{2026}'));
    assert!(short.ends_with("project\\src"));
    assert_eq!(PathDisplay::DEFAULT_MAX_LENGTH, 48);
}

#[test]
fn only_long_commands_in_unfocused_panes_badge() {
    let ten_seconds: u64 = 10_000_000_000;
    assert_eq!(
        PaneActivity::for_finished_command(Some(0), ten_seconds, true),
        None
    );
    assert_eq!(
        PaneActivity::for_finished_command(Some(0), 1_000_000_000, false),
        None
    );
    assert!(PaneActivity::for_finished_command(Some(0), ten_seconds, false).is_some());
}

#[test]
fn labels_and_failure() {
    assert_eq!(PaneActivity::Bell.label(), "bell");
    assert_eq!(
        PaneActivity::Finished {
            exit_code: Some(0),
            seconds: 12.4
        }
        .label(),
        "12s"
    );
    assert_eq!(
        PaneActivity::Finished {
            exit_code: None,
            seconds: 65.0
        }
        .label(),
        "1m 05s"
    );
    assert_eq!(
        PaneActivity::Finished {
            exit_code: Some(2),
            seconds: 30.0
        }
        .label(),
        "exit 2"
    );
    assert!(PaneActivity::Finished {
        exit_code: Some(2),
        seconds: 30.0
    }
    .failed());
    assert!(!PaneActivity::Finished {
        exit_code: Some(0),
        seconds: 30.0
    }
    .failed());
    assert!(!PaneActivity::Bell.failed());
}

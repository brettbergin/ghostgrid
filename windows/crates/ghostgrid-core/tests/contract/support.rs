//! Shared helpers for the contract tests.

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

/// A fresh, empty temporary directory for one test.
pub fn temp_dir(label: &str) -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!(
        "ghostgrid-tests-{label}-{}-{}-{nanos}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::SeqCst)
    ));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

/// A temporary directory holding `files` (relative path, contents).
pub fn directory(files: &[(&str, &str)]) -> PathBuf {
    let dir = temp_dir("config");
    for (name, contents) in files {
        let path = dir.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, contents).unwrap();
    }
    dir
}

/// Git Bash, when it is installed where its installer puts it.
pub fn git_bash() -> Option<PathBuf> {
    let program_files =
        std::env::var("ProgramFiles").unwrap_or_else(|_| "C:\\Program Files".into());
    let path = PathBuf::from(program_files)
        .join("Git")
        .join("bin")
        .join("bash.exe");
    path.is_file().then_some(path)
}

/// Every PowerShell installed here: Windows PowerShell 5.1 and pwsh 7.
pub fn powershells() -> Vec<PathBuf> {
    let mut found = Vec::new();
    let system_root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into());
    let classic =
        PathBuf::from(system_root).join("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    if classic.is_file() {
        found.push(classic);
    }
    let mut seven = Vec::new();
    if let Ok(program_files) = std::env::var("ProgramFiles") {
        seven.push(PathBuf::from(program_files).join("PowerShell\\7\\pwsh.exe"));
    }
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        seven.push(PathBuf::from(local).join("Microsoft\\WindowsApps\\pwsh.exe"));
    }
    if let Some(pwsh) = seven.into_iter().find(|p| p.symlink_metadata().is_ok()) {
        found.push(pwsh);
    }
    found
}

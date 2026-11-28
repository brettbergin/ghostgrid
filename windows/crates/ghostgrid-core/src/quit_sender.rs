//! Who asked ghostgrid-sessiond to stop (a Quit request or a console
//! event), as its log names them: the process, its executable, and what
//! started it, so shells that ended can be traced to their cause. Only the
//! process ID comes with the request; the rest is looked up when it
//! arrives, and the sender may already be gone.

use std::fmt;

/// Windows process IDs are DWORDs, so they are `u32` here (macOS: Int32).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct QuitSender {
    pub pid: Option<u32>,
    pub path: Option<String>,
    pub parent_pid: Option<u32>,
    pub parent_path: Option<String>,
}

impl fmt::Display for QuitSender {
    /// "from pid 812 C:\...\taskkill.exe (started by pid 640 C:\...\cmd.exe)".
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Some(pid) = self.pid.filter(|&pid| pid > 0) else {
            return f.write_str("from an unknown sender");
        };
        let Some(path) = &self.path else {
            return write!(f, "from pid {pid} (no longer running)");
        };
        write!(f, "from pid {pid} {path}")?;
        if let Some(parent) = self.parent_pid.filter(|&pid| pid > 0) {
            let parent_path = self.parent_path.as_deref().unwrap_or("(no longer running)");
            write!(f, " (started by pid {parent} {parent_path})")?;
        }
        Ok(())
    }
}

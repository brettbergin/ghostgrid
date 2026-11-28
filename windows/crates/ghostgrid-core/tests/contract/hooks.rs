//! Contract for ghostgrid's shell hooks on Windows (ShellHookTests): each
//! shell reports its prompt (OSC 133 A/B/D), its folder (OSC 7, and OSC
//! 9;9 for PowerShell) and each command line before it runs (OSC 633;E,
//! then OSC 133;C). Where a shell is installed here, the hook runs in it.

use crate::support::{git_bash, powershells, temp_dir};
use ghostgrid_core::blocks::{CommandBlockParser, CommandLineReport, StreamEvent};
use ghostgrid_core::shells::hooks;
use std::path::{Path, PathBuf};
use std::process::Command;

const COMMANDS: [&str; 6] = [
    "ls -la",
    "a;b\\c",
    "two\nlines",
    "tab\there",
    "h\u{e9}llo \u{1F30D}",
    "echo '$HOME' \"x\"",
];

fn contents(path: &str) -> String {
    hooks::files()
        .into_iter()
        .find(|(p, _)| *p == path)
        .map(|(_, text)| text)
        .expect(path)
}

fn installed() -> PathBuf {
    let dir = temp_dir("hooks");
    hooks::install(&dir).unwrap();
    dir
}

fn msys(path: &Path) -> String {
    path.display().to_string().replace('\\', "/")
}

/// Runs `script` in Git Bash, non-interactively, without the user's files.
fn bash(bash: &Path, script: &str, args: &[&str]) -> String {
    bash_with(bash, script, args, &[])
}

/// [`bash`] with extra environment variables. A Windows command line
/// cannot carry a newline into an MSYS program's argv, so text that may
/// hold one goes through the environment.
fn bash_with(bash: &Path, script: &str, args: &[&str], env: &[(&str, &str)]) -> String {
    let output = Command::new(bash)
        .args(["--norc", "--noprofile", "-c", script, "sh"])
        .args(args)
        .envs(env.iter().copied())
        .env("MSYS_NO_PATHCONV", "1")
        .env("MSYS2_ARG_CONV_EXCL", "*")
        .env("LANG", "C.UTF-8")
        .env("HOSTNAME", "box")
        .output()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).into_owned()
}

#[test]
fn the_hook_files_are_installed() {
    assert_eq!(
        hooks::files()
            .iter()
            .map(|(path, _)| *path)
            .collect::<Vec<_>>(),
        ["pwsh/ghostgrid.ps1", "bash/ghostgrid.bash", "zsh/.zshenv"]
    );
    let dir = installed();
    for (path, text) in hooks::files() {
        assert_eq!(
            std::fs::read_to_string(dir.join(path)).unwrap(),
            text,
            "{path}"
        );
    }
    std::fs::write(dir.join("bash/ghostgrid.bash"), "old").unwrap();
    hooks::install(&dir).unwrap();
    assert_eq!(
        std::fs::read_to_string(dir.join("bash/ghostgrid.bash")).unwrap(),
        contents("bash/ghostgrid.bash"),
        "older versions are replaced"
    );
}

#[test]
fn bash_and_zsh_share_the_macos_report_function() {
    assert!(hooks::REPORT_FUNCTION
        .starts_with("_ghostgrid_report_command() {\n    local c=\"$1\" b='\\' r\n"));
    assert!(hooks::REPORT_FUNCTION.contains("builtin printf '\\033]633;E;%s\\007' \"$c\""));
    for path in ["bash/ghostgrid.bash", "zsh/.zshenv"] {
        assert!(contents(path).contains(hooks::REPORT_FUNCTION), "{path}");
    }
}

#[test]
fn the_powershell_hook_runs_on_windows_powershell_too() {
    let ps1 = contents("pwsh/ghostgrid.ps1");
    assert!(
        !ps1.contains("`e"),
        "Windows PowerShell 5.1 has no `e escape"
    );
    assert!(ps1.contains("[char]27"));
    for part in [
        "133;D;",
        "133;A",
        "133;B",
        "633;E;",
        "133;C",
        "9;9;",
        "7;file://",
        "PSConsoleHostReadLine",
        "LASTEXITCODE",
        "FileSystem",
    ] {
        assert!(ps1.contains(part), "{part}");
    }
    assert!(ps1.is_ascii());
}

#[test]
fn the_bash_hook_loads_the_users_startup_files_then_marks_the_prompt() {
    let text = contents("bash/ghostgrid.bash");
    for part in [
        "/etc/profile",
        "~/.bash_profile",
        "~/.bash_login",
        "~/.profile",
        "~/.bashrc",
        "PROMPT_COMMAND",
        "DEBUG",
        "133;B",
        "\\[",
        "\\]",
    ] {
        assert!(text.contains(part), "{part}");
    }
}

#[test]
fn the_zsh_hook_restores_zdotdir_and_adds_hooks() {
    let text = contents("zsh/.zshenv");
    for part in [
        "GHOSTGRID_ZDOTDIR",
        ".zshenv",
        "add-zsh-hook precmd",
        "add-zsh-hook preexec",
        "%{",
        "133;D;",
        "133;A",
        "133;C",
        "]7;file://",
    ] {
        assert!(text.contains(part), "{part}");
    }
}

#[test]
fn the_hook_reports_command_lines_exactly_in_git_bash() {
    let Some(shell) = git_bash() else { return };
    let dir = installed();
    let script = msys(&dir.join("bash/ghostgrid.bash"));
    for command in COMMANDS {
        let output = bash_with(
            &shell,
            "source \"$1\"; _ghostgrid_report_command \"$GHOSTGRID_TEST_COMMAND\"",
            &[&script],
            &[("GHOSTGRID_TEST_COMMAND", command)],
        );
        assert_eq!(
            output,
            format!("\x1b]633;E;{}\x07", CommandLineReport::escape(command)),
            "{command:?}"
        );
    }
}

#[test]
fn the_bash_hook_parses() {
    let Some(shell) = git_bash() else { return };
    let dir = installed();
    let status = Command::new(&shell)
        .args(["-n", &msys(&dir.join("bash/ghostgrid.bash"))])
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn the_bash_prompt_reports_the_status_and_the_folder() {
    let Some(shell) = git_bash() else { return };
    let dir = installed();
    let script = msys(&dir.join("bash/ghostgrid.bash"));
    let here = temp_dir("bash-cwd");
    let output = bash(
        &shell,
        "source \"$1\"; cd \"$2\"; _ghostgrid_prompt; (exit 3); _ghostgrid_prompt; printf 'rc=%s' \"$?\"",
        &[&script, &msys(&here)],
    );
    let (first, rest) = output.split_once("\x1b]133;A\x07").expect("a prompt mark");
    assert!(
        !first.contains("133;D"),
        "no status before the first prompt: {first:?}"
    );
    assert!(
        rest.starts_with("\x1b]133;D;3\x07\x1b]7;file://"),
        "{rest:?}"
    );
    assert!(
        rest.ends_with("\x1b]133;A\x07rc=3"),
        "the status is kept for what runs next: {rest:?}"
    );
    let events = CommandBlockParser::new().feed(output.as_bytes(), false);
    let Some(StreamEvent::WorkingDirectory(folder)) = events.first() else {
        panic!("{events:?}")
    };
    assert!(
        folder.eq_ignore_ascii_case(&here.display().to_string()),
        "{folder} vs {}",
        here.display()
    );
}

#[test]
fn the_bash_debug_trap_reports_each_command_line_once() {
    let Some(shell) = git_bash() else { return };
    let dir = installed();
    let script = msys(&dir.join("bash/ghostgrid.bash"));
    let output = bash(
        &shell,
        "source \"$1\"; trap 'printf T' DEBUG; PROMPT_COMMAND='printf P'; _ghostgrid_install\n\
         _ghostgrid_ps1\necho hi\necho there\n_ghostgrid_ps1\n_ghostgrid_prompt >/dev/null\nprintf '[%s]' \"$PROMPT_COMMAND\"",
        &[&script],
    );
    assert_eq!(output.matches("633;E;").count(), 1, "{output:?}");
    assert!(
        output.contains("\x1b]633;E;echo hi\x07\x1b]133;C\x07"),
        "{output:?}"
    );
    assert!(
        output.contains('T'),
        "an existing DEBUG trap still runs: {output:?}"
    );
    let prompt_command = output.rsplit_once('[').unwrap().1;
    assert!(
        prompt_command.starts_with("_ghostgrid_prompt"),
        "{prompt_command}"
    );
    assert!(
        prompt_command.contains("printf P"),
        "an existing PROMPT_COMMAND still runs: {prompt_command}"
    );
}

/// Dot-sources the hook in each installed PowerShell and runs `body`.
fn powershell(shell: &Path, hook: &Path, body: &str, args: &[&str]) -> String {
    let dir = temp_dir("pwsh-driver");
    let driver = dir.join("driver.ps1");
    let text = format!(
        "param([string]$hook, [string]$arg)\r\n\
         [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false\r\n\
         . $hook\r\n{body}\r\n"
    );
    std::fs::write(&driver, text).unwrap();
    let output = Command::new(shell)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(&driver)
        .arg(hook)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success() || !output.stdout.is_empty(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).into_owned()
}

#[test]
fn the_powershell_hook_escapes_command_lines_exactly() {
    let dir = installed();
    let hook = dir.join("pwsh/ghostgrid.ps1");
    for shell in powershells() {
        for command in COMMANDS {
            let output = powershell(
                &shell,
                &hook,
                "[Console]::Write((__ghostgrid_escape $arg))",
                &[command],
            );
            assert_eq!(
                output,
                CommandLineReport::escape(command),
                "{}: {command:?}",
                shell.display()
            );
        }
    }
}

#[test]
fn the_powershell_prompt_reports_the_status_and_the_folder() {
    let dir = installed();
    let hook = dir.join("pwsh/ghostgrid.ps1");
    let here = temp_dir("pwsh-cwd");
    for shell in powershells() {
        let output = powershell(
            &shell,
            &hook,
            "Set-Location -LiteralPath $arg\r\nfunction global:__ghostgrid_test_prompt { 'PS> ' }\r\n\
             $global:__ghostgrid_original_prompt = $function:__ghostgrid_test_prompt\r\n\
             [Console]::Write((prompt))\r\ncmd /c exit 3\r\n[Console]::Write((prompt))\r\n\
             [Console]::Write('rc=' + $LASTEXITCODE)",
            &[&here.display().to_string()],
        );
        let (first, rest) = output
            .split_once("PS> \x1b]133;B\x07")
            .expect("the original prompt, then B");
        assert!(
            !first.contains("133;D"),
            "{}: no status before the first prompt: {first:?}",
            shell.display()
        );
        assert!(first.contains("\x1b]133;A\x07"), "{first:?}");
        assert!(
            rest.starts_with("\x1b]133;D;3\x07\x1b]133;A\x07"),
            "{}: {rest:?}",
            shell.display()
        );
        assert!(
            rest.ends_with("PS> \x1b]133;B\x07rc=3"),
            "{}: $LASTEXITCODE is kept: {rest:?}",
            shell.display()
        );
        let events = CommandBlockParser::new().feed(output.as_bytes(), false);
        let folders: Vec<_> = events
            .iter()
            .filter_map(|e| match e {
                StreamEvent::WorkingDirectory(f) => Some(f.clone()),
                _ => None,
            })
            .collect();
        assert!(!folders.is_empty(), "{output:?}");
        for folder in folders {
            assert!(
                folder.eq_ignore_ascii_case(&here.display().to_string()),
                "{folder} vs {}",
                here.display()
            );
        }
    }
}

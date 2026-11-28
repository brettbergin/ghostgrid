//! ghostgrid's shell hooks on Windows: small startup files that make each
//! shell report what xterm.js cannot see on its own. Each marks its
//! prompt (OSC 133;A, then 133;B where typing starts, and 133;D;<status>
//! when a command ends), reports its folder (OSC 7; PowerShell also OSC
//! 9;9) and reports each command line before it runs (OSC 633;E, see
//! [`crate::blocks::CommandLineReport`]), then 133;C. On macOS Ghostty's
//! own integration provides the marks and these files only add the report;
//! on Windows there is no Ghostty, so they provide everything.
//!
//! PowerShell dot-sources `pwsh/ghostgrid.ps1` after its profile; Git Bash
//! and WSL's bash start with `--rcfile bash/ghostgrid.bash`; WSL's zsh with
//! ZDOTDIR at `zsh/` (see [`super::launch`]).

use std::io;
use std::path::Path;

/// Escapes `$1` like `CommandLineReport::escape` and prints the report.
/// The macOS hook's function, byte for byte: written for zsh, bash 3.2
/// and bash 5.2 alike (the quoted replacement stays literal in all three).
pub const REPORT_FUNCTION: &str = r#"_ghostgrid_report_command() {
    local c="$1" b='\' r
    r="$b$b"; c=${c//"$b"/"$r"}
    r="${b}x3b"; c=${c//;/"$r"}
    r="${b}x0a"; c=${c//$'\n'/"$r"}
    r="${b}x0d"; c=${c//$'\r'/"$r"}
    r="${b}x09"; c=${c//$'\t'/"$r"}
    r="${b}x1b"; c=${c//$'\e'/"$r"}
    r="${b}x07"; c=${c//$'\a'/"$r"}
    builtin printf '\033]633;E;%s\007' "$c"
}"#;

/// For PowerShell 7 and Windows PowerShell 5.1 alike: no `e escapes (5.1
/// has none), [char]27 instead. Wraps the prompt function the profile left
/// and, when PSReadLine is loaded, PSConsoleHostReadLine (the line just
/// read is the command about to run).
const PWSH: &str = r#"# ghostgrid: prompt marks for PowerShell 7 and Windows PowerShell 5.1
# (commands as blocks, the pane's folder). Dot-sourced after the profile.
# Generated; edits are overwritten.

if ($global:__ghostgrid_loaded) { return }
$global:__ghostgrid_loaded = $true
$global:__ghostgrid_esc = [string][char]27
$global:__ghostgrid_bel = [string][char]7
$global:__ghostgrid_first = $true
$global:__ghostgrid_original_prompt = $function:prompt
$global:__ghostgrid_original_readline = $null

# A command line as ghostgrid reads it: \ as \\, ; and control
# characters as \xNN.
function global:__ghostgrid_escape([string]$text) {
    $out = New-Object System.Text.StringBuilder
    foreach ($ch in $text.ToCharArray()) {
        $code = [int]$ch
        if ($ch -ceq [char]'\') { [void]$out.Append('\\') }
        elseif ($ch -ceq [char]';') { [void]$out.Append('\x3b') }
        elseif ($code -lt 32 -or $code -eq 127) { [void]$out.Append('\x' + $code.ToString('x2')) }
        else { [void]$out.Append($ch) }
    }
    $out.ToString()
}

function global:__ghostgrid_mark([string]$body) {
    $global:__ghostgrid_esc + ']' + $body + $global:__ghostgrid_bel
}

# Reports each command line as it is read, before it runs. PSReadLine may
# load after this file, so the prompt tries again until it is there.
function global:__ghostgrid_wrap_readline {
    if ($null -ne $global:__ghostgrid_original_readline) { return }
    if (-not (Test-Path Function:\PSConsoleHostReadLine)) { return }
    $global:__ghostgrid_original_readline = $function:PSConsoleHostReadLine
    function global:PSConsoleHostReadLine {
        $line = & $global:__ghostgrid_original_readline
        if ($null -ne $line -and $line.Trim().Length -gt 0) {
            [Console]::Write((__ghostgrid_mark ('633;E;' + (__ghostgrid_escape $line))) + (__ghostgrid_mark '133;C'))
        }
        $line
    }
}

function global:prompt {
    # First, before anything else changes them.
    $ok = $?
    $code = $global:LASTEXITCODE
    $marks = ''
    if (-not $global:__ghostgrid_first) {
        $status = 0
        if (-not $ok) {
            $status = 1
            if ($code -is [int] -and $code -ne 0) { $status = $code }
        }
        $marks += __ghostgrid_mark ('133;D;' + $status)
    }
    $global:__ghostgrid_first = $false
    $marks += __ghostgrid_mark '133;A'
    $location = $executionContext.SessionState.Path.CurrentLocation
    if ($location.Provider.Name -eq 'FileSystem') {
        $folder = $location.ProviderPath
        try {
            # file:///C:/x (or file://server/share/x): the path, escaped.
            $uri = [System.Uri]$folder
            $rest = $uri.AbsoluteUri.Substring(7)
            if (-not $uri.IsUnc) { $rest = $env:COMPUTERNAME + $rest }
            $marks += __ghostgrid_mark ('7;file://' + $rest)
        } catch { }
        # Last, so the exact folder wins over the URL's reading of it.
        $marks += __ghostgrid_mark ('9;9;"' + $folder + '"')
    }
    # Written now, so they come before anything the original prompt
    # writes to the host itself.
    [Console]::Write($marks)
    __ghostgrid_wrap_readline
    $text = $null
    if ($null -ne $global:__ghostgrid_original_prompt) { $text = & $global:__ghostgrid_original_prompt }
    if ($null -eq $text) { $text = 'PS ' + $location.Path + '> ' }
    $global:LASTEXITCODE = $code
    [string]::Join('', [string[]]$text) + (__ghostgrid_mark '133;B')
}

__ghostgrid_wrap_readline
"#;

/// For Git Bash and WSL's bash, started with `--rcfile` (so bash reads
/// this instead of its usual files, which this then loads itself).
fn bash() -> String {
    format!(
        r#"# ghostgrid: bash startup for Git Bash and WSL panes (started with
# --rcfile), then prompt marks and a hook reporting each command line
# (commands as blocks). Generated; edits are overwritten.

if [[ $- == *i* ]]; then
    # --rcfile replaces the startup files: load them as a login shell does.
    if [[ -r /etc/profile ]]; then builtin source /etc/profile; fi
    _ghostgrid_rc=
    for _ghostgrid_file in ~/.bash_profile ~/.bash_login ~/.profile; do
        if [[ -r "$_ghostgrid_file" ]]; then
            _ghostgrid_rc=$_ghostgrid_file
            break
        fi
    done
    if [[ -n "$_ghostgrid_rc" ]]; then
        builtin source "$_ghostgrid_rc"
    elif [[ -r ~/.bashrc ]]; then
        builtin source ~/.bashrc
    fi
    builtin unset _ghostgrid_rc _ghostgrid_file
fi

{REPORT_FUNCTION}

_ghostgrid_first=1
_ghostgrid_armed=
_ghostgrid_last_history=

# The folder as a file URL. Git Bash's /c/Users/x is C:/Users/x to
# Windows (pwd -W for its other folders); WSL's folders stay as they are.
_ghostgrid_folder() {{
    local dir=$PWD
    if [[ "${{OSTYPE:-}}" == msys* || "${{OSTYPE:-}}" == cygwin* ]]; then
        if [[ $dir =~ ^/([a-zA-Z])(/.*)?$ ]]; then
            dir="/${{BASH_REMATCH[1]^^}}:${{BASH_REMATCH[2]:-/}}"
        else
            dir="/$(builtin pwd -W 2>/dev/null)"
        fi
    fi
    builtin printf '\033]7;file://%s%s\007' "${{HOSTNAME:-}}" "$dir"
}}

# First in PROMPT_COMMAND: the status of the command that just ended,
# then a new prompt. Keeps $? for what runs after it.
_ghostgrid_prompt() {{
    local code=$?
    if [[ -z "$_ghostgrid_first" ]]; then
        builtin printf '\033]133;D;%s\007' "$code"
    fi
    _ghostgrid_first=
    _ghostgrid_folder
    builtin printf '\033]133;A\007'
    return $code
}}

# Last in PROMPT_COMMAND: marks where typing starts in PS1 (a theme may
# have just rebuilt it) and arms the DEBUG trap for the next command line.
_ghostgrid_ps1() {{
    local code=$?
    if [[ "$PS1" != *'133;B'* ]]; then
        PS1="$PS1"'\[\033]133;B\007\]'
    fi
    _ghostgrid_armed=1
    return $code
}}

# Before the first command of each command line: report the line, then
# mark the start of its output.
_ghostgrid_debug() {{
    [[ -n "$_ghostgrid_armed" ]] || return 0
    _ghostgrid_armed=
    # Enter on an empty line runs nothing but PROMPT_COMMAND.
    [[ "$BASH_COMMAND" == _ghostgrid_prompt* ]] && return 0
    local line= entry number
    if [[ -o history ]]; then
        entry=$(LC_ALL=C HISTTIMEFORMAT= builtin history 1)
        entry="${{entry#"${{entry%%[![:space:]]*}}"}}"
        number="${{entry%%[![:digit:]]*}}"
        if [[ -n "$number" && "$number" != "$_ghostgrid_last_history" ]]; then
            _ghostgrid_last_history=$number
            line="${{entry#"$number"}}"
            line="${{line#\*}}"
            line="${{line#"${{line%%[![:space:]]*}}"}}"
        fi
    fi
    # Not in history (ignorespace, history off): the command bash runs.
    [[ -n "$line" ]] || line=$BASH_COMMAND
    _ghostgrid_report_command "$line"
    builtin printf '\033]133;C\007'
}}

# Adds the hooks around what the user's files set up: their
# PROMPT_COMMAND runs between ghostgrid's two, their DEBUG trap before
# ghostgrid's.
_ghostgrid_install() {{
    if [[ "$(builtin declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        PROMPT_COMMAND=(_ghostgrid_prompt "${{PROMPT_COMMAND[@]}}" _ghostgrid_ps1)
    else
        PROMPT_COMMAND="_ghostgrid_prompt"$'\n'"${{PROMPT_COMMAND:-}}"$'\n'"_ghostgrid_ps1"
    fi
    local prior
    prior=$(builtin trap -p DEBUG)
    if [[ -z "$prior" ]]; then
        builtin trap '_ghostgrid_debug' DEBUG
    else
        prior=${{prior#trap -- }}
        prior=${{prior% DEBUG}}
        builtin eval "builtin trap -- $prior'; _ghostgrid_debug' DEBUG"
    fi
}}

if [[ $- == *i* ]]; then
    _ghostgrid_install
fi
"#
    )
}

/// For zsh inside WSL, started with ZDOTDIR here: restores the user's
/// ZDOTDIR (kept in GHOSTGRID_ZDOTDIR) so zsh reads their files next, runs
/// their .zshenv, and adds the marks with add-zsh-hook.
fn zshenv() -> String {
    format!(
        r#"# ghostgrid: zsh startup for WSL panes (ZDOTDIR points here), then
# prompt marks and a hook reporting each command line (commands as
# blocks). Generated; edits are overwritten.
if [[ -n "${{GHOSTGRID_ZDOTDIR+set}}" ]]; then
    ZDOTDIR="$GHOSTGRID_ZDOTDIR"
    builtin unset GHOSTGRID_ZDOTDIR
else
    builtin unset ZDOTDIR
fi
if [[ -r "${{ZDOTDIR:-$HOME}}/.zshenv" ]]; then
    builtin source -- "${{ZDOTDIR:-$HOME}}/.zshenv"
fi

{REPORT_FUNCTION}

if [[ -o interactive ]]; then
    typeset -g _ghostgrid_first=1

    _ghostgrid_precmd() {{
        local code=$?
        if [[ -z "$_ghostgrid_first" ]]; then
            builtin printf '\033]133;D;%s\007' "$code"
        fi
        _ghostgrid_first=
        builtin printf '\033]7;file://%s%s\007' "${{HOST:-}}" "$PWD"
        builtin printf '\033]133;A\007'
        if [[ "$PS1" != *'133;B'* ]]; then
            PS1="$PS1"$'%{{\e]133;B\a%}}'
        fi
    }}

    _ghostgrid_preexec() {{
        _ghostgrid_report_command "$1"
        builtin printf '\033]133;C\007'
    }}

    # Prompt themes in .zshrc add precmd hooks after this file's, and may
    # rebuild PS1 there; on the first prompt ghostgrid's moves to the end.
    _ghostgrid_deferred() {{
        add-zsh-hook -d precmd _ghostgrid_deferred
        add-zsh-hook precmd _ghostgrid_precmd
        _ghostgrid_precmd
    }}

    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _ghostgrid_deferred
    add-zsh-hook preexec _ghostgrid_preexec
fi
"#
    )
}

/// Every hook file: its path under the hooks folder, and its contents.
pub fn files() -> Vec<(&'static str, String)> {
    vec![
        ("pwsh/ghostgrid.ps1", PWSH.to_string()),
        ("bash/ghostgrid.bash", bash()),
        ("zsh/.zshenv", zshenv()),
    ]
}

/// Writes the hook files into `dir`, replacing older versions. Shell
/// scripts keep LF line endings (bash rejects CR); the PowerShell file is
/// fine either way.
pub fn install(dir: &Path) -> io::Result<()> {
    for (path, text) in files() {
        let target = dir.join(path);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // Written beside, then moved over, so a shell starting meanwhile
        // never reads half a file.
        let partial = target.with_extension("partial");
        std::fs::write(&partial, text)?;
        std::fs::rename(&partial, &target)?;
    }
    Ok(())
}

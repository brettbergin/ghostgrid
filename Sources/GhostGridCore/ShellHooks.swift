import Foundation

/// ghostgrid's shell hooks: small startup files that run Ghostty's shell
/// integration as before, then report each command line before it runs
/// (``CommandLineReport``), which the prompt marks do not carry. zsh
/// starts with ZDOTDIR at `<dir>/zsh`, bash with ENV at
/// `<dir>/bash/ghostgrid.bash`; see ``ShellLaunch``.
public enum ShellHooks {
    /// Escapes `$1` like ``CommandLineReport/escape(_:)`` and prints the
    /// report. Written for zsh, bash 3.2 and bash 5.2 alike: the quoted
    /// replacement stays literal in all three (an unquoted one loses its
    /// backslashes to bash 5.2's patsub_replacement; one inside an outer
    /// pair of double quotes keeps its quotes in bash 3.2).
    static let reportFunction = #"""
    _ghostgrid_report_command() {
        local c="$1" b='\' r
        r="$b$b"; c=${c//"$b"/"$r"}
        r="${b}x3b"; c=${c//;/"$r"}
        r="${b}x0a"; c=${c//$'\n'/"$r"}
        r="${b}x0d"; c=${c//$'\r'/"$r"}
        r="${b}x09"; c=${c//$'\t'/"$r"}
        r="${b}x1b"; c=${c//$'\e'/"$r"}
        r="${b}x07"; c=${c//$'\a'/"$r"}
        builtin printf '\033]633;E;%s\007' "$c"
    }
    """#

    /// Setuid programs ignore TERMINFO (ncurses reads only the system
    /// database for them), so macOS's /usr/bin/top fails with "Error
    /// opening terminal: xterm-ghostty". Run it as xterm-256color unless
    /// the system database has xterm-ghostty. An alias or function of the
    /// user's own, set later in their startup files, still wins.
    static let setuidTerminal = #"""
    if [[ "${TERM:-}" == xterm-ghostty && ! -e /usr/share/terminfo/78/xterm-ghostty \
          && ! -e /usr/share/terminfo/x/xterm-ghostty && ! -e /lib/terminfo/x/xterm-ghostty ]]; then
        top() { TERM=xterm-256color command top "$@"; }
    fi
    """#

    static let zshenv = """
    # ghostgrid: Ghostty's zsh integration, then a hook reporting each
    # command line (commands as blocks). Generated; edits are overwritten.
    if [[ -n "${GHOSTGRID_GHOSTTY_ZDOTDIR:-}" && -r "$GHOSTGRID_GHOSTTY_ZDOTDIR/.zshenv" ]]; then
        builtin source -- "$GHOSTGRID_GHOSTTY_ZDOTDIR/.zshenv"
    elif [[ -n "${GHOSTTY_ZSH_ZDOTDIR+set}" ]]; then
        ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
        unset GHOSTTY_ZSH_ZDOTDIR
    else
        unset ZDOTDIR
    fi
    unset GHOSTGRID_GHOSTTY_ZDOTDIR

    \(reportFunction)

    \(setuidTerminal)

    if [[ -o interactive ]]; then
        autoload -Uz add-zsh-hook && add-zsh-hook preexec _ghostgrid_report_command
    fi

    """

    static let bash = """
    # ghostgrid: Ghostty's bash integration, then a hook reporting each
    # command line (commands as blocks). Generated; edits are overwritten.
    if [[ -n "${GHOSTGRID_GHOSTTY_ENV:-}" && -r "$GHOSTGRID_GHOSTTY_ENV" ]]; then
        builtin source "$GHOSTGRID_GHOSTTY_ENV"
    fi
    builtin unset GHOSTGRID_GHOSTTY_ENV

    \(reportFunction)

    \(setuidTerminal)

    if [[ $- == *i* ]]; then
        preexec_functions+=(_ghostgrid_report_command)
    fi

    """

    /// Writes the hook files into `directory` (zsh/.zshenv and
    /// bash/ghostgrid.bash), replacing older versions.
    public static func install(in directory: String) throws {
        let fm = FileManager.default
        for (path, text) in [("zsh/.zshenv", zshenv), ("bash/ghostgrid.bash", bash)] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }
}

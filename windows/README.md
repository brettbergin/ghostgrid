# ghostgrid for Windows

A Windows terminal where each tab is an animated, auto-balanced grid of
panes: the Windows counterpart of the macOS app in the repository root.

Ghostty has no Windows build and libghostty no Windows embedding, so this
one is built on Tauri 2 and xterm.js instead. It reads your own Ghostty
config (theme, fonts, padding, cursor, opacity, scrollback) and maps what
xterm.js can honor; see Ghostty feature coverage for what it cannot.

## Install

Download `ghostgrid_<version>_x64-setup.exe` from the
[releases](https://github.com/brettbergin/ghostgrid/releases) and run it.
It installs for the current user (no administrator prompt) and fetches the
WebView2 runtime if it is missing. Needs Windows 10 (1809 or later, for
ConPTY) or Windows 11, x64.

The installer adds **Open in ghostgrid** to Explorer's menu on folders and
on a folder's background (the counterpart of dropping a folder on the Dock
icon). Settings > Put gg on PATH adds the `gg` command:

```powershell
gg                  # a pane in the current folder (starts ghostgrid if needed)
gg C:\code\api      # a pane in that folder; several folders open several panes
```

It writes `%LOCALAPPDATA%\ghostgrid\bin\gg.cmd` and adds that folder to
your user PATH; terminals opened after that see it. A file argument stands
for its folder, and folders that do not exist are skipped. A running
ghostgrid gets the folders (it is single-instance) and opens the panes in
its focused window. Uninstalling removes the Explorer entries but leaves
`gg.cmd` and the PATH entry.

ghostgrid updates itself when the build carries an update key (see
Releases): it checks once a day, and Menu > Check for Updates... checks
now. An update downloads, installs and relaunches; your shells keep
running through it.

From source:

```powershell
cd windows
.\build.cmd install   # build the installer and install it for this user
```

`install` refuses while ghostgrid is running (quit it with Ctrl+Shift+Q
first) and does not put `gg` on PATH; use Settings for that.

## Build and run

Needs Node.js with npm, Rust 1.86+ with the MSVC toolchain (Visual Studio
Build Tools with C++, Tauri's Windows prerequisite) and WebView2 (part of
Windows 11). Everything runs from `windows\` through `build.cmd`, which
works the same from PowerShell, cmd and Explorer:

```powershell
.\build.cmd run        # dev build with hot reload (tauri dev)
.\build.cmd test       # vitest (TypeScript core) and cargo test (Rust workspace)
.\build.cmd app        # release build: target\release\ghostgrid.exe, no installer
.\build.cmd check      # typecheck, tests, clippy -D warnings, release app (what CI runs)
.\build.cmd installer  # NSIS installer in target\release\bundle\nsis\
.\build.cmd install    # build the installer and run it silently for this user
.\build.cmd release    # signed installer and update feed (see Releases)
.\build.cmd clean      # remove target, dist, node_modules and generated files
```

The tasks live in `build.ps1`. Started directly, a `.ps1` opens in Notepad
from cmd and Explorer, and PowerShell's default execution policy can
refuse to run it; `build.cmd` starts it with `-ExecutionPolicy Bypass`
(PowerShell 7 when installed, else Windows PowerShell). Inside PowerShell,
`.\build.ps1 <task>` works too where scripts are allowed.

Each build first runs `scripts/prepare.mjs`, which builds
`ghostgrid-sessiond` and puts it where Tauri bundles sidecars
(`src-tauri\binaries\`), and draws the icons from `app-icon.svg` when they
are missing or older.

## CI

The `windows` job in `.github/workflows/ci.yml` runs `.\build.ps1 check` on
GitHub's `windows-2025` runner for every pull request and push to main:
the TypeScript typecheck, vitest, `cargo test --workspace` (including the
core crate's contract tests, which also run the shell hooks in Git Bash and
both PowerShells when the runner has them), clippy with warnings as errors,
and the release app. CI has no signing keys; releases are built on a
Windows machine with `.\build.ps1 release`.

## Releases

`.\build.ps1 release` writes `windows\build\release\`: the installer, its
updater signature (`.sig`), a `.sha256`, and `latest-windows.json`, the
update feed, pointing at the installer on the `v<version>` release. The
version is `windows\package.json` (the app); keep `windows\Cargo.toml`
(the helper, and `TERM_PROGRAM_VERSION`) and the Mac's version in step.

One-time setup:

1. An update signing key pair, made by Tauri's signer:

   ```powershell
   npx tauri signer generate -w $HOME\.tauri\ghostgrid.key
   ```

   Back up the private key: an installed ghostgrid only takes updates
   signed with it, so losing it strands every install on its version.
2. For each release build, the environment:
   - `TAURI_SIGNING_PRIVATE_KEY` (and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
     if it has one): signs the update.
   - `GHOSTGRID_UPDATER_PUBKEY`: the public key, built into the app so it
     can check its own updates. `release` refuses without it. Any build
     made without it (`app`, `installer`, `install` included) never checks
     for updates, and its Check for Updates... is disabled.
   - `GHOSTGRID_SIGN_THUMBPRINT` (optional): the thumbprint of an
     Authenticode code-signing certificate in your certificate store. The
     installer is then signed (SHA-256, timestamped by DigiCert); without
     it, SmartScreen warns about an unknown publisher.

Publish onto the same GitHub release as the Mac DMG:

```powershell
gh release upload v<version> build\release\*
```

Installed apps read the feed from the latest release
(`releases/latest/download/latest-windows.json`), so the Windows files must
be on whichever release is marked latest.

## Picking a shell

The first pane ever, and every Ctrl+Alt+Shift+T tab and Ctrl+Alt+Shift+D
pane, opens with a menu: **1** PowerShell 7, **2** Command Prompt, **3** Git
Bash, **4** WSL, **5** nushell, **6** Windows PowerShell. ghostgrid
remembers your pick (in Settings, also across launches), so Ctrl+Shift+T,
Ctrl+Shift+D and new windows start that shell directly; the menu opens with
it highlighted. If the remembered shell is no longer installed, they show
the menu instead. Forget it with **Forget** in Settings. Press the number,
or Up/Down and Return; Escape cancels and closes the pane. A shell that is
not installed is shown dimmed ("not installed") and skipped.

| Shell | Looked for, in order | Started as |
|---|---|---|
| PowerShell 7 | `%ProgramFiles%\PowerShell\7`, the Store copy in `%LOCALAPPDATA%\Microsoft\WindowsApps`, PATH | `pwsh -NoLogo -NoExit`, dot-sourcing the hook |
| Command Prompt | `%SystemRoot%\System32\cmd.exe` | `cmd`, with a marked `PROMPT` |
| Git Bash | `%ProgramFiles%\Git`, `%LOCALAPPDATA%\Programs\Git`, Scoop's `git\current` (not PATH: `System32\bash.exe` is WSL) | `bash --rcfile <hook> -i` |
| WSL | `%SystemRoot%\System32\wsl.exe` | your distribution's `$SHELL` as a login shell, with the hook |
| nushell | `~\.cargo\bin`, `%LOCALAPPDATA%\Programs\nu`, `%ProgramFiles%\nu`, PATH | `nu -l` |
| Windows PowerShell | `System32\WindowsPowerShell\v1.0` | as PowerShell 7 |

Every shell gets `TERM=xterm-256color`, `COLORTERM=truecolor`,
`TERM_PROGRAM=ghostgrid`, `TERM_PROGRAM_VERSION`, `GHOSTGRID=1`,
`GHOSTGRID_SHELL` and `GHOSTGRID_SESSION` (WSL receives them through
`WSLENV`, added to yours). A pane starts in the folder it was opened from.
Windows shells only start in Windows folders: a WSL folder under
`/mnt/<drive>` is translated, one inside the distribution is dropped. WSL
takes Windows and Linux folders (`wsl --cd`) and starts in `~` otherwise.
Git Bash keeps the folder (`CHERE_INVOKING=1`) and gets `MSYSTEM=MINGW64`
unless you set your own.

ghostgrid's own hooks give the shells their prompt marks; Ghostty's shell
integration is not used. They are written to
`%LOCALAPPDATA%\ghostgrid\hooks` on each launch:

- `pwsh\ghostgrid.ps1`, for both PowerShells: wraps your `prompt` and
  PSReadLine to report the prompt, the folder and each command line.
- `bash\ghostgrid.bash`, for Git Bash and bash in WSL: loads your startup
  files as a login shell would (`/etc/profile`, `~/.bash_profile`,
  `~/.bash_login` or `~/.profile`, and `~/.bashrc`), then marks the
  prompt; your `PROMPT_COMMAND` and DEBUG trap keep running.
- `zsh\.zshenv`, for zsh in WSL: restores your `ZDOTDIR`, loads your
  `.zshenv`, and adds precmd/preexec hooks.

Command Prompt gets prompt marks and its folder through `PROMPT` only (your
own `PROMPT` is kept inside them): it cannot report when a command starts
or what it was, so cmd panes have no command blocks, finished-command
badges or explanations. nushell runs with its own marks. Other WSL shells
(fish, ...) start plainly. `shell-integration = none` in the Ghostty config
turns the hooks off for new panes: shells then start plainly (`bash --login
-i`, no `PROMPT`).

### Apps in a new PowerShell pane

Picking **PowerShell 7** from the shell menu opens a second menu of apps to
start in it. The list is yours, in Settings > PowerShell app launcher: each
app is a name, the command typed at the prompt (aliases and functions work)
and a description; add, remove and reorder up to 9 (keys 1-9 in list
order). It starts with **1** opencode, **2** claude, **3** btop, **4**
lazygit and **5** yazi (as `y`, so quitting with q leaves the pane in that
folder); Reset to Defaults brings those back, and an empty list means plain
PowerShell. Press the number to launch; **Escape** starts a plain shell.
The command is typed at PowerShell's first prompt (or after 2.5 s when no
prompt mark arrives), so it lands in history and quitting the app leaves
you at the prompt in the same pane. Programs are looked for in PATH, then
`~\.local\bin`, `~\.bun\bin`, `~\.opencode\bin` and WinGet's `Links`
folder, with each `PATHEXT` extension; one not found is marked "(not
found)" but stays pickable, since the command may be an alias. Turn the
menu off with Settings > Offer apps after choosing PowerShell. Panes that
start the remembered shell directly never show it.

## Tabs

A window holds tabs, and each tab is its own grid of panes with its own
layout, rotation, zoom and broadcast. Ctrl+Shift+T opens a tab right after
the one in front, with your last shell in the folder you were in; Ctrl+1 to
Ctrl+8 show that tab, Ctrl+9 the last one, and Ctrl+Tab / Ctrl+Shift+Tab
(or Ctrl+PageDown / Ctrl+PageUp) the next and previous.

ghostgrid draws its own title bar: the menu button on the left (Shell,
Tab, Pane and View, then Settings, the Ghostty config, updates and Quit),
the tab bar with a + button, and the window buttons on the right.
Double-click the empty part to maximize. The tab bar shows from the first
tab on, so that one can be renamed, colored and dragged like the rest.
Tabs share the bar's width and it scrolls (mouse wheel) when they no
longer fit.

- Click a tab to show it; drag it along the bar to move it. Drag it off
  the bar onto another ghostgrid window's tab bar to move it there, or let
  go anywhere else for a window of its own under the pointer (Tab > Move
  Tab to New Window does the same).
- Drag a pane by its header onto a tab in any window's bar to move it into
  that tab; the tab comes to the front. A tab whose last pane leaves
  closes, and a window whose last tab leaves closes.
- Moving a tab or pane keeps its shells running, with their recent output.
- Double-click a tab (or Tab > Rename Tab..., Ctrl+Alt+Shift+R) to name it:
  Return keeps the name, Escape cancels, and an empty name goes back to
  "Tab N". Unnamed tabs are numbered by position, matching their Ctrl+N
  shortcut.
- Right-click a tab (or Tab > Tab Color) to color it with one of eight
  Catppuccin colors, or None.
- The x on a tab, a middle click, or Ctrl+Alt+W closes it and ends its
  shells. Right-click > Close Other Tabs keeps only that one.
- While a tab is in the background, a bell or a long command finishing or
  failing in it shows the same badge on the tab as on the pane header.
  Showing the tab clears it.

## Keys

ghostgrid's shortcuts sit on Ctrl+Shift and Ctrl+Alt, not Ctrl alone: on
Windows, Ctrl plus a letter is a terminal control key (Ctrl+D is EOF,
Ctrl+W deletes a word). Ctrl alone is used only on keys that send a shell
nothing useful (digits, Tab, PageUp/PageDown, `=`, `-`, `,`). The table is
`src/core/keymap.ts`; the first chord of each row is the one menus show.

| Keys | Action |
|---|---|
| Ctrl+Shift+N | New window |
| Ctrl+Shift+T | New tab with your last shell (inherits the folder) |
| Ctrl+Alt+Shift+T | New tab, choosing the shell from the menu |
| Ctrl+Shift+D | New pane with your last shell (inherits the folder) |
| Ctrl+Alt+Shift+D | New pane, choosing the shell from the menu |
| Ctrl+Shift+W | Close pane |
| Ctrl+Alt+W | Close tab |
| Ctrl+Alt+Shift+W | Close window |
| Ctrl+Alt+I | Broadcast typing to every pane of the tab on/off |
| Ctrl+Tab, Ctrl+PageDown | Next tab |
| Ctrl+Shift+Tab, Ctrl+PageUp | Previous tab |
| Ctrl+1...8 / Ctrl+9 | Show that tab / the last tab |
| Ctrl+Alt+Shift+R | Rename tab |
| Ctrl+Shift+Enter | Zoom pane to fill the tab and back |
| Ctrl+Shift+B | Command blocks of the focused pane |
| Ctrl+Alt+Shift+C | Copy the last command's output |
| Ctrl+Shift+E | Explain the last failure (Return runs the fix) |
| Ctrl+Shift+] / [ | Next / previous pane |
| Ctrl+Alt+1...9 | Focus the pane at that position |
| Ctrl+Alt+arrows | Focus the pane in that direction |
| Ctrl+Alt+Shift+arrows | Swap the focused pane with that neighbour (or move its row) |
| Ctrl+Shift+M | Make the focused pane the main (first) one |
| Ctrl+Alt+= | Equalize panes (undo divider drags) |
| Ctrl+Alt+A | Attention grid on/off |
| Ctrl+Shift+L | Next layout (Grid, Main + Stack, Columns) |
| Ctrl+Alt+R | Rotate Layout: stack panes in a wide window (side by side in a tall one) |
| Ctrl+, | ghostgrid Settings |
| Ctrl+Alt+, | Open the Ghostty config |
| Ctrl+Shift+, | Reload the Ghostty config |
| Ctrl+Shift+Q | Quit (shells keep running) |
| F11, Alt+Enter | Full screen |
| Ctrl+Shift+C, Ctrl+Insert | Copy |
| Ctrl+Shift+V, Shift+Insert | Paste |
| Ctrl+Shift+F | Find |
| Ctrl+Shift+K | Clear the screen |
| Ctrl+=, Ctrl+Shift+=, Ctrl+Num+ | Bigger text (this pane) |
| Ctrl+-, Ctrl+Num- | Smaller text (this pane) |
| Ctrl+0, Ctrl+Num0 | Actual size |

Minimize and Move Tab to New Window have no shortcut (the window buttons
and the tab menu cover them, and every free chord stays with the programs
in the panes).

Shortcuts match the physical key, named by its US-layout label, so they
stay where the table says on every layout. The modifiers must match
exactly (Ctrl+Shift+Win+T is not New Tab). On layouts where AltGr types
characters, AltGr chords are typing, never Ctrl+Alt shortcuts. Every other
key goes to the terminal. Ghostty `keybind` lines are not read.

## Commands as blocks

Every command you run becomes a block: its command line, its output as
plain text, how it ended and how long it took. Pane > Command Blocks
(Ctrl+Shift+B) lists the pane's blocks, newest last, and keeps updating
while open:

- Fold or unfold each block's output (click its line), or all of them.
- Copy a block (command and output), Copy as Markdown (the same in a
  fenced code block, to paste into an issue or chat), or Run Again (types
  it into the pane).
- Pane > Copy Last Command Output (Ctrl+Alt+Shift+C) copies the output of
  the last finished command without opening the list.

Blocks come from the hooks' prompt marks (OSC 133) and command-line
reports (OSC 633;E, as VS Code does); see Picking a shell for which shells
have them. nushell's own marks give blocks without the command line. The
app keeps the last 200 commands per pane, with up to 256 KiB of output each
(the end of longer output). After a relaunch or a move to another window,
a kept shell's blocks are rebuilt from the output the helper replays (see
Shells that survive quitting), without their durations.

## Explain failures (local model)

When a command fails in the pane you are working in, ghostgrid sends its
command line and the end of its output (6 KB at most) to a local model and
shows a panel at the bottom of the pane: why it failed, and one command to
fix it. The answer streams in as the model writes it.

- The panel does not take the keyboard: keep typing and it goes to the
  shell, so a reflexive Return never runs a suggested command.
- Pane > Explain Last Failure (Ctrl+Shift+E) focuses the panel (or explains
  the last failure on demand). Then Return types the fix into this pane
  and runs it (only this pane, even while broadcasting), Escape dismisses,
  and any other key dismisses and goes to the shell.
- The panel goes away when the next command starts.
- Interrupted commands are not explained: Ctrl+C (exit 130, or Windows'
  STATUS_CONTROL_C_EXIT), Ctrl+Z and terminated ones. Neither are
  commands whose command line was not reported.
- Settings > Explain failures: turn the automatic panel off, or set the
  model server and model. The default is LM Studio's local server
  (`http://localhost:1234/v1`) and a model it already has loaded; any
  OpenAI-style server works. Output leaves the machine only if you point
  it at another one.

## Broadcast typing

Shell > Broadcast Input to All Panes (Ctrl+Alt+I) sends what you type in
the focused pane to every other pane of the tab as well. While it is on,
every pane header turns red and says BROADCAST, pane borders and the tab
go red, and the window's title starts with "BROADCAST:". Press Ctrl+Alt+I
again to stop.

- What is forwarded is the bytes the focused pane's terminal encoded, not
  key events. The cursor keys (arrows, Home, End) are re-encoded for each
  pane's cursor-key mode, so an arrow typed at a shell prompt still moves
  vim or less in another pane; everything else, pastes included, arrives
  as the focused pane encoded it.
- Command shortcuts (new pane, close, copy) still act once, on the focused
  pane. Paste (Ctrl+Shift+V) pastes into every pane, each with its own
  bracketed-paste mode.
- Panes still showing their shell menu are skipped.
- It is per tab and never saved: a restored tab types into one pane.

## Pane headers and activity badges

Each pane has a slim header: its shell, its folder (`~`-shortened, trimmed
from the left when long) and the git branch, read from `.git\HEAD` without
running git (worktrees and submodules included). It updates when the shell
reports a new folder and after each command.

Panes you are not looking at get a badge when something happens there:

- **bell** (peach): a program rang the bell.
- **a check mark and 12s** (green): a command that ran 5 s or more
  finished.
- **a cross and exit 2** (red): such a command failed, with its exit code.

Focusing the pane (or coming back to the window) clears it. "Not looking"
means not the focused pane of the tab in front, in the focused window, so
a long build finishing while you are in another app badges too. Both are
optional in Settings; with headers off, badges sit in the pane's corner.
Finished-command badges need command blocks (not cmd).

A bell also flashes the pane's border; when the window is in the
background, a bell, a badge or a notification flashes its taskbar button.
Desktop notifications from programs (OSC 9 and OSC 777) become Windows
toast notifications when their pane is not the one you are looking at.

## Shells that survive quitting

Every pane's shell runs in a small background helper, `ghostgrid-sessiond`,
in a ConPTY of its own, not under the app. Quit ghostgrid (Ctrl+Shift+Q)
and the shells keep going: running programs, builds, an agent mid-task.
Relaunch and each pane reattaches to its shell and gets its recent output
back (up to 4 MiB per pane), so the screen looks as you left it. Programs
that draw full-screen (vim, btop, lazygit) are made to redraw on reattach.

- Closing a pane, a tab or a window ends its shells, with one exception:
  closing the last window quits, so its shells are kept like on Quit.
- Settings > Shells > "Keep shells running after quitting" turns it off,
  as does `window-save-state = never`: quitting then ends every shell.
- If a kept shell is gone on relaunch (it exited, or Windows restarted),
  the pane starts a fresh shell in the same folder.
- The helper runs from a copy of itself,
  `%LOCALAPPDATA%\ghostgrid\bin\ghostgrid-sessiond-<version>.exe`, so the
  installer can replace the bundled one while it runs. ghostgrid starts it
  on demand, detached and outside the app's job, so ending the app does
  not end it.
- It listens on a named pipe named after the protocol version, your user
  SID and your logon session (so an update never talks to a helper that
  speaks another protocol, and users never share one). The pipe admits
  only you and SYSTEM, and refuses remote clients.
- It logs to `%LOCALAPPDATA%\ghostgrid\logs\sessiond.log`, and exits on its
  own about 30 s after its last shell and pane are gone.
- If the helper cannot start, panes run their shell in the app instead
  (it then ends with the app).
- If kept shells end when you did not expect it, the log says who asked:
  each request to end a shell is logged with the sending process, its
  executable and what started it.

## Session restore

Quit and relaunch, and ghostgrid reopens your windows where they were
(moved onto a monitor that is still there), maximized or not, with the
same tabs and panes in the same order, plus which pane had focus and which
was zoomed. With kept shells (above) each pane comes back attached to its
running shell; otherwise each starts its shell again in the folder it was
in, without scrollback. It follows Ghostty's `window-save-state`: `always`
restores, `never` does not (and ends kept shells), and `default` (or
unset) restores when "Keep shells running after quitting" is on. Windows
has no system setting for it to follow, so with keeping shells off,
`default` starts fresh. Closing a window yourself drops it from the
session.

Tabs come back in order with their names, colors, layouts and divider
sizes, and the tab that was in front is in front again. Saved to
`%LOCALAPPDATA%\ghostgrid\session.json` (machine-local: it names shells
running on this machine) shortly after each change and on quit, so a
crash loses little.

## Settings

Menu > Settings... (Ctrl+,) holds ghostgrid's own options, saved in
`%APPDATA%\ghostgrid\settings.json` (it roams with your profile) and
applied immediately in every window. Escape or Done closes it.

- **Shells**: what Ctrl+Shift+T and Ctrl+Shift+D open (your last shell, or
  the shell menu every time); the last shell, with Forget; Keep shells
  running after quitting.
- **PowerShell app launcher**: offer apps after choosing PowerShell, and
  the list itself.
- **Panes**: headers, activity badges, the gap between panes (0-24 px),
  and Animations: Springy (default), Smooth (no overshoot), or Off.
- **Grid**: the layout new tabs start with, and the attention grid.
- **Explain failures**: on/off, model server, model.
- **Ghostty**: the config file in use (or where a new one would go), any
  error reading it, whether windows are restored, the options in it that
  Windows cannot honor, and Open / Reload.
- **Updates and command line**: the daily update check (when the build
  has an update key), Put gg on PATH, and the version.

Everything about how terminals look stays in the Ghostty config.

## Layouts and reordering

Each tab has a layout, in Pane > Layout or cycled with Ctrl+Shift+L:

- **Grid**: balanced rows (below).
- **Main + Stack**: the first pane takes 60% on the left (top in a tall
  window), the rest stack beside it. Ctrl+Shift+M promotes the focused
  pane.
- **Columns**: equal columns (rows in a tall window).

Resize panes by dragging the gap between two of them: only those two
change, and neither gets smaller than 100 px. That works between grid
rows, between panes in a row, between the main pane and the stack, and
between stacked panes. Double-click a gap or use Pane > Equalize Panes
(Ctrl+Alt+=) to rebalance. Adding or removing a pane, or changing the
layout, rebalances too; the session keeps your adjustments otherwise.

A window's shape picks the split: side by side when it is wider than
tall, stacked when it is taller. Pane > Rotate Layout (Ctrl+Alt+R) turns
that for the tab, in every layout; press it again to turn back. It is
saved with the session.

Reorder panes by dragging one by its header onto another (the panes that
would move light up) or with Ctrl+Alt+Shift+arrows. In the grid, moving a
pane into a row with a different number of panes moves its whole row
instead, sizes and all. New tabs use Settings > Grid > New windows use.

## Attention grid

The grid leans toward whatever needs you. A pane that is waiting for you
(a bell, a desktop notification such as an agent asking for input, or a
command that finished while you looked elsewhere) grows the most; a pane
that printed in the last 4 seconds, and the pane you are in, grow a
little; a pane with no output for 90 seconds shrinks. When nothing stands
out the grid stays balanced. Changes are gentle: sizes move by small
factors on a soft 0.6 s ease, and only when some pane's state changes.

- A pane stops "needing you" once you focus it.
- Dragging a divider pauses the attention grid in that tab, so your sizes
  stay; Pane > Equalize Panes (Ctrl+Alt+=) resumes it.
- It rests while a pane is zoomed.
- Pane > Attention Grid (Ctrl+Alt+A), or Settings > Grid, turns it off.
- The sizes it picks are not saved with the session.

## Grid

Panes fill row by row with `ceil(sqrt(n))` columns: 1, 1x2, 2+1, 2x2, 3+2,
3x2, ... The last row stretches to the full width. Tall windows transpose
the grid into columns. The layout math is a port of the Mac's and gives
the same frames.

Adding, zooming and rebalancing use a short spring that overshoots and
settles; a new pane launches as a small card out of the pane you were in
and lands with a flash. Terminal text moves with its pane: each terminal
takes its final size once, and a uniform scale, sampled along the same
curve as the frame, keeps it covering the moving box without reflowing.

## Ghostty feature coverage

ghostgrid on Windows reads the Ghostty config but renders with xterm.js,
so each option is either mapped to xterm.js, provided by ghostgrid, or not
available. Unsupported options do not fail silently: Settings > Ghostty
lists the ones your config uses.

| Ghostty feature | In ghostgrid for Windows |
|---|---|
| `font-family` (with fallbacks), `font-size`, `cursor-style`, `cursor-style-blink`, `background-opacity`, `minimum-contrast`, `bold-is-bright` | mapped to xterm.js |
| `theme` (one, or `light:A,dark:B` following Windows' app mode), `background`, `foreground`, `palette`, cursor and selection colors | mapped; themes from the config folder's `themes`, then the bundled ones |
| `scrollback-limit` | bytes become lines (1,000 to 100,000; default 10,000) |
| `window-padding-x`, `window-padding-y` | both forms: one value for both sides, or `a,b` for left,right (top,bottom) |
| `adjust-cell-height` | a line height (xterm.js cannot go below 1) |
| `config-file` includes | flattened by ghostgrid-core (optional `?` files, cycles broken, CRLF and BOM files read) |
| `custom-shader` | not available: xterm.js has no shader support |
| `background-image`, `background-blur`, `window-decoration`, `macos-*`, `gtk-*`, `quick-terminal-*` | not available; listed in Settings |
| `keybind` | ignored; ghostgrid's own keys (see Keys) |
| `command`, per-pane shell | ghostgrid's shell menu and catalog |
| `shell-integration` | ghostgrid's own hooks; `none` turns them off |
| `shell-integration-features` (`sudo`, `ssh-*`, `cursor`, `title`) | read but not acted on |
| `copy-on-select` | selecting copies to the clipboard (on by default, as in Ghostty) |
| `confirm-close-surface` | read but not acted on: closing never asks |
| Copy, paste, select all, clear, font size | Ctrl+Shift+C/V (Ctrl+Insert, Shift+Insert), the pane's right-click menu, Ctrl+Shift+K, Ctrl+= / Ctrl+- / Ctrl+0 |
| Ctrl+click links | http(s), mailto, file, and paths that exist (relative to the pane's folder) |
| Search (Ctrl+Shift+F, Return / Shift+Return, Escape) | xterm.js search |
| Bell | border flash; taskbar flash in the background |
| Desktop notifications (OSC 9 / 777) | Windows toast notifications |
| `mouse-hide-while-typing` | hides the pointer until it moves |
| `unfocused-split-opacity` | dims unfocused panes (0.15 at least) |
| Reload config | Ctrl+Shift+, re-reads it into every pane (new panes for shell integration) |
| Open config | Ctrl+Alt+, opens it in VS Code (`code` on PATH), Notepad otherwise; creates `%USERPROFILE%\.config\ghostty\config` when there is none |
| Full screen | F11, Alt+Enter |
| Tabs, splits, `new_window` | ghostgrid's own grid, tabs and menu |
| `window-save-state` | session restore (windows, tabs, panes, shells, folders, focus, zoom) |
| Prompt jumps, terminal inspector, quick terminal | not available |

The bundled themes are the four Catppuccin flavors in
`resources\themes`. `scripts\fetch-themes.ps1` adds the whole collection
Ghostty ships (iTerm2-Color-Schemes, MIT) there before a build, so any
`theme = <name>` resolves.

## How it is put together

- `src\`: the front end, one web view per window. `src\ui` is the window
  (title bar, menus, tab bar, settings, command blocks) and its views:
  `grid.ts` (layout, animation, dividers, drags, attention) and `pane.ts`
  (an xterm.js terminal with the fit, search, Unicode 11 and WebGL
  addons, falling back to the DOM renderer when the GPU runs out of
  contexts; the shell menu; the explain panel). `src\core` is DOM-free
  logic ported from GhostGridCore, unit tested in `test\` with vitest:
  `gridLayout`, `tabs`, `keymap`, `attention`, `broadcast`, `animation`,
  `paneActivity`.
- `src-tauri\`: the Rust app process. It owns the windows, one pipe
  connection to the helper per pane (`panes.rs`, which also parses each
  pane's output into command blocks), starting the helper (`helper.rs`),
  the settings and session files (`store.rs`), the Ghostty config
  (`config.rs`), the model requests (`explain.rs`), updates
  (`updates.rs`), and the Windows calls (`platform.rs`: clipboard, opening
  links and files, `gg` and PATH, and `WindowFromPoint` for drags).
  `installer-hooks.nsh` adds the Explorer entries.
- `crates\ghostgrid-core`: platform-neutral Rust with contract tests
  (`tests\contract`, ported from the Swift tests): the session wire
  protocol (the same bytes as the macOS helper's), output history, the
  command block parser, Ghostty config flattening and its mapping to
  xterm.js, the shell catalog, launch rules and hooks, the app launcher,
  the session and settings models, the explain prompt, link and path
  rules, and pane header info.
- `crates\ghostgrid-sessiond`: the helper that owns every pane's shell
  (portable-pty's ConPTY, output history, one named-pipe connection per
  pane).
- Pane drags between windows go through the app process rather than OS
  drag and drop: when a tab or pane is let go outside its window, the app
  finds the ghostgrid window under the pointer (`WindowFromPoint`), asks
  it where on its tab bar the drop lands, lets go of the shells, and that
  window attaches to them by session ID.

### Ghostty config

ghostgrid looks for the config where Ghostty would: `GHOSTGRID_CONFIG`
(an entry file, used as is) first, then in each of `$XDG_CONFIG_HOME`,
`%USERPROFILE%\.config`, `%LOCALAPPDATA%` and `%APPDATA%`,
`ghostty\config.ghostty` then `ghostty\config`. It flattens the file at
launch and on Reload (includes inlined in Ghostty's order, relative file
paths made absolute) and maps the result; nothing is generated on disk.
Edit your Ghostty config, then Reload (Ctrl+Shift+,).

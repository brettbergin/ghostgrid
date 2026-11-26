# ghostgrid

A macOS terminal built on Ghostty's engine (libghostty) where every new
"tab" is a pane that joins an animated, auto-balanced grid.

It loads your own `~/.config/ghostty` config, so theme, font, padding,
opacity and shaders match your Ghostty.

## Install

```bash
make install   # release build -> /Applications/ghostgrid.app, gg -> ~/.local/bin/gg
gg             # a pane in the current folder (launches ghostgrid if needed)
gg ~/code/api  # a pane in that folder; several folders open several panes
```

`make install` refuses while ghostgrid is running (quit it first) and
`make uninstall` removes both. Dropping a folder on the Dock icon opens a
pane there too. `gg` opens the installed app by path, since a dev build
in `build/` has the same name. The icon is drawn by `Scripts/make-icon.swift`
at build time. In the dotfiles, `./install.sh ghostgrid` clones, builds
(with the shader-enabled libghostty when Xcode is installed) and installs.

## Build and run

Needs macOS 14+ and Swift 6.2+ (the Command Line Tools are enough; full
Xcode is only needed for `make libghostty`).

```bash
make run     # debug build, assemble build/ghostgrid.app, open it
make app     # release build of build/ghostgrid.app
make test    # unit tests (core module: layouts, config, shells, sessions, ...)
make check   # tests + release app + shellcheck
make release # signed, notarized DMG for other Macs (see Releases)
```

## CI

berg-runner (`.berg-runner/ci.yaml`): the `core` job builds the AppKit-free
`GhostGridCore` module and runs its tests in a Linux Swift container (the
app target exists only on macOS, see `Package.swift`). The app itself is
checked by `make check` on a Mac until there is a Mac CI agent.

## Releases

`make release` builds `build/release/ghostgrid-<version>.dmg` for other
Macs: signed with your Developer ID and the hardened runtime, notarized by
Apple and stapled (the app inside too, so it opens offline once copied
out), with a `.sha256` beside it. It is built from what is committed and
takes a few minutes, most of it waiting on Apple. The version is
`CFBundleShortVersionString` in `Resources/Info.plist` (or
`GHOSTGRID_VERSION`); the build number is the commit count.

ghostgrid is not in the Mac App Store and cannot be: the store requires the
App Sandbox, and a sandboxed terminal's shells could not see your files or
run your tools. Developer ID with notarization is how terminals ship.

One-time setup:

1. A **Developer ID Application** certificate in your login keychain:
   developer.apple.com > Certificates, Identifiers & Profiles >
   Certificates > + > Developer ID Application (or Xcode > Settings >
   Accounts > Manage Certificates > + > Developer ID Application).
2. Notarization credentials saved in the keychain as `ghostgrid-notary`,
   with an app-specific password made at account.apple.com:

   ```bash
   xcrun notarytool store-credentials ghostgrid-notary --apple-id <apple id> --team-id <team id>
   ```

3. Ghostty in `/Applications` (its themes are bundled, see `bundle.sh`).

`make release-check` runs the same packaging signed ad hoc and not
notarized, to check it without certificates. Release builds carry
`Resources/ghostgrid.entitlements`: no sandbox, but the permissions that
let programs in a pane ask for the microphone, camera, contacts and so on,
as Ghostty does. Publish with
`gh release create v<version> build/release/ghostgrid-<version>.dmg*`
(CI runs on Linux and cannot sign).

## Picking a shell

The first pane ever, and every Cmd+Shift+T pane, opens with a menu:
**1** zsh, **2** nushell, **3** bash. ghostgrid remembers your pick (also
across launches), so Cmd+T and new windows start that shell directly;
the menu opens with it highlighted. If the remembered shell is no longer
installed, Cmd+T shows the menu instead. Forget it with
**Forget** in Settings (or `defaults delete com.brettbergin.ghostgrid lastShell`).
Press the number to start that shell at once, or use Up/Down and Return;
Escape cancels and closes the pane. A shell that is not installed is shown
dimmed and skipped (nushell is looked for in `/opt/homebrew/bin/nu`,
`/usr/local/bin/nu` and `~/.cargo/bin/nu`; a Homebrew bash wins over the
system bash 3.2). Shells start as login shells, so `~/.zprofile` loads.

### Apps in a new zsh pane

Picking **zsh** from the Cmd+Shift+T menu opens a second menu of apps to
start in it. The list is yours, in Settings > zsh app launcher: each app is
a name, the command typed at the prompt (aliases and functions work) and a
description; add, remove and reorder up to 9 (keys 1-9 in list order). It
starts with **1** opencode, **2** claude, **3** btop, **4** lazygit and
**5** yazi (as `y`, so quitting with q leaves the pane in that folder);
Reset to Defaults brings those back, and an empty list means plain zsh.
Press the number to launch; **Escape** drops you into a plain zsh. The
app's command is typed at zsh's first prompt, so it lands in history and
quitting the app leaves you at the zsh prompt in the same pane. An app whose
program is not found is marked "(not found)" but stays pickable, since the
command may be an alias. Cmd+T never shows this menu.

This libghostty build ignores a per-pane command, so each shell gets its
own Ghostty app instance whose config ends with `command = <shell> -l`
(`~/Library/Application Support/ghostgrid/config-<shell>.ghostty`), created
the first time a pane picks that shell. The package bundles Ghostty's
zsh and bash integration only, so other shells (nushell) run with
`shell-integration = none`; nushell emits its own prompt markers.

## Keys

| Keys                  | Action                                   |
|-----------------------|------------------------------------------|
| Cmd+T / Cmd+D         | New pane with your last shell (inherits cwd) |
| Cmd+Shift+T           | New pane, choosing the shell from the menu |
| Cmd+W                 | Close pane                               |
| Cmd+Shift+Enter       | Zoom pane to fill the window and back    |
| Cmd+] / Cmd+[         | Next / previous pane                     |
| Cmd+Option+arrows     | Focus the pane in that direction         |
| Cmd+Shift+arrows      | Swap the focused pane with that neighbour (or move its row) |
| Cmd+Shift+M           | Make the focused pane the main (first) one |
| Cmd+Shift+L           | Next layout (Grid, Main + Stack, Columns) |
| Cmd+Ctrl+=            | Equalize panes (undo divider drags)      |
| Cmd+Option+I          | Broadcast typing to every pane on/off    |
| Cmd+Shift+B           | Command blocks of the focused pane       |
| Cmd+Option+Shift+C    | Copy the last command's output           |
| Cmd+Shift+E           | Explain the last failure (Return runs the fix) |
| Cmd+Ctrl+A            | Attention grid on/off                    |
| Cmd+N                 | New window                               |
| Cmd+,                 | ghostgrid Settings                       |

These win over Ghostty keybindings with the same keys; every other key
goes to the terminal (so Ghostty's own bindings still work).

## Commands as blocks

Every command you run becomes a block: its command line, its output as
plain text, how it ended and how long it took. Pane > Command Blocks
(Cmd+Shift+B) lists the pane's blocks, newest last:

- Fold or unfold each block's output (or all of them).
- Copy a block (command and output), run it again, or share it with the
  macOS share sheet.
- Pane > Copy Last Command Output (Cmd+Opt+Shift+C) copies the output of
  the last finished command without opening the list.

Blocks come from the shell integration's prompt marks (OSC 133). The
command line is reported by a small hook ghostgrid adds after Ghostty's
zsh and bash integration (OSC 633;E, as VS Code does); the hook files
live in `~/Library/Application Support/ghostgrid/hooks` and are rewritten
on each launch. nushell's own marks give blocks without the command line.
The last 200 commands per pane are kept, with up to 256 KiB of output
each (the end of longer output), and they come back with kept shells.

## Explain failures (local model)

When a command fails in the pane you are working in, ghostgrid sends its
command line and the end of its output (6 KB at most) to a local model and
shows a panel at the bottom of the pane: why it failed, and one command to
fix it. The answer streams in as the model writes it.

- The panel does not take the keyboard: keep typing and it goes to the
  shell, so a reflexive Return never runs a suggested command.
- Pane > Explain Last Failure (Cmd+Shift+E) focuses the panel (or explains
  the last failure on demand). Then Return types the fix and runs it,
  Escape dismisses, and any other key dismisses and goes to the shell.
- The panel goes away when the next command starts.
- Interrupted commands (Ctrl+C, Ctrl+Z, kill) are not explained.
- Settings > Explain failures: turn the automatic panel off, or set the
  model server and model. The default is LM Studio's local server
  (`http://localhost:1234/v1`) and a model it already has loaded,
  preferring one whose thinking can be turned off (a thinking model can
  take a minute or more to answer); any OpenAI-style server works. Output
  leaves the Mac only if you point it at another machine.

## Broadcast typing

Shell > Broadcast Input to All Panes (Cmd+Opt+I) sends what you type in the
focused pane to every other pane of the window as well: run the same
command on several hosts, or answer the same prompt everywhere. While it is
on, every pane header turns red and says BROADCAST, pane borders go red,
and the window title starts with "BROADCAST:". Press Cmd+Opt+I again to
stop.

- Each pane receives the key events themselves, so every program encodes
  them for its own mode (arrow keys in vim, Ctrl+C, pastes).
- Command shortcuts (new pane, close, copy) still act once, on the focused
  pane. Cmd+V pastes into every pane.
- Panes still showing their shell menu are skipped.
- It is per window and never saved: a restored window types into one pane.

## Pane headers and activity badges

Each pane has a slim header: its shell, its folder (`~`-shortened, trimmed
from the left when long) and the git branch, read from `.git/HEAD` without
running git (worktrees and submodules included). It updates on `cd`, after
each command, and on focus.

Panes you are not looking at get a badge when something happens there:

- **bell** (peach): a program rang the bell.
- **✓ 12s** (green): a command that ran 5 s or more finished.
- **✕ exit 2** (red): such a command failed, with its exit code.

Focusing the pane (or coming back to the window) clears it. "Not looking"
means not the focused pane of the key window of the active app, so a long
build finishing while you are in another app badges too. Both are
optional in Settings; with headers off, badges sit in the pane's corner.
Finished-command badges need shell integration (zsh and bash via
Ghostty's, nushell natively).

## Shells that survive quitting

Every pane's shell runs in a small background helper,
`ghostgrid-sessiond` (bundled in `Contents/Helpers`), not under the app.
Quit ghostgrid and the shells keep going: running programs, builds, an
agent mid-task. Relaunch and each pane reattaches to its shell and gets
its recent output back (up to 4 MiB per pane), so the screen looks as you
left it. Programs that draw full-screen (vim, btop, lazygit) are asked to
redraw on reattach.

- Closing a pane or a window ends its shells; only quitting keeps them.
- Settings > Shells > "Keep shells running after quitting" turns it off:
  quitting then ends every shell, as before.
- If a kept shell is gone on relaunch (it exited, or the Mac restarted),
  the pane starts a fresh shell in the same folder.
- The helper is a background-only app inside ghostgrid
  (`Contents/Helpers/ghostgrid-sessiond.app`, no Dock icon), started on
  demand through LaunchServices: macOS ends everything an app started when
  the app quits, so the helper has to be an app of its own. It listens on
  a user-only socket in
  `~/Library/Application Support/ghostgrid/` (one per protocol version, so
  an update never talks to an older helper), logs to
  `~/Library/Logs/ghostgrid/sessiond.log`, and exits on its own 30 s after
  its last shell and pane are gone.
- If the helper cannot start, panes fall back to running their shell
  directly (it then ends with the app).

## Session restore

Quit and relaunch, and ghostgrid reopens your windows where they were,
with the same panes in the same order, plus which pane had focus and
which was zoomed. With kept shells (above) each pane comes back attached
to its running shell; otherwise each starts its shell again in the folder
it was in, without scrollback. It follows Ghostty's `window-save-state`:
`always` restores, `never` does not (and ends kept shells), and `default`
follows macOS's "Close windows when quitting an application", except that
windows with kept shells always come back. Closing a window yourself drops
it from the session. Saved to
`~/Library/Application Support/ghostgrid/session.json` on quit and shortly
after each change, so a crash loses little.

## Settings

ghostgrid > Settings... (Cmd+,) holds ghostgrid's own options, saved in
the app's defaults (`com.brettbergin.ghostgrid`) and applied immediately:

- **Cmd+T opens**: your last shell, or the shell menu every time.
- **Last shell**: shown, with Forget.
- **Pane headers** and **activity badges**: on/off.
- **Offer apps after choosing zsh** (the app menu).
- **Gap between panes**: 0-24 pt.
- **Animations**: Springy (default), Smooth (no overshoot), or Off.
- **Ghostty**: the config file in use, whether windows are restored
  (from `window-save-state`), whether libghostty is the local
  build (custom shaders on) or the published one, and Open / Reload.

Everything about how terminals look stays in the Ghostty config.

## Layouts and reordering

Each window has a layout, in Pane > Layout or cycled with Cmd+Shift+L:

- **Grid**: balanced rows (below).
- **Main + Stack**: the first pane takes 60% on the left (top in a tall
  window), the rest stack beside it. Cmd+Shift+M promotes the focused pane.
- **Columns**: equal columns (rows in a tall window).

Resize panes by dragging the gap between two of them: only those two
change, and neither gets smaller than 100 pt. That works between grid rows,
between panes in a row, between the main pane and the stack in Main + Stack
(instead of its fixed 60%), and between stacked panes. Double-click a gap or
use Pane > Equalize Panes (Cmd+Ctrl+=) to rebalance. Adding or removing a
pane, or changing the layout, rebalances too; the session keeps your
adjustments otherwise.

Reorder panes by dragging one by its header onto another (the target
lights up; they swap) or with Cmd+Shift+arrows. In the grid, moving a pane
into a row with a different number of panes moves its whole row instead,
sizes and all: with two panes on top and a long one below, moving the long
one up puts it, still long, on top and the other two below. The layout is
saved with the session; new windows use Settings > Grid > New windows use.

## Attention grid

The grid leans toward whatever needs you. A pane that is waiting for you
(a bell, a desktop notification such as an agent asking for input, or a
command that finished while you looked elsewhere) grows the most; a pane
printing right now, and the pane you are in, grow a little; a pane with no
output for 90 seconds shrinks. When nothing stands out the grid stays
balanced. Changes are gentle: sizes move by small factors on a soft
0.6 s ease, and only when some pane's state changes.

- A pane stops "needing you" once you focus it.
- Dragging a divider pauses the attention grid in that window, so your
  sizes stay; Pane > Equalize Panes (Cmd+Ctrl+=) resumes it.
- Pane > Attention Grid (Cmd+Ctrl+A), or Settings > Grid, turns it off.
- The sizes it picks are not saved with the session.

## Grid

Panes fill row by row with `ceil(sqrt(n))` columns: 1, 1x2, 2+1, 2x2, 3+2,
3x2, ... The last row stretches to the full width. Tall windows transpose
the grid into columns.

Adding, zooming and rebalancing use a short spring that overshoots and
settles; a new pane launches as a small card out of the pane you were in
and lands with a flash. Terminal text moves with its pane: each terminal
takes its final size once, and a uniform scale, sampled along the same
curve as the frame, keeps it covering the moving box without stretching.
`GHOSTGRID_SLOW_ANIMATIONS=8` plays everything 8x slower for tuning.

## Custom shaders (cursor trail and friends)

The published libghostty-spm binary is built with `-Dcustom-shaders=false`,
so `custom-shader` lines in your Ghostty config do nothing. To get them:

```bash
make libghostty   # Scripts/build-libghostty.sh
make run
```

That checks out libghostty-spm at the version `Package.swift` pins into
`Vendor/libghostty-spm` (Git-ignored), turns `-Dcustom-shaders` on, builds
the macOS slice, and `Package.swift` switches to it automatically. Delete
`Vendor/` to go back to the published binary. It needs full Xcode (the
Metal compiler; `xcodebuild -downloadComponent MetalToolchain`) and the Zig
version from Ghostty's `build.zig.zon` (`brew install zig`). While building
locally SwiftPM rewrites `Package.resolved` without the remote pin; do not
commit that change.

## Ghostty feature coverage

libghostty does the terminal; Ghostty's macOS app does everything around
it. ghostgrid has to provide the app half itself, and anything it does not
provide fails silently. Check this list when adding Ghostty options or
upgrading libghostty-spm.

| Ghostty feature | In ghostgrid |
|---|---|
| Fonts, theme (light/dark), padding, cursor, opacity, scrollback | libghostty |
| Copy/paste, select all, Cmd+K, font size, prompt jumps, Option as Alt | libghostty |
| `config-file` includes | ConfigFlattener (package ignores them) |
| `custom-shader` | needs `make libghostty` (published binary has shaders off) |
| Per-pane shell / command | one Ghostty instance per shell (package drops it) |
| Shell integration `cursor`, `title` | package's zsh/bash integration; nushell off |
| Shell integration `sudo`, `ssh-*` | not available (package's integration) |
| Cmd+click links | LinkPolicy: http(s), mailto, file, existing paths |
| Search (Cmd+F, Return / Shift+Return, Esc) | SearchBarView |
| Bell | border flash; Dock bounce in the background |
| Desktop notifications (OSC 9 / 777) | macOS notifications (asks permission once) |
| `mouse-hide-while-typing` | hides the pointer until it moves |
| `unfocused-split-opacity` | dims unfocused panes |
| Reload config (Cmd+Shift+,) | re-flattens your files into every shell's instance |
| Open config | Cmd+Option+, opens your config in VS Code (TextEdit otherwise); Cmd+, is ghostgrid Settings |
| Full screen (Cmd+Enter, Ctrl+Cmd+F) | menu |
| Cmd+1...9 | focus pane N (Ghostty: tab N) |
| Tabs, splits, `new_window` keybinds | ghostgrid's own grid and menu |
| `window-save-state` | session restore (windows, panes, shells, folders, focus, zoom) |
| Quick terminal, `macos-icon*`, `macos-titlebar-style`, `split-divider-color`, `background-blur` | Ghostty app only; ghostgrid uses its own window and glass |
| Terminal inspector | removed from the package build |

## How it is put together

- `Sources/GhostGrid`: the AppKit app (window, grid view, panes, menu).
- `Sources/ghostgrid-sessiond`: the helper that owns each pane's shell
  (forkpty, output history, one Unix-socket connection per pane). The
  wire format, history and shell launch rules live in
  `GhostGridCore/SessionProtocol.swift`; panes use libghostty's in-memory
  backend to talk to it.
- `Sources/GhostGridCore`: AppKit-free logic with unit tests:
  `GridLayout` (frames, directional neighbours), `ConfigFlattener`,
  `ShellCatalog`/`ShellConfig` and `ContentScale` (animation curve math).
- [libghostty-spm](https://github.com/Lakr233/libghostty-spm) (MIT),
  pinned exactly in `Package.swift`: prebuilt `GhosttyKit.xcframework`
  plus AppKit terminal views. libghostty's embedding API is not stable, so
  upgrade it deliberately.
- `Scripts/bundle.sh`: assembles the `.app` from `swift build` output and
  copies color themes from the installed Ghostty.app (the package ships
  none), so names like `Catppuccin Latte` resolve.

### Ghostty config

The package loads a single config file and does not follow `config-file`
includes. ghostgrid therefore flattens your config (includes inlined in
Ghostty's order, relative shader paths made absolute) at launch, and each
shell's generated config above is that plus its `command`. Edit your Ghostty config, not the generated file.
`GHOSTGRID_CONFIG=/path/to/config` uses a different entry file.

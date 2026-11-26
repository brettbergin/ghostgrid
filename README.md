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
```

## CI

berg-runner (`.berg-runner/ci.yaml`): the `core` job builds the AppKit-free
`GhostGridCore` module and runs its tests in a Linux Swift container (the
app target exists only on macOS, see `Package.swift`). The app itself is
checked by `make check` on a Mac until there is a Mac CI agent.

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
| Cmd+Shift+arrows      | Swap the focused pane with that neighbour |
| Cmd+Shift+M           | Make the focused pane the main (first) one |
| Cmd+Shift+L           | Next layout (Grid, Main + Stack, Columns) |
| Cmd+Ctrl+=            | Equalize panes (undo divider drags)      |
| Cmd+N                 | New window                               |
| Cmd+,                 | ghostgrid Settings                       |

These win over Ghostty keybindings with the same keys; every other key
goes to the terminal (so Ghostty's own bindings still work).

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

## Session restore

Quit and relaunch, and ghostgrid reopens your windows where they were,
with the same panes in the same order, each running its shell in the
folder it was in, plus which pane had focus and which was zoomed.
Scrollback and running programs are not restored (Ghostty does not
restore them either). It follows Ghostty's `window-save-state`: `always`
restores, `never` does not, and `default` follows macOS's "Close windows
when quitting an application". Closing a window yourself drops it from the
session. Saved to `~/Library/Application Support/ghostgrid/session.json`
on quit and shortly after each change, so a crash loses little.

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
lights up; they swap) or with Cmd+Shift+arrows. The layout is saved with
the session; new windows use Settings > Grid > New windows use.

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

# ghostgrid

A macOS terminal built on Ghostty's engine (libghostty) where every new
"tab" is a pane that joins an animated, auto-balanced grid.

It loads your own `~/.config/ghostty` config, so theme, font, padding,
opacity and shaders match your Ghostty.

## Build and run

Needs macOS 14+ and Swift 6.2+ (the Command Line Tools are enough; full
Xcode is not required).

```bash
make run     # debug build, assemble build/ghostgrid.app, open it
make app     # release build of build/ghostgrid.app
make test    # unit tests (grid layout, config flattening)
make check   # tests + release app + shellcheck
```

## Picking a shell

The first pane ever, and every Cmd+Shift+T pane, opens with a menu:
**1** zsh, **2** nushell, **3** bash. ghostgrid remembers your pick (also
across launches), so Cmd+T and new windows start that shell directly;
the menu opens with it highlighted. If the remembered shell is no longer
installed, Cmd+T shows the menu instead. Forget it with
`defaults delete com.brettbergin.ghostgrid lastShell`.
Press the number to start that shell at once, or use Up/Down and Return;
Escape cancels and closes the pane. A shell that is not installed is shown
dimmed and skipped (nushell is looked for in `/opt/homebrew/bin/nu`,
`/usr/local/bin/nu` and `~/.cargo/bin/nu`; a Homebrew bash wins over the
system bash 3.2). Shells start as login shells, so `~/.zprofile` loads.

### Apps in a new zsh pane

Picking **zsh** from the Cmd+Shift+T menu opens a second menu of apps to
start in it: **1** opencode, **2** claude, **3** btop, **4** lazygit,
**5** yazi (as `y`, so quitting with q leaves the pane in that folder).
Press the number to launch; **Escape** drops you into a plain zsh. The
app's command is typed at zsh's first prompt, so it lands in history and
quitting the app leaves you at the zsh prompt in the same pane. Apps that
are not installed are dimmed. Cmd+T never shows this menu.

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
| Cmd+N                 | New window                               |

These win over Ghostty keybindings with the same keys; every other key
goes to the terminal (so Ghostty's own bindings still work).

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

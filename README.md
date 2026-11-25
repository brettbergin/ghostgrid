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

## Keys

| Keys                  | Action                                   |
|-----------------------|------------------------------------------|
| Cmd+T / Cmd+D         | New pane (joins the grid, inherits cwd)  |
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
the grid into columns. Adding, closing and zooming animate.

## How it is put together

- `Sources/GhostGrid`: the AppKit app (window, grid view, panes, menu).
- `Sources/GhostGridCore`: AppKit-free logic with unit tests:
  `GridLayout` (frames, directional neighbours) and `ConfigFlattener`.
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
Ghostty's order, relative shader paths made absolute) into
`~/Library/Application Support/ghostgrid/config.ghostty` at launch and
loads that. Edit your Ghostty config, not the generated file.
`GHOSTGRID_CONFIG=/path/to/config` uses a different entry file.

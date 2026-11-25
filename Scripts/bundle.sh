#!/usr/bin/env bash
# Build ghostgrid with SwiftPM and assemble build/ghostgrid.app.
# Works with the Command Line Tools alone; full Xcode is not required.
# Usage: Scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/ghostgrid.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/GhostGrid" "$APP/Contents/MacOS/GhostGrid"
# SwiftPM resource bundles (GhosttyTerminal's shell integration, terminfo).
# The package looks for them in Contents/Resources.
cp -R "$BIN"/*.bundle "$APP/Contents/Resources/"

# The package ships no color themes. Borrow the installed Ghostty's, so theme
# names such as "Catppuccin Latte" resolve the way they do in Ghostty.
THEMES="/Applications/Ghostty.app/Contents/Resources/ghostty/themes"
RES="$(echo "$APP"/Contents/Resources/*_GhosttyTerminal.bundle)/Contents/Resources/Ghostty"
if [[ -d $THEMES && -d $RES ]]; then
  cp -R "$THEMES" "$RES/themes"
else
  echo "bundle.sh: Ghostty.app themes not found; bundled theme names will not resolve" >&2
fi

# Ad-hoc signature so the assembled bundle is consistent for Gatekeeper.
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

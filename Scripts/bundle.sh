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
# The helper that keeps shells running after the app quits: a background-
# only app of its own, so LaunchServices runs it as its own launchd job and
# it is not ended with ghostgrid (see SessionDaemon.start).
HELPER="$APP/Contents/Helpers/ghostgrid-sessiond.app"
mkdir -p "$HELPER/Contents/MacOS"
cp "$BIN/ghostgrid-sessiond" "$HELPER/Contents/MacOS/ghostgrid-sessiond"
cat >"$HELPER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>ghostgrid-sessiond</string>
	<key>CFBundleIdentifier</key>
	<string>com.brettbergin.ghostgrid.sessiond</string>
	<key>CFBundleName</key>
	<string>ghostgrid-sessiond</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSBackgroundOnly</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
</dict>
</plist>
PLIST
# The helper is the parent of kept shells, so programs in them ask macOS
# through it: it needs the app's usage descriptions too.
for key in $(plutil -convert xml1 -o - Resources/Info.plist | sed -n 's|.*<key>\(NS[A-Za-z]*UsageDescription\)</key>.*|\1|p'); do
  plutil -insert "$key" -string "$(plutil -extract "$key" raw Resources/Info.plist)" "$HELPER/Contents/Info.plist"
done
# gg, for the Homebrew cask to link onto PATH (make install copies it to
# ~/.local/bin instead). It finds the app it is bundled in.
mkdir -p "$APP/Contents/Resources/bin"
install -m 0755 Scripts/gg "$APP/Contents/Resources/bin/gg"
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

# App icon: drawn by Scripts/make-icon.swift, cached in build/ until the
# script changes, then sized into an .icns with sips and iconutil.
ICON_PNG="build/icon/AppIcon.png"
if [[ ! -f $ICON_PNG || Scripts/make-icon.swift -nt $ICON_PNG ]]; then
  mkdir -p build/icon
  swift Scripts/make-icon.swift "$ICON_PNG" >/dev/null
fi
ICONSET="build/icon/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
  sips -z $px $px "$ICON_PNG" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$ICON_PNG" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so the assembled bundle is consistent for Gatekeeper.
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

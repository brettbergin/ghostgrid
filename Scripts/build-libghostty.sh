#!/usr/bin/env bash
# Build GhosttyKit (libghostty) locally WITH custom shader support, for
# macOS only, and make ghostgrid use it.
#
# Why: libghostty-spm's published binary is built with -Dcustom-shaders=false,
# so Ghostty `custom-shader` configs (e.g. a cursor trail) are ignored.
#
# What it does:
#   1. Checks out libghostty-spm at the version Package.swift pins, into
#      Vendor/libghostty-spm (Git-ignored).
#   2. Flips -Dcustom-shaders=false to true in its Ghostty build script.
#   3. Builds the macOS slice (clones Ghostty at the package's Ghostty.ref).
#   4. Uses the package's Package.local.swift there, which points at the
#      freshly built BinaryTarget/GhosttyKit.xcframework.
# ghostgrid's Package.swift switches to Vendor/libghostty-spm automatically
# once that framework exists. Delete Vendor/ to go back to the published one.
#
# Needs: Zig (version from Ghostty's build.zig.zon; brew install zig), full
# Xcode selected with xcode-select (the Metal shader compiler and
# xcodebuild -create-xcframework are not in the Command Line Tools), and
# Xcode's Metal toolchain (xcodebuild -downloadComponent MetalToolchain).
# The first build takes a while; later ones reuse Zig's cache.
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR="Vendor/libghostty-spm"
REPO="https://github.com/Lakr233/libghostty-spm.git"
# The exact version ghostgrid pins for the published binary.
VERSION="$(sed -n 's/.*libghostty-spm.git", exact: "\([^"]*\)".*/\1/p' Package.swift)"
[[ -n $VERSION ]] || { echo "build-libghostty: cannot read the pinned version from Package.swift" >&2; exit 1; }

command -v zig >/dev/null || { echo "build-libghostty: zig not found (brew install zig)" >&2; exit 1; }
if ! xcrun --find metal >/dev/null 2>&1; then
  echo "build-libghostty: the Metal compiler is missing." >&2
  echo "  Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app" >&2
  echo "  and: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

if [[ ! -d $VENDOR/.git ]]; then
  mkdir -p Vendor
  git clone --quiet "$REPO" "$VENDOR"
fi
git -C "$VENDOR" fetch --quiet --tags --force origin
git -C "$VENDOR" checkout --quiet --force "refs/tags/$VERSION"
echo "build-libghostty: libghostty-spm $VERSION (Ghostty $(tr -d '[:space:]' < "$VENDOR/Ghostty.ref" | cut -c1-12))"

# Turn custom shaders on. Fail loudly if the flag moved upstream.
BUILD_SCRIPT="$VENDOR/Script/build-ghostty.sh"
if grep -q -- '-Dcustom-shaders=false' "$BUILD_SCRIPT"; then
  sed -i '' 's/-Dcustom-shaders=false/-Dcustom-shaders=true/' "$BUILD_SCRIPT"
elif ! grep -q -- '-Dcustom-shaders=true' "$BUILD_SCRIPT"; then
  echo "build-libghostty: -Dcustom-shaders not found in $BUILD_SCRIPT; check the package" >&2
  exit 1
fi

(cd "$VENDOR" && ./build.sh --platforms macos --skip-tests)

# Point the vendored package at its own freshly built framework.
cp "$VENDOR/Package.local.swift" "$VENDOR/Package.swift"
test -d "$VENDOR/BinaryTarget/GhosttyKit.xcframework"
echo "build-libghostty: done. ghostgrid now builds against $VENDOR (custom shaders on)."

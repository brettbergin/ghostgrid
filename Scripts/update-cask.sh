#!/usr/bin/env bash
# Point the Homebrew cask at the release just published: sets version and
# sha256 in Casks/ghostgrid.rb of the brettbergin/homebrew-tap checkout and
# commits it there (push it yourself). Run after `make release` and
# `gh release create v<version> build/release/ghostgrid-<version>.dmg*`.
#
# Environment:
#   GHOSTGRID_TAP      the tap checkout (default: ../homebrew-tap)
#   GHOSTGRID_VERSION  version (default: Resources/Info.plist)
set -euo pipefail
cd "$(dirname "$0")/.."

die() {
  echo "update-cask.sh: $*" >&2
  exit 1
}

TAP="${GHOSTGRID_TAP:-../homebrew-tap}"
CASK="$TAP/Casks/ghostgrid.rb"
VERSION="${GHOSTGRID_VERSION:-$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)}"
LOCAL="build/release/ghostgrid-$VERSION.dmg.sha256"
URL="https://github.com/brettbergin/ghostgrid/releases/download/v$VERSION/ghostgrid-$VERSION.dmg"

[[ -f $CASK ]] || die "no cask at $CASK; clone github.com/brettbergin/homebrew-tap there or set GHOSTGRID_TAP"
[[ -f $LOCAL ]] || die "no $LOCAL; run make release first"
SHA="$(cut -d' ' -f1 "$LOCAL")"
[[ $SHA =~ ^[0-9a-f]{64}$ ]] || die "$LOCAL does not hold a SHA-256"

# The cask must point at what users will download: the published DMG,
# which has to be this exact build.
PUBLISHED="$(curl -fsSL "$URL.sha256" 2>/dev/null | cut -d' ' -f1)" ||
  die "v$VERSION is not published (no $URL.sha256); gh release create it first"
[[ $PUBLISHED == "$SHA" ]] ||
  die "the published v$VERSION DMG ($PUBLISHED) is not this build ($SHA)"

sed -i '' -E \
  -e "s/^  version \"[^\"]*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \"[0-9a-f]*\"/  sha256 \"$SHA\"/" \
  "$CASK"
if ! grep -q "^  version \"$VERSION\"$" "$CASK" || ! grep -q "^  sha256 \"$SHA\"$" "$CASK"; then
  die "could not update version and sha256 in $CASK"
fi

if git -C "$TAP" diff --quiet -- Casks/ghostgrid.rb; then
  echo "$CASK is already at $VERSION"
  exit 0
fi
git -C "$TAP" commit -q -m "ghostgrid $VERSION" -- Casks/ghostgrid.rb
echo "Committed ghostgrid $VERSION in $TAP; publish it with: git -C $TAP push"

#!/usr/bin/env bash
# Build a release of ghostgrid for other Macs: signed with your Developer ID,
# hardened runtime, notarized by Apple and stapled, packaged as
# build/release/ghostgrid-<version>.dmg (plus its .sha256).
#
# One-time setup (see README, "Releases"): a "Developer ID Application"
# certificate in your login keychain, and notarytool credentials saved as a
# keychain profile:
#   xcrun notarytool store-credentials ghostgrid-notary --apple-id <you> --team-id <team>
#
# Environment:
#   GHOSTGRID_SIGN_IDENTITY   codesign identity; default: the one Developer ID
#                             Application identity in the keychain. "-" signs
#                             ad hoc to test the packaging (no notarization).
#   GHOSTGRID_NOTARY_PROFILE  notarytool keychain profile (default ghostgrid-notary)
#   GHOSTGRID_NOTARIZE=0      sign and package without notarizing
#   GHOSTGRID_VERSION         version to stamp (default: Resources/Info.plist)
set -euo pipefail
cd "$(dirname "$0")/.."

die() {
  echo "release.sh: $*" >&2
  exit 1
}

# -- What to sign with, and checks that would otherwise fail late. --------

IDENTITY="${GHOSTGRID_SIGN_IDENTITY:-}"
if [[ -z $IDENTITY ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning |
    sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | sort -u)"
  case "$(grep -c . <<<"$IDENTITIES" || true)" in
  1) IDENTITY="$IDENTITIES" ;;
  0) die "no \"Developer ID Application\" certificate in the keychain. Create one at
  developer.apple.com > Certificates (or Xcode > Settings > Accounts > Manage
  Certificates), or set GHOSTGRID_SIGN_IDENTITY." ;;
  *) die "several Developer ID Application identities; pick one with GHOSTGRID_SIGN_IDENTITY:
$IDENTITIES" ;;
  esac
fi

NOTARIZE="${GHOSTGRID_NOTARIZE:-1}"
PROFILE="${GHOSTGRID_NOTARY_PROFILE:-ghostgrid-notary}"
if [[ $IDENTITY == - ]]; then
  NOTARIZE=0
  TIMESTAMP=(--timestamp=none)
else
  TIMESTAMP=(--timestamp)
  # A release is built from what is committed, so it can be traced to a commit.
  git diff --quiet HEAD -- . ':!Package.resolved' || die "uncommitted changes; commit them first"
fi
if [[ $NOTARIZE == 1 ]] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  die "no notarytool credentials in keychain profile \"$PROFILE\". Save them once with:
  xcrun notarytool store-credentials $PROFILE --apple-id <apple id> --team-id <team id>
(it asks for an app-specific password from account.apple.com), or set GHOSTGRID_NOTARIZE=0."
fi

# bundle.sh only warns when Ghostty's themes are missing; a release without
# them would not resolve theme names, so it is an error here.
[[ -d /Applications/Ghostty.app/Contents/Resources/ghostty/themes ]] ||
  die "Ghostty.app's themes are missing (/Applications/Ghostty.app); install Ghostty to bundle them"

VERSION="${GHOSTGRID_VERSION:-$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)}"
BUILD="$(git rev-list --count HEAD)"
OUT="build/release"
APP="build/ghostgrid.app"
HELPER="$APP/Contents/Helpers/ghostgrid-sessiond.app"
DMG="$OUT/ghostgrid-$VERSION.dmg"

# -- Build, stamp, sign. ----------------------------------------------------

Scripts/bundle.sh release
rm -rf "$OUT"
mkdir -p "$OUT"
for plist in "$APP/Contents/Info.plist" "$HELPER/Contents/Info.plist"; do
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
  plutil -replace CFBundleVersion -string "$BUILD" "$plist"
done

# Inside out: the helper first, then the app that seals it.
for code in "$HELPER" "$APP"; do
  codesign --force --options runtime "${TIMESTAMP[@]}" \
    --entitlements Resources/ghostgrid.entitlements --sign "$IDENTITY" "$code"
done
codesign --verify --strict --deep "$APP"
# (Captured first: grep -q stopping early would fail the pipe under pipefail.)
for code in "$HELPER" "$APP"; do
  details="$(codesign -dv "$code" 2>&1)"
  [[ $details == *flags=*runtime* ]] || die "$code is not signed with the hardened runtime"
  entitlements="$(codesign -d --entitlements - "$code" 2>/dev/null)"
  [[ $entitlements == *device.audio-input* ]] || die "$code is missing its entitlements"
  [[ $entitlements != *get-task-allow* ]] || die "$code allows debugging (get-task-allow); notarization rejects it"
done

# Waits for Apple's verdict on $1 and prints the log when it is not Accepted.
notarize() {
  local result status id
  result="$(mktemp)"
  echo "Notarizing $(basename "$1") (this usually takes a few minutes)..."
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format plist >"$result"
  status="$(plutil -extract status raw "$result" 2>/dev/null || echo unknown)"
  id="$(plutil -extract id raw "$result" 2>/dev/null || true)"
  rm -f "$result"
  if [[ $status != Accepted ]]; then
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    die "notarization of $1 ended with status: $status"
  fi
}

# The app gets its own ticket so it opens offline once copied out of the DMG.
if [[ $NOTARIZE == 1 ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/ghostgrid.zip"
  notarize "$OUT/ghostgrid.zip"
  rm "$OUT/ghostgrid.zip"
  xcrun stapler staple "$APP"
fi

# -- Package. ---------------------------------------------------------------

STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ghostgrid.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "ghostgrid $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force "${TIMESTAMP[@]}" --sign "$IDENTITY" "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG" ||
    die "Gatekeeper rejects $DMG"
  spctl --assess --type execute "$APP" || die "Gatekeeper rejects $APP"
else
  echo "release.sh: not notarized; other Macs will refuse to open it" >&2
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")
echo "Built $DMG ($IDENTITY)"

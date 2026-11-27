#!/bin/sh
# Prints the Sparkle appcast for one release: its DMG, the build number
# Sparkle compares with an installed app's CFBundleVersion, and the DMG's
# EdDSA signature. release.sh writes it to build/release/appcast.xml, which
# is published with the release; the app reads the latest release's copy.
# Usage: Scripts/appcast.sh <version> <build> '<sign_update output>'
#   sign_update prints: sparkle:edSignature="..." length="..."
set -eu

[ "$#" -eq 3 ] || { echo "usage: appcast.sh <version> <build> '<sign_update output>'" >&2; exit 2; }
VERSION="$1"
BUILD="$2"
SIGNATURE="$3"

case "$SIGNATURE" in
*'sparkle:edSignature="'*'" length="'*'"'*) ;;
*)
  echo "appcast.sh: not sign_update output: $SIGNATURE" >&2
  exit 1
  ;;
esac

RELEASE="https://github.com/brettbergin/ghostgrid/releases"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ghostgrid</title>
    <link>$RELEASE</link>
    <item>
      <title>ghostgrid $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$RELEASE/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$RELEASE/download/v$VERSION/ghostgrid-$VERSION.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

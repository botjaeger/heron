#!/bin/zsh
# Builds dist/Heron.dmg: a disk image holding Heron.app and a link to /Applications, so
# people who download it drag Heron across to install it.
#
#   packaging/make-dmg.sh                 # ad-hoc signed: opens once allowed in System Settings ›
#                                         # Privacy & Security (no Developer ID, no notarization)
#   SIGN_ID="Developer ID Application: …" packaging/make-dmg.sh   # then notarize the .dmg (docs.md)
#
# Takes the same environment as make-app.sh (VERSION, BUILD, FEED_URL, ED_KEY, SIGN_ID).
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
# One name for every version: the website links to releases/latest/download/Heron.dmg.
DMG="dist/Heron.dmg"
STAGE="dist/dmg"

VERSION="$VERSION" packaging/make-app.sh

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto dist/Heron.app "$STAGE/Heron.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Heron" -srcfolder "$STAGE" -fs APFS -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null

# Check what people get: mount it, and the app inside must carry an intact signature and the link.
MNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT
codesign --verify --deep --strict "$MNT/Heron.app"
[[ "$(readlink "$MNT/Applications")" == "/Applications" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$MNT/Heron.app/Contents/Info.plist")" == "$VERSION" ]]
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '), Heron $VERSION, $(lipo -archs "$MNT/Heron.app/Contents/MacOS/Heron"))"

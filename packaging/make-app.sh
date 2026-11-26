#!/bin/zsh
# Builds dist/Heron.app from the Swift package.
#
#   packaging/make-app.sh                 # release build, ad-hoc signed (runs on this Mac)
#   SIGN_ID="Heron Signing" packaging/make-app.sh   # releases (scripts/release.sh)
#
# Optional environment:
#   VERSION, BUILD           version strings (default 1.0.0 / 1)
#   FEED_URL, ED_KEY         Sparkle appcast URL and EdDSA public key (updates stay off without them)
#   SIGN_ID                  signing identity; "-" (default) is ad hoc
#   BUNDLE_ID                bundle identifier (default app.heron.Heron; test copies use another, so
#                            they never share the real app's settings)
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
FEED_URL="${FEED_URL:-}"
ED_KEY="${ED_KEY:-}"
SIGN_ID="${SIGN_ID:--}"          # "-" = ad-hoc signature
BUNDLE_ID="${BUNDLE_ID:-app.heron.Heron}"
APP="dist/Heron.app"

swift build -c release --product Heron
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/Heron" "$APP/Contents/MacOS/Heron"
cp -R ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
[[ -f packaging/AppIcon.icns ]] && cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

sed -e "s|__VERSION__|$VERSION|" -e "s|__BUILD__|$BUILD|" -e "s|__FEED_URL__|$FEED_URL|" -e "s|__ED_KEY__|$ED_KEY|" \
    -e "s|<string>app.heron.Heron</string>|<string>$BUNDLE_ID</string>|" \
    packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Sign inside-out: framework, then the app. No hardened runtime with ad-hoc or Heron Signing: its
# library validation needs a Team ID, and a self-signed certificate has none, so dyld refused
# Sparkle ("different Team IDs", 2026-11-26).
OPTS=(--force --options runtime --sign "$SIGN_ID")
[[ "$SIGN_ID" == "-" || "$SIGN_ID" == "Heron Signing" ]] && OPTS=(--force --sign "$SIGN_ID")
codesign "${OPTS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${OPTS[@]}" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD, signed: $SIGN_ID)"

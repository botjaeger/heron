#!/bin/zsh
# Builds dist/Heron.app from the Swift package.
#
#   packaging/make-app.sh                 # release build, ad-hoc signed (runs on this Mac)
#   SIGN_ID="Developer ID Application: …" packaging/make-app.sh   # for distribution
#
# Optional environment:
#   VERSION, BUILD           version strings (default 1.0.0 / 1)
#   FEED_URL, ED_KEY         Sparkle appcast URL and EdDSA public key (updates stay off without them)
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
FEED_URL="${FEED_URL:-}"
ED_KEY="${ED_KEY:-}"
SIGN_ID="${SIGN_ID:--}"          # "-" = ad-hoc signature
APP="dist/Heron.app"

swift build -c release --product Heron
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/Heron" "$APP/Contents/MacOS/Heron"
cp -R ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
[[ -f packaging/AppIcon.icns ]] && cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

sed -e "s|__VERSION__|$VERSION|" -e "s|__BUILD__|$BUILD|" -e "s|__FEED_URL__|$FEED_URL|" -e "s|__ED_KEY__|$ED_KEY|" \
    packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Sign inside-out: framework, then the app.
OPTS=(--force --options runtime --sign "$SIGN_ID")
[[ "$SIGN_ID" == "-" ]] && OPTS=(--force --sign -)
codesign "${OPTS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${OPTS[@]}" --identifier app.heron.Heron "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD, signed: $SIGN_ID)"

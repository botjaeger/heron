#!/bin/zsh
# Builds Heron and installs it as /Applications/Heron.app. A Heron already running from there
# reloads itself into the new build within 2 s (BundleWatcher); otherwise this starts it.
#
#   packaging/install.sh
#
# Signs with this Mac's first "Apple Development" identity when there is one (a stable signature
# keeps Heron's Keychain access across builds, so macOS does not ask again after each install),
# else ad-hoc. SIGN_ID overrides it.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="/Applications/Heron.app"

if [[ -z "${SIGN_ID:-}" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ { print $2; exit }')"
    SIGN_ID="${SIGN_ID:--}"
fi
SIGN_ID="$SIGN_ID" packaging/make-app.sh

# Swap the new copy in whole, so the running app never sees a half-copied bundle.
rm -rf "/Applications/.Heron.app.installing" "/Applications/.Heron.app.old"
ditto dist/Heron.app "/Applications/.Heron.app.installing"
[[ -d "$DEST" ]] && mv "$DEST" "/Applications/.Heron.app.old"
mv "/Applications/.Heron.app.installing" "$DEST"
rm -rf "/Applications/.Heron.app.old"
echo "Installed $DEST"

# Running from /Applications: it reloads itself. Not running: start it. Another copy running
# (dist/, an older install elsewhere): say so; it has to be quit once by hand.
running="$(ps -axo comm= | grep -x '.*/Heron.app/Contents/MacOS/Heron' || true)"
if [[ -z "$running" ]]; then
    open "$DEST"
    echo "Started Heron"
elif echo "$running" | grep -qvx "$DEST/Contents/MacOS/Heron"; then
    echo "Another Heron is running (not from /Applications); quit it, then open $DEST:"
    echo "$running" | grep -vx "$DEST/Contents/MacOS/Heron"
else
    echo "Heron reloads into the new build within 2 s"
fi

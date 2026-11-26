#!/bin/zsh
# Publishes a release of Heron from this Mac, Rift's way: the build is signed with the self-signed
# "Heron Signing" certificate and the update feed with the Sparkle key, both only in this Mac's
# login keychain (docs.md › Distribution). Nothing secret reaches GitHub.
#
#   scripts/release.sh 1.1.0                 # a release
#   scripts/release.sh 1.1.1-beta.1          # a pre-release, for the Beta channel only
#   scripts/release.sh 1.1.0 --dry-run       # build and check everything, publish nothing
#
# It tags the pushed HEAD v<version>, builds Heron.app (Heron Signing) and Heron.dmg, writes
# appcast.xml (the update feed, signed) with the notes from Changelog.entries, publishes the
# GitHub release with both, then downloads them back and checks them.
#
# The feed every copy reads is the newest stable release's appcast.xml
# (releases/latest/download/appcast.xml). A stable release's feed holds that release alone; a
# pre-release adds its entry, marked <sparkle:channel>beta</sparkle:channel>, to the newest stable
# release's feed, since latest/download skips pre-releases.
set -euo pipefail

cd "$(dirname "$0")/.."
die() { echo "release: $*" >&2; exit 1; }

VERSION="${1:-}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "usage: scripts/release.sh <version, e.g. 1.1.0> [--dry-run]" >&2; exit 2; }
TAG="v$VERSION"
BETA=0
[[ "$VERSION" == *-* ]] && BETA=1

REPO="botjaeger/heron"
IDENTITY="Heron Signing"
SPARKLE=".build/artifacts/sparkle/Sparkle/bin"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
ED_KEY="$(<packaging/sparkle-ed.pub)"
OUT="dist/release"

# 1. Refuse what would publish the wrong thing (a dry run only warns about the tree and the tag).
refuse() { if (( DRY_RUN )); then echo "release (dry run, would stop): $*" >&2; else die "$*"; fi; }
[[ -z "$(git status --porcelain)" ]] || refuse "the tree has changes: commit them first"
git fetch --quiet --tags origin
COMMIT="$(git rev-parse HEAD)"
[[ -n "$(git branch -r --contains "$COMMIT")" ]] || refuse "$COMMIT is not on GitHub yet: push first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && refuse "tag $TAG already exists"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && refuse "release $TAG already exists"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || die "no \"$IDENTITY\" certificate in the keychain (docs.md › Distribution)"
[[ -x "$SPARKLE/sign_update" ]] || swift package resolve
[[ "$("$SPARKLE/generate_keys" --account heron -p 2>/dev/null)" == "$ED_KEY" ]] || die "the keychain's Sparkle key (account heron) is not the one in packaging/sparkle-ed.pub"

# 2. The notes, from the same Changelog.entries as What's New.
swift build -c release --product Heron >/dev/null
BIN="$(swift build -c release --show-bin-path)"
rm -rf "$OUT"; mkdir -p "$OUT"
"$BIN/Heron" changelog --notes "$VERSION" > "$OUT/notes.html" || die "add $VERSION to Changelog.entries (HeronUI/Dialogs.swift) first"

# 3. The app and the disk image, signed with the certificate: its designated requirement is the
#    same in every build, so the Keychain keeps Heron's access across updates.
BUILD="$(git rev-list --count HEAD)"
VERSION="$VERSION" BUILD="$BUILD" FEED_URL="$FEED_URL" ED_KEY="$ED_KEY" SIGN_ID="$IDENTITY" packaging/make-dmg.sh
codesign -d -r- dist/Heron.app 2>&1 | grep -q 'certificate leaf' || die "Heron.app is not signed with $IDENTITY"
cp dist/Heron.dmg "$OUT/Heron.dmg"

# 4. The feed: this release's entry, signed; a pre-release keeps the stable feed's own entries.
SIGNATURE="$("$SPARKLE/sign_update" --account heron "$OUT/Heron.dmg")"   # sparkle:edSignature="…" length="…"
[[ "$SIGNATURE" == *'sparkle:edSignature="'*'length="'* ]] || die "sign_update gave no signature"
{
    echo "        <item>"
    echo "            <title>Heron $VERSION</title>"
    echo "            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
    echo "            <sparkle:version>$BUILD</sparkle:version>"
    echo "            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
    echo "            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"
    (( BETA )) && echo "            <sparkle:channel>beta</sparkle:channel>"
    echo "            <description><![CDATA["
    cat "$OUT/notes.html"
    echo "            ]]></description>"
    echo "            <enclosure url=\"https://github.com/$REPO/releases/download/$TAG/Heron.dmg\" type=\"application/octet-stream\" $SIGNATURE/>"
    echo "        </item>"
} > "$OUT/item.xml"
: > "$OUT/kept.xml"
STABLE_TAG=""
if (( BETA )); then
    STABLE_TAG="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || true)"
    # The stable feed's entries, without any earlier beta's: one beta at a time.
    if curl -sfL "$FEED_URL" -o "$OUT/stable.xml"; then
        awk '/<item>/ { buf = ""; keep = 1; on = 1 } on { buf = buf $0 "\n"; if (/<sparkle:channel>/) keep = 0 } /<\/item>/ { if (keep) printf "%s", buf; on = 0 }' "$OUT/stable.xml" > "$OUT/kept.xml"
    fi
fi
{
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    echo '    <channel>'
    echo '        <title>Heron</title>'
    cat "$OUT/item.xml" "$OUT/kept.xml"
    echo '    </channel>'
    echo '</rss>'
} > "$OUT/appcast.xml"
xmllint --noout "$OUT/appcast.xml" || die "appcast.xml is not well-formed"
grep -q "<sparkle:shortVersionString>$VERSION<" "$OUT/appcast.xml" || die "appcast.xml lacks $VERSION"

if (( DRY_RUN )); then
    echo "Dry run: $OUT/Heron.dmg and $OUT/appcast.xml are ready; nothing was tagged or published."
    exit 0
fi

# 5. Publish: the tag (the pre-push hook runs the gates on it), then the release.
git tag -a "$TAG" -m "Heron $VERSION" "$COMMIT"
git push origin "refs/tags/$TAG"
PRE=()
(( BETA )) && PRE=(--prerelease)
gh release create "$TAG" "$OUT/Heron.dmg" "$OUT/appcast.xml" --repo "$REPO" --verify-tag --title "Heron $VERSION" --generate-notes "${PRE[@]}"
# A pre-release's entry reaches the Beta channel through the stable feed.
[[ -n "$STABLE_TAG" ]] && gh release upload "$STABLE_TAG" "$OUT/appcast.xml" --repo "$REPO" --clobber

# 6. Read back what people get: the feed names this version and the disk image is the one built.
mkdir -p "$OUT/check"
curl -sfL "https://github.com/$REPO/releases/download/$TAG/Heron.dmg" -o "$OUT/check/Heron.dmg"
cmp -s "$OUT/Heron.dmg" "$OUT/check/Heron.dmg" || die "the published Heron.dmg differs from the one built"
curl -sfL "$FEED_URL" | grep -q "<sparkle:shortVersionString>$VERSION<" || die "the live feed does not list $VERSION yet"
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"

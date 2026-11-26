#!/bin/zsh
# Releases Heron: tags the current commit v<version> and pushes the tag. GitHub Actions
# (.github/workflows/release.yml) then builds Heron.dmg and publishes it as a release; the website's
# Download button fetches the newest one (releases/latest/download/Heron.dmg).
#
#   scripts/release.sh 1.0.0              # a release
#   scripts/release.sh 1.1.0-beta.1       # a pre-release (the Download button skips it)
#
# Needs a clean tree whose commit is already on GitHub (push first, so the pre-push gates have run
# on it). To build the disk image on this Mac instead: packaging/make-dmg.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "usage: scripts/release.sh <version, e.g. 1.0.0>" >&2; exit 2; }
TAG="v$VERSION"

[[ -z "$(git status --porcelain)" ]] || { echo "The tree has changes: commit them first." >&2; exit 1; }
git fetch --quiet --tags origin
COMMIT="$(git rev-parse HEAD)"
[[ -n "$(git branch -r --contains "$COMMIT")" ]] || { echo "$COMMIT is not on GitHub yet: push first." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "Tag $TAG already exists." >&2; exit 1; fi

git tag -a "$TAG" -m "Heron $VERSION" "$COMMIT"
git push origin "refs/tags/$TAG"
echo "Pushed $TAG. GitHub Actions builds Heron.dmg and publishes the release:"
echo "  https://github.com/botjaeger/heron/actions/workflows/release.yml"

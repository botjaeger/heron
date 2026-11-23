#!/bin/zsh
# Points git at the hooks in .githooks (pre-commit: format + lint the staged files and build;
# pre-push: scripts/check.sh). Run once per clone; safe to run again.
set -euo pipefail

cd "${0:A:h}/.."

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    print "No git repository here yet, so there is nothing to hook into."
    print "After 'git init' (or in a clone), run: scripts/install-hooks.sh"
    exit 0
fi

chmod +x .githooks/pre-commit .githooks/pre-push scripts/check.sh
git config core.hooksPath .githooks
print "Hooks active: core.hooksPath = $(git config core.hooksPath) (pre-commit, pre-push)."

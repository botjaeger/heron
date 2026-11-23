#!/bin/zsh
# Heron's one gate runner. Runs the checks AGENTS.md lists, prints each step's time, and stops at
# the first failure.
#
#   scripts/check.sh           format lint, SwiftLint, debug build, release build, tests, heron-snap
#   scripts/check.sh --fast    format lint, SwiftLint, debug build (what pre-commit needs)
#   scripts/check.sh --fix     swift format in place, then swiftlint --fix, then swift format again
#
# Builds, tests and heron-snap use their own build folder (.build/gate) with warnings turned into
# errors: an incremental build does not print the warnings of files it skips, so grepping the
# output of a plain `swift build` would pass a warning compiled earlier. The output is grepped
# for `warning:` too (linker and package warnings are not errors).
#
# Never runs the smoke run, make-app.sh or install.sh: those stay manual (AGENTS.md).
set -euo pipefail
zmodload zsh/datetime

cd "${0:A:h}/.."

usage() { print "usage: scripts/check.sh [--fast | --fix]"; }

mode=full
case "${1:-}" in
    "") ;;
    --fast) mode=fast ;;
    --fix) mode=fix ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

paths=(Sources Tests Package.swift)
gate=(--scratch-path .build/gate -Xswiftc -warnings-as-errors -Xcc -Werror)
logs=$(mktemp -d "${TMPDIR:-/tmp}/heron-check.XXXXXX")
total=$EPOCHREALTIME

# step <name> <function> [hint]: runs it, prints its time, stops the script when it fails.
step() {
    local name=$1 fn=$2 hint=${3:-} t0=$EPOCHREALTIME
    print -n -- "==> $name ... "
    if $fn; then
        printf 'ok (%.1fs)\n' $((EPOCHREALTIME - t0))
    else
        printf 'FAILED (%.1fs)\n' $((EPOCHREALTIME - t0))
        print -u2 -- "check.sh: '$name' failed. Logs: $logs"
        [[ -n $hint ]] && print -u2 -- "$hint"
        exit 1
    fi
}

need() {
    command -v "$1" > /dev/null && return 0
    print -u2 -- "\n$1 is not installed. $2"
    return 1
}

# A build log with a `warning:` line fails, even when the build succeeded.
no_warnings() {
    local log=$1
    if grep -q "warning:" "$log"; then
        print -u2 -- "\nwarnings in $log:"
        grep "warning:" "$log" | sort -u >&2
        return 1
    fi
}

format_lint() {
    swift format lint --strict --recursive $paths > "$logs/format.log" 2>&1 && return 0
    print -u2 ""; cat "$logs/format.log" >&2
    return 1
}

swiftlint_lint() {
    need swiftlint "brew install swiftlint" || return 1
    swiftlint lint --strict --quiet > "$logs/swiftlint.log" 2>&1 && return 0
    print -u2 ""; cat "$logs/swiftlint.log" >&2
    return 1
}

build_debug() {
    if ! swift build --build-tests $gate > "$logs/build-debug.log" 2>&1; then
        print -u2 ""; grep -E "error:|warning:" "$logs/build-debug.log" | sort -u >&2 || tail -40 "$logs/build-debug.log" >&2
        return 1
    fi
    no_warnings "$logs/build-debug.log"
}

build_release() {
    if ! swift build -c release $gate > "$logs/build-release.log" 2>&1; then
        print -u2 ""; grep -E "error:|warning:" "$logs/build-release.log" | sort -u >&2 || tail -40 "$logs/build-release.log" >&2
        return 1
    fi
    no_warnings "$logs/build-release.log"
}

run_tests() {
    if ! swift test $gate > "$logs/test.log" 2>&1; then
        print -u2 ""
        grep -E "✘|error:|failed" "$logs/test.log" | head -60 >&2 || tail -60 "$logs/test.log" >&2
        return 1
    fi
    print -n -- "$(grep -E '^(✔|✘) Test run with' "$logs/test.log" | sed -E 's/^✔ Test run with ([0-9]+ tests in [0-9]+ suites).*/\1;/' | tr '\n' ' ')"
}

run_snap() {
    local out="$logs/snap"
    swift run $gate heron-snap "$out" > "$logs/snap.log" 2>&1 || { print -u2 ""; tail -40 "$logs/snap.log" >&2; return 1; }
    local count=$(ls "$out" | grep -c '\.png$' || true)
    (( count > 0 )) || { print -u2 -- "\nheron-snap wrote no PNGs"; return 1; }
    print -n -- "$count PNGs in $out "
}

fix_format() { swift format format --in-place --recursive $paths; }
fix_lint() {
    need swiftlint "brew install swiftlint" || return 1
    # Fixes what it can; what is left is printed by the next scripts/check.sh.
    swiftlint lint --fix --quiet > "$logs/swiftlint-fix.log" 2>&1 || { cat "$logs/swiftlint-fix.log" >&2; return 1; }
}

if [[ $mode == fix ]]; then
    step "swift format (in place)" fix_format
    step "swiftlint --fix" fix_lint
    step "swift format (after swiftlint)" fix_format
    rm -rf "$logs"
    printf 'Fixed (%.1fs). Run scripts/check.sh to see what is left.\n' $((EPOCHREALTIME - total))
    exit 0
fi

fixable="Fix the layout and the auto-fixable lint with scripts/check.sh --fix, then the rest by hand."
step "swift format lint --strict" format_lint "$fixable"
step "swiftlint --strict" swiftlint_lint "$fixable"
step "swift build (debug + tests, 0 warnings)" build_debug
if [[ $mode == full ]]; then
    step "swift build -c release (0 warnings)" build_release
    step "swift test" run_tests
    step "heron-snap" run_snap
    printf 'All full checks passed (%.1fs). Snapshots: %s/snap\n' $((EPOCHREALTIME - total)) "$logs"
else
    rm -rf "$logs"
    printf 'All fast checks passed (%.1fs).\n' $((EPOCHREALTIME - total))
fi

@AGENTS.md

## Claude Code

The rules above apply in full; `AGENTS.md` is the one place they are kept, so edit them there.
What follows is only how they play out in a Claude Code session.

- **Read first:** `README.md` (what Heron does), `docs.md` (how it is built), then the files the
  task touches.
- **Gates:** `scripts/check.sh` once, after all the work is done; `--fast` while working. Then
  `packaging/make-app.sh` + `codesign`, the smoke run as the last gate, and `packaging/install.sh`
  after every finished change. The maintainer runs the installed copy.
- **Report:** a verdict line, what changed, then every gate by name with its counts (tests run,
  warnings, `SMOKE FAIL` lines, idle CPU).
- **Subagents:** give each one the AGENTS.md safety rules verbatim (no smoke run, no install, no
  pattern kills, no real pointer, scratch defaults only) and verify its claims before relaying them:
  open the diff, re-run its tests.
- **UI changes:** mockup first; the maintainer reviews the design canvas, not the built app, so a UI
  change built in Swift goes to the mockup in the same turn.
- **Never** commit, push or branch unless asked; never run `git init` unasked.

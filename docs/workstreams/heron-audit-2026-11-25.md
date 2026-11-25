# Heron whole-project sweep — open items (2026-11-25)

Everything else the sweep found is fixed and guarded (see `heron-redesign-defect-classes.md`, rows
marked "2026-11-25 sweep"). These two needed a product decision; both were decided and fixed on
2026-11-26 (ledger rows "AUD-001" and "AUD-002").

## AUD-001 — Privacy Mode and the Settings window

- Status: FIXED 2026-11-26 (decision: cover every Heron window, Settings included)
- Trigger: Privacy Mode on, Settings › AI Usage open during a screen recording or share.
- Expected: unclear — Privacy Mode keeps the menu bar item, popover and panels out of screen
  recordings; the Settings window is not covered, and it lists account names (e-mail addresses).
- Actual: Settings shows account labels in recordings.
- Evidence: source (`AppDelegate.applySettings` privacy setter applies to the item, popover and
  panel windows only).
- Correction direction: either also set `sharingType = .none` on the Settings window while Privacy
  Mode is on, or state in the setting's hint that Settings is not covered.
- Acceptance: the chosen behaviour holds in a screen recording, and the setting's hint says so.

## AUD-002 — Cards before the first sample

- Status: FIXED 2026-11-26 (decision: keep the card, hide its numbers)
- Trigger: the popover opened within about a second of launch.
- Expected: AGENTS.md "No placeholders": a reading this Mac cannot provide hides; never "—" or "0".
- Actual: before the first sample the CPU, GPU, Memory and Disk cards draw "0" / "–"
  (`MenuBarLabel` cpu/gpu/memory/disk `?? "–"`, `OverviewCards` 279, `PopoverParts` 178).
- Evidence: source; a reading that will arrive is not a missing source, so the rule's intent is
  unclear here. Hiding the cards would make the overview jump when they appear.
- Correction direction: hide until the first sample, or keep the card and hide only its number
  (as the history page now does), or take one sample before the item and popover exist.
- Acceptance: no "–" or invented "0" on any card at launch, with no layout jump the maintainer
  rejects.

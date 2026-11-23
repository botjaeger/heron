# Heron — instructions for coding agents

Heron is a read-only menu bar system monitor for macOS 14+ on Apple silicon. Swift 6, SwiftPM,
SwiftUI + AppKit, Swift Testing, Sparkle for updates. `README.md` says what it does; `docs.md`
explains how it is built, where every number comes from, the checks and releases. Read both first.
This file holds the rules for changing it.

## Layout

| Target | What lives there |
|---|---|
| `CSystem` | C for private APIs with no Swift headers: SMC, HID sensors, IOReport |
| `HeronCore` | Samplers, `Snapshot` model, `MetricHistory` / `TieredHistory`, formatting, alerts. AI usage: `AIModels`, `AIProviders` (endpoints and mapping), `AIAuth` / `AISignInFlow` (sign-in), `AIStore` (Keychain, borrowed sign-ins), `AIUsageService` (refresh), `AIPriority` (pace, urgency ranking), `AIAlerts`, `AIUsageExport` (`Heron usage --json`). No UI |
| `HeronUI` | Every view: overview (`PopoverView`, `OverviewCards`, `OverviewSections`, `PopoverParts`, `HistoryViews`, `Summaries` for `FanSummary` / `SensorSummary`), detail panels (`DetailPanels`, `PanelRows`), menu bar item (`MenuBarLabel`), Settings (`SettingsView`, `SettingsParts`, one file per pane: `SettingsMenuBar`, `SettingsOverview`, `SettingsAlerts`, `SettingsUpdates`), `AboutView`, AI usage (`AICard`, `AIPanel`, `SettingsAIUsage`, `SettingsMenuBarAI`, `SettingsOverviewAI`, `AISettings`, `ProviderMarks`), icons, `Theme`, `Warnings` |
| `Heron` | The app: `StatusBarController` (status item, popover, panel; its smoke hooks in `StatusBarController+Smoke`), `DetailPanelWindow`, `WindowManager`, notifications, Sparkle |
| `heron-probe` | Prints every reading once. Prove a new data source here before any UI uses it |
| `heron-snap` | Renders every screen to PNG in light and dark |

## Commands

```sh
scripts/check.sh                              # the one gate runner: format lint, swiftlint, the builds, swift test, heron-snap
scripts/check.sh --fast                       # format lint, swiftlint, debug build (what pre-commit runs)
scripts/check.sh --fix                        # swift format in place, then swiftlint --fix
scripts/install-hooks.sh                      # once per clone: pre-commit (staged files) and pre-push (check.sh) hooks
```

`scripts/check.sh` runs these, in this order, timing each and stopping at the first failure (its
builds use `.build/gate` with warnings as errors, so a warning cached by an earlier build still fails):

```sh
swift format lint --strict --recursive Sources Tests Package.swift
swiftlint lint --strict
swift build                                   # debug, every target; must have 0 warnings
swift build -c release
swift test                                    # unit, guard and live cross-check tests
swift run heron-snap <folder>                 # every screen, light + dark
```

These stay by hand; `check.sh` never runs them:

```sh
swift run heron-probe                         # every reading once
packaging/make-app.sh && codesign --verify --deep --strict dist/Heron.app
HERON_SMOKE_SECONDS=8 swift run Heron         # end to end; opens real windows (see below)
packaging/install.sh                          # last: installs /Applications/Heron.app; the running one reloads itself
```

Run the full set once, after all work is done, before saying it is finished. Name each gate and
its counts in the report. Then run `packaging/install.sh` after every finished change: the
maintainer runs the installed copy and never quits or reopens it by hand (`BundleWatcher` reloads
Heron within 2 s when the installed copy is replaced).

## Product rules

- **One status item.** Heron has a single `NSStatusItem`: the Heron glyph, plus whichever metrics
  the user turned on, drawn inside it. Never add per-metric status items or a "combine" toggle; a
  new metric is a new `MenuItemKind` with variants in `MenuBarLabel`.
- **The popover is the overview.** There are no tabs. Each section is a card; hovering it (or
  clicking, or ↑ ↓ → Return) opens its detail panel beside the popover. Order and hidden sections
  come from `AppSettings.overviewOrder` / `hiddenSections`.
- **Read-only.** Never write the SMC, pmset, powerd files or any system default; no root helper,
  no `SMAppService.daemon`. Guard: `heronHasNoWayToWriteTheSMC`.
- **AI sign-ins.** Heron's own sign-ins live in its Keychain service `app.heron.ai.accounts`. A
  borrowed Claude Code or Codex sign-in is read each time and never renewed or written back (a
  renewal would sign the CLI out). The only AI network calls are the providers' endpoints in
  `AIProviders.swift`; spending a limit reset always asks first.
- **No placeholders.** A reading this Mac cannot provide hides its row, card or menu bar item. Never
  show "—", "0 rpm" or invented values. Panel rows are built in `PanelRows.swift`; menu bar items
  are filtered by `MenuBarLabel.hasSource`.
- **One source per reading.** Temperatures come from `SensorSummary`, fans from `FanSummary`,
  battery temperature from `Snapshot.batteryCelsius`. A value shown in several places (menu bar,
  card in every style, panel, history) comes from the same helper.
- **One rule per warning.** "Too hot", "nearly full" and "low battery" live in `Warnings.swift`
  only. Never write a threshold literal anywhere else.
- **Everywhere or nowhere.** A change to one piece of data goes to every surface that shows it:
  menu bar, overview card in every style, its panel, its history, the Settings previews.
- **Colours live in `Theme.Palette`.** Text reaches 4.5:1 on every surface in `textBackgrounds`;
  white glyphs on fixed fills 3:1. No hex anywhere else.
- **Heron's own design language.** Screenshots of other apps show wanted behaviour, never the
  look. Build from `Card`, `IconTile`, `BigRing`, `MetricHeader`, `KeyValueRow` and the palette.
- **Local time.** Every day, date and time shown is in the user's time zone; never a "(UTC)" label.
  When a provider only reports UTC days, find a local source (Codex: the CLI's session logs).
  Guard: `NoUTCLabelsTests`.
- **Mockup first.** A UI change starts as a mockup the maintainer approves, then is built in Swift;
  the maintainer's mockups are kept in step with the app.

## Engineering rules

- Follow the patterns already here; smallest change that does the job; keep existing comments.
- Format and lint are clean: `swift format lint --strict` and `swiftlint lint --strict` report
  nothing. New code follows `.swift-format` and `.swiftlint.yml`; `scripts/check.sh --fix` applies
  both. A rule is switched off only in those files, with its reason in `docs/tooling.md`; the
  three custom SwiftLint rules mirror guard tests (`NoGlobalFramesTests`,
  `PaletteOnlyColoursTests`, `NoLeakedDefaultsTests`), which stay.
- Every new setting goes into `AppSettings.keys`, `reset()` and a Settings pane (guards:
  `SettingsKeyListTests`, `ResetCoversEverySettingTests`, `everySettingBelongsToAPane`).
- Read SwiftUI frames in a named coordinate space, never `.global` (inside the popover, global is
  the window, 13 pt off the hosting view). Guards: `CardFrameSpaceTests`, `NoGlobalFramesTests`.
- Menu bar values keep a fixed width (no jitter) and sit right after their tag. Guards:
  `MenuBarWidthTests`, `MenuBarTightnessTests`.
- Tests use their own `UserDefaults` suites through `scratchDefaults(_:)`; never touch the user's
  real defaults domains. Guard: `NoLeakedDefaultsTests`.
- Every new test is negative-controlled: break what it guards, watch it fail, restore the file
  byte for byte.
- A defect is a class: find every sibling site, fix them all, add or extend a guard test, and add a
  row to `docs/workstreams/heron-redesign-defect-classes.md`.
- New data: add it to `heron-probe`, run it on a real Mac, paste the output, then build UI.
- Look at the `heron-snap` PNGs in both modes after any UI change; tests don't catch layout.
- Docs move with the code: a new data source goes in `docs.md`'s source table, a new command in
  the Commands above and `docs.md` › Checks, a new feature in `README.md` › Features.

## Safety

- The smoke run (`HERON_SMOKE_SECONDS`) opens windows on the user's screen and takes focus. Run it
  only as the final gate. It drives the popover with posted events; never move the real pointer
  or post CGEvents.
- Never kill processes by pattern; stop only processes you started.
- Never commit, push or branch unless asked.

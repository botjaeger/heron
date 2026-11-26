# Heron developer docs

How Heron is built, where every number comes from, and how to check, release and learn from it.
The product overview is in [README.md](README.md). The rules for changing the code are in
[AGENTS.md](AGENTS.md), which Claude Code also reads through [CLAUDE.md](CLAUDE.md).

- [Architecture](#architecture)
- [Where each number comes from](#where-each-number-comes-from)
- [AI plan usage](#ai-plan-usage)
- [Hardware quirks the code handles](#hardware-quirks-the-code-handles)
- [Checks](#checks)
- [Updates (Sparkle)](#updates-sparkle)
- [Website](#website)
- [Distribution](#distribution)
- [Learning Swift with this code](#learning-swift-with-this-code)
- [More docs](#more-docs)

## Architecture

```
Sources/
  CSystem/      C: SMC (fans, temperatures), HID temperature sensors, IOReport energy. Private APIs.
  HeronCore/    Swift, no UI: one sampler per subsystem, Snapshot model, history, alerts, AI usage.
  HeronUI/      SwiftUI: overview and detail panels, menu bar item, Settings, AI usage, icons, theme, warnings.
  Heron/        The app: status item, popover, detail panel windows, windows, notifications, Sparkle,
                the AI shortcut, reload on install, `Heron usage --json`.
  heron-probe/  CLI that prints every reading once.
  heron-snap/   Renders every screen to PNG (light and dark) and the app icon.
Tests/          HeronCoreTests (samplers, maths, AI parsing) and HeronUITests (views, settings, guards).
packaging/      Info.plist, AppIcon.icns, make-app.sh, install.sh, make-dmg.sh
scripts/        check.sh (the gate runner), install-hooks.sh, release.sh
site/           The website: index.html and real screen renders (see Website)
```

**Data flow.** `Monitor` (HeronCore, `@MainActor`) owns the samplers. A timer fires every second;
the samplers run on one serial background queue (`Samplers`, never touched anywhere else) and the
result is applied on the main thread as a `Snapshot` plus a 24-hour `MetricHistory`. Views read
them through Observation (`@Observable`) and redraw on their own. After each sample the app redraws
the menu bar item (only when its picture changes) and evaluates the alert rules.

**History.** One value per second whatever the sampling interval, so "10 min" always covers ten
minutes. The main graphs keep every second for 24 hours. Panel rows (power rails, memory parts,
sensor groups, fans) keep a `TieredHistory`: every second for 10 minutes, 10-second averages for an
hour, 2-minute averages for 24 hours.

**Menu bar.** One status item. By default it is the Heron icon alone; Settings › Menu Bar turns on
metrics drawn inside it, each in a variant: CPU, GPU and memory as a labelled bar, a percentage, a
bar graph or a gauge; memory used or available GB and pressure; the hottest, CPU, GPU or SSD
temperature; network up and down; disk free, used or %; fans in rpm or % of maximum; the battery
icon and %; AI plan limits. Plus colour, spacing, the icon and "turn red" options.

**Popover and panels.** Clicking the item opens the overview: every section as a card in
Settings › Overview order. Resting the pointer on a card (or clicking it, or ↑ ↓ → Return) opens its
detail panel beside the popover; resting on a row with a history opens that history beside the
panel, like a submenu, 1 minute to 24 hours. Esc steps back. A closed popover and hidden panels let
go of their views, so Heron idles at about 1% CPU.

**Concurrency.** Swift 6 language mode with strict data-race checking. UI types are `@MainActor`;
anything `@unchecked Sendable` or `nonisolated(unsafe)` carries a comment saying why it is safe.

## Where each number comes from

| Reading | Source | Public API? |
|---|---|---|
| CPU per core | `host_processor_info`; P/E cores from `IODeviceTree:/cpus` `cluster-type` | yes |
| Memory | `host_statistics64(HOST_VM_INFO64)`, swap `vm.swapusage`, pressure `kern.memorystatus_vm_pressure_level`, pressure % from `kern.memorystatus_level` | yes |
| Disk | `FileManager.mountedVolumeURLs`, throughput and bytes since boot from `IOBlockStorageDriver` "Statistics" | yes |
| Network | `sysctl(NET_RT_IFLIST2)` (64-bit counters), primary interface from SystemConfiguration | yes |
| Battery | `IOPSCopyPowerSourcesInfo` + `AppleSmartBattery` registry (`BatteryData` for health) | yes |
| Top processes | `proc_listallpids` + `proc_pid_rusage` (CPU time converted with the mach timebase) | yes |
| GPU | `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %` | undocumented |
| Temperatures | SMC `T…` keys (fallback: HID sensors, page 0xff00 usage 5) | private |
| Fans | SMC `FNum`, `F<n>Ac/Mn/Mx/Tg` | private |
| Power | IOReport "Energy Model" (`CPU Energy`, `GPU Energy`, `ANE…`, `DRAM…`, display engines `DISP…`) | private |
| CPU clocks | IOReport "CPU Stats" state residency, frequency tables from the `pmgr` registry entry (`voltage-states1/5-sram`) | private |
| Charge limit | powerd's `/Library/Preferences/com.apple.powerd.charging.plist` (`manualChargeLimit` policy), read only | undocumented |
| Claude usage | `api.anthropic.com/api/oauth/usage` (5 hours, Weekly, Sonnet, scoped models, Extra usage), `…/usage?cedar_ember=1` (limit resets and their kind), `/api/oauth/profile` (plan) | undocumented |
| ChatGPT usage | `chatgpt.com/backend-api/wham/usage`, `…/rate-limit-reset-credits`, `…/analytics/daily-workspace-usage-counts` (tokens, last 30 days); Today and Yesterday in local days from the Codex CLI's session logs (`$CODEX_HOME/sessions/**/*.jsonl`, `token_count` events), read only | undocumented |
| OpenCode usage | `opencode.ai/zen/go/v1/usage`, `/console/api/go/status` (plan) | undocumented |

Heron never writes the SMC, pmset or any system setting, and has no root helper.

## AI plan usage

Claude, ChatGPT (Codex) and OpenCode limits, following [OpenUsage](https://github.com/robinebers/openusage)
(MIT): the same endpoints, sign-in flows and ranking rules, in Heron's own design.

- **Sign-ins.** Browser sign-in (Claude, ChatGPT) or a device code (OpenCode); tokens live in
  Heron's own Keychain items (`app.heron.ai.accounts`) and renew themselves. "Use Claude Code's
  sign-in" / "Use Codex's sign-in" borrow the login the CLI saved: read each time, never renewed or
  written back (a renewal would sign the CLI out).
- **Refresh.** Every 5 minutes, one request per account at a time, with backoff and `Retry-After`.
  Nothing else leaves the Mac; the only AI network calls are the endpoints in `AIProviders.swift`.
- **The panel.** Every account's limits, money and tokens. The overview card shows the most urgent
  limits (pinned, then running out, then burning fast), the ones pinned, or the ones you chose.
- **Limit resets.** Each reset says what it refills: Claude marks grants as 5-hour, weekly, Fable
  or full (`ClaudeAPI.kind`, the rule Claude Code uses); ChatGPT credits always refill the 5-hour
  and weekly limits (full). Which rows a reset refills comes from the grant's `clears` (Claude) or
  is both limits (ChatGPT), kept as `AIResetGrant.refills`. The "Limit resets" row opens beside the
  panel like a history (`HistorySource.aiResets`, `AIResetsPage`): a 30-day strip of when each
  reset runs out and when each limit it refills refills itself or is out (`AIResetPlan`), one
  sentence on what matters most, each kind with what it would give back now, and "Use…".
  Hovering the strip lights the day under the pointer and reads it out (`AIResetPlan.day(at:)`):
  the date, how many days away, and the resets running out, refills and time out on it. Amber
  when a reset runs out within 7 days (`Warnings.resetSoon`). Spending one always asks first.
- **Local time.** Every day Heron shows is a local day. ChatGPT's analytics only has whole UTC days
  (`group_by` takes day, week or month; no hours), so Today and Yesterday come from the Codex CLI's
  own logs; checked against ChatGPT's totals on real data.
- **Command line.** `Heron usage --json` prints the last readings, including each reset's kind.

## Hardware quirks the code handles

Learned on an M3 Max:

- Dozens of SMC temperature keys report a fixed 40.0 °C (unused slots). Whole-number values shared
  by 4+ keys are dropped (`SensorNaming.droppingPlaceholders`).
- Idle CPU clusters' keys switch between real values and -4.0 °C, so every reading (not only the
  start-up scan) is filtered to 5–130 °C (`SensorNaming.plausible`).
- There are 58 CPU hotspots; single ones touch 99 °C under ordinary load. A component's temperature
  is the average of its sensors (`SensorStats`); "Hottest sensor" is the maximum.
- 160 of 274 temperature keys have no known name; they are only read while Settings › Overview ›
  Sensors › "Hide unnamed" is off.
- Binned chips skip core numbers (no `cpu9`), so cores are ordered by `cpu-id`, not by name.
- IOReport energy arrives in lumps every ~2 s; `PowerWindow` averages lumps over 10 s.
- The energy model has 300+ channels; `CPU Energy` already contains `EACC_CPU`/`PACC*_CPU`.
- The kernel's page size (16 KB) comes from `host_page_size`, the unit of `host_statistics64` counts.

## Checks

`scripts/check.sh` is the one gate runner. It runs these in order, timing each and stopping at the
first failure; its builds use `.build/gate` with warnings as errors, so a warning cached by an
earlier build still fails.

| Check | Command |
|---|---|
| Formatting (`.swift-format`) | `swift format lint --strict --recursive Sources Tests Package.swift` |
| Lint (`.swiftlint.yml`; `brew install swiftlint`) | `swiftlint lint --strict` |
| Site links: every local file and in-page `#anchor` `site/index.html` links to exists | (in `check.sh`) |
| Debug build, every target, 0 warnings | `swift build` |
| Release build | `swift build -c release` |
| Tests (unit, guards, live cross-checks on this Mac) | `swift test` |
| Every screen in light and dark, as PNG | `swift run heron-snap <folder>` |

`--fast` runs format, lint, site links and the debug build (the pre-commit hook runs the same on
the staged Swift files, without site links; pre-push runs the full set); `--fix` applies the
formatter and SwiftLint's autofixes (always run the full gate after it: one autofix once broke the
build). `scripts/install-hooks.sh` turns on `.githooks` in a git clone: pre-commit checks the
staged files, pre-push runs the full `check.sh`. Formatter and linter choices and their reasons:
[docs/tooling.md](docs/tooling.md).

By hand, never in `check.sh`:

| Check | Command |
|---|---|
| Every reading once | `swift run heron-probe` |
| Bundle and signature | `packaging/make-app.sh` then `codesign --verify --deep --strict dist/Heron.app` |
| App end to end, quits by itself | `HERON_SMOKE_SECONDS=8 swift run Heron` |
| Install (the running copy reloads itself within 2 s) | `packaging/install.sh` |

**The smoke run** opens every window, the popover and a detail panel, logs where the panel sits
against its card, drives the popover with posted events (a click on a panel row, Esc three times, a
click outside), checks that the closed popover and hidden panels let go of their views, that
Privacy Mode hides every window and the Settings sheet from recordings (the status item's own window
ignores it on macOS 27.2), that the first readings have arrived, and measures idle CPU with
everything closed. Any `SMOKE FAIL:` line is a failure. It never moves the
real pointer, but it does put windows on your screen for a few seconds.

**Live tests** (`LiveCrossCheckTests`) compare the public readings with a second, independent
macOS API (our 64-bit network counters with `getifaddrs`, our CPU load with `host_statistics`,
memory with `sysctl`, the startup disk with `statfs`, the battery with its registry entry), so a
parsing mistake shows up as a mismatch instead of a believable wrong number. Readings with no second
source are held to their own bounds: fans within their minimum and maximum, CPU clocks inside their
frequency tables, disk totals since boot only growing.

**Guard tests** enforce whole classes of past defects: one source per reading, one rule per
warning, colours only from the palette, no `.global` frames, every setting reset and shown in
Settings, no "(UTC)" labels, and more. Each class, its rule, its guard and every instance found are
listed in [docs/workstreams/heron-defect-classes.md](docs/workstreams/heron-defect-classes.md) and
[docs/workstreams/heron-redesign-defect-classes.md](docs/workstreams/heron-redesign-defect-classes.md).
Every new test is negative-controlled: break what it guards, watch it fail, restore byte for byte.

## Updates (Sparkle)

Sparkle refuses to run without a signing key, so updates stay off until you set one up:

1. `./.build/artifacts/sparkle/Sparkle/bin/generate_keys` stores the private key in your Keychain
   and prints the public key.
2. Host an appcast (for example on GitHub Releases) and build with
   `FEED_URL=https://…/appcast.xml ED_KEY=<public key> packaging/make-app.sh`.
3. For each release: `./.build/artifacts/sparkle/Sparkle/bin/generate_appcast <folder of zips>`.
   Beta builds go in the appcast with `<sparkle:channel>beta</sparkle:channel>`; Settings › Updates
   › Beta opts in.

After an update Heron opens "What's New" once; add the release to `Changelog.entries`
(`HeronUI/Dialogs.swift`).

## Website

`site/` is the website: one static `index.html` (no build step, system fonts, no libraries) and
the app's own screens in `site/img`. `.github/workflows/pages.yml` publishes it to GitHub Pages when
`site/` changes on `main` (Settings › Pages › Source: GitHub Actions; the free plan needs a public
repo). `scripts/check.sh` checks that every local file the page links to exists.

- **One moving piece.** Scrolling builds the menu bar item part by part, magnified in a loupe under
  it, then "clicks" it and the overview drops down. The wallpaper behind it is the Heron gauge as
  tone-on-tone paper and stays background; nothing else on the page animates.
- **Screens are real renders.** Refresh them with `swift run heron-snap <folder>` and copy
  `popover-overview`, `panel-sensors` and `ai-popover-card` (`-light` and `-dark`) into `site/img`,
  then update the image `alt` text and the "rendered on" note to the new readings.
- **Never publish a render that shows your own data**: the CPU and memory panels list your running
  processes, and real AI accounts show their names. Use the example accounts (`heron-snap` fixtures).
- **Claims stay true.** No feature, release or number on the page that the app or repo does not have.

## Distribution

Without an Apple Developer account, `packaging/make-app.sh` makes an ad-hoc signed app. People who
download it must allow it once in System Settings › Privacy & Security before it opens.

Every release ships a disk image on GitHub Releases, built by GitHub Actions. After the release
commit is pushed (so the pre-push gates ran on it), `scripts/release.sh 1.2.0` tags it `v1.2.0`
and pushes the tag. `.github/workflows/release.yml` then runs `packaging/make-dmg.sh` (Heron.app
plus a link to Applications, mounted and checked) on a macOS runner with its newest released
Xcode, and publishes the release with `Heron.dmg` attached. The asset keeps one name, so the
website's Download button (`releases/latest/download/Heron.dmg`) always gets the newest release; a
version with a suffix (`1.2.0-beta.1`) is published as a pre-release, which that link skips.
Running the workflow by hand (Actions › Release › Run workflow) builds the disk image without
releasing it; `packaging/make-dmg.sh` builds the same one on this Mac.

With a Developer ID: `SIGN_ID="Developer ID Application: …" packaging/make-app.sh`, then notarize
the zip with `xcrun notarytool submit … --wait` and `xcrun stapler staple dist/Heron.app`. For
releases, the certificate and notarization would move into the workflow as repository secrets.

The app icon is drawn from code (`HeronShape`, `HeronMark`); regenerate it with
`swift run heron-snap --icon packaging/AppIcon.icns`.

## Learning Swift with this code

A reading order, each file small enough for one sitting:

1. `HeronCore/Models.swift`: structs, optionals, computed properties.
2. `HeronCore/Format.swift` and `Tests/HeronCoreTests/MathTests.swift`: pure functions and Swift
   Testing (`@Test`, `#expect`).
3. `HeronCore/CPUSampler.swift`: calling C APIs, pointers, `defer`, wrap-around arithmetic (`&-`).
4. `HeronCore/History.swift`: value types and `mutating`.
5. `HeronCore/Monitor.swift`: `@Observable`, `@MainActor`, timers, background queues (Swift 6
   strict concurrency).
6. `HeronUI/PopoverView.swift`, then `OverviewCards.swift` and `OverviewSections.swift`: SwiftUI
   layout, `@Environment`, `ForEach`.
7. `HeronUI/SettingsView.swift` and `SettingsParts.swift` (one file per pane: `SettingsMenuBar`,
   `SettingsOverview`, `SettingsAlerts`…): `@Bindable`, bindings, `Binding(get:set:)`, a custom
   sidebar, drag and drop.
8. `Heron/StatusBarController.swift`: AppKit interop (`NSStatusItem`, `NSPopover`,
   `NSHostingController`).

## More docs

| File | What it holds |
|---|---|
| [AGENTS.md](AGENTS.md) | Rules for changing the code: product rules, engineering rules, safety |
| [CLAUDE.md](CLAUDE.md) | Claude Code's entry point; imports AGENTS.md |
| [docs/tooling.md](docs/tooling.md) | Why each formatter and linter setting is what it is |
| [docs/workstreams/](docs/workstreams/) | Defect-class ledgers: every class, its rule, its guard, its instances |

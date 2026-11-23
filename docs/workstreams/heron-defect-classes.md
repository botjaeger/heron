# Heron — defect classes

One row per class of defect. Each class has a rule, a guard that fails when a new site breaks
the rule, and the sites found so far. Before a sweep, re-check every class across the whole app.

| Class | Rule | Guard (test) | Instances (found → fixed) |
|---|---|---|---|
| Implausible sensor readings | Every temperature reading, at the scan AND on every read, passes `SensorNaming.plausible` (5–130 °C, no shared placeholder). | `SensorIdentityTests.slotsThatGoIdleAfterTheScanDoNotCount`, `liveCPUTemperatureHasNoImplausibleSensors`, `implausibleHIDReadingsAreDropped` | SMC per-read (−4.0 °C idle slots, CPU average 45 instead of 82 °C); HID (−1.6 °C) — 2026-11-20 |
| Component temperature = hotspot | Component temperatures (menu bar, popovers, alerts, fan curves) are the average of the group (`SensorStats`); only "Hottest" and fan safety use the maximum. | `ComponentTemperatureTests` (3 tests) | Alert value, SensorSummary, fan curve input — 2026-11-20 |
| Non-unique list ids | Every sensor id is unique for any input (SwiftUI keys lists by id). | `SensorIdentityTests.idsAreUniqueEvenWhenTheSystemRepeatsANameOrKey` | HID duplicate names; SMC duplicate keys — 2026-11-20 |
| Menu bar width jitter | Every value in the menu bar item is drawn in a box as wide as its widest value (`MenuBarSegment.Widest`). | `MenuBarWidthTests.everyMetricKeepsItsWidthAsValuesChange` (all kinds × styles, plus all at once) | Every text value — 2026-11-20 |
| Temperature unit leaks | Temperatures are stored in °C; every place that shows or takes one converts with `Format.converted` / `Format.celsius`, or names °C explicitly. | `AlertEngineTests.temperatureLimitsFollowTheDisplayUnit` | Alert summaries, alert editor limit and "Now", fan curve axis, safety texts — 2026-11-20 |
| Text contrast | Every text colour in `Theme.Palette.text` reaches 4.5:1 on every surface in `textBackgrounds`, both modes; badge text too. | `ContrastTests.textColoursMeetAAInBothModes` | Light CPU / network / warning, dark warning / CPU / muted / GPU, menu bar badge — 2026-11-20 |
| Hardware write path | Heron only reads. No source file may contain an SMC write, `Ftst` or a privileged daemon (`SMAppService.daemon`): fan control needs a Developer ID–signed root helper, so it was removed. | `ComponentTemperatureTests.heronHasNoWayToWriteTheSMC` (scans `Sources/`) | Fan control, root helper, `heron_smc_write` removed 2026-11-20 (replaces the retired "stale helper state" class) |
| Interval-dependent time axis | History stores one slot per second; graphs ask for seconds, never samples. | `HistoryTimeAxisTests` (4 tests) | `MetricHistory.series` at 0.5 s and 5 s sampling — 2026-11-20 |
| Missing key equivalents | The app sets a main menu carrying Edit (⌘X/C/V/A/Z) and Window (⌘W/⌘M) items. | `MainMenuTests` (with an empty-menu control) | No main menu at all — 2026-11-20 |
| Unvalidated stored settings | Stored values the UI cannot show fall back to a default; lists are one entry per kind. | `SettingsGuardTests` | `interval`, `menuItems` duplicates — 2026-11-20 |

Every guard above was negative-controlled on 2026-11-20: the fix was removed, the guard failed,
the file was restored byte for byte.

# Tooling: formatter, linter, gate, hooks

| Role | Tool | Config | Run |
|---|---|---|---|
| Formatter (prettier) | `swift format` (in the Swift 6 toolchain) | `.swift-format` | `scripts/check.sh --fix` |
| Linter (eslint) | SwiftLint (`brew install swiftlint`) | `.swiftlint.yml` | `scripts/check.sh --fast` |
| Gate | `scripts/check.sh` | — | before saying work is done; pre-push |
| Hooks | `.githooks/pre-commit`, `.githooks/pre-push` | `git config core.hooksPath .githooks` | `scripts/install-hooks.sh` once per clone |

JSON has no comments, so the reasons for `.swift-format` live here.

## `.swift-format`

swift-format's defaults, except where a default fights a deliberate, consistent style in this code:

| Setting | Value | Why |
|---|---|---|
| `indentation` | 4 spaces | the code is written in 4 |
| `lineLength` | 180 | the code keeps a call, its arguments and a short trailing comment on one line; 100 would wrap most view modifiers |
| `DoNotUseSemicolons` | off | short paired statements share a line on purpose: `failures[id] = nil; waitUntil[id] = nil` |
| `OneVariableDeclarationPerLine` | off | related values are declared together: `let ink = …, bgs = …` |
| `OneCasePerLine` | off | small enums are one line: `enum ClaimOutcome { case done, nothingToReset, unavailable(String) }`; the rule splits every case with an associated value onto its own line |
| `EndOfLineComment` | removed | not a rule in swift-format 6.4; the entry only printed a warning per file |

Everything else is the default. What the formatter does and cannot be configured away:

- An `if`/`else` chain whose branches sit on separate lines (`if a { x }` newline `else { y }`)
  becomes `} else {` blocks. A whole chain that fits on one line stays on one line.
- A condition that wraps gets its `{` on a line of its own.
- Aligned trailing comments lose their alignment (two spaces before `//`).
- Imports are sorted; multi-line collections get a trailing comma.

## `.swiftlint.yml`

SwiftLint checks code, not layout; layout is swift-format's.

Switched off because they disagree with swift-format's output:
`line_length` (swift-format's `lineLength` owns it), `trailing_comma` (swift-format adds them),
`opening_brace` (the `{` after a wrapped condition), `statement_position` (a comment kept between `}`
and `else`), `vertical_parameter_alignment` (swift-format indents wrapped parameters by 4).

Switched off for the house style: the size metrics (`file_length`, `type_body_length`,
`function_body_length`, `cyclomatic_complexity`, `function_parameter_count`, `large_tuple`; one file
per pane and long view builders are intended) and `for_where` (as swift-format's
`UseWhereClausesInForLoops`).

Switched off on its first run (2026-11-23): `optional_data_string_conversion`. Heron decodes C
buffers, sysctl strings, session logs and HTTP bodies with `String(decoding:as:)` on purpose: it
repairs a bad UTF-8 byte instead of dropping the whole reading, which the failable init would do.

Tuned: `identifier_name` allows one-letter names (`x`, `s`, `a` in short scopes) and long Swift
Testing names; `type_name` allows long suite names; `nesting` allows the nested types SwiftUI views use.

Opt-in rules: the cheap correctness and clarity ones (`empty_count`, `first_where`, `last_where`,
`contains_over_*`, `sorted_first_last`, `redundant_nil_coalescing`, `toggle_bool`,
`fatal_error_message`, `implicitly_unwrapped_optional`, `empty_string`, `empty_collection_literal`,
`flatmap_over_map_reduce`, `identical_operands`, `joined_default_parameter`, `legacy_multiple`,
`legacy_random`, `yoda_condition`, `unavailable_function`, `prefer_self_type_over_type_of_self`).
Not on: `force_unwrapping` (`URL(string: "https://…")!` on constants is used throughout),
`discouraged_optional_boolean` (`Bool?` is a deliberate three-state in places), `unused_import`
(needs `swiftlint analyze` with a compiler log, not `lint`).

Custom rules, each mirroring a guard test that stays (the rule reports sooner, the test is the proof):

| Rule | AGENTS.md rule | Guard test |
|---|---|---|
| `no_global_coordinate_space` | read frames in a named space, never `.global` | `NoGlobalFramesTests` |
| `no_hex_colour_outside_theme` | colours live in `Theme.Palette` (the Settings tile table excepted) | `PaletteOnlyColoursTests.noHexColourOutsideTheTheme` |
| `no_standard_defaults_in_tests` | tests never touch the user's defaults (removing a scratch domain is allowed) | `NoLeakedDefaultsTests` |

## `scripts/check.sh`

`--fast`: format lint, SwiftLint, debug build. Default: those, then the release build, `swift test`
and `heron-snap` into a temporary folder (about two minutes warm). `--fix`: `swift format` in place,
`swiftlint --fix`, then `swift format` again (SwiftLint's fixes can undo layout).

The builds, tests and heron-snap use their own build folder, `.build/gate`, with
`-warnings-as-errors` (Swift) and `-Werror` (C): an incremental `swift build` prints nothing for the
files it skips, so grepping its output would pass a warning compiled earlier. The output is still
grepped for `warning:` (linker and package warnings are not errors). The first run builds
`.build/gate` from scratch; after that it is incremental.

## Hooks

`pre-commit` writes the staged versions of the staged `.swift` files to a scratch folder (so a
partly staged file is checked as it will be committed), runs `swift format lint --strict` and
`swiftlint lint --strict` on them, then the 0-warning debug build of the working tree. `pre-push`
runs `scripts/check.sh`. Neither is active until `scripts/install-hooks.sh` runs inside a git
repository.

`swiftlint --fix` is not trusted blindly: on its first run (2026-11-23) `empty_count` rewrote
`count == 0` to `isEmpty` where `count` was a plain `Int` property (the history ring's fill level,
the reset count), which no longer compiled. `scripts/check.sh --fix` is always followed by the full
`scripts/check.sh`; those two sites carry `// swiftlint:disable:next empty_count` with the reason.

# Changelog - Forge

All notable changes across the Forge family (parent + every sub-addon).
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions are sequential build numbers (+1 per release.ps1 run).

This is the **single source of truth**. Per-sub-addon CHANGELOG.md files
were consolidated here on 2026-05-05; new entries go in this file with
a `(Component)` tag identifying which sub-addon changed.

The in-game Changelog tab mirrors this file.

## [6] - 2026-05-05

### Added
- `Forge.Changelog`: in-game Changelog tab. Pulls release notes into a
  scrollable view so users can see what changed without leaving WoW.
- `Cairn.Locale` dev override: `/forge locale <code>` overrides
  `GetLocale()` for every Cairn.Locale instance, persists across
  reloads. `/forge locale clear` removes the override. Useful for
  testing translations without restarting the client.
- `Forge_AddonManager` localized via Cairn-Locale-1.0. enUS is
  authoritative; nine other locale tables wait for translations.
- `Forge_AddonManager`: CPU profiler columns (Recent / Peak / Spikes)
  next to Memory. Tooltip on a row shows the full breakdown
  (encounter avg, last frame, spike counts at every threshold).
  Backed by `C_AddOnProfiler` (Mainline 11.0.5+); silent on Classic.

### Changed
- `Forge.About`: trimmed long-form description. The Changelog tab now
  carries the rolling release notes; About is a one-screen overview.

## [5] - 2026-05-05

### Fixed
- `release.ps1` and `refresh.ps1` anchor at the repo root from the
  new `.dev/` location. Previously two `dirname()` calls landed in
  `.dev/`; the correct depth is three.

## [4] - 2026-05-05

### Changed
- All dev-local artifacts consolidated under `.dev/` at the repo
  root. Tools, release scripts, intermediate import dumps, caches,
  and per-tool configs now live in one folder; `.gitignore` and
  `.pkgmeta` each carry one entry that covers everything.

## [3] - 2026-05-05

### Added
- Sequential build numbering (replaces YYMMDDHHMM stamps). Each
  release reads the current TOC version and increments by 1.
  Strictly monotonic; immune to timezone drift between dev machines.

## Older (pre-v3, YYMMDDHHMM-stamped era)

These entries predate the v3 consolidation. They were lifted verbatim
from per-sub-addon `Forge_*/CHANGELOG.md` files (now deleted) into this
single changelog. New entries always go in the top section, tagged by
component.

### Forge_Console

#### [2605051821] - 2026-05-05

##### Fixed
- `Indent.lua:84: attempt to perform indexed assignment on local 'lib'
  (a nil value)` at addon load. `local lib = ns.indent` ran before
  anything had created `ns.indent`, so every subsequent `lib.X = ...`
  blew up. Now `ns.indent` is created on demand at the top of the file.

#### [2605051145] - 2026-05-05

##### Added
- REPL command line below the output pane. Single-line input with `>` /
  `>>` prompt; pressing Enter compiles and runs (or extends the buffer
  if the block has unbalanced `do` / `function` / `if` / `then`).
- `= expr` shorthand auto-prints the value (delegated to `Eval.Run`,
  which already attempts a `return ...` compile first).
- Native UP / DOWN arrow history via `EditBox:AddHistoryLine`. Seeded
  from `db.profile.history` at panel build, so commands persist across
  reloads.
- Esc on a multi-line continuation drops the buffer and emits
  `(cancelled)` to the transcript.
- Welcome banner now mentions the REPL.

##### Changed
- Output pane height reduced by `REPL_H + PAD` to make room for the
  REPL strip; editor's bottom anchor pushed up by the same amount.

#### [2605051138] - 2026-05-05

##### Added
- Lua syntax highlighting in the editor via a port of FAIAP (For All
  Indents And Purposes, MIT, Kristofer Karlsson 2007). Keywords,
  strings, numbers, and comments are colored.
- Smart auto-indent. `Tab` inserts two spaces, `Shift+Tab` dedents,
  `Enter` inherits the previous line's leading whitespace.
- Line-number gutter on the left edge of the editor. Auto-grows wider
  when the snippet crosses a decade boundary (10, 100, 1000 lines).
- Runtime error -> cursor jump. When `Run` produces an error, the
  cursor jumps to the failing line and that line number flashes red
  in the gutter.

##### Changed
- `Eval.Run(input)` now returns `(ok, lines, errLine)`. The third
  value is the line number parsed out of Lua's `[string "..."]:NN:`
  error format (or `nil` if not present).

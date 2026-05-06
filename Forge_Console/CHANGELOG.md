# Changelog - Forge_Console

All notable changes to this project. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are
YYMMDDHHMM build stamps.

## [2605051821] - 2026-05-05

### Fixed
- `Indent.lua:84: attempt to perform indexed assignment on local 'lib'
  (a nil value)` at addon load. `local lib = ns.indent` ran before
  anything had created `ns.indent`, so every subsequent `lib.X = ...`
  blew up. Now `ns.indent` is created on demand at the top of the file.

## [2605051145] - 2026-05-05

### Added
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

### Changed
- Output pane height reduced by `REPL_H + PAD` to make room for the
  REPL strip; editor's bottom anchor pushed up by the same amount.

## [2605051138] - 2026-05-05

### Added
- Lua syntax highlighting in the editor via a port of FAIAP (For All Indents
  And Purposes, MIT, Kristofer Karlsson 2007). Keywords, strings, numbers,
  and comments are colored.
- Smart auto-indent. `Tab` inserts two spaces, `Shift+Tab` dedents, `Enter`
  inherits the previous line's leading whitespace.
- Line-number gutter on the left edge of the editor. Auto-grows wider when
  the snippet crosses a decade boundary (10, 100, 1000 lines).
- Runtime error -> cursor jump. When `Run` produces an error, the cursor
  jumps to the failing line and that line number flashes red in the gutter.

### Changed
- `Eval.Run(input)` now returns `(ok, lines, errLine)`. The third value is
  the line number parsed out of Lua's `[string "..."]:NN:` error format
  (or `nil` if not present).

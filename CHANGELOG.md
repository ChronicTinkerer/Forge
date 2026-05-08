# Changelog - Forge

All notable changes across the Forge family (parent + every sub-addon).
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions are sequential build numbers (+1 per release.ps1 run).

This is the **single source of truth**. Per-sub-addon CHANGELOG.md files
were consolidated here on 2026-05-05; new entries go in this file with
a `(Component)` tag identifying which sub-addon changed.

The in-game Changelog tab mirrors this file.

## [15] — Forge_AddonManager fix: drop login-time StaticPopup that tainted GameMenu (2026-05-08)

### Fixed

- **(Forge_AddonManager)** `ADDON_ACTION_FORBIDDEN` was raised when the user pressed ESC to open the Game Menu after a login session where `autoDisableNew` had queued any disables. Root cause: `Core.lua` showed a `FORGE_ADDONMANAGER_RELOAD` StaticPopup from `OnLogin` to nudge the user to Apply. In modern Retail (interface 120005) showing a StaticPopup from PLAYER_LOGIN attaches that popup frame to the global escape-close callback chain, and the chain is iterated by `Blizzard_GameMenu/Shared/GameMenuFrame.lua:66-69` when the menu opens — finding any addon-tainted handler in the chain throws ADDON_ACTION_FORBIDDEN with that addon blamed. Fix: removed the StaticPopup_Show call and the `FORGE_ADDONMANAGER_RELOAD` dialog definition; the OnLogin code now prints a chat nudge (`Open /forge -> Addons and click Apply + Reload to commit.`). The existing `FORGE_AM_RELOAD` popup in `UI.lua` is unaffected — it is shown from a button click inside the Forge tab, which is a real hardware-secure context.

## [14] — Forge_CairnInspect + Forge_Logs sort dropdown (2026-05-07)

### Added

- **(Forge_Logs)** Sort cycling button in the toolbar: cycles `Sort: Latest` -> `Sort: Oldest` -> `Sort: Source`. Defaults to `Latest` so the most recent log activity appears at the top of the list. New `ns.GetSortMode` / `ns.SetSortMode` API on the saved profile.

  Why this matters: Cairn.Log's ring buffer wraps once it hits 1000 entries, and `Log:GetEntries` returns entries in oldest-first chronological order. Once the buffer wraps, the "newest" entries are at low indices in the buffer array and old archived entries from prior sessions fill the high indices. Forge_Logs's default oldest-first iteration was therefore showing stale data on top, hiding current activity. The new "Latest" default is a correct view regardless of buffer state.

- **(Forge_CairnInspect)** New sub-addon: a tab-level consumer of Cairn-Gui-2.0's Decision 10B introspection surface (Inspector / Stats / EventLog / DevAPI). Adds a `Cairn-Inspect` tab to /forge with four panels:

  - **Widget tree** (top-left): every Cairn-Gui-2.0 widget the library has ever Acquired, walked via `Inspector:WalkAll`. Indented by parent/child depth, click to select. Live filter input in the toolbar (substring match on widget type) hides non-matching rows. Selection persists across refreshes.

  - **Detail / Dump panel** (top-right): when a tree row is selected, shows that widget's `:Dump()` output as a sorted key/value list. Scrollable. Clears when nothing is selected.

  - **Stats panel** (middle): live counters from `Stats:Snapshot` rendered as labeled rows. Sections: animations (added / completed / active), layout recomputes, primitives draws (rect / border / icon), event dispatches, pool occupancy, EventLog buffer state. Refreshes every `statsRefreshSec` (default 0.5s). Pause button freezes refresh.

  - **EventLog tail** (bottom): scrolling list of recent entries from `EventLog:Tail(200)`, formatted as `time  WidgetType  event  (N args)`. Filter input (substring match on `WidgetType:event`) hides non-matching rows. Local buttons: Enable/Disable EventLog (auto-syncs label), Clear buffer. Auto-scrolls to bottom on new entries when not paused.

- **Toolbar** (top): Refresh (forces full refresh), Pause (freezes Stats + EventLog updates), Dev (toggles `Cairn.DevAPI` — shows Cairn's frame-outline overlay on every tracked widget; label live-syncs via `Cairn.DevAPI:OnChange`), Search input for tree filter.

- **Click-to-highlight**: selecting a widget in the tree briefly tints its on-screen frame tan for 0.6 seconds so you can locate it visually. Works regardless of `Cairn.Dev` state.

- **Auto-enable EventLog on first open** (configurable via the saved profile's `autoEnableLog`). The buffer starts recording the moment you open the tab so you see real data without ceremony.

- **Slash subcommand**: `/forge cairninspectstats` prints a one-line snapshot to chat (anims, layout, events, pool counts). Useful as a low-ceremony "is anything happening" check without opening the tab.

### Changed

- **(Forge build orchestration)** `Forge_CairnInspect` registered in `.pkgmeta` (move-folders) and `.dev/release.ps1` (FilesToBump) so it ships in the published zip and auto-bumps with every release.

### Notes

- Forge_CairnInspect is **load-on-demand** (matches Forge_Console / CVars / etc. — pure UI tools per the forge_lod_pattern memory). Descriptor self-registers in `OnInit` so the LoD path doesn't miss the retro-PLAYER_LOGIN broadcast that eager addons rely on.
- The tab is currently invisible to your in-game session until you create the AddOns junction (one PowerShell command, see deployment notes below).

## [13] — Forge_Console streaming output + snippet management (2026-05-07)

### Added

- **(Forge_Console)** Streaming output for snippets that schedule deferred work. Prints emitted from `C_Timer.After`, ticker callbacks, event handlers, and other post-snippet-body callbacks now stream into the output pane instead of being silently swallowed by the previous "restore `_G.print` on Run return" path.
- **(Forge_Console)** Reserved `scratch` snippet as the default safe pad. On every Forge open per game session, the active snippet is forced to `scratch` and its content is cleared. Other snippets stay untouched until you select them explicitly. Solves the "I keep typing into the wrong snippet and overwriting it" problem.
- **(Forge_Console)** Modified indicator on the dropdown label. A trailing ` *` appears as soon as the editor's text diverges from the saved snippet code, and disappears when they match again. Hooks into the editor's `OnTextChanged`.
- **(Forge_Console)** Confirm-on-switch prompt when switching away from a modified snippet. Three buttons: Save (writes editor text to the snippet), Discard (jumps to the new snippet without saving), Cancel (stays on the current snippet). Replaces the old auto-save-on-switch behavior. Auto-save on tab hide is preserved (lock state still gates it).
- **(Forge_Console)** Lock state on snippets. Right-click a row in the snippet dropdown to toggle a lock; locked snippets show a tan `[L]` next to their name. Locked snippets refuse `SaveSnippet` calls (returns `false, "locked"`), which means auto-save on tab hide AND the explicit Save button in the switch-confirm prompt both honor the lock. Scratch can't be locked (`Core.lua` refuses) since its purpose is to be the always-safe pad.
- **(Forge_Console)** Soft warning when typing in a locked snippet. The first time per session that the editor diverges from the saved code while a locked snippet is active, a tan `[lock] '<name>' is locked; changes won't save. Right-click in the dropdown to unlock.` line drops into the output pane.
- **(Forge_Console)** New public APIs: `ns.SCRATCH` (the reserved name), `ns.IsLocked(name)`, `ns.SetLocked(name, locked)`, `ns.ToggleLocked(name)`, `ns.EnsureScratch()`, `ns.ResetScratch()`, `ns.IsScratchResetPending()`, `ns.MarkScratchResetDone()`, `UI.IsModified()`, `Eval.EndSession()`.

### Changed

- **(Forge_Console)** Run no longer auto-saves the editor's text into the current snippet. Previously, clicking Run wrote the editor's content into the snippet's saved code as a side effect, which meant the modified asterisk would disappear after Run and the switch-confirm prompt would silently skip on subsequent dropdown clicks. Save is now explicit only: the switch-confirm Save button, slash commands, or tab-hide auto-save (which still respects lock state). Run executes the editor's current text without touching saved code.

### Fixed

- **(Forge_Console)** Snippet-picker dropdown list was 60% transparent (alpha 0.40 from the ambient theme), letting the editor's code bleed through between rows. Bumped its specific backdrop to alpha 0.97 so it reads as a real overlay; rest of the Forge UI keeps the translucent ambient look.

  Mechanics: `Eval.Run` is now two-phase. The synchronous body fills the returned `lines` array as before (preserving every existing caller). After the body returns, an idle-aware streaming session installs a wrapped `_G.print` that fires an `onAppend(line)` callback for every subsequent print, posts to chat via the original print, and resets an idle timer. After 5 seconds with no new prints, `_G.print` is restored automatically.

  - **Idle-aware shutoff**: implemented as a generation counter. Each print bumps the gen and schedules a fresh `C_Timer.After` restore-check at the new gen; older timers fire and silently no-op when their captured gen no longer matches. No need to cancel C_Timer handles.
  - **Session ownership**: a second `Run` force-ends the prior session before starting its own, so starting a new snippet immediately owns the print stream. `UI.ClearOutput` also ends any active session so late prints don't appear in a freshly-cleared pane.
  - **Visual differentiation**: streamed deferred prints render in blue (`ff7fbfff`) so users can tell async output from the synchronous batch.
  - **Error path skips streaming**: if a snippet aborts with a syntax or runtime error, no streaming session is installed. The error message renders inline as before; there's no async to wait for from a snippet that didn't get to schedule anything.
  - **New public API**: `ns.Eval.EndSession()` for callers that need to force-end the active streaming session (used by `UI.ClearOutput`, available for any future code that needs the same primitive).

### Notes

- This unblocks a class of in-game tests for any timer-driven Cairn lib (Cairn-FSM async transitions, Cairn-Sequencer ticker advancement, animation completion callbacks) that previously had to use synchronous-only acceptance tests because deferred prints couldn't be observed. Existing tests can be rewritten to use real C_Timer-driven async paths in a follow-up.

## [12] — bake.py manifest preservation (2026-05-06)

### Fixed

- **(Forge_APIRef bake.py)** Manifest-update functions no longer risk silently truncating `Forge/.pkgmeta` and `Forge/.dev/release.ps1`. Both `update_pkgmeta` and `update_release_ps1` now route their write through a new `_safe_write_text` helper that:
  1. Refuses to write if the new content is < 50% of the original size (the fingerprint of a regex-overshoot bug).
  2. Writes to a `.tmp` sibling file first, reads it back, and verifies byte-equality with what we asked to write.
  3. Atomic-renames the temp file into place via `Path.replace`.
  Failures raise loudly and leave the original file untouched. Replaces the previous fragile `PATH.write_text(text, "utf-8")` calls.
- **(bake.py)** Removed a corrupted self-overwriting trailer on the file itself (an orphan `_pkgmeta(baked, dry_run=args.dry_run)` line followed by a duplicated copy of `main()`'s tail and a second `if __name__ == "__main__":` block at the very end of the file). The corruption was an artifact of a prior partial-paste manual restoration and was visually confusing; functionally inert because Python exits via the first `if __name__` block before reaching the orphans.
- **(Forge/.pkgmeta)** Removed a stub artifact at the bottom of the file (a duplicated single-line "We do NOT use @project-version@..." paste that preceded the real 4-line comment block). Same partial-paste origin as the bake.py corruption.

### Added

- **(Forge_APIRef bake.py)** Regression test at `Forge/SubAddons/Forge_APIRef/.dev/tests/test_bake_manifest_preservation.py`. 16/16 PASS. Covers `_safe_write_text` presence + behavior, pkgmeta + release.ps1 trailer preservation across substitutions, namespace add/remove, idempotency on repeat runs.

## [11] - 2026-05-06

### Changed

- **(Source layout)** Every sub-addon folder moved from the repo root into `Forge/SubAddons/`. The repo root drops from 594 folders to 1. The packager's `move-folders` directive still flattens to siblings at install time, so the published zip is byte-identical to the previous build and end users see no change.
- `.pkgmeta` `move-folders` source paths now `Forge/SubAddons/Forge_*`. Updated descriptive prose accordingly.
- `.dev/release.ps1` `$FilesToBump` sub-addon paths now prefixed `SubAddons\`. Parent `Forge.toc` entry unchanged.
- **(Forge_APIRef bake.py)** New `SUBADDONS_ROOT = FORGE_ROOT / "SubAddons"`. Generated namespace addons now land under `Forge/SubAddons/Forge_APIRef-<Namespace>/`. The auto-rewrite of `Forge/.pkgmeta` `move-folders` and `Forge/.dev/release.ps1` `$FilesToBump` emits the new prefix on every bake.
- **(Forge_APIRef link-siblings.ps1)** Anchor renamed `$SubAddonsRoot` to reflect the new location; deprecation note added pointing at workspace-level `Sync-WoWAddons.ps1` for general use.

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

# Changelog

All notable changes to Forge_CVars are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses sequential build numbers (one bump per release).

## [3] - 2026-05-06

### Changed
- All consumer-facing UI now goes through `Cairn-Gui-Core-1.0` widgets.
  - Toolbar search box: `Gui:Create("Input")` (was raw `EditBox` + `InputBoxTemplate`).
  - Toolbar Refresh + footer New / Save / Apply / Export / Import buttons:
    `Gui:Create("Button")` (was raw `Button` + `UIPanelButtonTemplate`).
  - Toolbar "Modified only" checkbox: `Gui:Create("CheckBox")` (was raw
    `CheckButton` + `UICheckButtonTemplate`).
  - Category and Profile dropdowns: now follow the Forge_AddonManager
    pattern of a Cairn `Button` trigger plus a backdrop popup with a
    `Gui:Create("ScrollFrame")` inside. Drops the deprecated
    `UIDropDownMenuTemplate` calls.
  - List virtualized scroll: `Gui:Create("ScrollFrame")` (was raw
    `UIPanelScrollFrameTemplate`).
  - Per-row Edit / Reset / Copy buttons: `Gui:Create("Button")`.
  - Edit modal value EditBox + Confirm / Cancel buttons: `Gui:Create("Input")`
    and `Gui:Create("Button")`.
  - Name prompt for New / Save As: same Cairn-Gui pattern Forge_AddonManager
    uses for its set-name prompt; replaces the previous `StaticPopupDialogs`
    name dialog.
- Container shells (toolbar / footer / list area / modal backdrop / popup
  backdrops) remain plain `Frame` since Cairn-Gui-Core has no equivalent
  widget for those — same pattern Forge_AddonManager applies.
- Each Cairn-Gui call has a raw-frame fallback for clients where the kit
  failed to load, matching the existing Forge sub-addon convention.

## [2] - 2026-05-06

### Added
- `Snapshot.lua` real impl: walks the console API (tries
  `C_Console.GetAllCommands` first, falls back to the legacy
  `ConsoleGetAllCommands` global, both pcall-guarded), builds per-entry
  `name` / `category` (string from `Enum.ConsoleCategory`) / `commandType` /
  `help` / pre-lowercased `searchKey`. Adds `Snapshot.Categories()` for the
  toolbar dropdown. `Snapshot.Filter` handles substring + category +
  modified-only with sort by name / category / modified.
- `List.lua` real impl: virtualized scroll list. Pool sized to `visibleRows +
  buffer`, rows reused as the user scrolls. Each row paints name (orange if
  risky, green if modified-from-default), current, default, type, plus Edit /
  Reset / Copy buttons and a "!" mark for risky entries. `SetCallbacks`
  exposes onEdit / onReset / onCopy hooks.
- `EditModal.lua` real impl: lazy-built shared modal with current / default
  / new-value EditBox. Tag-specific warning copy for `danger` / `audio` /
  `reload`. Confirm runs `pcall SetCVar`; Enter / Escape work.
- `Profiles.lua` real impl: Save / Delete / Rename / Apply (returns
  applied / failed / needsReload). `CaptureCurrentDiffs` snapshots every
  modified CVar. `ToConsoleBlock` renders `/console SetCVar` lines for
  export / paste.
- `UI.lua` real impl: toolbar (search EditBox / category dropdown /
  modified-only checkbox / Refresh button / last-refreshed status) +
  virtualized list area + footer (profile dropdown + New / Save / Apply /
  Export / Import buttons). UI state (search / category / modified-only)
  persists per profile via `ForgeCVarsDB.profile.ui`. Apply pops the
  reload-required prompt when any applied CVar is in `RiskyList.NeedsReload`.

### Notes
- Import is currently a stub: it tells the user to round-trip via chat
  `/console`. A real paste-and-parse dialog can land later if needed.
- Inline edit (skip the modal for cheap CVars) is also deferred; everything
  goes through the modal in this build for simplicity.

## [1] - 2026-05-06

### Added
- Initial scaffold: TOC, Forge.Registry descriptor (registered in OnInit so
  LoadOnDemand load works post-PLAYER_LOGIN), and module skeletons:
  - `Snapshot.lua` — query layer over `C_Console.GetAllCommands`.
  - `RiskyList.lua` — allowlist of CVars that pop a confirm modal on edit
    (graphics, audio, network, and reload-required entries).
  - `Profiles.lua` — named CVar profile data layer.
  - `EditModal.lua` — inline edit + risky-confirm modal.
  - `List.lua` — HybridScrollFrame-backed virtualized list (~3000 rows).
  - `UI.lua` — toolbar, list area, footer; assembled by Forge tab system.
- Sub-addon is `## LoadOnDemand: 1`; the Forge parent's TOC scanner creates
  a stub tab that loads this addon on first click.

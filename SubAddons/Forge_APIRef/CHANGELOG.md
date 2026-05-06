# Changelog

All notable changes to Forge_APIRef are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses sequential build numbers (one bump per release).

## [4] - 2026-05-06

### Added
- `bake.py` data pipeline shipped. Walks every
  `Blizzard_APIDocumentationGenerated/*Documentation.lua` on the
  Gethe/wow-ui-source live mirror, evaluates each Lua doc table
  (custom Python parser, no third-party deps), transforms into our
  schema, and emits one `Forge_APIRef-<Namespace>/Module.lua` plus its
  TOC per namespace.
- 583 namespaces baked. ~9,400 entries across functions, events, and
  structures/enums. Forge_APIRef-C_Map now has 41 entries (was 5
  hand-authored).
- `link-siblings.ps1` PowerShell helper at `.dev/`: walks the source
  tree and `mklink /J`s every `Forge_APIRef-*` folder into the user's
  WoW AddOns directory in one shot. Supports `-DryRun` and `-Remove`.
- `Forge/.dev/tests/forge_apiref_bake.lua` Forge_Console test snippet
  that samples lookups across many namespaces, force-loads every
  installed sibling, and reports pass/fail + coverage counts.

### Notes
- Hand-authored richness on the C_Map pilot (full descriptions,
  examples, see-also, related-events) is replaced with bake-generated
  data using only Blizzard's `Documentation` field. Wiki enrichment
  (descriptions, examples, patch history pulled from warcraft.wiki.gg)
  is the v2 of bake.py and will layer on top of this dataset.
- 3 Constants files skipped because their enum values use Lua
  arithmetic expressions (`BIT0 + BIT1`, `LAST - CONST`) which the
  parser doesn't evaluate yet:
  CharacterCustomizationShared, CurrencyConstants, PetConstants.
- Known issue: bake.py's manifest update for `Forge/.pkgmeta` and
  `Forge/.dev/release.ps1` truncates the trailing comment block /
  trailing git-ops block. Restored by hand this session; bake.py
  needs a defensive write-and-verify pass.

## [3] - 2026-05-06

### Fixed
- List rows now display events by their literal name (`ZONE_CHANGED`)
  and structures by bare name (`UiMapDetails`) instead of prefixing them
  with the namespace. Functions still show as `C_Map.GetBestMapForUnit`.
  Matches how WoW APIs are actually called/referenced.
- Row name FontString gets a right anchor pinned just left of the type
  tag, so long entry names get ellipsis-truncated instead of running
  over the type/flag columns.

## [2] - 2026-05-06

### Added
- Browsing tab UI built against `Cairn-Gui-Core-1.0` widgets:
  - Toolbar: search `Input` (live filter), namespace trigger `Button` +
    popup, type trigger `Button` + popup, "Load all" `Button` (scans
    every installed `Forge_APIRef-*` sibling and `LoadAddOn`s the
    unloaded ones), entry-count status text.
  - Body split: virtualized list pane on the left (~40%), detail pane
    on the right. Both backed by `Cairn-Gui-Core` `ScrollFrame`. Thin
    forge-orange divider between them.
  - List rows show `name`, type tag (`fn` / `ev` / `st`), and a flag
    glyph for restricted (`!`), removed (`x`), or deprecated (`d`)
    entries. Click selects; selection highlight tracks across scroll.
  - Detail pane renders the full schema vertically: title, type tag +
    flags, signature, description, arguments / returns / payload /
    fields (whichever apply), version info, examples, see-also,
    related events.
- Filters and search persist per profile via `ForgeAPIRefDB.profile.ui`.

### Notes
- Until bake.py runs, only the `Forge_APIRef-C_Map` pilot module is
  loaded (5 entries). "Load all" today only catches sibling addons that
  are installed; full coverage waits on bake.py.

## [1] - 2026-05-06

### Added
- Initial scaffold: TOC (LoadOnDemand, X-Forge-Tool-Name=APIRef), Cairn.Addon
  lifecycle, Forge.Registry descriptor (registered in OnInit so LoD load
  works post-PLAYER_LOGIN), placeholder tab content until the browsing UI
  lands.
- Public API in `Lookup.lua`:
  - `ForgeAPIRef:Register(namespace, entries)` for sibling modules to
    publish their data.
  - `ForgeAPIRef:Lookup(name)` accepting `"C_Foo.Bar"` namespace function
    syntax or bare event / structure names. Demand-loads the matching
    `Forge_APIRef-<Namespace>` sibling addon on first hit.
  - `ForgeAPIRef:Iter(namespace?)` and `ForgeAPIRef:Namespaces()` for
    walking loaded entries.
- Pilot data: `Forge_APIRef-C_Map` sibling addon ships 5 hand-authored
  entries (GetBestMapForUnit, GetMapInfo, OpenWorldMap, ZONE_CHANGED,
  UiMapDetails) covering function / event / structure entry types and
  validating the locked schema end-to-end.
- Global `ForgeAPIRef` exposed for `/dump` and consumer addons.

### Notes
- Browsing UI (Cairn-Gui-Core-1.0 list + detail panel) deferred to a
  follow-up build.
- bake.py for full coverage (Blizzard `Blizzard_APIDocumentationGenerated`
  primary + Wiki enrichment) deferred to a follow-up build.

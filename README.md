# CTS_Forge

![CTS_Forge logo: anvil and hammer with a glowing F](ForgeLogo.png)

> A comprehensive in-game developer toolset for World of Warcraft addon authors.

CTS_Forge is a parent + sub-addon suite of dev tools for WoW addon authors who use the Cairn library stack. Install only the tools you want; each sub-addon plugs into the parent's main window as its own tab.

Targets **WoW Retail (Midnight, Interface 120005)**. Built on the [Cairn](https://github.com/ChronicTinkerer/Cairn) library stack.

The `CTS_` prefix is a folder-name convention only. The user-facing name in WoW's AddOns list is still "Forge"; the slash command is still `/forge`. The prefix exists so the addon folders don't collide with any other author's `Forge` / `Forge_*` addons in the wild.

---

## What's in the box

The parent provides the slash router (`/forge`), the sub-module registry, and the main window with a tab strip. Each sub-addon adds one tool as a tab.

| Sub-addon                | Tab           | What it does                                                                                                                  |
| ------------------------ | ------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `CTS_Forge_BugCatcher`   | BugCatcher    | Lua error handler. Captures errors quietly to a browsable viewer. Copy-as-block, ignore list, optional auto-popup.            |
| `CTS_Forge_Console`      | Console       | In-game Lua REPL. Snippet picker, FAIAP syntax highlighting, line-number gutter, REPL strip, streaming deferred prints.       |
| `CTS_Forge_Stats`        | Stats         | Live stats tab. Character, location, network, system. Updates 2x/sec while the tab is visible.                                |
| `CTS_Forge_Tables`       | Tables        | Lua table inspector. Browse any global by name; drill into sub-tables.                                                        |
| `CTS_Forge_CVars`        | CVars         | WoW CVar viewer + editor. Search, filter, get/set values, see defaults.                                                       |
| `CTS_Forge_Events`       | Events        | Live event monitor. Subscribe to any Blizzard event, see args + timestamps, filter by name.                                   |
| `CTS_Forge_APIBrowser`   | API Browser   | Browse WoW's Lua API. Search by function name, see signatures, insert call skeletons.                                         |
| `CTS_Forge_Textures`     | Textures      | Texture + atlas browser. Preview Blizzard textures + atlas slices by name.                                                    |
| `CTS_Forge_Sounds`       | Sounds        | Sound kit + file browser. Search, play, copy sound IDs and paths.                                                             |
| `CTS_Forge_Logs`         | Logs          | Viewer for `Cairn.Log` entries. Live tail, pause-when-scrolled-away, CSV export, category filter, WoW event taps.             |
| `CTS_Forge_Macros`       | Macros        | Full-size macro editor. Account + Character lists, icon picker, drag-to-bar, 255-char counter.                                |
| `CTS_Forge_Profiles`     | Profiles      | Cross-addon profile manager. Switcher UI, declaration API, auto-discovery adapters for non-Cairn addons.                      |
| `CTS_Forge_Registry`     | Registry      | Inspect Forge's sub-module registry. See what's loaded, descriptor metadata, slash sub-commands, LoD stubs.                   |
| `CTS_Forge_Codex`        | Codex         | LibCodex browser. Search, browse, and inspect LibCodex catalogs (quests, items, currencies, etc.). Requires `LibCodex-1.0`.   |
| `CTS_Forge_AddonManager` | AddOn Manager | In-game addon enable/disable, named sets (Raid / Solo / PvP), memory + CPU columns, dependency graph, error counts.           |
| `CTS_Forge_Profiler`     | Profiler      | Live CPU time-series chart for the top-5 hottest addons.                                                                      |
| `CTS_Forge_Radar`        | Radar         | Live list of nearby players, NPCs, vignettes, and POIs with distance + bearing.                                               |

---

## Installation

1. Copy the `CTS_Forge/` folder into:
   `World of Warcraft\_retail_\Interface\AddOns\CTS_Forge\`
2. Copy any `CTS_Forge_*` sub-addon folders you want into the same `AddOns\` directory (each is an independent sibling addon, not a subfolder of `CTS_Forge\`).
3. Make sure [Cairn](https://github.com/ChronicTinkerer/Cairn) is also installed (`CTS_Forge` declares it as a hard dependency).
4. `CTS_Forge_Codex` additionally requires [LibCodex-1.0](https://github.com/ChronicTinkerer/LibCodex-1.0).

After login, type `/forge` to open the main window. With no sub-addons installed you'll see an empty window with a placeholder message; install any sub-addon to populate a tab.

---

## Slash commands

The parent registers `/forge` (alias `/fg`). Built-in subcommands:

| Subcommand        | Action                                                |
| ----------------- | ----------------------------------------------------- |
| `/forge`          | Toggle the main window                                |
| `/forge status`   | Print Cairn / LibCodex / profile / sub-modules info   |
| `/forge modules`  | List every loaded CTS_Forge sub-module                |
| `/forge logs`     | Open the Logs tab                                     |
| `/forge reset`    | Reset the current profile to defaults                 |
| `/forge help`     | List all registered subcommands                       |
| `/forge locale`   | Dev-only locale override for the current session      |

Each sub-addon adds its own subcommand on load. They appear in `/forge help` automatically.

---

## Writing your own sub-addon

A sub-addon is a regular WoW addon that depends on `CTS_Forge` and registers a descriptor with `Forge.Registry`:

```
-- CTS_MyTool/CTS_MyTool.toc
## Interface: 120005
## Title: My Tool
## Dependencies: Cairn, CTS_Forge
## X-Forge-Tool-Name: MyTool
## X-Forge-Tool-Order: 50
Core.lua
```

```lua
-- CTS_MyTool/Core.lua
local ADDON, ns = ...

Cairn.Register("CTS_MyTool", ns, { Log = true })

local _entry = Cairn.GetRegistry()["CTS_MyTool"]
local addon  = _entry and _entry.cairnAddon

function addon:OnInit()
    Forge.Registry.Register({
        name        = "MyTool",
        title       = "My Tool",
        order       = 50,
        description = "Does the thing.",
        SlashSub    = { name = "mytool", help = "open My Tool" },
        OnTabShow   = function(parent, mod)
            if not mod._built then
                mod._frame = CreateFrame("Frame", nil, parent)
                mod._frame:SetAllPoints(parent)
                -- build your UI here once
                mod._built = true
            end
            mod._frame:Show()
        end,
        OnTabHide = function(parent, mod)
            if mod._frame then mod._frame:Hide() end
        end,
    })
end
```

The descriptor table is your module object; stash any state on it. Forge never mutates it. The tab strip rebuilds automatically, and `/forge mytool` is wired automatically.

### LoadOnDemand sub-addons

For tools the user only needs occasionally, make the sub-addon LoadOnDemand so it stays cold until the tab is clicked:

```
## Title: My Tool
## LoadOnDemand: 1
## X-Forge-Tool-Name: MyTool
## X-Forge-Tool-Order: 50
## X-Forge-Tool-Icon: Interface\Icons\INV_Misc_Note_01
```

The CTS_Forge parent scans installed `CTS_Forge_*` addons at `PLAYER_LOGIN`, reads the `X-Forge-Tool-*` fields, and registers a stub tab for any LoD addon that isn't loaded yet. On first click the stub does `C_AddOns.LoadAddOn`, which fires your sub-addon's `OnInit`, which calls `Forge.Registry.Register(descriptor)` to overwrite the stub with the real descriptor.

**Register in `OnInit`, NOT `OnLogin`.** `Cairn.Events` does not retro-fire `PLAYER_LOGIN` for late subscribers, so a sub-addon LoD-loaded mid-session via tab click never sees `OnLogin`.

### Descriptor fields

| Field                   | Required | Description                                                                              |
| ----------------------- | -------- | ---------------------------------------------------------------------------------------- |
| `name`                  | yes      | Short identifier; used as the tab key (no `CTS_Forge_` prefix).                          |
| `title`                 | no       | Human-readable tab label. Defaults to `name`.                                            |
| `order`                 | no       | Tab sort order (lower = leftmost). Default 100.                                          |
| `description`           | no       | One-line subtitle.                                                                       |
| `icon`                  | no       | Texture path for a future icon column.                                                   |
| `OnTabShow(parent, mod)`| yes      | Build or show your UI inside the parent frame.                                           |
| `OnTabHide(parent, mod)`| no       | Hide or tear down when another tab takes over.                                           |
| `SlashSub`              | no       | `{ name = "...", help = "..." }`. Auto-registers a `/forge <name>` subcommand.           |

---

## Architecture

Forge is split into the parent and the sub-addons:

- **CTS_Forge** (parent): the slash router (built on `Cairn.Slash`), the sub-module registry, and the main window. ~520 lines.
- **CTS_Forge_*** (sub-addons): each one is a regular WoW addon that calls `Forge.Registry.Register(descriptor)` on load.

The parent uses Cairn directly:

- `Cairn.Addon` for lifecycle (`OnInit` / `OnLogin` / `OnLogout`)
- `Cairn.DB` for SavedVariables (the `ForgeDB` global, profile per character)
- `Cairn.Slash` for `/forge` routing
- `Cairn.Log` for diagnostic logging

The `_G.Forge` namespace is the ergonomic in-engine handle. Sub-addons reach the registry, window, and shared helpers via `Forge.Registry.Register(...)`, `Forge.Slash:Sub(...)`, etc. That global stays as `Forge` even though the addon folder is `CTS_Forge`; it's a developer-ergonomic API, not a folder identifier.

---

## License

**All Rights Reserved.** Copyright (c) 2026 ChronicTinkerer.

This software is proprietary. No use, modification, redistribution, or derivative works without prior written permission of the copyright holder. End users obtaining unmodified copies through official channels (CurseForge, Wago, WoWInterface, GitHub releases) may install and run the addon for personal use within World of Warcraft. See [LICENSE](LICENSE) for full terms.

Library dependencies (Cairn, LibCodex-1.0) are MIT-licensed and unaffected by this change.

Author: **ChronicTinkerer**

Naming family: Cairn (stones / foundation), Codex (book / data), Vellum (page / rendered guide), Forge (workshop / dev tools).

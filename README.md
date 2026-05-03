# Forge

<p align="center">
  <img src="ForgeLogo.png" width="340" alt="Forge logo: anvil and hammer with a glowing F"/>
</p>

> A comprehensive developer toolset for World of Warcraft addons.

Forge is a parent + sub-addon suite of developer tools for WoW addon
authors who use Cairn and LibCodex. Install only the tools you want; each
sub-addon plugs into the parent's main window as its own tab.

It targets **WoW Retail (Midnight, Interface 120005)** and is built on
the [Cairn](../Cairn/README.md) library stack.

**Status:** parent addon scaffolded (v0.1.0-dev, build 2605031552).
Sub-addons in active development. See [Roadmap](#roadmap).

---

## What's in the box

Forge ships as a small parent addon plus a set of optional sub-addons.
The parent provides the slash router, the sub-module registry, and the
main window. Each sub-addon adds one tool as a tab.

| Sub-addon | Tool | What it does |
|---|---|---|
| `Forge_BugCatcher` | Error handler | Captures Lua errors quietly. Browsable viewer with copy-as-block, minimap counter, ignore list, optional auto-popup, color-coded severity. |
| `Forge_Macros` | Macro editor | Full-size editor: Account + Character lists, big text area, icon picker, drag-to-action-bar, 255-char counter. |
| `Forge_Console` | Lua REPL | In-game Lua console with history, syntax check, scrollable output. |
| `Forge_Inspector` | Namespace browser | Real-time `_G` tree explorer with type display, per-level search, 0.5s auto-poll on expanded nodes, pinnable watch list. |
| `Forge_Logs` | Activity dashboard | Per-addon log viewer with copy-as-block, level filter, search, lifecycle info. Replaces Cairn.Dashboard. |
| `Forge_Profiles` | Profile manager | Cross-addon profile switcher, profile manager API, auto-discovery adapters so non-Cairn addons appear automatically. |
| `Forge_Setup` | Setup wizard API | Declarative multi-page first-run wizard library that any addon can use. |
| `Forge_AddonManager` | Addon manager | Toggle addons in-game, named sets (Raid / Solo / PvP), ReloadUI, per-addon memory and load order, profile-aware enable lists. |
| `Forge_Codex` | Codex browser | Browse / search / stats over LibCodex's 45-module catalog. Replaces LibCodex's UI. |

---

## Installation

1. Copy the `Forge/` folder into:
   `World of Warcraft\_retail_\Interface\AddOns\Forge\`
2. Copy any `Forge_*` sub-addon folders you want into the same directory.
3. Make sure **Cairn** is also installed (Forge depends on it).
4. `Forge_Codex` additionally requires **LibCodex-1.0**.

After login, type `/forge` to open the main window. With no sub-addons
installed you'll see an empty window with a placeholder message; install
any sub-addon to populate a tab.

---

## Slash commands

The parent registers `/forge` (alias `/fg`). Built-in subcommands:

| Subcommand | Action |
|---|---|
| `/forge` | Toggle the main window |
| `/forge status` | Print Cairn / LibCodex / profile / sub-modules info |
| `/forge modules` | List every loaded Forge sub-module |
| `/forge logs` | Open the Logs tab (or fall back to Cairn.Dashboard) |
| `/forge reset` | Reset the current profile to defaults |
| `/forge help` | List all registered subcommands |

Each sub-addon adds its own subcommand on load (e.g. `/forge bug`,
`/forge console`, `/forge inspect`). They appear in `/forge help`
automatically.

---

## Writing your own sub-addon

A sub-addon is a regular WoW addon that depends on Forge and registers a
descriptor with `Forge.Registry`:

```lua
-- MySubAddon/MySubAddon.toc
## Interface: 120005
## Title: Forge_MyTool
## Dependencies: Cairn, Forge
Core.lua
```

```lua
-- MySubAddon/Core.lua
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
```

The descriptor table is your module object; stash any state on it.
Forge never mutates it. The tab strip rebuilds automatically, and
`/forge mytool` is wired automatically.

### Descriptor fields

| Field | Required | Description |
|---|---|---|
| `name` | yes | Short identifier; used as the tab key (no `Forge_` prefix). |
| `title` | no | Human-readable tab label. Defaults to `name`. |
| `order` | no | Tab sort order (lower = leftmost). Default 100. |
| `description` | no | One-line subtitle. |
| `icon` | no | Texture path for a future icon column. |
| `OnTabShow(parent, mod)` | yes | Build or show your UI inside the parent frame. |
| `OnTabHide(parent, mod)` | no | Hide or tear down when another tab takes over. |
| `SlashSub` | no | `{ name = "...", help = "..." }`. Auto-registers a `/forge <name>` subcommand. |

---

## Architecture

Forge is split into the parent and the sub-addons:

- **Forge** (parent): the slash router (built on `Cairn.Slash`), the
  sub-module registry, and the main window. ~520 lines.
- **Forge_*** (sub-addons): each one is a regular WoW addon that calls
  `Forge.Registry.Register(descriptor)` on load.

The parent uses Cairn directly:

- `Cairn.Addon` for lifecycle (`OnInit` / `OnLogin` / `OnLogout`)
- `Cairn.DB` for SavedVariables (the `ForgeDB` global, profile per character)
- `Cairn.Slash` for `/forge` routing
- `Cairn.Log` for diagnostic logging

Forge does not duplicate work already in Cairn. The Logs tab renders
`Cairn.Log`'s ring buffer; the per-addon dashboard work that lives in
`Cairn.Dashboard` today moves into `Forge_Logs` once it ships, after
which the next Cairn release drops `Cairn-Dashboard-1.0.lua`.

---

## Roadmap

**Built:**

- Forge parent (v0.1.0-dev): slash router, registry, main window with
  dynamic tab strip, geometry persistence.

**Build order for v0.1:**

1. `Forge_Console` (Lua REPL)
2. `Forge_BugCatcher` (error handler)
3. `Forge_Macros` (macro editor)
4. `Forge_Setup` (wizard API)
5. `Forge_Logs` (activity dashboard; replaces `Cairn.Dashboard`)
6. `Forge_Codex` (catalog browser; replaces LibCodex UI)
7. `Forge_Inspector` (Lua namespace browser)
8. `Forge_Profiles` (UI + API + auto-discovery adapters)
9. `Forge_AddonManager` (toggle + sets + memory + profile-aware)

**Migration plan:** once `Forge_Logs` and `Forge_Codex` are verified
in-game, the next Cairn and LibCodex releases drop their dashboards.
Both libraries become headless; the GUI lives in Forge.

---

## File layout

```
Forge/
  Forge.toc       Manifest. Interface 120005, hard dep Cairn, optional dep LibCodex-1.0.
  Core.lua        DB, Cairn.Addon lifecycle, /forge slash router with built-in subcommands.
  Registry.lua    Sub-module registry: descriptor schema, ordered iteration, slash auto-wire.
  Window.lua      Main window: tab strip, content area, geometry persistence, empty-state.
  ForgeLogo.png   Logo.
  README.md       This file.
```

---

## License

MIT.

Author: **ChronicTinkerer**

Naming family: Cairn (stones / foundation), Codex (book / data),
Vellum (page / rendered guide), Forge (workshop / dev tools).

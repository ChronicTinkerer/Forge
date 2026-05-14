-- Forge_Profiles: cross-addon profile manager.
--
-- Placeholder scaffold. Three features from the original spec roll into here:
--   (2) Profile Manager UI — switcher across ALL addons, not just Cairn-registered
--   (6) Profile Manager API — author-facing declaration API for profiles
--   (7) Auto-Discovery Adapters — adapter registration so non-Cairn addons
--                                 appear in the switcher
--
-- To-build:
--   * Adapter contract: { list, get, set, copy, delete }
--   * Built-in adapters: Cairn-DB (read profileType/currentProfile), AceDB
--   * UI: addon list (left) → profile list per addon (right) → actions toolbar
--   * Copy across addons (e.g., "load this set of profiles together")

local ADDON, ns = ...
_G.Forge_Profiles = ns

Cairn.Register("CTS_Forge_Profiles", ns, {
    dbName = "Forge_ProfilesDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = {
        profile = {},
        global  = {
            adapters = {},  -- registered discovery adapters
        },
    },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Profiles"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


ns.descriptor = {
    name        = "Profiles",
    title       = "Profiles",
    order       = 70,
    description = "Cross-addon profile manager. Switchers + author API + auto-discovery adapters.",

    OnTabShow = function(pane, mod)
        if pane.Cairn._builtOnce then return end
        pane.Cairn._builtOnce = true
        local Gui = LibStub("Cairn-Gui-2.0", true)
        if not Gui then return end
        pane.Cairn:SetLayout("Stack",
            { direction = "vertical", gap = 6, padding = 16 })
        Gui:Acquire("Label", pane, { text = "Profiles", variant = "heading" })
        Gui:Acquire("Label", pane, {
            text    = "Coming soon. Switch profiles across every Cairn / AceDB / adapter-registered addon.",
            variant = "muted",
        })
    end,
}


function addon:OnInit()
    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
end

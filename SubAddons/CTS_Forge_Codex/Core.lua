-- Forge_Codex: LibCodex browser tab.
--
-- Placeholder scaffold. To-build (subsumes LibCodex's standalone dashboard):
--   * Module picker: Quests / Items / Currencies / Achievements / NPCs / ...
--     (whatever modules LibCodex-1.0 has registered via LibStub at runtime)
--   * Search box per module (substring + ID match)
--   * Results table with columns derived from the module's schema
--   * Detail pane: full row dump + raw bundled record + per-character state
--   * Stats tab: count by module, bundle build, last-update timestamps
--   * Settings tab: per-module enable, daily-update toggle, source picker
--
-- LibCodex is a HARD dep (declared in TOC). If LibCodex's MAJOR ever
-- changes, this sub-addon needs an explicit version bump to match.

local ADDON, ns = ...
_G.Forge_Codex = ns

Cairn.Register("CTS_Forge_Codex", ns, {
    dbName = "Forge_CodexDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = { profile = {}, global = {} },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Codex"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


ns.descriptor = {
    name        = "Codex",
    title       = "Codex",
    order       = 80,
    description = "Browse LibCodex catalogs (quests, items, currencies, etc.) in one tab.",

    OnTabShow = function(pane, mod)
        if pane.Cairn._builtOnce then return end
        pane.Cairn._builtOnce = true
        local Gui = LibStub("Cairn-Gui-2.0", true)
        if not Gui then return end
        pane.Cairn:SetLayout("Stack",
            { direction = "vertical", gap = 6, padding = 16 })
        Gui:Acquire("Label", pane, { text = "Codex", variant = "heading" })

        local LCX = LibStub and LibStub("LibCodex-1.0", true)
        if not LCX then
            Gui:Acquire("Label", pane, {
                text    = "LibCodex-1.0 not loaded. Install LibCodex to enable this tab.",
                variant = "muted",
            })
            return
        end
        Gui:Acquire("Label", pane, {
            text    = "Coming soon. Browse / Search / Stats / Settings for every LibCodex module.",
            variant = "muted",
        })
    end,
}


function addon:OnInit()
    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
end

-- Forge_Sounds: sound kit + file browser.
--
-- Placeholder scaffold. To-build:
--   * Search by sound-kit name or file path
--   * Play preview via PlaySound / PlaySoundFile
--   * Stop / single-active-handle state (avoid overlapping playback)
--   * Favorites + recent in db.profile
--   * Data generated at runtime via known sound-kit enumerations

local ADDON, ns = ...
_G.Forge_Sounds = ns

Cairn.Register("CTS_Forge_Sounds", ns, {
    dbName = "Forge_SoundsDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = { profile = { favorites = {}, recent = {} }, global = {} },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Sounds"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


ns.descriptor = {
    name        = "Sounds",
    title       = "Sounds",
    order       = 55,
    description = "Browse, preview, and copy WoW sound IDs / paths.",

    OnTabShow = function(pane, mod)
        if pane.Cairn._builtOnce then return end
        pane.Cairn._builtOnce = true
        local Gui = LibStub("Cairn-Gui-2.0", true)
        if not Gui then return end
        pane.Cairn:SetLayout("Stack",
            { direction = "vertical", gap = 6, padding = 16 })
        Gui:Acquire("Label", pane, { text = "Sounds", variant = "heading" })
        Gui:Acquire("Label", pane, {
            text    = "Coming soon. Preview sound kits + files, copy IDs and paths.",
            variant = "muted",
        })
    end,
}


function addon:OnInit()
    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
end

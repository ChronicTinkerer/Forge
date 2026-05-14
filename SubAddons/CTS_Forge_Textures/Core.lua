-- Forge_Textures: texture + atlas browser.
--
-- Placeholder scaffold. To-build:
--   * Search by name / path
--   * Live texture preview at multiple sizes
--   * Atlas browser: list atlas elements via GetAtlasInfo + SetAtlas
--   * Click-to-copy path or atlas name
--   * Data generated at runtime — iterate known prefixes (Interface\\Icons\\*,
--     Interface\\AddOns\\..., atlas list from C_Texture)

local ADDON, ns = ...
_G.Forge_Textures = ns

Cairn.Register("CTS_Forge_Textures", ns, {
    dbName = "Forge_TexturesDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = { profile = { favorites = {}, recent = {} }, global = {} },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Textures"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


ns.descriptor = {
    name        = "Textures",
    title       = "Textures",
    order       = 50,
    description = "Browse and preview WoW textures + atlases.",

    OnTabShow = function(pane, mod)
        if pane.Cairn._builtOnce then return end
        pane.Cairn._builtOnce = true
        local Gui = LibStub("Cairn-Gui-2.0", true)
        if not Gui then return end
        pane.Cairn:SetLayout("Stack",
            { direction = "vertical", gap = 6, padding = 16 })
        Gui:Acquire("Label", pane, { text = "Textures", variant = "heading" })
        Gui:Acquire("Label", pane, {
            text    = "Coming soon. Browse, preview, and copy paths for textures + atlas slices.",
            variant = "muted",
        })
    end,
}


function addon:OnInit()
    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
end

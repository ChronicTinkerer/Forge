-- Forge_Macros: full-size macro editor.
--
-- Placeholder scaffold. To-build:
--   * Account-vs-Character separation (GetNumMacros returns both counts)
--   * List view with icons + names; click to load into editor
--   * Multi-line editor with 255-char counter
--   * Icon picker (probably reuses Textures' icon browser)
--   * Drag-to-bar: SecureActionButtonTemplate overlay with type=macro
--   * Create / Delete / Rename / Save through CreateMacro / EditMacro / DeleteMacro

local ADDON, ns = ...
_G.Forge_Macros = ns

Cairn.Register("CTS_Forge_Macros", ns, {
    dbName = "Forge_MacrosDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = { profile = {}, global = {} },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Macros"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


ns.descriptor = {
    name        = "Macros",
    title       = "Macros",
    order       = 65,
    description = "Full-size macro editor with account + character lists and icon picker.",

    OnTabShow = function(pane, mod)
        if pane.Cairn._builtOnce then return end
        pane.Cairn._builtOnce = true
        local Gui = LibStub("Cairn-Gui-2.0", true)
        if not Gui then return end
        pane.Cairn:SetLayout("Stack",
            { direction = "vertical", gap = 6, padding = 16 })
        Gui:Acquire("Label", pane, { text = "Macros", variant = "heading" })
        Gui:Acquire("Label", pane, {
            text    = "Coming soon. Account + Character lists, icon picker, drag-to-bar.",
            variant = "muted",
        })
    end,
}


function addon:OnInit()
    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
end

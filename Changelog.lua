-- Forge.Changelog: built-in tab that points users at the GitHub releases
-- page for the full changelog. We don't embed the full text inline — it
-- would inflate the loaded addon size and go stale fast.

local ADDON, ns = ...

local Changelog = {}
ns.Changelog = Changelog


local function onShow(pane, mod)
    if pane.Cairn._builtOnce then return end
    pane.Cairn._builtOnce = true

    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    pane.Cairn:SetLayout("Stack", { direction = "vertical", gap = 8, padding = 16 })

    Gui:Acquire("Label", pane, {
        text    = "Forge build " .. (ns.BUILD or "?"),
        variant = "heading",
    })

    Gui:Acquire("Label", pane, {
        text = "Full changelog is published with each release on the project pages:",
    })

    Gui:Acquire("Label", pane, {
        text    = "  CurseForge:  https://www.curseforge.com/wow/addons/forge",
        variant = "muted",
    })
    Gui:Acquire("Label", pane, {
        text    = "  Wago:        https://addons.wago.io/addons/forge",
        variant = "muted",
    })
    Gui:Acquire("Label", pane, {
        text    = "  WoWInterface: https://www.wowinterface.com/downloads/info27136",
        variant = "muted",
    })
    Gui:Acquire("Label", pane, {
        text    = "  GitHub:      https://github.com/ChronicTinkerer/Forge",
        variant = "muted",
    })
end


Changelog.descriptor = {
    name        = "Changelog",
    title       = "Changelog",
    order       = 998,                 -- second-rightmost tab (About is 999)
    description = "Release notes (link to project pages).",
    OnTabShow   = onShow,
}

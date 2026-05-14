-- Forge.About: built-in tab showing build / author / license / Cairn
-- + LibCodex status, plus the per-Forge_*-addon build list. Lives at
-- order 999 so it's the rightmost tab in the strip.

local ADDON, ns = ...

local About = {}
ns.About = About


local function onShow(pane, mod)
    if pane.Cairn._builtOnce then return end
    pane.Cairn._builtOnce = true

    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    pane.Cairn:SetLayout("Stack", { direction = "vertical", gap = 6, padding = 16 })

    Gui:Acquire("Label", pane, {
        text    = "Forge build " .. (ns.BUILD or "?"),
        variant = "heading",
    })

    Gui:Acquire("Label", pane, { text = "Developer tools suite for Cairn / LibCodex addon authors." })
    Gui:Acquire("Label", pane, {
        text    = "Author: ChronicTinkerer  |  License: All Rights Reserved",
        variant = "muted",
    })

    Gui:Acquire("Label", pane, {
        text    = "Dependencies",
        variant = "heading",
    })
    Gui:Acquire("Label", pane, {
        text    = "  Cairn:    " .. (Cairn and "OK" or "MISSING"),
    })
    Gui:Acquire("Label", pane, {
        text    = "  LibCodex: " .. (((LibStub and LibStub("LibCodex-1.0", true))) and "OK" or "absent (optional)"),
        variant = "muted",
    })

    Gui:Acquire("Label", pane, {
        text    = "Loaded Forge sub-addons",
        variant = "heading",
    })

    local list = ns.listForgeAddonFolders and ns.listForgeAddonFolders() or {}
    if #list == 0 then
        Gui:Acquire("Label", pane, {
            text    = "  (none loaded)",
            variant = "muted",
        })
    else
        for _, addonName in ipairs(list) do
            local build = ns.readBuild and ns.readBuild(addonName) or "?"
            Gui:Acquire("Label", pane, {
                text = ("  %-26s  build %s"):format(addonName, build),
            })
        end
    end
end


About.descriptor = {
    name        = "About",
    title       = "About",
    order       = 999,
    description = "Build info, dependencies, loaded sub-addons.",
    OnTabShow   = onShow,
}

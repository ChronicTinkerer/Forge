-- Forge_Registry: a "what's wired up" browser for every Cairn registry.
-- Left pane = registry type (Addons, Hooks, Timers, Events, ...).
-- Right pane = entries in the selected registry, with a detail row per click.
--
-- Each registry source is defined declaratively in Sources.lua; this file
-- handles bootstrap, persisted state, slash, and the Forge tab descriptor.

local ADDON, ns = ...

ns.VERSION = "0.1.0-dev"

local db = Cairn.DB.New("ForgeRegistryDB", {
    defaults = {
        profile = {
            selectedSource = "Addons",
            searchText     = "",
        },
    },
    profileType = "default",  -- account-level: Forge is a dev tool, no per-char variation
})
ns.db = db

local addon = Cairn.Addon.New("Forge_Registry")
ns.addon = addon

-- ----- Settings API (used by the UI) ------------------------------------
function ns.GetSelectedSource()  return db.profile.selectedSource or "Addons" end
function ns.SetSelectedSource(s) db.profile.selectedSource = s or "Addons" end

function ns.GetSearchText()      return db.profile.searchText or "" end
function ns.SetSearchText(s)     db.profile.searchText = s or "" end

-- ----- Tab descriptor ---------------------------------------------------
local descriptor = {
    name        = "Registry",
    title       = "Registry",
    order       = 35,
    description = "Browse every Cairn registry.",
    SlashSub    = { name = "registry", help = "open the Registry tab" },
    OnTabShow   = function(parent, mod)
        if not mod._built then
            if ns.UI and ns.UI.Build then ns.UI.Build(parent, mod) end
            mod._built = true
        end
        if mod._frame then mod._frame:Show() end
        if ns.UI and ns.UI.OnTabShow then ns.UI.OnTabShow(mod) end
    end,
    OnTabHide   = function(parent, mod)
        if mod._frame then mod._frame:Hide() end
    end,
}
ns.descriptor = descriptor

-- ----- Lifecycle --------------------------------------------------------
function addon:OnInit()
    local _ = db.profile
    -- One-time migration to account-level profile (see Forge_Logs/Core.lua).
    if db.global and not db.global.__acctMigrated then
        if (db:GetCurrentProfile() or "") ~= "Default" then
            db:SetProfile("Default")
        end
        db.global.__acctMigrated = true
    end
    if db.profile.selectedSource == nil then db.profile.selectedSource = "Addons" end
    if db.profile.searchText     == nil then db.profile.searchText     = ""        end
end

function addon:OnLogin()
    if Forge and Forge.Registry then
        Forge.Registry.Register(descriptor)
    end
    local log = self:Log()
    if log then log:Info("Forge_Registry v%s registered.", ns.VERSION) end
end

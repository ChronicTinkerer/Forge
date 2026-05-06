-- Forge_APIRef: in-game WoW API reference.
--
-- Per-namespace data ships in LoadOnDemand sibling addons named
-- `Forge_APIRef-<Namespace>` (e.g. `Forge_APIRef-C_Map`). The siblings each
-- declare `## LoadOnDemand: 1` and have `Forge_APIRef` as a hard dep, so
-- WoW only loads the data when the parent demand-loads them on first
-- :Lookup against that namespace.
--
-- Architecture:
--   Core.lua    DB, Cairn.Addon lifecycle, Forge.Registry descriptor.
--   Lookup.lua  Public Forge_APIRef:Lookup() / :Register() API.
--   UI.lua      (deferred) browsing tab UI; built against Cairn-Gui-Core-1.0.
--
-- LoD note: this addon is LoadOnDemand. The descriptor MUST be registered
-- in OnInit (not OnLogin). See cairn_events_no_retro_login.

local ADDON, ns = ...

ns.VERSION = "0.1.0-dev"

-- Expose globally so consumers (Forge_Console hover, /dump, etc.) can hit
-- ForgeAPIRef:Lookup directly. ns.Lookup is the implementation.
_G.ForgeAPIRef = ns

-- --------------------------------------------------------------------------
-- DB. Mostly a vehicle for cached UI state today; future passes may store
-- per-character pinned entries or recent lookups.
-- --------------------------------------------------------------------------
local db = Cairn.DB.New("ForgeAPIRefDB", {
    defaults = {
        profile = {
            ui = {
                lastSearch   = "",
                lastCategory = "All",
                pinned       = {},
            },
        },
        global = {
            firstSeen = nil,
            lastSeen  = nil,
        },
    },
    profileType = "default",
})
ns.db = db

-- --------------------------------------------------------------------------
-- Tiny chat helper.
-- --------------------------------------------------------------------------
local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge APIRef:|r " .. tostring(msg))
    end
end
ns.out = out

-- --------------------------------------------------------------------------
-- Forge.Registry descriptor.
-- --------------------------------------------------------------------------
local descriptor = {
    name        = "APIRef",
    title       = "API Ref",
    order       = 35,
    description = "WoW API reference: signatures, flags, patch history.",
    SlashSub    = { name = "apiref", help = "open the API reference tab" },
    OnTabShow   = function(parent, mod)
        if not mod._built then
            if ns.UI and ns.UI.Build then
                ns.UI.Build(parent, mod)
                mod._built = true
            else
                -- UI module not yet implemented (deferred to next session).
                -- Render a placeholder so the tab clicks don't error out.
                local f = CreateFrame("Frame", nil, parent)
                f:SetAllPoints(parent)
                local msg = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                msg:SetPoint("CENTER")
                msg:SetText("|cffd87f3aForge_APIRef|r data layer is loaded.\n"
                    .. "Browsing UI lands in a follow-up build.\n\n"
                    .. "For now, query from /run or /dump:\n"
                    .. "|cffaaaaaa/dump ForgeAPIRef:Lookup(\"C_Map.GetBestMapForUnit\")|r")
                msg:SetJustifyH("CENTER"); msg:SetJustifyV("MIDDLE")
                mod._frame = f
            end
        end
        if mod._frame then mod._frame:Show() end
        if ns.UI and ns.UI.OnTabShow then ns.UI.OnTabShow(mod) end
    end,
    OnTabHide   = function(parent, mod)
        if mod._frame then mod._frame:Hide() end
        if ns.UI and ns.UI.OnTabHide then ns.UI.OnTabHide(mod) end
    end,
}
ns.descriptor = descriptor

-- --------------------------------------------------------------------------
-- Addon lifecycle.
-- --------------------------------------------------------------------------
local addon = Cairn.Addon.New("Forge_APIRef")
ns.addon = addon

function addon:OnInit()
    local _ = db.profile

    if db.global and not db.global.__acctMigrated then
        if (db:GetCurrentProfile() or "") ~= "Default" then
            db:SetProfile("Default")
        end
        db.global.__acctMigrated = true
    end

    if db.profile.ui == nil then db.profile.ui = {} end

    if Forge and Forge.Registry then
        Forge.Registry.Register(descriptor)
    end
end

function addon:OnLogin()
    db.global.lastSeen = (time and time()) or os.time()
    if not db.global.firstSeen then
        db.global.firstSeen = db.global.lastSeen
    end

    local log = self:Log()
    if log then log:Info("Forge_APIRef v%s loaded.", ns.VERSION) end
end

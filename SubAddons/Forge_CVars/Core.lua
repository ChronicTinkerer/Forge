-- Forge_CVars: in-game CVar browser and editor.
--
-- Scope: every entry returned by C_Console.GetAllCommands (CVars, command-
-- CVars, and pure slash commands), filterable to whatever subset the user
-- wants. Inline edit with a risky-CVar confirm guard (see RiskyList.lua).
-- Named profiles let you save and switch sets of CVars per play style.
--
-- Architecture:
--   Core.lua       - DB, addon lifecycle, Forge.Registry descriptor (registered in OnInit).
--   Snapshot.lua   - Cached snapshot of all C_Console commands; query / filter API.
--   RiskyList.lua  - Allowlist of CVars that pop a confirm modal on edit.
--   Profiles.lua   - Named-set save/load/apply backed by SavedVariables.
--   EditModal.lua  - Inline edit + risky-confirm modal.
--   List.lua       - Virtualized HybridScrollFrame list (~3000 rows).
--   UI.lua         - Top-level layout assembled by Forge's tab system.
--
-- LoD note: this addon is LoadOnDemand. The descriptor MUST be registered in
-- OnInit, not OnLogin, because Cairn.Events does not retro-fire PLAYER_LOGIN
-- for LoD addons loaded mid-session via user click.

local ADDON, ns = ...

ns.VERSION = "0.1.0-dev"

-- Expose the namespace globally so it's reachable from /dump for debugging:
--   /dump ForgeCVars.Snapshot.GetAll()[1]
--   /dump #ForgeCVars.Snapshot.GetAll()
-- This is dev-affordance, not API surface; real consumers go through
-- Forge.Registry.
_G.ForgeCVars = ns

-- --------------------------------------------------------------------------
-- DB.
-- --------------------------------------------------------------------------
local db = Cairn.DB.New("ForgeCVarsDB", {
    defaults = {
        profile = {
            -- Last-seen UI state, restored on tab open.
            ui = {
                lastSearch        = "",
                lastCategory      = "All",
                showModifiedOnly  = false,
                sort              = "name",     -- "name" | "category" | "modified"
                sortDir           = "asc",
            },
            -- Named CVar profiles. Each profile is a sparse map of
            -- cvarName -> stringValue (CVars are always strings at the API
            -- level; conversion happens in EditModal.lua per declared type).
            -- A profile only stores values that differ from default; loading
            -- "Default" means "reset every CVar to its default".
            cvarProfiles  = {},
            activeProfile = nil,
        },
        global = {
            firstSeen = nil,
            lastSeen  = nil,
        },
    },
    profileType = "default",  -- account-level: CVars are mostly account-wide
})
ns.db = db

-- --------------------------------------------------------------------------
-- Tiny chat helper (mirrors Forge's so /print-style messages are consistent).
-- --------------------------------------------------------------------------
local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge CVars:|r " .. tostring(msg))
    end
end
ns.out = out

-- --------------------------------------------------------------------------
-- Forge.Registry descriptor.
--
-- OnTabShow lazily builds the UI on first show, then re-shows the cached
-- frame on subsequent visits. Mirrors the Forge_Console pattern.
-- --------------------------------------------------------------------------
local descriptor = {
    name        = "CVars",
    title       = "CVars",
    order       = 30,
    description = "Browse and edit every console variable; save named profiles.",
    SlashSub    = { name = "cvars", help = "open the CVars tab" },
    OnTabShow   = function(parent, mod)
        if not mod._built then
            if ns.UI and ns.UI.Build then
                ns.UI.Build(parent, mod)
                mod._built = true
            else
                ns.out("UI module not loaded; check TOC file order.")
                return
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
--
-- Register the descriptor in OnInit (NOT OnLogin) so that LoD-loaded
-- mid-session installs still wire the tab. See cairn_events_no_retro_login.
-- --------------------------------------------------------------------------
local addon = Cairn.Addon.New("Forge_CVars")
ns.addon = addon

function addon:OnInit()
    -- Force lazy DB init so .profile is available below.
    local _ = db.profile

    -- One-time migration to account-level profile (mirrors Forge_Console).
    if db.global and not db.global.__acctMigrated then
        if (db:GetCurrentProfile() or "") ~= "Default" then
            db:SetProfile("Default")
        end
        db.global.__acctMigrated = true
    end

    -- Defaults aren't retroactive in Cairn.DB; ensure required keys exist.
    if db.profile.ui            == nil then db.profile.ui            = {} end
    if db.profile.cvarProfiles  == nil then db.profile.cvarProfiles  = {} end

    -- Register with the Forge tab registry. Has to be OnInit not OnLogin
    -- because this addon may be LoadOnDemand-loaded after PLAYER_LOGIN.
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
    if log then log:Info("Forge_CVars v%s loaded.", ns.VERSION) end
end

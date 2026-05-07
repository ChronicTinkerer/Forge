-- Forge_CairnInspect: live introspection for Cairn-Gui-2.0 widgets.
-- Consumes Decision 10B APIs (Inspector / Stats / EventLog / DevAPI).
--
-- The library exposes data; this addon owns the visualization. We keep
-- this Core module thin -- descriptor + lifecycle + saved-variables
-- defaults -- and put the rendering work in UI.lua.

local ADDON, ns = ...

ns.VERSION = "0.1.0"

ns.db = Cairn.DB.New("ForgeCairnInspectDB", {
    defaults = {
        profile = {
            -- UI preferences. All optional; sensible defaults match the
            -- "I just opened this and want to see things" experience.
            statsRefreshSec  = 0.5,    -- live stats refresh interval (seconds)
            eventLogPaused   = false,  -- start unpaused
            statsPaused      = false,
            treeFilter       = "",     -- last-used substring filter for tree
            eventLogFilter   = "",     -- last-used filter for event log
            autoEnableLog    = true,   -- enable Core.EventLog on first tab show
        },
    },
    profileType = "default",  -- account-level: dev tool, no per-char variation
})

local addon = Cairn.Addon.New("Forge_CairnInspect")
ns.addon = addon

-- ----- Forge.Registry descriptor -----------------------------------------
-- Per the forge_lod_pattern memory: pure UI tools register in OnInit
-- (NOT OnLogin), because LoadOnDemand sub-addons don't retro-fire
-- PLAYER_LOGIN. OnInit runs whenever Cairn.Addon initializes the addon,
-- regardless of when in the load sequence.

local descriptor = {
    name        = "CairnInspect",
    title       = "Cairn-Inspect",
    order       = 25,   -- between APIRef (20) and CVars (30) in the tab strip
    description = "Live introspection of Cairn-Gui-2.0 widgets, stats, and events.",
    SlashSub    = { name = "cairninspect", help = "open the Cairn-Inspect tab" },
    OnTabShow   = function(parent, mod)
        if not mod._built then
            if ns.UI and ns.UI.Build then
                ns.UI.Build(parent, mod)
                mod._built = true
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

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge:|r " .. tostring(msg))
    end
end
ns.out = out

function addon:OnInit()
    -- Force lazy DB init so saved-variable defaults are visible.
    local _ = ns.db.profile

    -- Migration + ensure required keys exist (Cairn.DB doesn't retro-merge defaults).
    local p = ns.db.profile
    if p.statsRefreshSec  == nil then p.statsRefreshSec  = 0.5 end
    if p.eventLogPaused   == nil then p.eventLogPaused   = false end
    if p.statsPaused      == nil then p.statsPaused      = false end
    if p.treeFilter       == nil then p.treeFilter       = "" end
    if p.eventLogFilter   == nil then p.eventLogFilter   = "" end
    if p.autoEnableLog    == nil then p.autoEnableLog    = true end

    -- Register the descriptor with Forge.Registry. Per the
    -- forge_lod_pattern memory, this happens in OnInit (not OnLogin)
    -- because LoadOnDemand sub-addons miss the retro PLAYER_LOGIN
    -- broadcast that eager addons rely on.
    if Forge and Forge.Registry then
        Forge.Registry.Register(descriptor)
    end

    -- Register slash subcommand.
    if Forge and Forge.slash then
        Forge.slash:Subcommand("cairninspectstats", function()
            -- Quick chat dump of the current stats snapshot. Useful as a
            -- low-ceremony "is anything happening" check.
            local Core = LibStub("Cairn-Gui-2.0", true)
            if not (Core and Core.Stats) then
                out("Cairn-Gui-2.0 Stats not loaded.")
                return
            end
            local s = Core.Stats:Snapshot()
            out(string.format("anims: %d/%d (active %d)  layout: %d  events: %d  pool: %d",
                s.animations.added, s.animations.completed, s.animations.active,
                s.layout.recomputes, s.events.dispatches, s.pool._total or 0))
        end, "print a one-line Cairn-Gui-2.0 stats snapshot")
    end
end

function addon:OnLogin()
    local log = self:Log()
    if log then log:Info("Forge_CairnInspect v%s registered.", ns.VERSION) end
end

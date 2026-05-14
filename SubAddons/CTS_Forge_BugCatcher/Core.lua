-- Forge_BugCatcher: Lua error handler with browsable viewer.
--
-- Eager-loaded (no LoadOnDemand): error capture must start at session
-- boot, not when the user opens the tab. The descriptor registers
-- itself on OnInit so the parent's tab strip picks it up at PLAYER_LOGIN.
--
-- Sub-addon naming: sub-addons drop the "2" suffix that the parent
-- carries during the rebuild (Forge). When the parent is renamed back
-- to Forge, no sub-addon rename is needed — they're already at their
-- final names.

local ADDON, ns = ...

_G.Forge_BugCatcher = ns


Cairn.Register("CTS_Forge_BugCatcher", ns, {
    dbName = "Forge_BugCatcherDB",
    Log    = true,        -- ns:Info / ns:Warn / ns:Error / ns:Category
    Events = true,
    Hooks  = true,
    Timer  = true,
    Media  = true,

    dbDefaults = {
        profile = {
            errors  = {},
            ignored = {},
            options = { autoPopup = false },
        },
        global = {
            firstSeen     = nil,
            totalSessions = 0,
        },
    },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_BugCatcher"]
local db        = _entry and _entry.db
ns.db           = db

local addon = _entry and _entry.cairnAddon
ns.addon    = addon


local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge:|r " .. tostring(msg))
    end
end
ns.out = out


-- ---------------------------------------------------------------------------
-- Tab descriptor
-- ---------------------------------------------------------------------------
-- The descriptor table IS the module object passed back to OnTabShow /
-- OnTabHide. Per-instance state goes on `mod`, not on `ns`, so a future
-- re-acquire path doesn't carry stale state.

ns.descriptor = {
    name        = "BugCatcher",
    title       = "Bug Catcher",
    order       = 10,
    description = "Captures Lua errors quietly.",
    SlashSub    = { name = "bug", help = "open the bug viewer" },

    OnTabShow = function(pane, mod)
        if pane.Cairn._builtOnce then
            if ns.Viewer and ns.Viewer.Refresh then
                ns.Viewer.Refresh(pane, mod)
            end
            return
        end
        pane.Cairn._builtOnce = true

        if ns.Viewer and ns.Viewer.Build then
            ns.Viewer.Build(pane, mod)
        else
            -- Fallback placeholder until Viewer.lua is wired up.
            local Gui = LibStub("Cairn-Gui-2.0", true)
            if Gui then
                pane.Cairn:SetLayout("Stack",
                    { direction = "vertical", gap = 6, padding = 16 })
                Gui:Acquire("Label", pane, {
                    text    = "Bug Catcher",
                    variant = "heading",
                })
                Gui:Acquire("Label", pane, {
                    text    = "Viewer not yet built. Capture is running in the background.",
                    variant = "muted",
                })
            end
        end
    end,

    OnTabHide = function(pane, mod)
        -- No teardown needed; the Cairn-Gui pane keeps its children pooled
        -- and we re-render via Refresh on next OnTabShow.
    end,
}


-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function addon:OnInit()
    -- Touching db.profile materializes the bucket and runs default-merge.
    local _ = db.profile

    -- Install error capture as early as possible. Sub-addon files load
    -- BEFORE PLAYER_LOGIN, and OnInit runs at ADDON_LOADED — both happen
    -- early enough to catch errors thrown by other addons during their
    -- own load + login phases.
    if ns.Capture and ns.Capture.Install then
        ns.Capture.Install(db)
    end

    -- Register the descriptor with the parent's registry. The parent's
    -- LoD-stub scanner skips eager-loaded sub-addons, so we register
    -- ourselves here. OnInit is mandatory (not OnLogin) so that a future
    -- LoD-loaded variant works the same way.
    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
end


function addon:OnLogin()
    db.global.totalSessions = (db.global.totalSessions or 0) + 1
    if not db.global.firstSeen then
        db.global.firstSeen = (time and time()) or 0
    end

    -- Auto-popup: when an error is captured AND the option is on, open the
    -- Bug Catcher tab. Rate-limited to once every 5s so an error storm
    -- doesn't keep snapping the window open faster than the user can close
    -- it. Tab is reused — opening when already open is a no-op visually.
    local lastAutoPopupTs = 0
    if ns.Capture and ns.Capture.OnChange then
        ns.Capture.OnChange(function()
            local opts = ns.Capture.GetOptions and ns.Capture.GetOptions() or nil
            if not (opts and opts.autoPopup) then return end
            local now = (GetTime and GetTime()) or 0
            if now - lastAutoPopupTs < 5 then return end
            lastAutoPopupTs = now
            if Forge and Forge.Window and Forge.Window.OpenTab then
                Forge.Window.OpenTab("BugCatcher")
            end
        end)
    end

    if ns.Info then
        local status = ns.Capture and ns.Capture.Status and ns.Capture.Status() or nil
        ns:Info("Bug Catcher ready (capture=%s, entries=%d).",
            status and tostring(status.method) or "off",
            status and (status.entries or 0) or 0)
    end

    -- Combat-deferred toast notifications. Captures still happen during
    -- combat; this layer only batches the user-visible alert so we don't
    -- interrupt a pull.
    if ns.Notify and ns.Notify.Init then ns.Notify.Init() end

    -- Settle pause: re-Install once after 2s so a BugGrabber/BugSack that
    -- loaded AFTER us (LoD or post-login) gets a chance to win the
    -- callback probe. Then arm the watchdog so any further stomps trigger
    -- a re-install of OUR handler (only meaningful for the seh path).
    if C_Timer and C_Timer.After then
        C_Timer.After(2, function()
            if ns.Capture and ns.Capture.Install then
                ns.Capture.Install(db, true)
            end
            if ns.Capture and ns.Capture.WireSlotGuard then
                ns.Capture.WireSlotGuard()
            end
        end)
    end
end


-- ---------------------------------------------------------------------------
-- /forge subcommands (diagnostic)
-- ---------------------------------------------------------------------------
-- These attach to the parent's slash router so users get `/forge bugtest`
-- etc. without each sub-addon owning its own slash command.

if Forge and Forge.Slash then
    Forge.Slash:Sub("bugtest", function()
        if ns.Capture and ns.Capture.Add then
            ns.Capture.Add("Forge_BugCatcher manual test error at "
                .. tostring((time and time()) or 0))
            out("injected a test error. Open /forge bug to see it.")
        else
            out("Capture not loaded yet.")
        end
    end, "inject a test error (verifies BugCatcher capture pipeline)")

    Forge.Slash:Sub("listignores", function()
        if not (ns.Capture and ns.Capture.GetIgnoreList) then
            out("Capture not loaded yet.")
            return
        end
        local list = ns.Capture.GetIgnoreList()
        if #list == 0 then
            out("ignore list is empty.")
            return
        end
        out("ignore patterns:")
        for i, pat in ipairs(list) do
            out(("  %d. %s"):format(i, tostring(pat)))
        end
        out("remove one with /forge unignore <index>")
    end, "list current ignore patterns")

    Forge.Slash:Sub("unignore", function(input)
        if not (ns.Capture and ns.Capture.RemoveIgnore) then
            out("Capture not loaded yet.")
            return
        end
        local idx = tonumber(input and input:match("%S+"))
        if not idx then
            out("usage: /forge unignore <index>   (see /forge listignores)")
            return
        end
        local list = ns.Capture.GetIgnoreList()
        local pat  = list and list[idx]
        if not pat then
            out("no ignore at index " .. tostring(idx) .. ".")
            return
        end
        ns.Capture.RemoveIgnore(idx)
        out(("removed: %s"):format(tostring(pat)))
    end, "remove an ignore pattern by index")

    Forge.Slash:Sub("bugstatus", function()
        if not (ns.Capture and ns.Capture.Status) then
            out("Capture not loaded yet.")
            return
        end
        local s = ns.Capture.Status()
        out("install method:   " .. tostring(s.method))
        out("active right now: " .. tostring(s.active))
        out("external grabber: BugGrabber=" .. tostring(s.hasBugGrabber)
            .. "  BugSack=" .. tostring(s.hasBugSack))
        out("callback hooks:   bg=" .. tostring(s.bgRegistered)
            .. "  bs=" .. tostring(s.bsRegistered))
        if s.bgError then out("  bg probe: |cffff8080" .. s.bgError .. "|r") end
        if s.bsError then out("  bs probe: |cffff8080" .. s.bsError .. "|r") end
        out(("bs poll: active=%s  lastSeen=%d  totalRead=%d"):format(
            tostring(s.bsPollActive), s.bsPollLastSeen or 0, s.bsPollTotalRead or 0))
        out(("watchdog: active=%s  checks=%d  reinstalls=%d"):format(
            tostring(s.watchdogActive), s.watchdogChecks or 0, s.watchdogReinstalls or 0))
        out("registered displays: " .. tostring(s.bugDisplayCount or 0))
        out(("entries: %d   ignored: %d   sessions: %d"):format(
            s.entries or 0, s.ignored or 0, db.global.totalSessions or 0))
    end, "show BugCatcher install status")
end

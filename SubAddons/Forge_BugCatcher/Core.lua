-- Forge_BugCatcher: Lua error handler with browsable viewer.

local ADDON, ns = ...

ns.VERSION = "0.1.0-dev"

local db = Cairn.DB.New("ForgeBugCatcherDB", {
    defaults = {
        profile = {
            errors  = {},
            ignored = {},
            options = { autoPopup = false },
        },
        global = {
            sessionStart  = 0,
            totalSessions = 0,
        },
    },
    profileType = "default",  -- account-level: Forge is a dev tool, no per-char variation
})
ns.db = db
-- IMPORTANT: do NOT touch db.profile at file scope. WoW loads SavedVariables
-- AFTER addon files execute but BEFORE ADDON_LOADED fires. Reading db.profile
-- here orphans the wrapper. Capture.Install reads db.profile.errors, so the
-- install + auto-popup wiring all runs from addon:OnInit below.

local addon = Cairn.Addon.New("Forge_BugCatcher")
ns.addon = addon

ns.descriptor = {
    name        = "BugCatcher",
    title       = "Bug Catcher",
    order       = 10,
    description = "Captures Lua errors quietly.",
    SlashSub    = { name = "bug", help = "open the bug viewer" },
    OnTabShow   = function(parent, mod)
        if not mod._built then
            ns.Viewer.Build(parent, mod)
            mod._built = true
        end
        if mod._frame then
            ns.Viewer.Refresh(mod)
            mod._frame:Show()
        end
    end,
    OnTabHide   = function(parent, mod)
        if mod._frame then mod._frame:Hide() end
    end,
}

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge:|r " .. tostring(msg))
    end
end

function addon:OnInit()
    -- SVs are now loaded. Safe to touch db.profile.
    local _ = db.profile
    -- One-time migration to account-level profile (see Forge_Logs/Core.lua).
    if db.global and not db.global.__acctMigrated then
        if (db:GetCurrentProfile() or "") ~= "Default" then
            db:SetProfile("Default")
        end
        db.global.__acctMigrated = true
    end

    ns.Capture.Install(db)

    local lastAutoPopupTs = 0
    ns.Capture.OnChange(function()
        local opts = ns.Capture.GetOptions()
        if not (opts and opts.autoPopup) then return end
        local now = (time and time()) or os.time()
        if now - lastAutoPopupTs < 5 then return end
        lastAutoPopupTs = now
        if Forge and Forge.Window and Forge.Window.OpenTab then
            Forge.Window.OpenTab("BugCatcher")
        end
    end)
end

function addon:OnLogin()
    -- sessionStart is set in Capture.Install (which runs at file scope, before
    -- this lifecycle fires). Just bump session count here.
    db.global.totalSessions = (db.global.totalSessions or 0) + 1

    if Forge and Forge.Registry then
        Forge.Registry.Register(ns.descriptor)
    end

    if ns.Minimap and ns.Minimap.Create then
        ns.Minimap.Create()
    end

    -- Force a re-install 2 seconds after PLAYER_LOGIN to settle in AFTER any
    -- external error tracker's own re-install. Critical when we fell back
    -- to the seh path: their PLAYER_LOGIN handler can stomp us if we got
    -- there first.
    if C_Timer and C_Timer.After then
        C_Timer.After(2, function()
            ns.Capture.Install(db, true)
            ns.Capture.WireSlotGuard()
            local s = ns.Capture.Status()
            local log = self.Log and self:Log() or nil
            if log then
                log:Info("post-login re-install: method=%s active=%s",
                    tostring(s.method), tostring(s.active))
            end
        end)
    end

    -- Diagnostic subcommands on the parent /forge router.
    if Forge and Forge.slash then
        Forge.slash:Subcommand("bugtest", function()
            ns.Capture.Add("Forge_BugCatcher manual test error fired at " .. tostring((time and time()) or 0))
            out("injected a test error. Open /forge bug to see it.")
        end, "inject a test error (verifies BugCatcher capture pipeline)")

        Forge.slash:Subcommand("bugstatus", function()
            local s = ns.Capture.Status()
            out("install method:   " .. tostring(s.method))
            out("active right now: " .. tostring(s.active))
            out("external grabber: " .. tostring(s.hasBugGrabber) ..
                "    external display: " .. tostring(s.hasBugSack))
            out("BG callback: " .. tostring(s.bgRegistered) ..
                "    BS callback: " .. tostring(s.bsRegistered) ..
                "    seh chained: " .. tostring(s.chained))
            if s.bgError then out("|cffff8080BG error:|r " .. tostring(s.bgError)) end
            if s.bsError then out("|cffff8080BS error:|r " .. tostring(s.bsError)) end
            out(string.format("entries: %d   ignored: %d   session count: %d",
                s.entries, s.ignored, s.sessionCount))
            out(string.format("slot-guard hook: %s   fires: %d",
                tostring(s.hookInstalled or false), s.hookFireCount or 0))
            out(string.format("watchdog: active=%s checks=%d reinstalls=%d",
                tostring(s.watchdogActive or false), s.watchdogChecks or 0, s.watchdogReinstalls or 0))
            out(string.format("BS poll: active=%s lastSeen=%d totalRead=%d",
                tostring(s.bsPollActive or false), s.bsPollLastSeen or 0, s.bsPollTotalRead or 0))
        end, "show BugCatcher install status")

        Forge.slash:Subcommand("bugprobe", function(rest)
            local target = (rest and rest:match("%S+")) or "Forge"
            local p = ns.Capture.Probe(target, 50)
            if p.absent then
                out("|cffff8080no global '" .. p.name .. "' present.|r")
                return
            end
            out(string.format("probe %s (%s, %s keys):", p.name, p.kind, tostring(p.count or 0)))
            for _, line in ipairs(p.keys) do
                out("  " .. line)
            end
        end, "list keys/types of a global: /forge bugprobe <GlobalName>")

        Forge.slash:Subcommand("bugretry", function()
            ns.Capture.Install(db, true)
            local s = ns.Capture.Status()
            out("re-installed. method=" .. tostring(s.method) ..
                " active=" .. tostring(s.active))
        end, "force re-install of the BugCatcher handler")
    end

    local log = self:Log()
    if log then
        local s = ns.Capture.Status()
        log:Info("Forge_BugCatcher v%s ready (capture method = %s, active = %s).",
            ns.VERSION, tostring(s.method), tostring(s.active))
    end
end

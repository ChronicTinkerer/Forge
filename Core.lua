-- Forge: developer tools suite for Cairn / LibCodex addon authors.
-- Parent addon. Hosts /forge slash router, sub-module registry, main window.
-- Sub-addons (Forge_BugCatcher, Forge_Macros, Forge_Console, Forge_Inspector,
-- Forge_Logs, Forge_Profiles, Forge_Registry, Forge_AddonManager, Forge_Codex)
-- plug into the registry on PLAYER_LOGIN and add their own tabs to the window.

local ADDON, ns = ...

Forge = ns
ns.VERSION = "0.1.0-dev"

-- Read the live .toc Version (build stamp). Auto-stays in sync with bumps
-- so /forge status doesn't drift from the actual loaded build.
local function readBuild(addonName)
    local v
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        v = C_AddOns.GetAddOnMetadata(addonName, "Version")
    elseif GetAddOnMetadata then
        v = GetAddOnMetadata(addonName, "Version")
    end
    return v or "?"
end
ns.BUILD = readBuild(ADDON)
ns.readBuild = readBuild  -- exposed so the status sub can show sub-addon builds

-- --------------------------------------------------------------------------
-- DB.
-- --------------------------------------------------------------------------
local db = Cairn.DB.New("ForgeDB", {
    defaults = {
        profile = {
            window = {
                x = 0, y = 0, w = 880, h = 560,
                shown = false,
                activeTab = nil,
            },
            -- Dev-only locale override. When set to a locale code (e.g.
            -- "deDE"), Cairn-Locale-1.0 returns strings from that locale
            -- regardless of GetLocale(). nil means use the real GetLocale().
            -- See `/forge locale <code>` to set, `/forge locale clear` to
            -- reset.
            localeOverride = nil,
        },
        global = {
            firstSeen = nil,
            lastSeen  = nil,
        },
    },
    profileType = "default",  -- account-level: Forge is a dev tool, no per-char variation
})
ns.db = db

-- --------------------------------------------------------------------------
-- Tiny chat helper.
-- --------------------------------------------------------------------------
local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge:|r " .. tostring(msg))
    end
end
ns.out = out

-- --------------------------------------------------------------------------
-- Addon lifecycle.
-- --------------------------------------------------------------------------
local addon = Cairn.Addon.New("Forge")
ns.addon = addon

function addon:OnInit()
    -- Force DB init so .profile is available below.
    local _ = db.profile
    -- One-time migration to account-level profile (see Forge_Logs/Core.lua).
    if db.global and not db.global.__acctMigrated then
        if (db:GetCurrentProfile() or "") ~= "Default" then
            db:SetProfile("Default")
        end
        db.global.__acctMigrated = true
    end
end

function addon:OnLogin()
    local log = self:Log()
    if log then
        log:Info("Forge v%s loaded.", ns.VERSION)
        log:Info("  Cairn:    %s", Cairn and "OK" or "MISSING")
        log:Info("  LibCodex: %s", (LibStub and LibStub("LibCodex-1.0", true)) and "OK" or "absent (optional)")
        log:Info("  Profile:  %s", tostring(db:GetCurrentProfile()))
    end

    db.global.lastSeen = (time and time()) or os.time()
    if not db.global.firstSeen then
        db.global.firstSeen = db.global.lastSeen
    end

    -- Restore window if it was open at logout.
    if db.profile.window.shown and ns.Window and ns.Window.Show then
        ns.Window.Show()
    end

    -- Restore the dev locale override if one is saved. Done after Cairn is
    -- loaded but before any sub-module's L["..."] reads in their OnLogin.
    -- (Sub-modules registered via the Registry haven't called OnLogin yet
    -- when this runs - they're invoked afterward via Registry.RunOnLogin.)
    do
        local cl = LibStub and LibStub("Cairn-Locale-1.0", true)
        local code = db.profile.localeOverride
        if cl and code then
            cl.SetOverride(code)
            if log then
                log:Info("  Locale:   override active (%s)", code)
            end
        end
    end

    if log and ns.Registry then
        log:Info("  Sub-modules: %s", ns.Registry.CountString())
    end

    -- Built-in tabs hosted by the parent itself. Order matters for the tab
    -- bar layout: Changelog (998) sits to the left of About (999).
    if ns.Registry then
        if ns.Changelog and ns.Changelog.descriptor then
            ns.Registry.Register(ns.Changelog.descriptor)
        end
        if ns.About and ns.About.descriptor then
            ns.Registry.Register(ns.About.descriptor)
        end
    end

    -- LoD-stub scan: surface tabs for installed-but-unloaded Forge_* sub-addons
    -- so the user can click them to lazy-load. Eager sub-addons that already
    -- registered a real descriptor are left alone (Registry.Register refuses
    -- to downgrade real -> stub).
    --
    -- Indirect via ns.* because the local function is declared further down
    -- in this file (after the slash router section). At file-load time the
    -- assignment ns.scanForgeToolStubs = scanForgeToolStubs has run by the
    -- time PLAYER_LOGIN fires, so this lookup resolves correctly.
    if ns.scanForgeToolStubs then ns.scanForgeToolStubs() end
end

function addon:OnLogout()
    if ns.Window and ns.Window.IsShown then
        db.profile.window.shown = ns.Window.IsShown()
    end
end

-- --------------------------------------------------------------------------
-- Slash router.
-- --------------------------------------------------------------------------
local slash = Cairn.Slash.Register("Forge", "/forge", { aliases = { "/fg" } })
ns.slash = slash

-- --------------------------------------------------------------------------
-- LoD-stub scanner.
--
-- Walks every installed Forge_* addon and, for any LoadOnDemand one that
-- isn't yet loaded but advertises X-Forge-Tool-Name in its TOC, registers a
-- placeholder ("stub") descriptor. The stub renders the tab in the strip; on
-- first click its OnTabShow does C_AddOns.LoadAddOn(name), which fires the
-- sub-addon's OnInit synchronously, which registers the real descriptor
-- (overwriting this stub via Forge.Registry), and then we delegate to the
-- real OnTabShow.
--
-- IMPORTANT: LoD sub-addons MUST register their descriptor in OnInit (not
-- OnLogin). Cairn.Events does not retro-fire PLAYER_LOGIN for late
-- subscribers, so a sub-addon LoD-loaded post-login never sees OnLogin.
-- See cairn_events_no_retro_login memory note.
--
-- TOC fields read:
--   ## X-Forge-Tool-Name: <Title>          -- required, becomes descriptor.name and tab label
--   ## X-Forge-Tool-Order: <number>        -- optional, default 100
--   ## X-Forge-Tool-Icon: <texture path>   -- optional, captured for future tab-strip icons
--   ## LoadOnDemand: 1                     -- only addons with LoD=1 get a stub
-- --------------------------------------------------------------------------
local function scanForgeToolStubs()
    if not (C_AddOns and ns.Registry) then return end
    local count = (C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns()) or 0
    for i = 1, count do
        local nm = C_AddOns.GetAddOnInfo and C_AddOns.GetAddOnInfo(i)
        if nm and nm:match("^Forge_") then
            local toolName = C_AddOns.GetAddOnMetadata(nm, "X-Forge-Tool-Name")
            -- IMPORTANT: GetAddOnMetadata does NOT return the LoadOnDemand TOC
            -- field (it's parsed specially by WoW, not exposed via metadata).
            -- Use C_AddOns.IsAddOnLoadOnDemand instead.
            local lod      = C_AddOns.IsAddOnLoadOnDemand and C_AddOns.IsAddOnLoadOnDemand(nm)
            local loaded   = C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(nm)
            if toolName and toolName ~= "" and lod and not loaded then
                -- Skip if a real (non-stub) descriptor is already registered.
                local existing = ns.Registry.Get(toolName)
                if not (existing and not existing._isStub) then
                    local order = tonumber(C_AddOns.GetAddOnMetadata(nm, "X-Forge-Tool-Order")) or 100
                    local icon  = C_AddOns.GetAddOnMetadata(nm, "X-Forge-Tool-Icon")
                    local addonName = nm
                    local stub = {
                        _isStub    = true,
                        _addonName = addonName,
                        name       = toolName,
                        title      = toolName,
                        order      = order,
                        icon       = icon,
                        OnTabShow  = function(parent, mod)
                            local ok, reason = C_AddOns.LoadAddOn(addonName)
                            if not ok then
                                out(string.format("could not load %s: %s", addonName, tostring(reason)))
                                return
                            end
                            -- The sub-addon's OnInit fired synchronously inside
                            -- LoadAddOn and (if written correctly) called
                            -- Forge.Registry.Register with its real descriptor.
                            local real = ns.Registry.Get(mod.name)
                            if not real or real == mod or real._isStub then
                                out(string.format(
                                    "%s loaded but did not register a descriptor; "
                                    .. "make sure its Core.lua calls Forge.Registry.Register in OnInit (not OnLogin).",
                                    addonName))
                                return
                            end
                            if type(real.OnTabShow) == "function" then
                                local ok2, err = pcall(real.OnTabShow, parent, real)
                                if not ok2 and geterrorhandler then geterrorhandler()(err) end
                            end
                        end,
                    }
                    ns.Registry.Register(stub)
                end
            end
        end
    end
end
ns.scanForgeToolStubs = scanForgeToolStubs

-- Walk WoW's addon list and return every loaded Forge_* folder, sorted.
-- Robust against registry tab-key vs folder-name mismatches (e.g. the tab
-- key "Addons" maps to folder "Forge_AddonManager").
local function listForgeAddonFolders()
    local names = {}
    local count = (C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns())
        or (GetNumAddOns and GetNumAddOns()) or 0
    for i = 1, count do
        local nm
        if C_AddOns and C_AddOns.GetAddOnInfo then
            nm = C_AddOns.GetAddOnInfo(i)
        elseif GetAddOnInfo then
            nm = GetAddOnInfo(i)
        end
        if nm and nm:match("^Forge_") then names[#names + 1] = nm end
    end
    table.sort(names)
    return names
end
ns.listForgeAddonFolders = listForgeAddonFolders

slash:Subcommand("status", function()
    out("Forge v" .. ns.VERSION .. " (build " .. ns.BUILD .. ")")
    out("  Cairn:    " .. (Cairn and "OK" or "MISSING"))
    out("  LibCodex: " .. (((LibStub and LibStub("LibCodex-1.0", true))) and "OK" or "absent"))
    out("  Profile:  " .. tostring(db:GetCurrentProfile()))
    if ns.Registry then
        out("  Sub-modules: " .. ns.Registry.CountString())
    end
    for _, n in ipairs(listForgeAddonFolders()) do
        out(string.format("    %-22s %s", n, readBuild(n)))
    end
end, "show wiring (Cairn, LibCodex, profile, sub-modules + per-addon builds)")

slash:Subcommand("logs", function()
    if ns.Registry and ns.Registry.Get("Logs") and ns.Window then
        ns.Window.OpenTab("Logs")
        return
    end
    out("no log viewer available (install Forge_Logs).")
end, "open the Logs tab")

slash:Subcommand("modules", function()
    if not ns.Registry then out("registry not ready.") return end
    local list = ns.Registry.List()
    if #list == 0 then out("no Forge sub-modules loaded.") return end
    out("loaded sub-modules:")
    for _, name in ipairs(list) do
        local d = ns.Registry.Get(name)
        local title = (d and d.title) or name
        out(string.format("  - %s  (%s)", name, title))
    end
end, "list every Forge sub-module that has registered")

slash:Subcommand("reset", function()
    db:ResetProfile()
    out("profile reset to defaults.")
end, "reset the current profile to defaults")

-- Dev tool: override what GetLocale() returns for every Cairn.Locale
-- instance (every Forge sub-addon, plus any other addon that uses
-- Cairn-Locale-1.0). Lets you preview translations without restarting
-- the WoW client in a different language. Persists across reloads via
-- db.profile.localeOverride; restored at OnLogin.
slash:Subcommand("locale", function(input)
    local cl = LibStub and LibStub("Cairn-Locale-1.0", true)
    if not cl then
        out("Cairn-Locale-1.0 not loaded.")
        return
    end
    local arg = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if arg == "" or arg == "show" then
        local override = cl.GetOverride()
        local active   = (GetLocale and GetLocale()) or "?"
        if override then
            out(string.format("Locale override: |cffd87f3a%s|r (real: %s)", override, active))
        else
            out("Locale override: |cff888888none|r (real: " .. active .. ")")
        end
        out("Usage: /forge locale <code>   e.g. deDE, frFR, esES, ruRU, koKR, zhCN, zhTW")
        out("       /forge locale clear   to remove the override")
        return
    end
    if arg == "clear" or arg == "off" or arg == "none" or arg == "nil" then
        cl.SetOverride(nil)
        db.profile.localeOverride = nil
        out("Locale override cleared.")
        return
    end
    cl.SetOverride(arg)
    db.profile.localeOverride = arg
    out(string.format("Locale override -> |cffd87f3a%s|r. Reload some panels to see changes.", arg))
end, "override Cairn.Locale (dev tool). /forge locale [code|clear|show]")

-- Default action: open (or toggle) the main Forge window. If user typed an
-- unknown subcommand, show help instead.
slash:Default(function(input)
    if input and input:match("%S") then
        out("unknown subcommand: " .. input)
        slash:PrintHelp()
        return
    end
    if ns.Window and ns.Window.Toggle then
        ns.Window.Toggle()
    else
        out("window not yet ready.")
    end
end)

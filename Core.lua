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

    if log and ns.Registry then
        log:Info("  Sub-modules: %s", ns.Registry.CountString())
    end

    -- Built-in About tab (hosted by the parent itself).
    if ns.Registry and ns.About and ns.About.descriptor then
        ns.Registry.Register(ns.About.descriptor)
    end
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

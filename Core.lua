-- Forge: developer tools suite for Cairn / LibCodex addon authors.
-- Parent addon. Hosts /forge slash router, sub-module registry, main window.
-- Sub-addons (Forge_BugCatcher, Forge_Macros, Forge_Console, Forge_Inspector,
-- Forge_Logs, Forge_Profiles, Forge_Setup, Forge_AddonManager, Forge_Codex)
-- plug into the registry on PLAYER_LOGIN and add their own tabs to the window.

local ADDON, ns = ...

Forge = ns
ns.VERSION = "0.1.0-dev"
ns.BUILD   = "2605040127"

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
    profileType = "char",
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

slash:Subcommand("status", function()
    out("v" .. ns.VERSION .. " (build " .. ns.BUILD .. ")")
    out("  Cairn:    " .. (Cairn and "OK" or "MISSING"))
    out("  LibCodex: " .. (((LibStub and LibStub("LibCodex-1.0", true))) and "OK" or "absent"))
    out("  Profile:  " .. tostring(db:GetCurrentProfile()))
    if ns.Registry then
        out("  Sub-modules: " .. ns.Registry.CountString())
    end
end, "show wiring (Cairn, LibCodex, profile, sub-modules)")

slash:Subcommand("logs", function()
    -- Forge_Logs (when installed) registers a "Logs" tab. If it is not
    -- installed, fall back to Cairn.Dashboard so users always have a viewer.
    if ns.Registry and ns.Registry.Get("Logs") and ns.Window then
        ns.Window.OpenTab("Logs")
        return
    end
    if Cairn.Dashboard and Cairn.Dashboard.Toggle then
        Cairn.Dashboard:Toggle()
        return
    end
    out("no log viewer available (install Forge_Logs).")
end, "open the Logs tab (or fall back to Cairn.Dashboard)")

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

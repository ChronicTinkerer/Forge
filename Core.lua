-- Forge (rebuild). Developer tools suite for Cairn / LibCodex addon
-- authors. This parent addon hosts the /forge slash router, the sub-
-- module registry, and the main window. Sub-addons (Forge_*) plug in.
--
-- File map:
--   Core.lua       this file. Lifecycle, slash, locale override, LoD scanner.
--   Registry.lua   sub-module descriptor table.
--   Window.lua     Cairn-Gui-2.0 main window with tab strip.
--   Changelog.lua  built-in tab descriptor for the CHANGELOG view.
--   About.lua      built-in tab descriptor for the About view.

local ADDON, ns = ...

-- Global handle so sub-addons can reach the registry, window, and shared
-- helpers via `Forge.Registry.Register(...)` etc.
_G.Forge = ns


-- Read the live TOC `## Version: N` (the BigWigs-packager build stamp).
-- Auto-stays in sync with release bumps so /forge status reflects the
-- actual loaded build rather than a hardcoded string.
local function readBuild(addonName)
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"
    end
    if GetAddOnMetadata then
        return GetAddOnMetadata(addonName, "Version") or "?"
    end
    return "?"
end
ns.BUILD    = readBuild(ADDON)
ns.readBuild = readBuild  -- exposed for per-sub-addon build display


-- Tiny chat-printer with the Forge orange brand color.
local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge:|r " .. tostring(msg))
    end
end
ns.out = out


-- ---------------------------------------------------------------------------
-- Cairn.Register orchestrator
-- ---------------------------------------------------------------------------
-- Single-call wiring: creates the lifecycle instance, auto-creates a
-- Cairn-DB instance (saved-vars name comes from the TOC -> ForgeDB),
-- and auto-attaches the companion libs we name via `opts`. The `Log`
-- flag uses Cairn-Log's :Embed path so `ns:Info(...) / ns:Warn(...) /
-- ns:Error(...) / ns:Category(...)` work directly on the Forge namespace.
--
-- Account-level profile by default (Forge is a dev tool; per-character
-- variation would create more friction than it solves). The `dbDefaults`
-- here is the same shape Cairn-DB-1.0 expects: top-level buckets at
-- well-known keys.
Cairn.Register("CTS_Forge", ns, {
    dbName = "ForgeDB",   -- pin SV to original "ForgeDB" so existing user data survives the folder rename to CTS_Forge
    Log    = true,        -- ns:Info / ns:Warn / ns:Error / ns:Category
    Events = true,        -- ns.Events
    Hooks  = true,        -- ns.Hooks
    Timer  = true,        -- ns.Timer
    Locale = true,        -- ns.Locale (lib-level; instance comes from :New)
    Media  = true,        -- ns.Media

    dbDefaults = {
        profile = {
            window = {
                x = 0, y = 0, w = 880, h = 560,
                shown     = false,
                activeTab = nil,
            },
            -- Dev-only locale override. When set to a locale code (e.g.
            -- "deDE"), Cairn-Locale-1.0 returns strings from that locale
            -- regardless of GetLocale(). nil means use the real GetLocale().
            -- See `/forge locale <code>` to set, `/forge locale clear`
            -- to remove.
            localeOverride = nil,
        },
        global = {
            firstSeen = nil,
            lastSeen  = nil,
        },
    },
})

-- Grab the DB instance the orchestrator auto-created. Cairn.GetRegistry()
-- exposes the rich entry table keyed by tocName.
local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge"]
local db        = _entry and _entry.db
ns.db           = db


-- Grab the lifecycle instance the same way (or by re-calling
-- Cairn.Addon:New("Forge.toc") which is idempotent on the same name).
local addon = _entry and _entry.cairnAddon
ns.addon    = addon


function addon:OnInit()
    -- Touching db.profile materializes the bucket and runs default-merge.
    -- Idempotent and cheap; just here to force eager init.
    local _ = db.profile
end


function addon:OnLogin()
    -- Log methods are embedded on `ns` by Cairn-Log via :Embed during
    -- Cairn.Register's auto-wire phase. Use ns:Info / ns:Warn / etc.
    if ns.Info then
        ns:Info("Forge build %s loaded.", ns.BUILD)
        ns:Info("  Cairn:    %s", Cairn and "OK" or "MISSING")
        ns:Info("  LibCodex: %s", (LibStub and LibStub("LibCodex-1.0", true)) and "OK" or "absent (optional)")
        ns:Info("  Profile:  %s", tostring(db:GetProfile()))
    end

    db.global.lastSeen = (time and time()) or os.time()
    if not db.global.firstSeen then
        db.global.firstSeen = db.global.lastSeen
    end

    -- Apply the persisted locale override BEFORE sub-modules render their
    -- first frame so they pick up the correct strings on first paint.
    do
        local code = db.profile.localeOverride
        if Cairn.Locale and code then
            Cairn.Locale:SetActiveLocale(code)
            if ns.Info then
                ns:Info("  Locale:   override active (%s)", code)
            end
        end
    end

    -- Built-in tabs hosted by the parent itself. Registered BEFORE the
    -- window restore below: Window.Show snapshots the Registry on first
    -- build and never rebuilds, so any tab registered after that snapshot
    -- won't appear until the user closes + reopens. Changelog (998) and
    -- About (999) sit at the right of the strip via their order field.
    if ns.Registry then
        if ns.Changelog and ns.Changelog.descriptor then
            ns.Registry.Register(ns.Changelog.descriptor)
        end
        if ns.About and ns.About.descriptor then
            ns.Registry.Register(ns.About.descriptor)
        end
    end

    -- LoD-stub scan ALSO runs before Window.Show for the same reason:
    -- stub descriptors for installed-but-unloaded Forge_* sub-addons need
    -- to be in the Registry before the tab strip is snapshotted.
    if ns.scanForgeToolStubs then ns.scanForgeToolStubs() end

    if ns.Info and ns.Registry then
        ns:Info("  Sub-modules: %s", ns.Registry.CountString())
    end

    -- Restore window if it was open at logout. MUST come after all the
    -- Registry.Register calls above; the window snapshots the Registry
    -- the first time it's shown and won't pick up later registrations.
    if db.profile.window.shown and ns.Window and ns.Window.Show then
        ns.Window.Show()
    end

    -- Minimap button. Uses LibDBIcon-1.0 if present, falls back to a
    -- fixed top-right anchor otherwise. Safe to call when the libs are
    -- missing - the fallback handles it.
    if ns.Minimap and ns.Minimap.Create then
        ns.Minimap.Create(db)
    end
end


function addon:OnDisable()
    -- Persist window-open state so the next session can restore it.
    if ns.Window and ns.Window.IsShown then
        db.profile.window.shown = ns.Window.IsShown()
    end
end


-- ---------------------------------------------------------------------------
-- Slash router
-- ---------------------------------------------------------------------------
-- `/forge` opens the window (default action). `/forge <subcommand>` dispatches
-- through Cairn-Slash's nested-tree router. The alias `/fg` is provided
-- for muscle-memory but `/forge` is the canonical form.
local slash = Cairn.Slash:Register("Forge", "/forge", { aliases = { "/fg" } })
ns.Slash = slash


-- ---------------------------------------------------------------------------
-- LoD-stub scanner
-- ---------------------------------------------------------------------------
-- Walks every installed `Forge_*` addon and, for any LoadOnDemand one
-- that isn't yet loaded but advertises `## X-Forge-Tool-Name`, registers
-- a stub descriptor with the Registry. The stub renders the tab in the
-- strip; clicking it calls C_AddOns.LoadAddOn which fires the sub-addon's
-- OnInit synchronously, the sub-addon's OnInit registers its real
-- descriptor (which overwrites the stub via Registry.Register protections),
-- and then we delegate to the real OnTabShow.
--
-- IMPORTANT: LoD sub-addons MUST register their descriptor in OnInit (not
-- OnLogin). PLAYER_LOGIN doesn't fire for a sub-addon LoD-loaded post-
-- login, so OnLogin is the wrong hook.
--
-- TOC fields read:
--   ## X-Forge-Tool-Name: <Title>          required, becomes descriptor.name + tab label
--   ## X-Forge-Tool-Order: <number>        optional, default 100
--   ## X-Forge-Tool-Icon: <texture path>   optional
--   ## LoadOnDemand: 1                     only LoD=1 addons get a stub
local FORGE_TOOL_PREFIX = "CTS_Forge_"


local function scanForgeToolStubs()
    if not (C_AddOns and ns.Registry) then return end
    local count = (C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns()) or 0
    for i = 1, count do
        local nm = C_AddOns.GetAddOnInfo and C_AddOns.GetAddOnInfo(i)
        if nm and nm:sub(1, #FORGE_TOOL_PREFIX) == FORGE_TOOL_PREFIX then
            local toolName = C_AddOns.GetAddOnMetadata(nm, "X-Forge-Tool-Name")
            -- GetAddOnMetadata does NOT return LoadOnDemand (it's parsed
            -- specially by WoW). Use C_AddOns.IsAddOnLoadOnDemand instead.
            local lod    = C_AddOns.IsAddOnLoadOnDemand and C_AddOns.IsAddOnLoadOnDemand(nm)
            local loaded = C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(nm)
            if toolName and toolName ~= "" and lod and not loaded then
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
                                out(("could not load %s: %s"):format(addonName, tostring(reason)))
                                return
                            end
                            -- The sub-addon's OnInit fired inside LoadAddOn
                            -- and (if written correctly) called
                            -- Forge.Registry.Register with its real
                            -- descriptor.
                            local real = ns.Registry.Get(mod.name)
                            if not real or real == mod or real._isStub then
                                out(("%s loaded but did not register a descriptor; "
                                     .. "make sure its Core.lua calls Forge.Registry.Register in OnInit (not OnLogin)."):format(addonName))
                                return
                            end
                            if type(real.OnTabShow) == "function" then
                                local ok2, err = pcall(real.OnTabShow, parent, real)
                                if not ok2 then geterrorhandler()(err) end
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


-- Enumerate every loaded Forge_* folder, sorted. Used by /forge status
-- for the per-sub-addon build display.
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
        if nm and nm:sub(1, #FORGE_TOOL_PREFIX) == FORGE_TOOL_PREFIX then
            names[#names + 1] = nm
        end
    end
    table.sort(names)
    return names
end
ns.listForgeAddonFolders = listForgeAddonFolders


-- ---------------------------------------------------------------------------
-- /forge subcommands
-- ---------------------------------------------------------------------------

slash:Sub("status", function()
    out("Forge build " .. ns.BUILD)
    out("  Cairn:    " .. (Cairn and "OK" or "MISSING"))
    out("  LibCodex: " .. (((LibStub and LibStub("LibCodex-1.0", true))) and "OK" or "absent"))
    out("  Profile:  " .. tostring(db:GetProfile()))
    if ns.Registry then
        out("  Sub-modules: " .. ns.Registry.CountString())
    end
    for _, n in ipairs(listForgeAddonFolders()) do
        out(("    %-22s %s"):format(n, readBuild(n)))
    end
end, "show wiring (Cairn / LibCodex / profile / sub-modules / per-addon builds)")


slash:Sub("logs", function()
    if ns.Registry and ns.Registry.Get("Logs") and ns.Window then
        ns.Window.OpenTab("Logs")
        return
    end
    out("no log viewer available (install Forge_Logs).")
end, "open the Logs tab")


slash:Sub("modules", function()
    if not ns.Registry then out("registry not ready.") return end
    local list = ns.Registry.List()
    if #list == 0 then out("no Forge sub-modules loaded.") return end
    out("loaded sub-modules:")
    for _, name in ipairs(list) do
        local d = ns.Registry.Get(name)
        local title = (d and d.title) or name
        out(("  - %s  (%s)"):format(name, title))
    end
end, "list every Forge sub-module that has registered")


slash:Sub("reset", function()
    -- Re-create the default profile in-place by re-running wildcardMerge.
    -- Cairn-DB-1.0 doesn't currently expose :ResetProfile (it's on the
    -- roadmap for v1 of the spec-aware-profile work); for now we just
    -- nil out the bucket and let the next access re-fill from defaults.
    local profile = db.profile
    for k in pairs(profile) do profile[k] = nil end
    -- Force re-fill from defaults table.
    db:SetProfile(db:GetProfile())
    out("profile reset to defaults.")
end, "reset the current profile to defaults")


-- Dev tool: override what GetLocale() returns for every Cairn-Locale
-- instance (every Forge sub-addon, plus any other addon using
-- Cairn-Locale-1.0). Lets you preview translations without restarting
-- WoW in a different language. Persists via db.profile.localeOverride;
-- restored at OnLogin.
slash:Sub("locale", function(input)
    local cl = Cairn and Cairn.Locale
    if not cl then out("Cairn-Locale-1.0 not loaded.") return end

    local arg = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if arg == "" or arg == "show" then
        local override = db.profile.localeOverride
        local active   = cl:GetLocale()
        if override then
            out(("Locale override: |cffd87f3a%s|r (effective: %s)"):format(override, active))
        else
            out("Locale override: |cff888888none|r (effective: " .. active .. ")")
        end
        out("Usage: /forge locale <code>   e.g. deDE, frFR, esES, ruRU, koKR, zhCN, zhTW")
        out("       /forge locale clear   remove the override")
        return
    end
    if arg == "clear" or arg == "off" or arg == "none" or arg == "nil" then
        cl:SetActiveLocale(nil)
        db.profile.localeOverride = nil
        out("Locale override cleared.")
        return
    end
    cl:SetActiveLocale(arg)
    db.profile.localeOverride = arg
    out(("Locale override -> |cffd87f3a%s|r. Reload panels to see changes."):format(arg))
end, "override Cairn.Locale (dev tool). /forge locale [code|clear|show]")


-- Default action: open / toggle the main window. I
-- Forge_AddonManager: in-game addon enable/disable with named sets,
-- per-addon memory + load info, search, sortable columns, dependency
-- tooltips, recursive enable, protected addons, and auto-disable-new.

local ADDON, ns = ...

ns.VERSION = "0.1.0-dev"

local db = Cairn.DB.New("ForgeAddonManagerDB", {
    defaults = {
        profile = {
            sets         = {},   -- name -> { addonName, addonName, ... }
            protected    = {},   -- name -> true
            knownAddons  = {},   -- name -> true (snapshot of every addon ever seen)
            options      = {
                recursiveEnable  = true,
                loadChildAddons  = false,
                autoDisableNew   = false,
            },
        },
    },
    profileType = "default",  -- account-level: Forge is a dev tool, no per-char variation
})
ns.db = db

-- IMPORTANT: do NOT touch db.profile at file scope. WoW loads SavedVariables
-- AFTER the addon's files execute but BEFORE ADDON_LOADED fires. Triggering
-- Cairn.DB.init() here would pin the wrapper to a fresh empty SV table; WoW
-- would then overwrite _G[svName] with disk data, leaving the wrapper
-- orphaned. The first db.profile access happens in OnInit below.

ns.Manager.Bind(db)

local addon = Cairn.Addon.New("Forge_AddonManager")
ns.addon = addon

local descriptor = {
    name        = "Addons",
    title       = "Addons",
    order       = 50,
    description = "In-game addon manager with named sets.",
    SlashSub    = { name = "addon", help = "open the Addons tab" },
    OnTabShow   = function(parent, mod)
        if not mod._built then
            ns.UI.Build(parent, mod)
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

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge:|r " .. tostring(msg))
    end
end
ns.out = out

-- NOTE: previously this file declared a "FORGE_ADDONMANAGER_RELOAD" StaticPopup
-- shown from OnLogin to nudge the user about auto-disable. That popup tainted
-- the GameMenu's secure callback chain in modern Retail (120005): showing a
-- StaticPopup from PLAYER_LOGIN attaches it to the global escape-close chain,
-- and pressing ESC later raised ADDON_ACTION_FORBIDDEN from
-- Blizzard_GameMenu/Shared/GameMenuFrame.lua's callback iterator with
-- Forge_AddonManager blamed. Replaced by a chat nudge below; the user clicks
-- Apply inside the Forge -> Addons tab (a real hardware click) to commit.

function addon:OnInit()
    -- ADDON_LOADED fired; SVs are populated. Trigger lazy init of Cairn.DB
    -- now so the wrapper binds to the disk-loaded _G[svName].
    local _ = db.profile
    -- One-time migration to account-level profile (see Forge_Logs/Core.lua).
    if db.global and not db.global.__acctMigrated then
        if (db:GetCurrentProfile() or "") ~= "Default" then
            db:SetProfile("Default")
        end
        db.global.__acctMigrated = true
    end

    -- Force-init missing keys (Cairn.DB doesn't retro-merge defaults).
    if db.profile.sets        == nil then db.profile.sets        = {} end
    if db.profile.protected   == nil then db.profile.protected   = {} end
    if db.profile.knownAddons == nil then db.profile.knownAddons = {} end
    if db.profile.options     == nil then db.profile.options     = {} end
    if db.profile.options.autoDisableNew  == nil then db.profile.options.autoDisableNew  = false end
    if db.profile.options.recursiveEnable == nil then db.profile.options.recursiveEnable = true end
    if db.profile.options.loadChildAddons == nil then db.profile.options.loadChildAddons = false end
end

function addon:OnLogin()
    ns.Manager._SnapshotInitial()
    ns.Manager.Refresh()
    -- NOTE: ClearPending() removed - pending changes are now persistent
    -- across reloads. Calling Apply consumes the queue.

    -- Detect new addons and auto-re-enable protected. Both QUEUE changes
    -- only - no C_AddOns calls happen here, so no taint window. The popup's
    -- buttons run from a hardware click, where the actual API call is safe.
    local changes = ns.Manager.CheckNewAddons()
    if changes.firstRun then
        out("first run: snapshotted " .. tostring(#changes.newlySeen) ..
            " installed addons as 'known'. Auto-disable will catch genuinely new ones from here on.")
    elseif changes.newlySeen and #changes.newlySeen > 0 then
        out("new addons detected: " .. table.concat(changes.newlySeen, ", "))
    end
    if changes.newlyDisabled and #changes.newlyDisabled > 0 then
        local list = table.concat(changes.newlyDisabled, ", ")
        out("|cffffaa00auto-disabled new addons|r (queued): " .. list)
        out("Open |cffd87f3a/forge|r -> |cffd87f3aAddons|r and click |cff80ff80Apply + Reload|r to commit.")
    end

    -- Queue re-enables for any protected addon that's currently disabled.
    -- No C_AddOns call here; user applies on next click.
    for name in pairs(db.profile.protected) do
        if not ns.Manager.IsEnabled(name) then
            ns.Manager.SetEnabled(name, true)
        end
    end

    if Forge and Forge.Registry then
        Forge.Registry.Register(descriptor)
    end

    if Forge and Forge.slash then
        Forge.slash:Subcommand("addonenable", function(rest)
            local name = rest:match("^%s*(%S+)")
            if not name then out("usage: /forge addonenable <name>") return end
            ns.Manager.SetEnabled(name, true)
            out("enabled '" .. name .. "'. ReloadUI to apply.")
        end, "enable an addon by name (reload required)")

        Forge.slash:Subcommand("addondisable", function(rest)
            local name = rest:match("^%s*(%S+)")
            if not name then out("usage: /forge addondisable <name>") return end
            ns.Manager.SetEnabled(name, false)
            out("disabled '" .. name .. "'. ReloadUI to apply.")
        end, "disable an addon by name (reload required)")

        Forge.slash:Subcommand("addonset", function(rest)
            local cmd, arg = rest:match("^%s*(%S+)%s*(.*)$")
            if cmd == "list" then
                local names = ns.Manager.ListSetNames()
                if #names == 0 then out("no sets saved.") return end
                out("sets:")
                for _, n in ipairs(names) do
                    local set = ns.Manager.GetSets()[n] or {}
                    out("  " .. n .. "   |cffaaaaaa(" .. #set .. ")|r")
                end
            elseif cmd == "save" and arg ~= "" then
                ns.Manager.SaveCurrentAsSet(arg)
                out("saved set '" .. arg .. "'.")
            elseif cmd == "load" and arg ~= "" then
                if ns.Manager.LoadSet(arg) then
                    out("loaded set '" .. arg .. "'. ReloadUI to apply.")
                else
                    out("no set named '" .. arg .. "'.")
                end
            elseif cmd == "delete" and arg ~= "" then
                ns.Manager.DeleteSet(arg)
                out("deleted set '" .. arg .. "' (if it existed).")
            else
                out("usage: /forge addonset list  |  save <name>  |  load <name>  |  delete <name>")
            end
        end, "manage addon sets")

        Forge.slash:Subcommand("addonprotect", function(rest)
            local name = rest:match("^%s*(%S+)")
            if not name then out("usage: /forge addonprotect <name>") return end
            ns.Manager.SetProtected(name, not ns.Manager.IsProtected(name))
            out(string.format("'%s' protected: %s", name, tostring(ns.Manager.IsProtected(name))))
        end, "toggle protected status of an addon")

        Forge.slash:Subcommand("addondump", function()
            -- Diagnostic: print what's actually in the SV right now.
            local sv = _G["ForgeAddonManagerDB"]
            if not sv then out("|cffff8080ForgeAddonManagerDB global is nil|r") return end
            local pkeys = sv.profileKeys or {}
            local profiles = sv.profiles or {}
            out("--- ForgeAddonManagerDB ---")
            out("profileKeys:")
            for k, v in pairs(pkeys) do out("  '" .. tostring(k) .. "' -> '" .. tostring(v) .. "'") end
            local current = (db.GetCurrentProfile and db:GetCurrentProfile()) or "?"
            out("current char's profile name: " .. tostring(current))
            local p = profiles[current]
            if not p then
                out("|cffff8080no profile entry for current key|r (so settings load as defaults each session)")
                out("known profile names: ")
                for n in pairs(profiles) do out("  " .. tostring(n)) end
                return
            end
            local opts = p.options or {}
            out(string.format("options.recursiveEnable = %s", tostring(opts.recursiveEnable)))
            out(string.format("options.autoDisableNew  = %s", tostring(opts.autoDisableNew)))
            out(string.format("options.loadChildAddons = %s", tostring(opts.loadChildAddons)))

            -- Identity check: does Manager._db.profile actually point at the
            -- same table the SV holds? If they diverge, writes via the wrapper
            -- never make it into the persisted SV.
            local wrapperProfile = ns.db.profile
            local wrapperOptions = wrapperProfile and wrapperProfile.options or nil
            out("--- identity ---")
            out(string.format("ns.db.profile == sv.profiles[current]: %s", tostring(wrapperProfile == p)))
            out(string.format("ns.db.profile.options == sv profile.options: %s", tostring(wrapperOptions == opts)))
            out(string.format("wrapper options.recursiveEnable = %s",
                tostring(wrapperOptions and wrapperOptions.recursiveEnable)))

            -- Round-trip test: write a sentinel via the wrapper, read via the SV.
            local stamp = tostring((time and time()) or 0)
            ns.db.profile.options = ns.db.profile.options or {}
            ns.db.profile.options._diag_writeStamp = stamp
            local svRead = (sv.profiles[current] and sv.profiles[current].options
                and sv.profiles[current].options._diag_writeStamp) or "(nil)"
            out(string.format("write-stamp via wrapper: '%s'  /  read via SV: '%s'  /  match: %s",
                stamp, svRead, tostring(stamp == svRead)))
            local nProt, nSets, nKnown = 0, 0, 0
            for _ in pairs(p.protected or {})    do nProt  = nProt  + 1 end
            for _ in pairs(p.sets or {})         do nSets  = nSets  + 1 end
            for _ in pairs(p.knownAddons or {})  do nKnown = nKnown + 1 end
            out(string.format("protected: %d entries", nProt))
            out(string.format("sets:      %d entries", nSets))
            out(string.format("knownAddons: %d entries", nKnown))
            -- Live in-memory comparison.
            out("--- in-memory (Manager) ---")
            out(string.format("IsRecursiveEnable(): %s", tostring(ns.Manager.IsRecursiveEnable())))
            out(string.format("IsAutoDisableNew():  %s", tostring(ns.Manager.IsAutoDisableNew())))
        end, "dump the SV state for AddonManager (diagnose persistence)")

        Forge.slash:Subcommand("addonautonew", function()
            local now = not ns.Manager.IsAutoDisableNew()
            ns.Manager.SetAutoDisableNew(now)
            out("auto-disable new addons on next login: " .. (now and "ON" or "OFF"))
        end, "toggle auto-disable-new-addons-on-login")
    end

    local log = self:Log()
    if log then log:Info("Forge_AddonManager v%s registered.", ns.VERSION) end
end

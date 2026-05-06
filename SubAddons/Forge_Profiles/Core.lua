-- Forge_Profiles: cross-addon profile manager.
--
-- Auto-discovers every Cairn.DB instance via Cairn.DB.GetAllInstances and
-- lets the user switch profiles per addon. Named "profile sets" let you
-- snapshot a config across multiple addons (e.g. "Raid", "Solo", "PvP")
-- and restore the whole set in one click.

local ADDON, ns = ...

ns.VERSION = "0.1.0-dev"

local db = Cairn.DB.New("ForgeProfilesDB", {
    defaults = {
        profile = {
            -- sets[name] = { [svName] = profileName, ... }
            sets = {},
        },
    },
    profileType = "default",  -- account-level: Forge is a dev tool, no per-char variation
})
ns.db = db

local addon = Cairn.Addon.New("Forge_Profiles")
ns.addon = addon

local descriptor = {
    name        = "Profiles",
    title       = "Profiles",
    order       = 60,
    description = "Cross-addon profile manager.",
    SlashSub    = { name = "profiles", help = "open the Profiles tab" },
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

-- ----- Discovery / API --------------------------------------------------

-- Returns array of { svName, instance, current, profiles } for every
-- registered Cairn.DB. Sorted by svName.
function ns.ListAddons()
    if not (Cairn and Cairn.DB and Cairn.DB.GetAllInstances) then return {} end
    local instances = Cairn.DB.GetAllInstances() or {}
    local out_list = {}
    for _, inst in ipairs(instances) do
        local svName = inst._svName or "?"
        local current, profiles
        local ok = pcall(function()
            current  = inst:GetCurrentProfile()
            profiles = inst:GetProfiles()
        end)
        if ok then
            out_list[#out_list + 1] = {
                svName   = svName,
                instance = inst,
                current  = current,
                profiles = profiles or {},
            }
        end
    end
    table.sort(out_list, function(a, b) return a.svName < b.svName end)
    return out_list
end

-- Switch a single addon's profile.
function ns.SwitchProfile(svName, profileName)
    if not (Cairn and Cairn.DB and Cairn.DB.GetAllInstances) then return false end
    for _, inst in ipairs(Cairn.DB.GetAllInstances() or {}) do
        if inst._svName == svName then
            local ok, err = pcall(function() inst:SetProfile(profileName) end)
            if not ok then
                out("|cffff8080error switching " .. svName .. ":|r " .. tostring(err))
                return false
            end
            return true
        end
    end
    return false
end

-- ----- Profile sets -----------------------------------------------------

function ns.GetSets()        return db.profile.sets or {} end
function ns.ListSetNames()
    local names = {}
    for k in pairs(db.profile.sets or {}) do names[#names + 1] = k end
    table.sort(names)
    return names
end

-- Snapshot the current profile of every Cairn.DB into a named set.
function ns.SaveCurrentAsSet(name)
    if type(name) ~= "string" or name == "" then return false end
    db.profile.sets = db.profile.sets or {}
    local snapshot = {}
    for _, info in ipairs(ns.ListAddons()) do
        snapshot[info.svName] = info.current
    end
    db.profile.sets[name] = snapshot
    return true
end

-- Apply a saved set: switch each addon to its remembered profile.
function ns.LoadSet(name)
    local set = db.profile.sets and db.profile.sets[name]
    if not set then return false end
    local applied = 0
    for svName, profileName in pairs(set) do
        if ns.SwitchProfile(svName, profileName) then
            applied = applied + 1
        end
    end
    return true, applied
end

function ns.DeleteSet(name)
    if not name then return end
    db.profile.sets = db.profile.sets or {}
    db.profile.sets[name] = nil
end

-- ----- Lifecycle --------------------------------------------------------

function addon:OnInit()
    local _ = db.profile
    -- One-time migration to account-level profile (see Forge_Logs/Core.lua).
    if db.global and not db.global.__acctMigrated then
        if (db:GetCurrentProfile() or "") ~= "Default" then
            db:SetProfile("Default")
        end
        db.global.__acctMigrated = true
    end
    if db.profile.sets == nil then db.profile.sets = {} end
end

function addon:OnLogin()
    if Forge and Forge.Registry then
        Forge.Registry.Register(descriptor)
    end

    if Forge and Forge.slash then
        Forge.slash:Subcommand("profilelist", function()
            local list = ns.ListAddons()
            if #list == 0 then out("no Cairn.DB addons registered.") return end
            out("Cairn.DB addons (" .. #list .. "):")
            for _, info in ipairs(list) do
                out(string.format("  %s   |cffaaaaaa->|r |cffd87f3a%s|r   |cffaaaaaa(%d profiles)|r",
                    info.svName, tostring(info.current), #info.profiles))
            end
        end, "list every Cairn.DB addon and its current profile")

        Forge.slash:Subcommand("profileset", function(rest)
            local cmd, arg = rest:match("^%s*(%S+)%s*(.*)$")
            if cmd == "save" and arg ~= "" then
                ns.SaveCurrentAsSet(arg)
                out("saved profile set '" .. arg .. "'.")
            elseif cmd == "load" and arg ~= "" then
                local ok, n = ns.LoadSet(arg)
                if ok then out(string.format("loaded set '%s' (%d addons updated).", arg, n))
                else out("no set named '" .. arg .. "'.") end
            elseif cmd == "delete" and arg ~= "" then
                ns.DeleteSet(arg)
                out("deleted set '" .. arg .. "' (if it existed).")
            elseif cmd == "list" then
                local names = ns.ListSetNames()
                if #names == 0 then out("no profile sets saved.") return end
                out("profile sets:")
                for _, n in ipairs(names) do
                    local set = db.profile.sets[n] or {}
                    local count = 0
                    for _ in pairs(set) do count = count + 1 end
                    out("  " .. n .. "   |cffaaaaaa(" .. count .. " addons)|r")
                end
            else
                out("usage: /forge profileset list  |  save <name>  |  load <name>  |  delete <name>")
            end
        end, "manage profile sets across addons")
    end

    local log = self:Log()
    if log then log:Info("Forge_Profiles v%s registered.", ns.VERSION) end
end

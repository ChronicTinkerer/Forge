-- Forge_CVars.Profiles: named CVar profiles (Raid, Solo, PvP, ...).
--
-- A profile is a sparse map of cvarName -> stringValue. Sparse means: only
-- CVars whose value the user wants to enforce are stored. Loading a profile
-- iterates its entries and SetCVar's each. CVars not in the profile are
-- left untouched.
--
-- Storage shape (in db.profile.cvarProfiles):
--   {
--     ["Raid"] = { Sound_MasterVolume = "0.4", scriptErrors = "0", ... },
--     ["Solo"] = { Sound_MasterVolume = "1.0", scriptErrors = "1", ... },
--   }

local ADDON, ns = ...

local Profiles = {}
ns.Profiles = Profiles

local function db()
    return ns.db
end

local function profilesTable()
    local d = db()
    if not (d and d.profile) then return nil end
    if d.profile.cvarProfiles == nil then d.profile.cvarProfiles = {} end
    return d.profile.cvarProfiles
end

-- --------------------------------------------------------------------------
-- Listing.
-- --------------------------------------------------------------------------
function Profiles.List()
    local out = {}
    local p = profilesTable() or {}
    for name in pairs(p) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function Profiles.Get(name)
    local p = profilesTable() or {}
    return p[name]
end

function Profiles.Active()
    local d = db()
    return d and d.profile and d.profile.activeProfile or nil
end

function Profiles.SetActive(name)
    local d = db()
    if not (d and d.profile) then return end
    d.profile.activeProfile = name
end

function Profiles.Count()
    local n = 0
    for _ in pairs(profilesTable() or {}) do n = n + 1 end
    return n
end

-- --------------------------------------------------------------------------
-- Save / delete / rename.
-- --------------------------------------------------------------------------
function Profiles.Save(name, entries)
    if type(name) ~= "string" or name == "" then return false, "name required" end
    local p = profilesTable()
    if not p then return false, "db not ready" end
    -- Defensive copy + stringify so the profile owns its values.
    local clean = {}
    for k, v in pairs(entries or {}) do
        if type(k) == "string" and k ~= "" then
            clean[k] = tostring(v)
        end
    end
    p[name] = clean
    return true
end

function Profiles.Delete(name)
    local p = profilesTable()
    if not p then return false, "db not ready" end
    p[name] = nil
    if Profiles.Active() == name then Profiles.SetActive(nil) end
    return true
end

function Profiles.Rename(oldName, newName)
    if type(oldName) ~= "string" or type(newName) ~= "string" then
        return false, "names required"
    end
    if oldName == newName then return true end
    local p = profilesTable()
    if not p then return false, "db not ready" end
    if not p[oldName] then return false, "no such profile" end
    if p[newName] then return false, "name already taken" end
    p[newName], p[oldName] = p[oldName], nil
    if Profiles.Active() == oldName then Profiles.SetActive(newName) end
    return true
end

-- --------------------------------------------------------------------------
-- Apply.
--
-- Returns: applied (number), failed (array of {name, value, err}),
--          needsReload (boolean) if any applied CVar is in
--          RiskyList.NeedsReload.
-- --------------------------------------------------------------------------
function Profiles.Apply(name)
    local prof = Profiles.Get(name)
    if not prof then return 0, {{ name = name, err = "no such profile" }}, false end

    local applied, failed, needsReload = 0, {}, false
    for cvar, value in pairs(prof) do
        local ok, err = pcall(SetCVar, cvar, tostring(value))
        if ok then
            applied = applied + 1
            if ns.RiskyList and ns.RiskyList.NeedsReload(cvar) then
                needsReload = true
            end
        else
            failed[#failed + 1] = { name = cvar, value = value, err = tostring(err) }
        end
    end

    Profiles.SetActive(name)
    return applied, failed, needsReload
end

-- --------------------------------------------------------------------------
-- Capture / export helpers.
-- --------------------------------------------------------------------------
-- Build a profile-shaped table from the live client state, including only
-- CVars whose current value differs from default. Useful for "snapshot
-- everything I've changed into a new profile."
function Profiles.CaptureCurrentDiffs()
    local out = {}
    if not ns.Snapshot then return out end
    for _, entry in ipairs(ns.Snapshot.GetAll()) do
        if ns.Snapshot.IsModified(entry.name) then
            out[entry.name] = ns.Snapshot.GetCurrent(entry.name)
        end
    end
    return out
end

-- Render a /console SetCVar block the user can paste into chat or a macro.
-- Profiles can be nil (defaults to active profile) or a name or a table.
function Profiles.ToConsoleBlock(profile)
    local entries
    if profile == nil then
        entries = Profiles.Get(Profiles.Active() or "") or {}
    elseif type(profile) == "string" then
        entries = Profiles.Get(profile) or {}
    elseif type(profile) == "table" then
        entries = profile
    else
        entries = {}
    end

    local names = {}
    for k in pairs(entries) do names[#names + 1] = k end
    table.sort(names)

    local lines = {}
    for _, k in ipairs(names) do
        lines[#lines + 1] = string.format("/console SetCVar %s %s", k, tostring(entries[k]))
    end
    return table.concat(lines, "\n")
end

-- Forge_AddonManager.Manager: thin wrappers over C_AddOns API + sets + protected list.
--
-- Public surface:
--
--   Manager.Refresh()            -- (re)build the cached addon list
--   Manager.GetAll()             -- snapshot list (table of entries)
--   Manager.Get(name)            -- single entry by name
--   Manager.IsEnabled(name)      -- 0/1/2 -> false/true (treats 1 and 2 as enabled)
--   Manager.SetEnabled(name, on) -- enable or disable for current character
--   Manager.IsLoaded(name)
--   Manager.IsLoadOnDemand(name)
--   Manager.MemoryKB(name)
--   Manager.EnableAll() / DisableAll()  -- skips Forge_*, Cairn, LibCodex if protected
--   Manager.RestoreDefault()     -- restore enabled set to what was active at login
--   Manager.IsProtected(name)
--   Manager.SetProtected(name, on)
--
-- Sets:
--   Manager.SaveSet(name, list)
--   Manager.LoadSet(name)        -- enables list, disables everything else (respects protected)
--   Manager.DeleteSet(name)
--   Manager.GetSets()            -- {[name] = list, ...}
--   Manager.ListSetNames()
--   Manager.SaveCurrentAsSet(name)
--
-- Reload-required tracker:
--   Manager.HasPendingChange()   -- true if any enable/disable happened this session
--   Manager.PendingCount()
--   Manager.ClearPending()       -- after reload (called from OnLogin)

local ADDON, ns = ...

local Manager = {}
ns.Manager = Manager

local _db
local _cache               -- index -> entry table
local _byName              -- name  -> entry table
local _onChange = {}
local _initialEnabled      -- snapshot of which addons were enabled at login

-- ----- Self-protected addons --------------------------------------------
-- These cannot be disabled by any user action (checkbox, Disable All, Load Set,
-- slash command). Disabling Cairn would break Forge; disabling Forge would
-- break the parent window; disabling Forge_AddonManager would lock the user
-- out of re-enabling anything in-game. Effectively the bootstrap chain.
local SELF_PROTECTED = {
    ["Forge"]              = true,
    ["Forge_AddonManager"] = true,
    ["Cairn"]              = true,
}

function Manager.IsSelfProtected(name)
    return SELF_PROTECTED[name] and true or false
end

-- ----- Dependency helpers ----------------------------------------------
-- Inlined metadata read because the older safeMeta helper is declared later
-- in this file and isn't in scope here. Resolves modern + legacy global.
local function readDepList(name, baseField)
    local out = {}
    local C = _G.C_AddOns
    local getMeta = (C and C.GetAddOnMetadata) or _G.GetAddOnMetadata
    if not getMeta then return out end
    for k = 1, 8 do
        local label = (k == 1) and baseField or (baseField .. "-" .. k)
        local ok, raw = pcall(getMeta, name, label)
        if ok and raw and raw ~= "" then
            for dep in (raw .. ","):gmatch("([^,]+),") do
                local trimmed = dep:gsub("^%s+", ""):gsub("%s+$", "")
                if trimmed ~= "" then out[#out + 1] = trimmed end
            end
        end
    end
    return out
end

function Manager.GetDependencies(name)
    return readDepList(name, "Dependencies")
end

function Manager.GetOptionalDependencies(name)
    -- WoW exposes both `OptionalDeps` and `OptionalDependencies` over the years.
    local a = readDepList(name, "OptionalDeps")
    local b = readDepList(name, "OptionalDependencies")
    local seen = {}
    local out = {}
    for _, t in ipairs({ a, b }) do
        for _, n in ipairs(t) do
            if not seen[n] then seen[n] = true; out[#out + 1] = n end
        end
    end
    return out
end

-- Forward declare API helpers.
local function CA() return _G.C_AddOns end

local function safeMeta(name, field)
    local CA = CA()
    if CA and CA.GetAddOnMetadata then
        local ok, v = pcall(CA.GetAddOnMetadata, name, field)
        if ok then return v end
    end
    if GetAddOnMetadata then
        local ok, v = pcall(GetAddOnMetadata, name, field)
        if ok then return v end
    end
    return nil
end

local function fireChange()
    for i = 1, #_onChange do pcall(_onChange[i]) end
end

function Manager.OnChange(fn)
    if type(fn) ~= "function" then return function() end end
    _onChange[#_onChange + 1] = fn
    return function()
        for i, f in ipairs(_onChange) do
            if f == fn then table.remove(_onChange, i); return end
        end
    end
end

local function getNumAddOns()
    local CA = CA()
    if CA and CA.GetNumAddOns then return CA.GetNumAddOns() end
    if GetNumAddOns then return GetNumAddOns() end
    return 0
end

local function getInfo(i)
    local CA = CA()
    if CA and CA.GetAddOnInfo then
        return CA.GetAddOnInfo(i)
    elseif GetAddOnInfo then
        return GetAddOnInfo(i)
    end
end

local function isLoadable(name)
    local _, _, _, loadable = getInfo(name)
    return loadable
end

local function isLoadOnDemand(name)
    local CA = CA()
    if CA and CA.IsAddOnLoadOnDemand then return CA.IsAddOnLoadOnDemand(name) end
    if IsAddOnLoadOnDemand then return IsAddOnLoadOnDemand(name) end
    return false
end

local function isLoaded(name)
    local CA = CA()
    if CA and CA.IsAddOnLoaded then
        local loaded = CA.IsAddOnLoaded(name)
        return loaded and true or false
    end
    if IsAddOnLoaded then return IsAddOnLoaded(name) and true or false end
    return false
end

local function getEnableState(name)
    local CA = CA()
    if CA and CA.GetAddOnEnableState then
        local ok, v = pcall(CA.GetAddOnEnableState, name, UnitName and UnitName("player") or nil)
        if ok and v ~= nil then return v end
    end
    if GetAddOnEnableState then
        local ok, v = pcall(GetAddOnEnableState, UnitName and UnitName("player") or nil, name)
        if ok and v ~= nil then return v end
    end
    return 0
end

function Manager.MemoryKB(name)
    local CA = CA()
    if CA and CA.GetAddOnMemoryUsage then return CA.GetAddOnMemoryUsage(name) or 0 end
    if GetAddOnMemoryUsage then return GetAddOnMemoryUsage(name) or 0 end
    return 0
end

function Manager.IsLoaded(name)        return isLoaded(name) end
function Manager.IsLoadOnDemand(name)  return isLoadOnDemand(name) end

function Manager.IsEnabled(name)
    local s = getEnableState(name)
    -- 0 = disabled, 1 = enabled (default), 2 = enabled
    return (tonumber(s) or 0) > 0
end

-- ----- Pending changes (queue-then-apply pattern) -----------------------
-- C_AddOns.EnableAddOn/DisableAddOn taint secure execution if called outside
-- an explicit user click (e.g. from PLAYER_LOGIN). All mutations go through
-- this queue instead, persisted in db.profile.pendingChanges. The user then
-- clicks "Apply + Reload" - that click runs in a hardware-secure context,
-- where the C_AddOns calls (and the subsequent ReloadUI) are allowed.
--
-- Schema:
--   db.profile.pendingChanges[name] = true   -- queue enable
--   db.profile.pendingChanges[name] = false  -- queue disable

local function ensurePendingTable()
    if not _db then return nil end
    _db.profile.pendingChanges = _db.profile.pendingChanges or {}
    return _db.profile.pendingChanges
end

function Manager.GetPendingChanges()
    return ensurePendingTable() or {}
end

function Manager.PendingCount()
    local p = ensurePendingTable()
    if not p then return 0 end
    local n = 0
    for _ in pairs(p) do n = n + 1 end
    return n
end

function Manager.HasPendingChange()
    return Manager.PendingCount() > 0
end

function Manager.ClearPending()
    if _db then _db.profile.pendingChanges = {} end
    fireChange()
end

-- Returns the EFFECTIVE enabled state: current load state with any pending
-- change applied. UI checkboxes use this so the user sees what will be
-- after they click Apply.
function Manager.IsEffectivelyEnabled(name)
    local p = ensurePendingTable()
    if p and p[name] ~= nil then return p[name] and true or false end
    return Manager.IsEnabled(name)
end

-- SetEnabled now QUEUES. The actual API call happens in ApplyPendingChanges,
-- which must be called from a user click for taint safety.
function Manager.SetEnabled(name, on)
    if not on and Manager.IsSelfProtected(name) then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffd87f3aForge:|r |cffff8080" .. name .. " is essential and cannot be disabled.|r")
        end
        return
    end
    local p = ensurePendingTable()
    if not p then return end
    -- If queueing a state that matches the CURRENT load state, the queue
    -- entry is unnecessary - drop it instead of accumulating noise.
    if (Manager.IsEnabled(name) and on) or ((not Manager.IsEnabled(name)) and not on) then
        p[name] = nil
    else
        p[name] = on and true or false
    end
    fireChange()
end

-- Discards a single queued change.
function Manager.UnqueueChange(name)
    local p = ensurePendingTable()
    if p then p[name] = nil; fireChange() end
end

-- Apply all pending changes via the C_AddOns API, then ReloadUI. MUST be
-- called from a hardware-click context (button OnClick) so the API calls
-- and ReloadUI run in secure execution.
function Manager.ApplyPendingChanges()
    local p = ensurePendingTable()
    if not p then return end
    local CA = CA()
    for name, on in pairs(p) do
        if on then
            if CA and CA.EnableAddOn then CA.EnableAddOn(name) elseif EnableAddOn then EnableAddOn(name) end
        else
            if CA and CA.DisableAddOn then CA.DisableAddOn(name) elseif DisableAddOn then DisableAddOn(name) end
        end
    end
    _db.profile.pendingChanges = {}
    if ReloadUI then ReloadUI() end
end

function Manager.EnableAll()
    -- Queue every addon to be enabled.
    local n = getNumAddOns()
    for i = 1, n do
        local nm = select(1, getInfo(i))
        if nm then Manager.SetEnabled(nm, true) end
    end
end

function Manager.DisableAll()
    -- Queue every addon to be disabled EXCEPT user-protected and self-protected.
    local n = getNumAddOns()
    for i = 1, n do
        local nm = select(1, getInfo(i))
        if nm and not Manager.IsProtected(nm) and not Manager.IsSelfProtected(nm) then
            Manager.SetEnabled(nm, false)
        end
    end
end

function Manager.RestoreDefault()
    if not _initialEnabled then return end
    local n = getNumAddOns()
    for i = 1, n do
        local nm = select(1, getInfo(i))
        if nm then
            if _initialEnabled[nm] or Manager.IsSelfProtected(nm) then
                Manager.SetEnabled(nm, true)
            else
                Manager.SetEnabled(nm, false)
            end
        end
    end
end

-- ----- Protected -----
function Manager.IsProtected(name)
    if not _db then return false end
    return _db.profile.protected and _db.profile.protected[name] and true or false
end

function Manager.SetProtected(name, on)
    if not _db then return end
    _db.profile.protected = _db.profile.protected or {}
    _db.profile.protected[name] = on and true or nil
    fireChange()
end

-- ----- Sets -----
function Manager.GetSets()
    if not _db then return {} end
    return _db.profile.sets or {}
end

function Manager.ListSetNames()
    if not _db then return {} end
    local out = {}
    for k in pairs(_db.profile.sets or {}) do out[#out + 1] = k end
    table.sort(out)
    return out
end

function Manager.SaveSet(name, list)
    if not _db or not name or name == "" then return end
    _db.profile.sets = _db.profile.sets or {}
    -- Deep-copy the list to avoid sharing references.
    local copy = {}
    for i = 1, #(list or {}) do copy[i] = list[i] end
    _db.profile.sets[name] = copy
    fireChange()
end

function Manager.SaveCurrentAsSet(name)
    local enabled = {}
    local n = getNumAddOns()
    for i = 1, n do
        local nm = select(1, getInfo(i))
        if nm and Manager.IsEnabled(nm) then enabled[#enabled + 1] = nm end
    end
    Manager.SaveSet(name, enabled)
end

function Manager.LoadSet(name)
    if not _db then return end
    local set = _db.profile.sets and _db.profile.sets[name]
    if not set then return false end
    local lookup = {}
    for _, nm in ipairs(set) do lookup[nm] = true end
    -- Always keep self-protected enabled regardless of the set's contents.
    for nm in pairs(SELF_PROTECTED) do lookup[nm] = true end
    local n = getNumAddOns()
    for i = 1, n do
        local nm = select(1, getInfo(i))
        if nm then
            if lookup[nm] or Manager.IsProtected(nm) or Manager.IsSelfProtected(nm) then
                Manager.SetEnabled(nm, true)
            else
                Manager.SetEnabled(nm, false)
            end
        end
    end
    return true
end

function Manager.DeleteSet(name)
    if not _db then return end
    if _db.profile.sets then _db.profile.sets[name] = nil end
    fireChange()
end

-- ----- Recursive enable -----------------------------------------------
-- options:
--   options.silent      = true to skip the chat report
--   options.optional    = true to also auto-enable installed-but-disabled optional
--                         deps (no prompt). Default false: optional deps are
--                         queued for the UI prompt instead.
--   options.deferOptional = true to skip optional handling entirely (UI passes
--                         this when it wants to drive the prompt itself).
function Manager.EnableWithDeps(name, options)
    options = options or {}
    if not name or name == "" then return {} end
    Manager.SetEnabled(name, true)

    -- BFS over required deps.
    local enabledByUs = {}
    local seen = { [name] = true }
    local queue = { name }
    while #queue > 0 do
        local cur = table.remove(queue, 1)
        local deps = Manager.GetDependencies(cur)
        for _, d in ipairs(deps) do
            if Manager.Get(d) and not seen[d] then
                seen[d] = true
                if not Manager.IsEnabled(d) then
                    Manager.SetEnabled(d, true)
                    enabledByUs[#enabledByUs + 1] = d
                end
                queue[#queue + 1] = d
            end
        end
    end

    -- Collect optional deps (not enabled) for either auto-enable or prompt.
    local pendingOptional = {}
    if not options.deferOptional then
        local seenOpt = { [name] = true }
        local q = { name }
        while #q > 0 do
            local cur = table.remove(q, 1)
            local opts = Manager.GetOptionalDependencies(cur)
            for _, d in ipairs(opts) do
                if Manager.Get(d) and not seenOpt[d] then
                    seenOpt[d] = true
                    if not Manager.IsEnabled(d) then
                        if options.optional then
                            Manager.SetEnabled(d, true)
                            enabledByUs[#enabledByUs + 1] = d
                        else
                            pendingOptional[#pendingOptional + 1] = { dep = d, requestor = cur }
                        end
                    end
                    q[#q + 1] = d
                end
            end
        end
    end

    if not options.silent and DEFAULT_CHAT_FRAME and #enabledByUs > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffd87f3aForge:|r enabled deps for " .. name .. ": " ..
            table.concat(enabledByUs, ", "))
    end

    return { enabled = enabledByUs, pendingOptional = pendingOptional }
end

-- Convenience accessor for the toggleable option.
function Manager.IsRecursiveEnable()
    if not _db then return true end
    local opts = _db.profile.options or {}
    if opts.recursiveEnable == nil then return true end
    return opts.recursiveEnable and true or false
end

function Manager.SetRecursiveEnable(on)
    if not _db then return end
    _db.profile.options = _db.profile.options or {}
    _db.profile.options.recursiveEnable = on and true or false
    fireChange()
end

-- ----- Cache build -------------------------------------------------------
function Manager.Refresh()
    _cache, _byName = {}, {}
    local n = getNumAddOns()
    -- Refresh memory snapshot first.
    if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end

    for i = 1, n do
        local name, title, notes, loadable, reason, security, newVersion = getInfo(i)
        if name then
            local entry = {
                index       = i,
                name        = name,
                title       = title or name,
                notes       = notes,
                loadable    = loadable,
                reason      = reason,
                security    = security,
                newVersion  = newVersion,
                version     = safeMeta(name, "Version"),
                author      = safeMeta(name, "Author"),
                isLoD       = isLoadOnDemand(name),
            }
            _cache[#_cache + 1] = entry
            _byName[name] = entry
        end
    end
    table.sort(_cache, function(a, b)
        return (a.title or a.name):lower() < (b.title or b.name):lower()
    end)
end

function Manager.GetAll()
    if not _cache then Manager.Refresh() end
    return _cache
end

function Manager.Get(name)
    if not _byName then Manager.Refresh() end
    return _byName[name]
end

-- Internal: snapshot which addons are enabled right now (called once at login).
function Manager._SnapshotInitial()
    _initialEnabled = {}
    local n = getNumAddOns()
    for i = 1, n do
        local nm = select(1, getInfo(i))
        if nm and Manager.IsEnabled(nm) then _initialEnabled[nm] = true end
    end
end

-- ----- "Known addons" tracking + auto-disable-new toggle ----------------
-- WoW defaults newly-installed addons to enabled. With the autoDisableNew
-- option turned on, we snapshot the addon list each login; anything in the
-- current list that wasn't in the snapshot is treated as new and disabled.

function Manager.GetKnownAddons()
    if not _db then return {} end
    return _db.profile.knownAddons or {}
end

function Manager.IsAutoDisableNew()
    if not _db then return false end
    local opts = _db.profile.options or {}
    return opts.autoDisableNew and true or false
end

function Manager.SetAutoDisableNew(on)
    if not _db then return end
    _db.profile.options = _db.profile.options or {}
    _db.profile.options.autoDisableNew = on and true or false
    fireChange()
end

-- Returns: { newlyDisabled = {names...}, newlySeen = {names...}, firstRun = bool }
-- Updates _db.profile.knownAddons with the latest snapshot.
-- On first run (known set empty) we skip the auto-disable step and just seed
-- the snapshot so we don't blast every existing addon off.
function Manager.CheckNewAddons()
    if not _db then return {} end
    _db.profile.knownAddons = _db.profile.knownAddons or {}
    local known = _db.profile.knownAddons
    local firstRun = (next(known) == nil)
    local newlySeen, newlyDisabled = {}, {}
    local autoDisable = Manager.IsAutoDisableNew() and not firstRun

    local n = getNumAddOns()
    local seenNow = {}
    for i = 1, n do
        local nm = select(1, getInfo(i))
        if nm then
            seenNow[nm] = true
            if not known[nm] then
                newlySeen[#newlySeen + 1] = nm
                if autoDisable and not Manager.IsSelfProtected(nm) then
                    -- Queue the disable. The actual C_AddOns.DisableAddOn
                    -- call happens later from a user click in
                    -- ApplyPendingChanges - calling it here at PLAYER_LOGIN
                    -- would taint secure execution.
                    Manager.SetEnabled(nm, false)
                    newlyDisabled[#newlyDisabled + 1] = nm
                end
            end
        end
    end

    -- Update the known set with everything currently installed.
    for nm in pairs(seenNow) do known[nm] = true end
    -- Optionally prune entries for addons that no longer exist (uninstalled).
    for nm in pairs(known) do
        if not seenNow[nm] then known[nm] = nil end
    end

    return { newlySeen = newlySeen, newlyDisabled = newlyDisabled, firstRun = firstRun }
end

function Manager.Bind(db) _db = db end

-- Forge_CVars.Snapshot: cached query layer over C_Console.GetAllCommands.
--
-- C_Console returns ~3000 entries on Mainline. Calling it on every keystroke
-- of the search box is wasteful, and walking the result table to build per-
-- entry filter strings every frame is worse. Snapshot caches the entries
-- once at first request (or when the user hits Refresh) and exposes:
--
--   ns.Snapshot.Refresh()                 -- rebuild the cache
--   ns.Snapshot.GetAll()                  -- array of all entries
--   ns.Snapshot.Get(name)                 -- single entry by exact name
--   ns.Snapshot.Filter(opts)              -- filtered view (cheap, returns array of indices)
--   ns.Snapshot.Categories()              -- sorted list of category names ("All" first)
--   ns.Snapshot.GetCurrent(name)          -- live GetCVar value for name
--   ns.Snapshot.GetDefault(name)          -- GetCVarDefault value for name
--   ns.Snapshot.IsModified(name)          -- current ~= default
--
-- Each cached entry has the shape:
--   {
--     name          = "Sound_MasterVolume",
--     category      = "Sound",                                -- string from Enum.ConsoleCategory
--     categoryNum   = 7,                                      -- raw enum value (or nil)
--     commandType   = "Cvar" | "Command" | "Script" | "Other",
--     help          = "Master volume.",
--     searchKey     = "sound_mastervolume master volume",     -- pre-lowercased
--   }
--
-- Live (current/default) values are NOT cached; they're queried on demand
-- via GetCVar/GetCVarDefault so an external SetCVar isn't stale here.

local ADDON, ns = ...

local Snapshot = {}
ns.Snapshot = Snapshot

-- Internal cache.
Snapshot._entries     = nil   -- array of entry tables, nil until first Refresh
Snapshot._byName      = nil   -- name -> entry
Snapshot._refreshedAt = nil   -- epoch seconds

-- --------------------------------------------------------------------------
-- Enum reverse-lookups. Built once on first use; safe if Enum tables don't
-- exist (older clients).
-- --------------------------------------------------------------------------
local CATEGORY_NAMES, COMMAND_TYPE_NAMES

local function buildEnumLookups()
    if CATEGORY_NAMES then return end
    CATEGORY_NAMES = {}
    if Enum and Enum.ConsoleCategory then
        for k, v in pairs(Enum.ConsoleCategory) do
            CATEGORY_NAMES[v] = k
        end
    end
    COMMAND_TYPE_NAMES = {}
    if Enum and Enum.ConsoleCommandType then
        for k, v in pairs(Enum.ConsoleCommandType) do
            COMMAND_TYPE_NAMES[v] = k
        end
    end
end

local function categoryToString(n)
    buildEnumLookups()
    return (n ~= nil and CATEGORY_NAMES[n]) or "Other"
end

local function commandTypeToString(n)
    buildEnumLookups()
    return (n ~= nil and COMMAND_TYPE_NAMES[n]) or "Other"
end

-- --------------------------------------------------------------------------
-- Refresh.
-- --------------------------------------------------------------------------
function Snapshot.Refresh()
    local entries = {}
    local byName  = {}

    -- Try multiple APIs in order: modern C_Console, legacy global. First
    -- one that returns a non-empty list wins. Both calls are pcall-wrapped
    -- so a runtime error in one falls through to the next instead of
    -- bubbling out of Refresh.
    local commands
    if C_Console and C_Console.GetAllCommands then
        local ok, res = pcall(C_Console.GetAllCommands)
        if ok then commands = res end
    end
    if (not commands or #commands == 0) and _G.ConsoleGetAllCommands then
        local ok, res = pcall(_G.ConsoleGetAllCommands)
        if ok then commands = res end
    end
    commands = commands or {}

    for _, cmd in ipairs(commands) do
        local name = cmd.command
        if name and name ~= "" then
            local help        = cmd.help or ""
            local categoryNum = cmd.category
            local typeNum     = cmd.commandType
            local entry = {
                name        = name,
                category    = categoryToString(categoryNum),
                categoryNum = categoryNum,
                commandType = commandTypeToString(typeNum),
                help        = help,
                searchKey   = (name .. " " .. help):lower(),
            }
            entries[#entries + 1] = entry
            byName[name] = entry
        end
    end

    Snapshot._entries     = entries
    Snapshot._byName      = byName
    Snapshot._refreshedAt = (time and time()) or 0
end

-- --------------------------------------------------------------------------
-- Accessors.
-- --------------------------------------------------------------------------
function Snapshot.GetAll()
    if not Snapshot._entries then Snapshot.Refresh() end
    return Snapshot._entries or {}
end

function Snapshot.Get(name)
    if not Snapshot._byName then Snapshot.Refresh() end
    return Snapshot._byName and Snapshot._byName[name]
end

-- Sorted list of category names. "All" is always first; other categories
-- alphabetical. Used by the toolbar dropdown.
function Snapshot.Categories()
    if not Snapshot._entries then Snapshot.Refresh() end
    local seen, list = {}, { "All" }
    for _, entry in ipairs(Snapshot._entries) do
        if entry.category and not seen[entry.category] then
            seen[entry.category] = true
            list[#list + 1] = entry.category
        end
    end
    table.sort(list, function(a, b)
        if a == "All" then return true end
        if b == "All" then return false end
        return a < b
    end)
    return list
end

-- --------------------------------------------------------------------------
-- Filter.
--
-- opts = {
--   query        = "sound",      -- substring match against searchKey
--   category     = "Sound",      -- exact category match, or "All" / nil
--   modifiedOnly = true,         -- only entries where current ~= default
--   sort         = "name",       -- "name" | "category" | "modified"
--   sortDir      = "asc",        -- "asc" | "desc"
-- }
-- Returns: array of integer indices into GetAll(). The list view uses these
-- to render only visible rows; the full entry array isn't copied per filter.
-- --------------------------------------------------------------------------
function Snapshot.Filter(opts)
    if not Snapshot._entries then Snapshot.Refresh() end
    opts = opts or {}
    local query    = (opts.query or ""):lower()
    local cat      = opts.category
    local modOnly  = opts.modifiedOnly and true or false
    local sortKey  = opts.sort or "name"
    local sortDir  = opts.sortDir or "asc"

    local catFilter = (cat and cat ~= "" and cat ~= "All") and cat or nil

    local entries = Snapshot._entries
    local result  = {}
    for i, entry in ipairs(entries) do
        local include = true
        if query ~= "" and not entry.searchKey:find(query, 1, true) then
            include = false
        end
        if include and catFilter and entry.category ~= catFilter then
            include = false
        end
        if include and modOnly and not Snapshot.IsModified(entry.name) then
            include = false
        end
        if include then
            result[#result + 1] = i
        end
    end

    table.sort(result, function(ai, bi)
        local a, b = entries[ai], entries[bi]
        local av, bv
        if sortKey == "category" then
            av = (a.category or "") .. ":" .. a.name
            bv = (b.category or "") .. ":" .. b.name
        elseif sortKey == "modified" then
            -- Modified entries first by default; equal modified-state falls
            -- through to name as the tiebreaker.
            local am = Snapshot.IsModified(a.name) and 0 or 1
            local bm = Snapshot.IsModified(b.name) and 0 or 1
            if am ~= bm then
                if sortDir == "desc" then return am > bm end
                return am < bm
            end
            av, bv = a.name, b.name
        else
            av, bv = a.name, b.name
        end
        if sortDir == "desc" then return av > bv end
        return av < bv
    end)

    return result
end

-- --------------------------------------------------------------------------
-- Live-value helpers.
-- --------------------------------------------------------------------------
function Snapshot.GetCurrent(name)
    if GetCVar then return GetCVar(name) end
    return nil
end

function Snapshot.GetDefault(name)
    if GetCVarDefault then return GetCVarDefault(name) end
    return nil
end

function Snapshot.IsModified(name)
    local cur = Snapshot.GetCurrent(name)
    local def = Snapshot.GetDefault(name)
    if cur == nil or def == nil then return false end
    return cur ~= def
end

function Snapshot.RefreshedAt()
    return Snapshot._refreshedAt
end

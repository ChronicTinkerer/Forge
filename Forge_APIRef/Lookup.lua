-- Forge_APIRef.Lookup: the public query API.
--
-- Public surface (ForgeAPIRef is the global alias for this namespace):
--
--   ForgeAPIRef:Register(namespace, entries)
--     Called by Forge_APIRef-<Namespace> sibling modules to publish their
--     data. `entries` is a map of memberName -> entry table (function,
--     event, structure). Idempotent: a second Register with the same
--     namespace overwrites the prior entries (useful for hot-reloading
--     during development).
--
--   ForgeAPIRef:Lookup(name)
--     Find the entry for `name`, demand-loading the relevant sibling
--     module if needed. Accepts:
--       "C_Map.GetBestMapForUnit"  -> namespace function
--       "ZONE_CHANGED"             -> event (linear-scans loaded modules)
--       "UiMapDetails"             -> structure (linear-scans loaded modules)
--     Returns the entry table, or nil if not found.
--
--   ForgeAPIRef:Iter(namespace?)
--     Iterator over all entries (or all entries of one namespace).
--     Walks the in-memory cache; does not auto-load modules.
--
--   ForgeAPIRef:Namespaces()
--     Sorted list of namespace names that have been registered so far
--     (i.e., sibling modules that have already loaded).
--
-- Entry shape (locked schema; see forge_apiref.md memory):
--   {
--     type        = "function" | "event" | "structure",
--     namespace   = "C_Map" | nil for events,
--     name        = "GetBestMapForUnit" | "ZONE_CHANGED" | "UiMapDetails",
--     -- For functions:
--     signature   = "uiMapID = C_Map.GetBestMapForUnit(unitToken)",
--     params      = { { name, type, nilable, default } },
--     returns     = { { name, type, nilable } },
--     secretArguments = "AllowedWhenUntainted" | nil,
--     hasRestrictions = boolean | nil,
--     mayReturnNothing = boolean | nil,
--     -- For events:
--     literalName = "ZONE_CHANGED",
--     payload     = { { name, type, nilable } },
--     synchronous = boolean,
--     -- For structures:
--     fields      = { { name, type, nilable, default } },
--     -- For all:
--     desc        = "...",
--     examples    = { "/run ..." },
--     seeAlso     = { "C_Map.GetMapInfo", ... },
--     relatedEvents = { "ZONE_CHANGED", ... },
--     added       = "8.0.1",
--     removed     = nil,
--     deprecated  = nil,
--     existsInClient = nil,  -- set later by Overlay
--   }

local ADDON, ns = ...

-- In-memory cache: namespace -> { memberName -> entry }
ns._modules = ns._modules or {}

-- --------------------------------------------------------------------------
-- Register: called by sibling modules' Module.lua.
-- --------------------------------------------------------------------------
function ns:Register(namespace, entries)
    if type(namespace) ~= "string" or namespace == "" then
        error("ForgeAPIRef:Register: namespace must be a non-empty string", 2)
    end
    if type(entries) ~= "table" then
        error("ForgeAPIRef:Register: entries must be a table", 2)
    end
    -- Stamp namespace + name onto each entry so consumers don't have to
    -- carry context separately.
    for memberName, entry in pairs(entries) do
        if type(entry) == "table" then
            entry.namespace = entry.namespace or namespace
            entry.name      = entry.name      or memberName
        end
    end
    ns._modules[namespace] = entries
    return entries
end

-- --------------------------------------------------------------------------
-- Internal: ensure a namespace's sibling module is loaded.
-- --------------------------------------------------------------------------
local function ensureLoaded(namespace)
    if ns._modules[namespace] then return true end
    if not C_AddOns then return false end
    local addonName = "Forge_APIRef-" .. namespace
    if C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(addonName) then
        return ns._modules[namespace] ~= nil
    end
    if not C_AddOns.LoadAddOn then return false end
    local ok = C_AddOns.LoadAddOn(addonName)
    return ok and ns._modules[namespace] ~= nil
end

-- --------------------------------------------------------------------------
-- Lookup.
-- --------------------------------------------------------------------------
function ns:Lookup(name)
    if type(name) ~= "string" or name == "" then return nil end

    -- Namespace function syntax: "C_Foo.Bar" or "Foo.Bar".
    local namespace, member = name:match("^([%w_]+)%.(.+)$")
    if namespace and member then
        ensureLoaded(namespace)
        local nsTable = ns._modules[namespace]
        return nsTable and nsTable[member] or nil
    end

    -- Bare name: could be an event or a structure. Linear-scan loaded
    -- modules. Future work: a separate index that knows which sibling
    -- owns each event/structure name so we can demand-load.
    for _, nsTable in pairs(ns._modules) do
        if nsTable[name] then return nsTable[name] end
    end
    return nil
end

-- --------------------------------------------------------------------------
-- Iter: walks loaded entries.
-- --------------------------------------------------------------------------
function ns:Iter(namespace)
    if namespace then
        local nsTable = ns._modules[namespace] or {}
        local k
        return function()
            local entry
            k, entry = next(nsTable, k)
            return k, entry
        end
    end
    -- All namespaces.
    local nsKey, memberKey, nsTable
    return function()
        while true do
            if not nsTable then
                nsKey, nsTable = next(ns._modules, nsKey)
                if not nsTable then return nil end
                memberKey = nil
            end
            local member, entry = next(nsTable, memberKey)
            if member then
                memberKey = member
                return member, entry
            end
            nsTable, memberKey = nil, nil
        end
    end
end

function ns:Namespaces()
    local out = {}
    for nsName in pairs(ns._modules) do out[#out + 1] = nsName end
    table.sort(out)
    return out
end

function ns:HasNamespace(name)
    return ns._modules[name] ~= nil
end

-- Counts (loaded modules only).
function ns:CountEntries()
    local n = 0
    for _, nsTable in pairs(ns._modules) do
        for _ in pairs(nsTable) do n = n + 1 end
    end
    return n
end

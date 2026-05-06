-- Forge_Codex: catalog browser for LibCodex-1.0.
-- Replaces LibCodex.Dashboard as the canonical browse + search UI.

local ADDON, ns = ...

ns.VERSION = "0.1.0-dev"

local db = Cairn.DB.New("ForgeCodexDB", {
    defaults = {
        profile = {
            selectedModule = "@stats",  -- "@stats" or a real module name like "NPCs"
            searchText     = "",
        },
    },
    profileType = "default",  -- account-level: Forge is a dev tool, no per-char variation
})
ns.db = db

local addon = Cairn.Addon.New("Forge_Codex")
ns.addon = addon

local descriptor = {
    name        = "Codex",
    title       = "Codex",
    order       = 28,
    description = "LibCodex catalog browser.",
    SlashSub    = { name = "codex", help = "open the Codex tab" },
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

-- ----- Settings ---------------------------------------------------------
-- Used only at OnInit to migrate old saved values. Not applied at runtime
-- so a user clicking the LibCodex 'Stats' enum module isn't aliased to
-- the special @stats view.
local SPECIAL_ALIASES = {
    Stats = "@stats", Search = "@search", Where = "@where",
    Actions = "@actions", Settings = "@settings",
}

function ns.GetSelectedModule()  return db.profile.selectedModule or "@stats" end
function ns.SetSelectedModule(s) db.profile.selectedModule = s or "@stats" end

function ns.GetSearchText()      return db.profile.searchText or "" end
function ns.SetSearchText(s)     db.profile.searchText = s or "" end

-- ----- LibCodex helpers (used by UI) -----------------------------------
function ns.GetLC()
    if not LibStub then return nil end
    return LibStub("LibCodex-1.0", true)
end

-- Returns a sorted list of module names (e.g. {"NPCs", "Items", "Spells", ...}).
function ns.ListModuleNames()
    local LC = ns.GetLC()
    if not LC or not LC.modules then return {} end
    local names = {}
    for k in pairs(LC.modules) do names[#names + 1] = k end
    table.sort(names)
    return names
end

-- Returns count of entries in a module (best-effort; some modules may not have :Count).
function ns.ModuleCount(name)
    local LC = ns.GetLC()
    if not LC then return 0 end
    local mod = LC.modules and LC.modules[name]
    if not mod then return 0 end
    if mod.Count then return mod:Count() end
    if mod._count then return mod._count end
    if mod.AllArray then
        return #(mod:AllArray() or {})
    end
    return 0
end

-- Returns up to maxResults entries from a module, optionally filtered by search.
function ns.GetEntries(moduleName, search, maxResults)
    local LC = ns.GetLC()
    if not LC then return {} end
    local mod = LC.modules and LC.modules[moduleName]
    if not mod then return {} end

    local results = {}
    if search and search ~= "" and mod.Search then
        local hits = mod:Search(search) or {}
        for i, e in ipairs(hits) do
            results[#results + 1] = e
            if maxResults and i >= maxResults then break end
        end
        return results
    end

    -- No search: enumerate keys from every store LibCodex uses. Modules
    -- vary - some keep entries in _entries (eager), some in _rowIndex
    -- (compact rows), some in _tsvIndex (TSV blob lazy chunks). For each
    -- key we resolve the full entry via :Get(k), which materializes the
    -- specific row only - no full-module materialization that would blow
    -- the script-execution limit on huge modules.
    local seen = {}
    local function take(k)
        if k == nil or seen[k] then return false end
        seen[k] = true
        local e
        if mod.Get then
            local ok, val = pcall(function() return mod:Get(k) end)
            if ok then e = val end
        end
        if not e and mod._entries then e = mod._entries[k] end
        if e then
            results[#results + 1] = e
            if maxResults and #results >= maxResults then return true end
        end
        return false
    end

    for _, src in ipairs({ mod._entries, mod._rowIndex, mod._tsvIndex }) do
        if type(src) == "table" then
            for k in pairs(src) do
                if take(k) then return results end
            end
        end
    end

    -- Last resort: AllArray. Useful for modules that expose entries via
    -- a pattern we didn't anticipate (e.g. _extras-only).
    if #results == 0 and mod.AllArray then
        local ok, arr = pcall(function() return mod:AllArray() end)
        if ok and type(arr) == "table" then
            for i, e in ipairs(arr) do
                results[#results + 1] = e
                if maxResults and i >= maxResults then break end
            end
        end
    end

    return results
end

-- ----- LibCodex action wrappers ----------------------------------------
-- Thin wrappers so the UI doesn't have to know whether the LibCodex APIs
-- are present. Each returns false + reason if the runtime call isn't
-- available, true on success.

function ns.LC_ScanNow()
    local LC = ns.GetLC()
    if not (LC and LC.Runtime and LC.Runtime.ScanNow) then return false, "Runtime adapter missing" end
    return true, LC.Runtime.ScanNow()
end

function ns.LC_ForceSave()
    local LC = ns.GetLC()
    if not (LC and LC._PersistSavedVariables) then return false, "_PersistSavedVariables missing" end
    LC:_PersistSavedVariables()
    return true
end

function ns.LC_EnableFriendlyNameplates()
    local LC = ns.GetLC()
    if not (LC and LC.Runtime and LC.Runtime.EnableFriendlyNameplates) then return false, "Runtime missing" end
    return true, LC.Runtime.EnableFriendlyNameplates()
end

function ns.LC_GetEcho()
    local LC = ns.GetLC()
    if not (LC and LC.Log and LC.Log.IsEchoing) then return false end
    return LC.Log.IsEchoing()
end

function ns.LC_SetEcho(on)
    local LC = ns.GetLC()
    if LC and LC.Log and LC.Log.SetEcho then LC.Log.SetEcho(on) end
end

function ns.LC_GetVerbose()
    local LC = ns.GetLC()
    if not (LC and LC.Runtime) then return false end
    return LC.Runtime.verbose and true or false
end

function ns.LC_SetVerbose(on)
    local LC = ns.GetLC()
    if LC and LC.Runtime and LC.Runtime.SetVerbose then LC.Runtime.SetVerbose(on) end
end

function ns.LC_GetAutoScan()
    local LC = ns.GetLC()
    if not (LC and LC.Runtime and LC.Runtime.IsAutoScanning) then return false end
    return LC.Runtime.IsAutoScanning() and true or false
end

function ns.LC_SetAutoScan(on)
    local LC = ns.GetLC()
    if LC and LC.Runtime and LC.Runtime.SetAutoScan then LC.Runtime.SetAutoScan(on) end
end

-- Cross-module search. Returns { [moduleName] = { hits=count, entries={ ... } } }
function ns.LC_SearchAll(query)
    local LC = ns.GetLC()
    if not LC then return {} end
    local out = {}
    for name, mod in pairs(LC.modules or {}) do
        if mod.Search then
            local hits = mod:Search(query) or {}
            if #hits > 0 then out[name] = { hits = #hits, entries = hits } end
        end
    end
    return out
end

-- Where lookup: itemID -> drop sources (uses Items module's GetDropSources).
function ns.LC_GetItemDrops(itemID)
    local LC = ns.GetLC()
    if not LC then return nil, "LibCodex missing" end
    local Items = LC:Items()
    if not Items then return nil, "Items module missing" end
    local entry = Items:Get(itemID)
    if not entry then return nil, "item not in catalog" end
    local drops = (Items.GetDropSources and Items:GetDropSources(itemID)) or {}
    return entry, drops
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
    if db.profile.selectedModule == nil then db.profile.selectedModule = "@stats" end
    if db.profile.searchText     == nil then db.profile.searchText     = "" end
    -- Migrate old special-item names to "@"-prefixed form so the LibCodex
    -- "Stats" enum module no longer collides with the special view.
    local mig = SPECIAL_ALIASES[db.profile.selectedModule]
    if mig then db.profile.selectedModule = mig end
end

function addon:OnLogin()
    if Forge and Forge.Registry then
        Forge.Registry.Register(descriptor)
    end

    if Forge and Forge.slash then
        Forge.slash:Subcommand("codexstats", function()
            local total = 0
            local names = ns.ListModuleNames()
            out(string.format("LibCodex: %d modules", #names))
            for _, n in ipairs(names) do
                local c = ns.ModuleCount(n)
                total = total + c
                out(string.format("  %-22s |cffaaaaaa%s|r", n, c))
            end
            out(string.format("|cffd87f3aTotal entries:|r %d", total))
        end, "print LibCodex per-module entry counts")
    end

    local log = self:Log()
    if log then log:Info("Forge_Codex v%s registered.", ns.VERSION) end
end

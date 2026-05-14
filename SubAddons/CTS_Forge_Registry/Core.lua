-- Forge_Registry: inspect Cairn + Forge runtime registries.
--
-- v1 scope (this file):
--   * Cairn-Gui TreeView, one parent node per source. Click to expand;
--     click a child to load its detail block into the EditBox above.
--   * Substring filter (persisted to db.profile.searchText) narrows
--     visible entries across all sources.
--   * 14 sources total. Cairn libs (9): Addons / Hooks / Timers / Events
--     / DBs / Slash / Locales / Callbacks / Settings. Forge-specific (3):
--     Tabs / Slash Subs / Installed Forge_*. LibCodex (2): Modules /
--     Consumers.
--   * Each source is pcall'd so a broken Cairn lib doesn't poison the
--     panel. Empty sources are hidden when filter is active.
--   * Refresh button re-walks all sources. Snapshots only - the tree
--     doesn't update live as state changes.
--
-- Out of scope for v1 (queued for v2):
--   * Live updates via Cairn.Events instead of manual Refresh.
--   * Per-row "Reload sub-addon" / "Jump to tab" / "Trigger event" actions.
--   * Cairn-Comm source (lib not yet implemented in current Cairn).

local ADDON, ns = ...
_G.Forge_Registry = ns


Cairn.Register("CTS_Forge_Registry", ns, {
    dbName = "Forge_RegistryDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = {
        profile = { searchText = "" },  -- persisted across /reload
        global  = {},
    },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Registry"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local TREE_ROW_HEIGHT     = 18
local TREE_INDENT         = 16

-- Layout. Stack flow above the tree: heading + hint + toolbar + "Details:"
-- label + detail editbox + gaps. The tree is the only manual-anchor element
-- and fills the remaining space below. The detail-on-top arrangement mirrors
-- APIBrowser's skeleton/signature row layout, which is known to work.
local DETAIL_HEIGHT       = 100   -- multiline EditBox
local TOP_RESERVED        = 250   -- heading 22 + hint 14 + toolbar 28 + label 14 + detail 100 + 5 gaps*6 + padding 10*2
local BOTTOM_PAD          = 10
local SIDE_PAD            = 10


-- ---------------------------------------------------------------------------
-- Module-scope state
-- ---------------------------------------------------------------------------

local _searchFilter = ""
local _allTree      = nil   -- the assembled root array, cached between refreshes

local _pane
local _searchBox
local _refreshBtn
local _statusLabel
local _detailBox
local _treeScroll
local _treeView


-- Forward declarations.
local refreshTree


-- ---------------------------------------------------------------------------
-- Source enumerators
-- ---------------------------------------------------------------------------
-- Each enumerator returns an array of { key, summary, detail } where
-- detail is a multi-line string shown when the entry is clicked. All
-- pcall'd so a single broken source doesn't kill the entire panel.

local function safeBool(v)
    return v and "yes" or "no"
end


-- (1) Cairn Addons: every Cairn.Register addon, with init-seen flag.
-- The registry lives on the Cairn-Addon library instance (LibStub) or
-- on the legacy _G.Cairn_Addon table - we try both for forward compat.
local function listCairnAddons()
    local Lib = LibStub and LibStub("Cairn-Addon-1.0", true)
    local reg = (Lib and Lib.registry)
                or (_G.Cairn_Addon and _G.Cairn_Addon.registry)
    if type(reg) ~= "table" then return {} end
    local out = {}
    for name, a in pairs(reg) do
        local initSeen = rawget(a, "_initSeen") and "y" or "n"
        out[#out + 1] = {
            key     = name,
            summary = ("init=%s"):format(initSeen),
            detail  = ("name:          %s\ninit seen:     %s\nhas OnInit:    %s\nhas OnLogin:   %s\nhas OnEnter:   %s\nhas OnLogout:  %s")
                :format(
                    name, initSeen,
                    safeBool(type(rawget(a, "OnInit"))   == "function"),
                    safeBool(type(rawget(a, "OnLogin"))  == "function"),
                    safeBool(type(rawget(a, "OnEnter"))  == "function"),
                    safeBool(type(rawget(a, "OnLogout")) == "function")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (2) Forge Tabs: every descriptor in Forge.Registry, distinguishing
-- real descriptors from LoD-stubs the scanner injected for unloaded
-- Forge_* addons.
local function listForgeTabs()
    if not (_G.Forge and Forge.Registry and Forge.Registry._modules) then
        return {}
    end
    local out = {}
    for name, desc in pairs(Forge.Registry._modules) do
        local stub = desc._isStub and " (stub)" or ""
        out[#out + 1] = {
            key     = name,
            summary = ("order=%d%s"):format(desc.order or 0, stub),
            detail  = ("name:           %s\ntitle:          %s\norder:          %s\ndescription:    %s\nis LoD stub:    %s\nhas SlashSub:   %s\nhas OnTabShow:  %s\nhas OnTabHide:  %s")
                :format(
                    name,
                    tostring(desc.title or "?"),
                    tostring(desc.order or "?"),
                    tostring(desc.description or ""),
                    safeBool(desc._isStub),
                    safeBool(desc.SlashSub),
                    safeBool(type(desc.OnTabShow) == "function"),
                    safeBool(type(desc.OnTabHide) == "function")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (3) Forge Slash Subs: the subcommand catalog. Cairn-Slash stores them
-- on the slash object; field name varies by lib version so we probe.
local function listForgeSlashSubs()
    if not (_G.Forge and Forge.Slash) then return {} end
    local subs = Forge.Slash._subs or Forge.Slash.subs
    if type(subs) ~= "table" then return {} end
    local out = {}
    for name, sub in pairs(subs) do
        local help = ""
        local hasHandler = false
        if type(sub) == "table" then
            help = tostring(sub.help or sub.description or "")
            hasHandler = type(sub.fn or sub.handler or sub.callback) == "function"
        elseif type(sub) == "function" then
            hasHandler = true
        end
        out[#out + 1] = {
            key     = name,
            summary = help ~= "" and help or "(no help text)",
            detail  = ("name:        %s\nhelp:        %s\nhas handler: %s")
                :format(name, help, safeBool(hasHandler)),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (4) Installed Forge_* addons: C_AddOns scan. Flags every Forge_* in
-- the AddOns folder and whether it's loaded. Useful for spotting an
-- installed-but-disabled sub-addon that's missing from the tab strip.
local function listForgeInstalledAddons()
    if not (C_AddOns and C_AddOns.GetNumAddOns) then return {} end
    local out = {}
    local n = C_AddOns.GetNumAddOns()
    for i = 1, n do
        local name = C_AddOns.GetAddOnInfo and C_AddOns.GetAddOnInfo(i)
        if name and name:match("^Forge_") then
            local loaded = C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(i)
            local notes  = C_AddOns.GetAddOnMetadata
                           and C_AddOns.GetAddOnMetadata(i, "Notes") or ""
            local toolName = C_AddOns.GetAddOnMetadata
                             and C_AddOns.GetAddOnMetadata(i, "X-Forge-Tool-Name") or ""
            out[#out + 1] = {
                key     = name,
                summary = loaded and "loaded" or "installed, not loaded",
                detail  = ("name:               %s\nloaded:             %s\nX-Forge-Tool-Name:  %s\nNotes:              %s")
                    :format(
                        name,
                        safeBool(loaded),
                        toolName ~= "" and toolName or "(not declared)",
                        notes),
            }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- ---------------------------------------------------------------------------
-- Extended sources (ported from OLD Forge_Registry/Sources.lua)
-- ---------------------------------------------------------------------------
-- Cairn lib internals: each accesses the lib via LibStub first, falling back
-- to the legacy _G.Cairn_X table so the addon works whether or not the lib
-- is currently being LibStub-vended. Empty result when lib isn't loaded.

local function safeLib(major, gname)
    local Lib = LibStub and LibStub(major, true)
    if Lib then return Lib end
    return _G[gname]
end


-- (5) Hooks: Cairn-Hooks-1.0._registry. Each hook records its callback list
-- and whether the underlying HookScript / hooksecurefunc is installed.
local function listCairnHooks()
    local L = safeLib("Cairn-Hooks-1.0", "Cairn_Hooks")
    if not (L and L._registry) then return {} end
    local out = {}
    for key, entry in pairs(L._registry) do
        local cbCount = entry.callbacks and #entry.callbacks or 0
        out[#out + 1] = {
            key     = tostring(key),
            summary = ("callbacks=%d, installed=%s")
                :format(cbCount, safeBool(entry.hookInstalled)),
            detail  = ("key:           %s\nname:          %s\ntarget:        %s\ncallbacks:     %d\nhookInstalled: %s")
                :format(tostring(key), tostring(entry.name),
                        tostring(entry.target or "_G"),
                        cbCount, safeBool(entry.hookInstalled)),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (6) Timers: Cairn-Timer-1.0.byOwner / .named. Both surfaces show the
-- live timer count per owner / named handle.
local function listCairnTimers()
    local L = safeLib("Cairn-Timer-1.0", "Cairn_Timer")
    if not L then return {} end
    local out = {}
    if L.byOwner then
        for owner, handles in pairs(L.byOwner) do
            local n = (type(handles) == "table" and #handles) or 0
            out[#out + 1] = {
                key     = "owner:" .. tostring(owner),
                summary = ("live=%d"):format(n),
                detail  = ("owner: %s\nlive:  %d"):format(tostring(owner), n),
            }
        end
    end
    if L.named then
        for name, handle in pairs(L.named) do
            out[#out + 1] = {
                key     = "named:" .. tostring(name),
                summary = "named timer",
                detail  = ("named:  %s\nhandle: %s"):format(tostring(name), tostring(handle)),
            }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (7) Events: Cairn-Events-1.0.handlers. Per-event subscriber array.
local function listCairnEvents()
    local L = safeLib("Cairn-Events-1.0", "Cairn_Events")
    if not (L and L.handlers) then return {} end
    local out = {}
    for event, entries in pairs(L.handlers) do
        local n = (type(entries) == "table" and #entries) or 0
        local owners = {}
        if type(entries) == "table" then
            for _, e in ipairs(entries) do
                owners[#owners + 1] = tostring(e.owner or e[1] or "?")
            end
        end
        out[#out + 1] = {
            key     = event,
            summary = ("subs=%d"):format(n),
            detail  = ("event: %s\nsubs:  %d\nowners:\n  %s")
                :format(event, n, table.concat(owners, "\n  ")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (8) DBs: Cairn-DB-1.0.instances. Each instance reports its SV name and
-- profile key.
local function listCairnDBs()
    local L = safeLib("Cairn-DB-1.0", "Cairn_DB")
    if not (L and L.instances) then return {} end
    local out = {}
    for i, inst in ipairs(L.instances) do
        local svName  = inst._svName or inst.svName or "?"
        local profile = (inst.GetProfileKey and inst:GetProfileKey())
                        or inst._profileKey or "?"
        out[#out + 1] = {
            key     = tostring(svName),
            summary = ("profile=%s"):format(tostring(profile)),
            detail  = ("svName:       %s\nprofileKey:   %s\nprofileType:  %s\ninstance idx: %d")
                :format(tostring(svName), tostring(profile),
                        tostring(inst._profileType or "?"), i),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (9) Cairn Slash: every /slash registered through Cairn-Slash-1.0. Each
-- has its own _subs subcommand catalog.
local function listCairnSlash()
    local L = safeLib("Cairn-Slash-1.0", "Cairn_Slash")
    if not (L and L.registry) then return {} end
    local out = {}
    for name, slashObj in pairs(L.registry) do
        local subs = slashObj._subs or slashObj.subs
        local subCount = 0
        local subList = {}
        if type(subs) == "table" then
            for k in pairs(subs) do
                subCount = subCount + 1
                if #subList < 12 then subList[#subList + 1] = tostring(k) end
            end
        end
        out[#out + 1] = {
            key     = name,
            summary = ("subs=%d"):format(subCount),
            detail  = ("name:    %s\nsubs:    %d\nsubcommands:\n  %s")
                :format(name, subCount, table.concat(subList, ", ")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (10) Locales: Cairn-Locale-1.0.registry. Each addon's locale binding +
-- detected language.
local function listCairnLocales()
    local L = safeLib("Cairn-Locale-1.0", "Cairn_Locale")
    if not (L and L.registry) then return {} end
    local out = {}
    for addonName, locale in pairs(L.registry) do
        out[#out + 1] = {
            key     = addonName,
            summary = ("lang=%s"):format(tostring(locale._lang or "?")),
            detail  = ("addonName: %s\nlang:      %s")
                :format(addonName, tostring(locale._lang or "?")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (11) Callbacks: hybrid scan. Cairn-Callback-1.0.instances when the shim
-- wins LibStub, plus a fallback walk of every LibStub library for fields
-- that look like CallbackHandler registries (duck-typed: numeric recurse +
-- table events + Fire function). Catches the case where ElvUI or another
-- bundled CallbackHandler beat us to LibStub and our :New hook never ran.
local function looksLikeCallbackRegistry(t)
    return type(t) == "table"
       and type(t.recurse) == "number"
       and type(t.events)  == "table"
       and type(t.Fire)    == "function"
end


local function buildCallbackEntry(reg, label)
    local nEvents, nSubs = 0, 0
    local eventLines = {}
    if reg.events then
        for ev, handlers in pairs(reg.events) do
            nEvents = nEvents + 1
            local n = 0
            for _ in pairs(handlers) do n = n + 1; nSubs = nSubs + 1 end
            eventLines[#eventLines + 1] = ("  %s  (subs=%d)"):format(tostring(ev), n)
        end
        table.sort(eventLines)
    end
    local lbl = type(label) == "string" and label or "(unlabeled)"
    local eventBlock = #eventLines > 0
        and ("events:\n" .. table.concat(eventLines, "\n"))
        or  "events:\n  (none)"
    return {
        key     = lbl,
        summary = ("events=%d subs=%d"):format(nEvents, nSubs),
        detail  = ("label:       %s\nevent count: %d\ntotal subs:  %d\nrecurse:     %d\n\n%s")
            :format(lbl, nEvents, nSubs, reg.recurse or 0, eventBlock),
    }
end


local function listCairnCallbacks()
    local out = {}
    local seen = {}
    local L = safeLib("Cairn-Callback-1.0", "Cairn_Callback")
    if L and L.instances then
        for reg, label in pairs(L.instances) do
            seen[reg] = true
            out[#out + 1] = buildCallbackEntry(reg, label)
        end
    end
    -- Fallback: walk every LibStub library for fields shaped like callback
    -- registries. Skip anything already tracked above.
    if LibStub and LibStub.libs then
        for libMajor, libTable in pairs(LibStub.libs) do
            if type(libTable) == "table" then
                for fieldName, val in pairs(libTable) do
                    if not seen[val] and looksLikeCallbackRegistry(val) then
                        seen[val] = true
                        out[#out + 1] = buildCallbackEntry(val,
                            libMajor .. "." .. tostring(fieldName))
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        -- Real labels first, "table:" address-style last.
        local aRaw = a.key:match("^table:") and 1 or 0
        local bRaw = b.key:match("^table:") and 1 or 0
        if aRaw ~= bRaw then return aRaw < bRaw end
        return a.key < b.key
    end)
    return out
end


-- (12) Settings panels: Cairn-Settings-1.0.instances. Each instance is a
-- registered panel; entries = schema row count.
local function listCairnSettings()
    local L = safeLib("Cairn-Settings-1.0", "Cairn_Settings")
    if not (L and L.instances) then return {} end
    local out = {}
    for inst, addonName in pairs(L.instances) do
        local nEntries = inst._schema and #inst._schema or 0
        local hasCategory = inst._categoryID and "yes" or "stub mode"
        out[#out + 1] = {
            key     = tostring(addonName),
            summary = ("entries=%d, blizzard=%s"):format(nEntries, hasCategory),
            detail  = ("addon:             %s\nschema entries:    %d\nBlizzard category: %s\ncategoryID:        %s")
                :format(tostring(addonName), nEntries, hasCategory,
                        tostring(inst._categoryID or "(none)")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (13) LibCodex modules: each typed catalog (Quests/Items/NPCs/...) calls
-- RegisterModule on LibCodex. We surface that table.
local function listCodexModules()
    local LC = _G.LibCodex or (LibStub and LibStub("LibCodex-1.0", true))
    if not (LC and LC.modules) then return {} end
    local out = {}
    for name, mod in pairs(LC.modules) do
        local count = "?"
        if type(mod.Count) == "function" then
            local ok, n = pcall(mod.Count, mod)
            if ok and type(n) == "number" then count = tostring(n) end
        end
        out[#out + 1] = {
            key     = name,
            summary = ("entries=%s"):format(count),
            detail  = ("module:       %s\nentries:      %s\nhas Get:      %s\nhas AllArray: %s\nhas Search:   %s")
                :format(name, count,
                        safeBool(type(mod.Get) == "function"),
                        safeBool(type(mod.AllArray) == "function"),
                        safeBool(type(mod.Search) == "function")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- (14) LibCodex consumers: any installed addon that declares "LibCodex-1.0"
-- in its ## Dependencies or ## OptionalDeps. Misses pure-runtime LibStub
-- consumers (no enforced load order, rare and arguably broken).
local function listCodexConsumers()
    if not (C_AddOns and C_AddOns.GetNumAddOns) then return {} end
    local out = {}
    local n = C_AddOns.GetNumAddOns()
    for i = 1, n do
        local addonName = C_AddOns.GetAddOnInfo and C_AddOns.GetAddOnInfo(i)
        if addonName then
            local deps = {}
            if C_AddOns.GetAddOnDependencies then
                deps = { C_AddOns.GetAddOnDependencies(i) }
            end
            local opts = {}
            if C_AddOns.GetAddOnOptionalDependencies then
                opts = { C_AddOns.GetAddOnOptionalDependencies(i) }
            end
            local hasDep, viaOpt = false, false
            for _, d in ipairs(deps) do
                if d == "LibCodex-1.0" then hasDep = true end
            end
            for _, d in ipairs(opts) do
                if d == "LibCodex-1.0" then hasDep = true; viaOpt = true end
            end
            if hasDep then
                local loaded = C_AddOns.IsAddOnLoaded
                               and C_AddOns.IsAddOnLoaded(i)
                out[#out + 1] = {
                    key     = addonName,
                    summary = ("loaded=%s, via=%s")
                        :format(safeBool(loaded),
                                viaOpt and "OptionalDeps" or "Dependencies"),
                    detail  = ("addon:        %s\nloaded:       %s\ndeclared via: %s\nall deps:     %s\nopt deps:     %s")
                        :format(addonName, safeBool(loaded),
                                viaOpt and "OptionalDeps" or "Dependencies",
                                table.concat(deps, ", "),
                                table.concat(opts, ", ")),
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end


-- Source registry. Order here = tree display order. Cairn libs first
-- (alphabetical for predictable scan), then Forge-specific, then external.
local SOURCES = {
    { name = "Cairn Addons",       fn = listCairnAddons,
      describe = "Cairn-Addon registry (every Cairn.Register addon)" },
    { name = "Cairn Hooks",        fn = listCairnHooks,
      describe = "Cairn-Hooks _registry" },
    { name = "Cairn Timers",       fn = listCairnTimers,
      describe = "Cairn-Timer byOwner + named" },
    { name = "Cairn Events",       fn = listCairnEvents,
      describe = "Cairn-Events handlers" },
    { name = "Cairn DBs",          fn = listCairnDBs,
      describe = "Cairn-DB instances" },
    { name = "Cairn Slash",        fn = listCairnSlash,
      describe = "Cairn-Slash registry (every /slash)" },
    { name = "Cairn Locales",      fn = listCairnLocales,
      describe = "Cairn-Locale registry" },
    { name = "Cairn Callbacks",    fn = listCairnCallbacks,
      describe = "Cairn-Callback instances + LibStub scan" },
    { name = "Cairn Settings",     fn = listCairnSettings,
      describe = "Cairn-Settings instances" },
    { name = "Forge Tabs",         fn = listForgeTabs,
      describe = "Forge.Registry descriptors (real + LoD stubs)" },
    { name = "Forge Slash Subs",   fn = listForgeSlashSubs,
      describe = "/forge subcommand catalog" },
    { name = "Installed Forge_*",  fn = listForgeInstalledAddons,
      describe = "C_AddOns scan; flags installed-but-not-loaded" },
    { name = "Codex Modules",      fn = listCodexModules,
      describe = "LibCodex.modules" },
    { name = "Codex Consumers",    fn = listCodexConsumers,
      describe = "addons depending on LibCodex-1.0" },
}


-- ---------------------------------------------------------------------------
-- Tree assembly
-- ---------------------------------------------------------------------------
-- The tree has two levels: source branches at the root, entries as leaves.
-- Filter matches on either source name OR entry key/summary; a parent
-- whose own name matches is shown with all its children (even non-matching
-- ones) so the user can see what's in a source by name.

local function searchMatches(text)
    if _searchFilter == "" then return true end
    if not text then return false end
    return tostring(text):lower():find(_searchFilter, 1, true) ~= nil
end


local function buildTree()
    local root = {}
    for _, src in ipairs(SOURCES) do
        local ok, entries = pcall(src.fn)
        if not ok or type(entries) ~= "table" then entries = {} end

        local nameHit = searchMatches(src.name)
        local children = {}
        for _, e in ipairs(entries) do
            if nameHit
               or searchMatches(e.key)
               or searchMatches(e.summary) then
                children[#children + 1] = {
                    id    = src.name .. ":" .. e.key,
                    label = e.key,
                    aux   = e.summary or "",
                    _kind = "entry",
                    _detail = e.detail or e.summary or "",
                }
            end
        end

        -- Hide a source whose own name doesn't match AND has zero
        -- matching children; otherwise empty branches clutter the tree
        -- when a deep filter is active.
        if nameHit or #children > 0 then
            root[#root + 1] = {
                id       = "src:" .. src.name,
                label    = src.name,
                aux      = ("|cff80c0ff%s|r |cff888888(%d)|r")
                            :format(src.describe or "", #children),
                children = children,
                _kind    = "source",
            }
        end
    end
    return root
end


-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

refreshTree = function()
    if not _treeView then return end
    _allTree = buildTree()
    _treeView.Cairn:SetNodes(_allTree)

    if _statusLabel and _statusLabel.Cairn then
        local sourceCount = #_allTree
        local entryCount = 0
        for _, src in ipairs(_allTree) do
            entryCount = entryCount + (src.children and #src.children or 0)
        end
        _statusLabel.Cairn:SetText(
            ("|cff888888%d sources, %d entries|r"):format(sourceCount, entryCount))
    end
end


local function showDetail(text)
    if _detailBox and _detailBox.Cairn then
        _detailBox.Cairn:SetText(tostring(text or ""))
    end
end


-- ---------------------------------------------------------------------------
-- Relayout
-- ---------------------------------------------------------------------------

local function relayout()
    if not (_pane and _treeScroll) then return end
    -- Tree fills from TOP_RESERVED (past detail section) to BOTTOM_PAD
    -- above pane bottom. No guard on pane height because the anchors are
    -- relative; even if the pane has zero height at first call, the tree
    -- inherits the correct dimensions once the pane gets sized.
    _treeScroll:ClearAllPoints()
    _treeScroll:SetPoint("TOPLEFT",     _pane, "TOPLEFT",      SIDE_PAD, -TOP_RESERVED)
    _treeScroll:SetPoint("BOTTOMRIGHT", _pane, "BOTTOMRIGHT", -SIDE_PAD,  BOTTOM_PAD)
end


-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function build(pane)
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end
    _pane = pane

    pane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 10 })

    Gui:Acquire("Label", pane, { text = "Registry", variant = "heading" })

    Gui:Acquire("Label", pane, {
        text    = "|cff888888Inspect Cairn + Forge runtime registries. "
                  .. "Expand a source, click an entry for its detail block. "
                  .. "Filter matches across source names and entry keys.|r",
        variant = "muted",
    })

    -- Toolbar: search + Refresh + status.
    local toolbar = Gui:Acquire("Container", pane, { height = 28 })
    toolbar.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    -- Restore persisted filter from last session so reopening the tab
    -- doesn't lose the narrowing the user set up earlier.
    if ns.db and ns.db.profile and type(ns.db.profile.searchText) == "string" then
        _searchFilter = ns.db.profile.searchText:lower()
    end

    _searchBox = Gui:Acquire("EditBox", toolbar, {
        width       = 280,
        height      = 22,
        text        = (ns.db and ns.db.profile and ns.db.profile.searchText) or "",
        placeholder = "Filter sources + entries...",
    })
    _searchBox.Cairn:On("TextChanged", function(_, text)
        _searchFilter = (text or ""):lower()
        -- Persist as-typed (case preserved) so the EditBox restores
        -- exactly what the user saw.
        if ns.db and ns.db.profile then
            ns.db.profile.searchText = text or ""
        end
        refreshTree()
    end)

    _refreshBtn = Gui:Acquire("Button", toolbar, {
        text = "Refresh", variant = "ghost", width = 80, height = 22,
    })
    _refreshBtn.Cairn:On("Click", function()
        refreshTree()
        showDetail("")
    end)

    _statusLabel = Gui:Acquire("Label", toolbar, {
        text = "|cff888888loading...|r", variant = "muted",
    })

    -- Detail section (Stack flow, above the tree). Multi-line EditBox the
    -- user can Ctrl-A / Ctrl-C copy. Detail-on-top is the same pattern
    -- APIBrowser uses for its skeleton + signature rows; only the tree
    -- needs manual anchoring to fill the bottom.
    Gui:Acquire("Label", pane, {
        text = "|cff80c0ffSelected entry detail:|r", variant = "muted",
    })

    _detailBox = Gui:Acquire("EditBox", pane, {
        width       = 700,
        height      = DETAIL_HEIGHT,
        multiline   = true,
        text        = "",
        placeholder = "(click an entry in the tree to load its detail block here)",
    })

    -- TreeView in ScrollFrame. Only manual-anchored element on the pane;
    -- fills from below the detail section to the bottom of the pane.
    _treeScroll = Gui:Acquire("ScrollFrame", pane, {
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
    })
    _treeScroll.Cairn:SetLayoutManual(true)

    local treeContent = _treeScroll.Cairn:GetContent()
    _treeView = Gui:Acquire("TreeView", treeContent, {
        nodes     = {},
        rowHeight = TREE_ROW_HEIGHT,
        indent    = TREE_INDENT,
    })
    _treeView.Cairn:SetLayoutManual(true)
    _treeView:ClearAllPoints()
    _treeView:SetPoint("TOPLEFT",  treeContent, "TOPLEFT",  0, 0)
    _treeView:SetPoint("TOPRIGHT", treeContent, "TOPRIGHT", 0, 0)

    _treeView.Cairn:On("Click", function(_, nodeId, node)
        if node._kind == "entry" then
            showDetail(node._detail or "")
        else
            showDetail("")
        end
    end)

    _treeView:HookScript("OnSizeChanged", function()
        if _treeScroll.Cairn and _treeScroll.Cairn.SetContentHeight then
            _treeScroll.Cairn:SetContentHeight(
                math.max(40, _treeView:GetHeight() or 40))
        end
    end)

    pane:HookScript("OnSizeChanged", relayout)
    relayout()

    refreshTree()
end


-- ---------------------------------------------------------------------------
-- Tab descriptor
-- ---------------------------------------------------------------------------

ns.descriptor = {
    name        = "Registry",
    title       = "Registry",
    order       = 75,
    description = "Inspect Cairn + Forge runtime registries.",

    OnTabShow = function(pane, mod)
        if not pane.Cairn._builtOnce then
            pane.Cairn._builtOnce = true
            build(pane)
        end
        relayout()
        refreshTree()
    end,

    OnTabHide = function(pane, mod)
        -- Nothing to tear down.
    end,
}


-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function addon:OnInit()
    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
end

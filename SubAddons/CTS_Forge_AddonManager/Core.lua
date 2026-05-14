-- Forge_AddonManager: in-game addon management.
--
-- Phase 1 (Foundation): list view + enable/disable + memory/CPU columns
--   + queue-then-apply + profiler banner.                              DONE
-- Phase 2: Named sets (save/load enable profiles).                     DONE
-- Phase 3: Recursive dep enablement (Shift / Ctrl modifiers).          DONE
-- Phase 4: Protected list (Blizzard IsAddOnProtected + user opt-in).   DONE
-- Phase 5: TOC X-Part-Of auto-categorization (Group toggle).           DONE
-- Phase 6: TOC compatibility warnings (Interface major mismatch).      DONE
-- Phase 7: Extensible sort-criteria registry.                          DONE
--
-- Refresh strategy:
--   * Row list built once per tab open.
--   * Memory + CPU columns re-poll every REFRESH_INTERVAL seconds while
--     the tab is visible. Ticker cancelled in OnTabHide.
--   * Cascade operations bracketed by _cascadeInProgress so a 20-addon
--     dep walk produces ONE refreshList at the end, not 20.

local ADDON, ns = ...
_G.Forge_AddonManager = ns


Cairn.Register("CTS_Forge_AddonManager", ns, {
    dbName = "Forge_AddonManagerDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = {
        profile = {
            sets      = {},    -- { ["Raid"] = { "Addon1", "Addon2", ... }, ... }
            protected = {},    -- { [addonName] = true }
            grouped   = false, -- last group-toggle state
        },
        global = {},
    },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_AddonManager"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local REFRESH_INTERVAL = 2     -- seconds between memory/CPU re-polls
local ROW_HEIGHT       = 22
local ROW_GAP          =  2
local CHILD_INDENT     = 16    -- px indent for grouped child rows


-- ---------------------------------------------------------------------------
-- Module-scope state
-- ---------------------------------------------------------------------------

local _ticker
local _pending           = {}     -- { [addonName] = "enable" | "disable" }
local _addonList         = {}     -- sorted list of { name, title, notes, ... }
local _addonByName       = {}     -- name -> entry (rebuilt with _addonList)
local _reverseDeps       = {}     -- name -> array of addons that depend on it
local _partOfMap         = {}     -- name -> X-Part-Of value (or nil)
local _searchFilter      = ""
local _sortColumn        = "name"  -- key into _sortCriteria
local _sortDirection     = "asc"
local _filterMode        = "all"   -- "all" | "enabled" | "disabled" | "loaded" | "unloaded"
local _grouped           = false   -- group by X-Part-Of?
local _cascadeInProgress = false   -- batch refreshes across cascade walks

-- Widgets (set during build())
local _pendingLabel
local _applyBtn
local _discardBtn
local _profilerBanner
local _profilerBannerBtn
local _searchEdit
local _listScroll
local _listContent
local _rows          = {}     -- pool of row widget bundles (addon rows)
local _filterChips            -- { [mode] = button }
local _headerButtons          -- { name = btn, mem = btn, cpu = btn }
local _groupToggleBtn

-- Phase 2 (named sets) widgets
local _setNameEdit
local _setNameDropdown
local _setsLabel


-- ---------------------------------------------------------------------------
-- Data readers
-- ---------------------------------------------------------------------------

local function getAddOnMetadata(name, key)
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata(name, key)
    end
    if GetAddOnMetadata then return GetAddOnMetadata(name, key) end
    return nil
end


local function getAddOnDeps(name)
    if C_AddOns and C_AddOns.GetAddOnDependencies then
        return { C_AddOns.GetAddOnDependencies(name) }
    end
    if GetAddOnDependencies then return { GetAddOnDependencies(name) } end
    return {}
end


local function getAddOnOptionalDeps(name)
    if C_AddOns and C_AddOns.GetAddOnOptionalDependencies then
        return { C_AddOns.GetAddOnOptionalDependencies(name) }
    end
    if GetAddOnOptionalDependencies then
        return { GetAddOnOptionalDependencies(name) }
    end
    return {}
end


local function gatherAddons()
    local list = {}
    local count = (C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns()) or 0
    for i = 1, count do
        local name, title, notes, loadable, reason, security
        if C_AddOns and C_AddOns.GetAddOnInfo then
            name, title, notes, loadable, reason, security =
                C_AddOns.GetAddOnInfo(i)
        end
        if name then
            list[#list + 1] = {
                index    = i,
                name     = name,
                title    = title and title ~= "" and title or name,
                notes    = notes,
                loadable = loadable,
                reason   = reason,
                security = security,
            }
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end


-- Family inference fallback for addons without X-Part-Of in their TOC.
-- Splits the addon name on "-" and "_" separators and returns the
-- LONGEST prefix that matches another addon's name in the list. So:
--   Forge_AddonManager  -> Forge       (if Forge exists)
--   Cairn-Gui-2.0       -> Cairn       (Cairn-Gui doesn't exist; Cairn does)
--   LibCodex-1.0-Areas  -> LibCodex-1.0 (greedy match wins over LibCodex)
--   Bagnon_Forever      -> Bagnon
-- Requires _addonByName populated first (caller responsibility).
local function inferFamily(name)
    if not name:find("[-_]") then return nil end
    local positions = {}
    for i = 1, #name do
        local c = name:sub(i, i)
        if c == "-" or c == "_" then table.insert(positions, i) end
    end
    -- Longest prefix first (rightmost separator). Bail at the first match.
    for i = #positions, 1, -1 do
        local prefix = name:sub(1, positions[i] - 1)
        if _addonByName[prefix] and prefix ~= name then
            return prefix
        end
    end
    return nil
end


-- Build _reverseDeps + _partOfMap from _addonList. Called once after
-- gatherAddons, then again only on explicit refresh (deps don't change
-- mid-session). Two passes: pass 1 populates _addonByName so pass 2's
-- inferFamily prefix-matcher can see every addon, not just the
-- alphabetically-earlier ones.
local function buildDepGraph()
    _reverseDeps = {}
    _partOfMap   = {}
    _addonByName = {}
    for _, a in ipairs(_addonList) do
        _addonByName[a.name] = a
    end
    for _, a in ipairs(_addonList) do
        for _, dep in ipairs(getAddOnDeps(a.name)) do
            _reverseDeps[dep] = _reverseDeps[dep] or {}
            table.insert(_reverseDeps[dep], a.name)
        end
        local partOf = getAddOnMetadata(a.name, "X-Part-Of")
                    or getAddOnMetadata(a.name, "X-Child-Of")
        if partOf and partOf ~= "" then
            _partOfMap[a.name] = partOf
        else
            local inferred = inferFamily(a.name)
            if inferred then _partOfMap[a.name] = inferred end
        end
    end
end


-- Returns true when the addon is set to load (or currently loaded) for
-- the current character on the next /reload.
local function isEnabled(name)
    if not (C_AddOns and C_AddOns.GetAddOnEnableState) then return false end
    local state = C_AddOns.GetAddOnEnableState(name)
    -- state == 2 -> enabled for this character (and loadable)
    -- state == 1 -> enabled for SOME characters but NOT loadable for this one
    -- state == 0 -> disabled
    return state == 2
end


local function effectiveEnabled(name)
    local pending = _pending[name]
    if pending == "enable"  then return true  end
    if pending == "disable" then return false end
    return isEnabled(name)
end


local function refreshMemorySnapshot()
    if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end
end


local function readMemoryKB(name)
    if GetAddOnMemoryUsage then return GetAddOnMemoryUsage(name) or 0 end
    if C_AddOns and C_AddOns.GetAddOnMemoryUsage then
        return C_AddOns.GetAddOnMemoryUsage(name) or 0
    end
    return 0
end


-- Recent average CPU time per frame (ms) from C_AddOnProfiler. Returns
-- nil when the profiler isn't enabled (scriptProfile=0).
local function readCpuRecentMs(name)
    if not (C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric and Enum
            and Enum.AddOnProfilerMetric) then
        return nil
    end
    local metric = Enum.AddOnProfilerMetric.RecentAverageTime
    if not metric then return nil end
    local ok, value = pcall(C_AddOnProfiler.GetAddOnMetric, name, metric)
    if not ok then return nil end
    return value
end


local function profilerEnabled()
    if not (C_CVar and C_CVar.GetCVar) then
        return (GetCVar and GetCVar("scriptProfile") == "1") or false
    end
    return C_CVar.GetCVar("scriptProfile") == "1"
end


-- ---------------------------------------------------------------------------
-- Protected / compatibility (Phase 4 + Phase 6)
-- ---------------------------------------------------------------------------

-- Two sources of "protected":
--  1) Blizzard's IsAddOnProtected (locked addons, can't be disabled)
--  2) User's per-profile protected list (Alt-click on the checkbox)
local function isSysProtected(name)
    if C_AddOns and C_AddOns.IsAddOnProtected then
        local ok, v = pcall(C_AddOns.IsAddOnProtected, name)
        if ok then return v and true or false end
    end
    return false
end


local function isUserProtected(name)
    return db and db.profile.protected and db.profile.protected[name] or false
end


local function isAddOnProtected(name)
    return isSysProtected(name) or isUserProtected(name)
end


local function toggleUserProtected(name)
    if not (db and db.profile.protected) then return end
    if isSysProtected(name) then return end  -- can't override system lock
    db.profile.protected[name] = (not db.profile.protected[name]) or nil
end


local function getCurrentInterface()
    local _, _, _, ifaceNum = GetBuildInfo()
    return tonumber(ifaceNum) or 120005
end


local function getAddOnInterface(name)
    local v = getAddOnMetadata(name, "Interface")
    return tonumber(v)
end


-- Major-version compatibility heuristic. Interface 120005 = 12.0.5; the
-- "12" major changes across expansions. Same major = compatible enough
-- to not warn; different = yellow badge.
local function isCompatible(name)
    local iface = getAddOnInterface(name)
    if not iface then return true end
    local addonMajor = math.floor(iface / 10000)
    local currMajor  = math.floor(getCurrentInterface() / 10000)
    return addonMajor == currMajor
end


-- ---------------------------------------------------------------------------
-- Color helpers - threshold bands per the BraunerrsDevTools pattern.
-- ---------------------------------------------------------------------------

local function memColor(kb)
    if kb > 10240 then return "|cffff5050" end   -- > 10 MB
    if kb > 1024  then return "|cffffd060" end   -- > 1  MB
    return "|cff50d050"
end


local function cpuColor(ms)
    if not ms then return "|cff888888" end       -- profiler off
    if ms > 50 then return "|cffff5050" end
    if ms > 10 then return "|cffffd060" end
    return "|cff50d050"
end


local function formatMem(kb)
    if kb >= 1024 then return ("%.1f MB"):format(kb / 1024) end
    return ("%.0f KB"):format(kb)
end


local function formatCpu(ms)
    if not ms then return "-" end
    if ms < 0.1 then return "<0.1 ms" end
    return ("%.2f ms"):format(ms)
end


-- ---------------------------------------------------------------------------
-- Pending changes
-- ---------------------------------------------------------------------------

local function pendingCount()
    local n = 0
    for _ in pairs(_pending) do n = n + 1 end
    return n
end


local function refreshToolbar()
    local n = pendingCount()
    if _pendingLabel and _pendingLabel.Cairn then
        if n == 0 then
            _pendingLabel.Cairn:SetText("no pending changes")
        else
            _pendingLabel.Cairn:SetText(("%d pending change%s"):format(
                n, n == 1 and "" or "s"))
        end
    end
    local hasChanges = n > 0
    local inCombat   = InCombatLockdown and InCombatLockdown()
    if _applyBtn and _applyBtn.Cairn then
        _applyBtn.Cairn:SetEnabled(hasChanges and not inCombat)
    end
    if _discardBtn and _discardBtn.Cairn then
        _discardBtn.Cairn:SetEnabled(hasChanges)
    end
end


-- "action" is "enable" / "disable". Records intent unless it matches
-- current state (then clears the pending entry).
local function setPending(name, action)
    local currentlyEnabled = isEnabled(name)
    if (action == "enable" and currentlyEnabled)
        or (action == "disable" and not currentlyEnabled) then
        _pending[name] = nil
    else
        _pending[name] = action
    end
end


-- ---------------------------------------------------------------------------
-- Cascade ops (Phase 3)
-- ---------------------------------------------------------------------------

-- Shift-click: enable target + all transitive deps. Optional deps are
-- INCLUDED because the user explicitly asked for a recursive enable;
-- they can untoggle anything they don't want before Apply.
local function cascadeEnableDeps(name, visited)
    visited = visited or {}
    if visited[name] then return end
    visited[name] = true
    setPending(name, "enable")
    for _, dep in ipairs(getAddOnDeps(name)) do
        if _addonByName[dep] then cascadeEnableDeps(dep, visited) end
    end
    for _, dep in ipairs(getAddOnOptionalDeps(name)) do
        if _addonByName[dep] then cascadeEnableDeps(dep, visited) end
    end
end


-- Ctrl-click: disable target + all addons that depend on it. Protected
-- addons short-circuit a branch (we don't disable them and we don't
-- disable their dependents through them).
local function cascadeDisableReverseDeps(name, visited)
    visited = visited or {}
    if visited[name] then return end
    visited[name] = true
    if isAddOnProtected(name) then return end
    setPending(name, "disable")
    if _reverseDeps[name] then
        for _, dependent in ipairs(_reverseDeps[name]) do
            cascadeDisableReverseDeps(dependent, visited)
        end
    end
end


-- ---------------------------------------------------------------------------
-- Sort registry (Phase 7)
-- ---------------------------------------------------------------------------
--
-- Each entry: { label, defaultDir, getValue(addonEntry) -> comparable }.
-- ns.RegisterSortCriterion(key, def) lets future sub-addons register
-- additional columns; current UI only renders the three built-in headers.

local _sortCriteria = {
    name = {
        label      = "Addon",
        defaultDir = "asc",
        getValue   = function(a) return a.name:lower() end,
    },
    mem = {
        label      = "Memory",
        defaultDir = "desc",
        getValue   = function(a) return readMemoryKB(a.name) end,
    },
    cpu = {
        label      = "CPU",
        defaultDir = "desc",
        -- Profiler-off rows sort to the bottom on desc with -1.
        getValue   = function(a) return readCpuRecentMs(a.name) or -1 end,
    },
}

function ns.RegisterSortCriterion(key, def)
    if type(key) ~= "string" or type(def) ~= "table" then return end
    if type(def.getValue) ~= "function" then return end
    def.defaultDir = def.defaultDir or "asc"
    def.label      = def.label      or key
    _sortCriteria[key] = def
end


-- ---------------------------------------------------------------------------
-- Context menu (right-click on a row body)
-- ---------------------------------------------------------------------------

local function printDepsTree(name, depth, visited)
    depth = depth or 0
    visited = visited or {}
    if visited[name] then
        DEFAULT_CHAT_FRAME:AddMessage(("%s%s |cffff8060(cycle)|r"):format(
            string.rep("  ", depth), name))
        return
    end
    visited[name] = true
    DEFAULT_CHAT_FRAME:AddMessage(string.rep("  ", depth) .. name)
    for _, dep in ipairs(getAddOnDeps(name)) do
        printDepsTree(dep, depth + 1, visited)
    end
end


local function printTocInfo(name)
    local keys = { "Title", "Author", "Version", "Interface", "Notes",
                   "X-Category", "X-License", "X-Part-Of",
                   "X-Curse-Project-ID", "X-WoWI-ID", "X-Wago-ID" }
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd060Forge: TOC info for " .. name .. "|r")
    for _, k in ipairs(keys) do
        local v = getAddOnMetadata(name, k)
        if v and v ~= "" then
            DEFAULT_CHAT_FRAME:AddMessage(("  |cffaaaaaa%s:|r %s"):format(k, v))
        end
    end
    local deps = getAddOnDeps(name)
    if #deps > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(("  |cffaaaaaaDependencies:|r %s"):format(
            table.concat(deps, ", ")))
    end
    local odeps = getAddOnOptionalDeps(name)
    if #odeps > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(("  |cffaaaaaaOptional Deps:|r %s"):format(
            table.concat(odeps, ", ")))
    end
end


-- Right-click context menu. Uses Blizzard's MenuUtil (11.x+); falls back
-- to a chat notice if unavailable so older flavors don't crash.
local function showContextMenu(row, name)
    if not name then return end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        DEFAULT_CHAT_FRAME:AddMessage("Forge: context menu requires Blizzard MenuUtil")
        return
    end
    MenuUtil.CreateContextMenu(row.container, function(_, rd)
        rd:CreateTitle("Forge: " .. name)
        local userProt = isUserProtected(name)
        local sysProt  = isSysProtected(name)
        local protBtn  = rd:CreateButton(
            userProt and "Unprotect" or "Protect",
            function()
                toggleUserProtected(name)
                if refreshList then refreshList() end
            end)
        if sysProt and protBtn and protBtn.SetEnabled then
            -- System-protected can't be user-toggled.
            protBtn:SetEnabled(false)
        end
        rd:CreateButton("Disable + reverse-deps", function()
            _cascadeInProgress = true
            cascadeDisableReverseDeps(name)
            _cascadeInProgress = false
            refreshToolbar()
            if refreshList then refreshList() end
        end)
        rd:CreateButton("Show deps tree", function()
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffffd060Forge: deps tree for " .. name .. "|r")
            printDepsTree(name)
        end)
        rd:CreateButton("Show TOC info", function()
            printTocInfo(name)
        end)
    end)
end


-- ---------------------------------------------------------------------------
-- Row pool
-- ---------------------------------------------------------------------------

local refreshList -- forward decl (setSort / setFilter call it)


local function acquireRow(Gui, index)
    local existing = _rows[index]
    if existing and existing.container then
        existing.container:Show()
        return existing
    end

    local row = {}
    local rowW = (_listContent:GetWidth() or 800) - 12
    row.container = Gui:Acquire("Container", _listContent, {
        bg          = "color.bg.surface",
        border      = "color.border.default",
        borderWidth = 1,
        width       = rowW,
        height      = ROW_HEIGHT,
    })

    row.checkbox = Gui:Acquire("Checkbox", row.container, {
        text    = "",
        checked = false,
        width   = 24,
        height  = ROW_HEIGHT,
    })
    row.checkbox.Cairn:SetLayoutManual(true)
    row.checkbox:ClearAllPoints()
    -- Left position varies with indent; assigned in refreshList.

    row.nameLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.nameLabel.Cairn:SetLayoutManual(true)
    row.nameLabel:ClearAllPoints()
    -- Left position varies with indent; assigned in refreshList.
    row.nameLabel:SetPoint("RIGHT", row.container, "RIGHT", -220, 0)

    row.memLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.memLabel.Cairn:SetLayoutManual(true)
    row.memLabel:ClearAllPoints()
    row.memLabel:SetPoint("RIGHT", row.container, "RIGHT", -110, 0)
    row.memLabel:SetWidth(100)

    row.cpuLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.cpuLabel.Cairn:SetLayoutManual(true)
    row.cpuLabel:ClearAllPoints()
    row.cpuLabel:SetPoint("RIGHT", row.container, "RIGHT", -6, 0)
    row.cpuLabel:SetWidth(100)

    -- Right-click anywhere on the row body opens a context menu. The
    -- checkbox sits on top of the container at LEFT; right-clicking the
    -- checkbox itself still fires the Toggled handler (Cairn-Gui Checkbox
    -- registers "AnyUp") so the user-discoverable affordance is right-
    -- clicking the row body (name / mem / cpu area).
    row.container:EnableMouse(true)
    row.container:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and row._addonName then
            showContextMenu(row, row._addonName)
        end
    end)

    -- Checkbox click: dispatch based on modifier keys (Phase 3 + 4).
    --   Plain:     toggle this addon only.
    --   Shift:     enable target + all transitive deps.
    --   Ctrl:      disable target + all reverse-deps.
    --   Alt:       toggle user-protected (visual only; checkbox reverts).
    --
    -- The Toggled event fires AFTER the box flips state, so newValue is
    -- the user's intent. For Alt-protect we revert the box visually.
    row.checkbox.Cairn:On("Toggled", function(_, newValue)
        if not row._addonName then return end
        local name  = row._addonName
        local shift = IsShiftKeyDown   and IsShiftKeyDown()
        local ctrl  = IsControlKeyDown and IsControlKeyDown()
        local alt   = IsAltKeyDown     and IsAltKeyDown()

        if alt then
            -- Toggle user-protected. Revert the checkbox to current
            -- effective state because Alt-click is NOT a queue action.
            toggleUserProtected(name)
            row.checkbox.Cairn:SetChecked(effectiveEnabled(name))
            refreshList()
            return
        end

        _cascadeInProgress = true

        if newValue then
            if shift then
                cascadeEnableDeps(name)
            else
                setPending(name, "enable")
            end
        else
            if isAddOnProtected(name) and not ctrl then
                -- Protected addon, plain disable click - revert.
                row.checkbox.Cairn:SetChecked(true)
                _cascadeInProgress = false
                return
            end
            if ctrl then
                cascadeDisableReverseDeps(name)
            else
                setPending(name, "disable")
            end
        end

        _cascadeInProgress = false
        refreshToolbar()
        refreshList()
    end, "__addonMgrToggle")

    _rows[index] = row
    return row
end


local function hideExtraRows(fromIndex)
    for i = fromIndex, #_rows do
        if _rows[i] and _rows[i].container then
            _rows[i].container:Hide()
        end
    end
end


-- ---------------------------------------------------------------------------
-- Filter / sort logic
-- ---------------------------------------------------------------------------

local function rowMatchesSearch(a)
    if _searchFilter == "" then return true end
    local lower = _searchFilter:lower()
    return (a.name  and a.name:lower():find(lower, 1, true))
        or (a.title and a.title:lower():find(lower, 1, true))
end


local function addonMatchesFilter(a)
    if _filterMode == "all"      then return true end
    if _filterMode == "enabled"  then return effectiveEnabled(a.name) end
    if _filterMode == "disabled" then return not effectiveEnabled(a.name) end
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded
                   and C_AddOns.IsAddOnLoaded(a.name)
    if _filterMode == "loaded"   then return loaded and true or false end
    if _filterMode == "unloaded" then return not loaded end
    return true
end


-- Sort _addonList in place by the active column + direction. Ties always
-- resolve alphabetically by name so sort order is stable. When grouping
-- is on, the family name takes priority and the addon's own column is a
-- tiebreaker within the family.
local function sortAddons()
    local crit = _sortCriteria[_sortColumn] or _sortCriteria.name
    local ascending = (_sortDirection == "asc")
    table.sort(_addonList, function(a, b)
        if _grouped then
            -- Family = X-Part-Of value, or the addon's own name when it
            -- has no parent. That way Cairn (no parent) sorts as family
            -- "Cairn" and its children (X-Part-Of = "Cairn") share it.
            local fa = _partOfMap[a.name] or a.name
            local fb = _partOfMap[b.name] or b.name
            if fa:lower() ~= fb:lower() then
                return fa:lower() < fb:lower()
            end
            -- Within a family, parent first (no X-Part-Of), then children
            -- alphabetically.
            local pa = _partOfMap[a.name] and 1 or 0
            local pb = _partOfMap[b.name] and 1 or 0
            if pa ~= pb then return pa < pb end
            return a.name:lower() < b.name:lower()
        end

        local av, bv = crit.getValue(a), crit.getValue(b)
        if av == bv then return a.name:lower() < b.name:lower() end
        if ascending then return av < bv end
        return av > bv
    end)
end


local function updateSortHeaders()
    if not _headerButtons then return end
    local arrow = (_sortDirection == "asc") and " |cffa0a0a0^|r"
                                              or " |cffa0a0a0v|r"
    for col, btn in pairs(_headerButtons) do
        if btn.Cairn and btn.Cairn.SetText then
            local def  = _sortCriteria[col]
            local text = def and def.label or col
            if col == _sortColumn then text = text .. arrow end
            btn.Cairn:SetText(text)
        end
    end
end


local function updateFilterChips()
    if not _filterChips then return end
    for mode, btn in pairs(_filterChips) do
        if btn.Cairn and btn.Cairn.SetVariant then
            btn.Cairn:SetVariant(mode == _filterMode and "primary" or "ghost")
        end
    end
end


local function setSort(col)
    local crit = _sortCriteria[col]
    if not crit then return end
    if _sortColumn == col then
        _sortDirection = (_sortDirection == "asc") and "desc" or "asc"
    else
        _sortColumn    = col
        _sortDirection = crit.defaultDir or "asc"
    end
    updateSortHeaders()
    if _listScroll and _listScroll.Cairn and _listScroll.Cairn.ScrollToTop then
        _listScroll.Cairn:ScrollToTop()
    end
    refreshList()
end


local function setFilter(mode)
    _filterMode = mode
    updateFilterChips()
    refreshList()
end


local function setGrouped(on)
    _grouped = on and true or false
    if db and db.profile then db.profile.grouped = _grouped end
    if _groupToggleBtn and _groupToggleBtn.Cairn and _groupToggleBtn.Cairn.SetVariant then
        _groupToggleBtn.Cairn:SetVariant(_grouped and "primary" or "ghost")
    end
    refreshList()
end


-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

-- Build the name label with prefix glyphs:
--   [L] lock     = protected (system or user)
--   [!] warning  = incompatible interface major
-- and an indented "(part of X)" tag when grouping is off but the addon
-- has an X-Part-Of value.
local function buildNameText(a, indented)
    local parts = {}
    if isAddOnProtected(a.name) then
        table.insert(parts, "|cffffd060[L]|r")
    end
    if not isCompatible(a.name) then
        table.insert(parts, "|cffff8060[!]|r")
    end
    table.insert(parts, a.name)
    local text = table.concat(parts, " ")
    if a.title and a.title ~= a.name then
        text = text .. "  |cff888888" .. a.title .. "|r"
    end
    if (not indented) and _partOfMap[a.name] then
        text = text .. "  |cff666666(part of " .. _partOfMap[a.name] .. ")|r"
    end
    return text
end


refreshList = function()
    if _cascadeInProgress then return end
    if not _listContent then return end
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    refreshMemorySnapshot()
    sortAddons()

    local visibleIdx = 0
    for _, a in ipairs(_addonList) do
        if rowMatchesSearch(a) and addonMatchesFilter(a) then
            visibleIdx = visibleIdx + 1
            local row = acquireRow(Gui, visibleIdx)
            row._addonName = a.name

            -- Indent for grouped child rows. The child indent shifts the
            -- checkbox + name; mem/cpu stay right-anchored.
            local indent = (_grouped and _partOfMap[a.name]) and CHILD_INDENT or 0
            row.checkbox:ClearAllPoints()
            row.checkbox:SetPoint("LEFT", row.container, "LEFT", 4 + indent, 0)
            row.nameLabel:ClearAllPoints()
            row.nameLabel:SetPoint("LEFT",  row.container, "LEFT", 36 + indent, 0)
            row.nameLabel:SetPoint("RIGHT", row.container, "RIGHT", -220, 0)

            row.nameLabel.Cairn:SetText(buildNameText(a, indent > 0))
            row.checkbox.Cairn:SetChecked(effectiveEnabled(a.name))

            local kb = readMemoryKB(a.name)
            row.memLabel.Cairn:SetText(memColor(kb) .. formatMem(kb) .. "|r")

            local ms = readCpuRecentMs(a.name)
            row.cpuLabel.Cairn:SetText(cpuColor(ms) .. formatCpu(ms) .. "|r")

            if row.container.Cairn and row.container.Cairn.DrawRect then
                local bg = _pending[a.name] and "color.bg.button" or "color.bg.surface"
                row.container.Cairn:DrawRect("bg", bg)
            end

            -- Dim rows for addons that are enabled-state-2 but not yet
            -- loaded (LoD pending, or "will load on next /reload"). Helps
            -- distinguish "running right now" from "queued to run".
            local loadedNow = C_AddOns and C_AddOns.IsAddOnLoaded
                              and C_AddOns.IsAddOnLoaded(a.name)
            if effectiveEnabled(a.name) and not loadedNow then
                row.container:SetAlpha(0.55)
            else
                row.container:SetAlpha(1.0)
            end
        end
    end
    hideExtraRows(visibleIdx + 1)

    if _listScroll and _listScroll.Cairn and _listScroll.Cairn.SetContentHeight then
        _listScroll.Cairn:SetContentHeight(
            math.max(60, visibleIdx * (ROW_HEIGHT + ROW_GAP)))
    end
end


local function refreshProfilerBanner()
    if not _profilerBanner then return end
    if profilerEnabled() then
        _profilerBanner:Hide()
    else
        _profilerBanner:Show()
    end
end


local function refreshAll()
    refreshToolbar()
    refreshProfilerBanner()
    refreshList()
end


-- ---------------------------------------------------------------------------
-- Apply / Discard
-- ---------------------------------------------------------------------------

local function apply()
    if InCombatLockdown and InCombatLockdown() then return end
    if pendingCount() == 0 then return end
    for name, action in pairs(_pending) do
        if action == "enable" then
            if C_AddOns and C_AddOns.EnableAddOn then C_AddOns.EnableAddOn(name) end
        elseif action == "disable" then
            if C_AddOns and C_AddOns.DisableAddOn then C_AddOns.DisableAddOn(name) end
        end
    end
    _pending = {}
    if ReloadUI then ReloadUI() end
end


local function discard()
    _pending = {}
    refreshAll()
end


-- ---------------------------------------------------------------------------
-- Named sets (Phase 2)
-- ---------------------------------------------------------------------------

local function listSetNames()
    if not (db and db.profile.sets) then return {} end
    local names = {}
    for k in pairs(db.profile.sets) do names[#names + 1] = k end
    table.sort(names)
    return names
end


local function refreshSetsLabel()
    if not _setsLabel or not _setsLabel.Cairn then return end
    local names = listSetNames()
    if #names == 0 then
        _setsLabel.Cairn:SetText("|cff888888no sets saved yet|r")
    else
        _setsLabel.Cairn:SetText(("|cff888888Saved sets (%d):|r %s"):format(
            #names, table.concat(names, ", ")))
    end
end


local function refreshSetsDropdown()
    if not _setNameDropdown or not _setNameDropdown.Cairn then return end
    local names = listSetNames()
    local options = {}
    for _, n in ipairs(names) do
        options[#options + 1] = { value = n, label = n }
    end
    local prev = _setNameDropdown.Cairn:GetSelected()
    _setNameDropdown.Cairn:SetOptions(options)
    local stillExists = prev and db and db.profile.sets[prev]
    if stillExists then
        _setNameDropdown.Cairn:SetSelected(prev)
    else
        _setNameDropdown.Cairn:SetSelected(nil)
    end
end


local function saveSet(name)
    if not (db and name and name ~= "") then return end
    local members = {}
    for _, a in ipairs(_addonList) do
        if effectiveEnabled(a.name) then
            members[#members + 1] = a.name
        end
    end
    table.sort(members)
    db.profile.sets[name] = members
    refreshSetsLabel()
    refreshSetsDropdown()
end


local function loadSet(name)
    if not (db and name and db.profile.sets[name]) then return end
    local memberSet = {}
    for _, n in ipairs(db.profile.sets[name]) do memberSet[n] = true end
    _cascadeInProgress = true
    for _, a in ipairs(_addonList) do
        if memberSet[a.name] then
            setPending(a.name, "enable")
        elseif not isAddOnProtected(a.name) then
            setPending(a.name, "disable")
        end
    end
    _cascadeInProgress = false
    refreshAll()
end


local function deleteSet(name)
    if not (db and name and db.profile.sets[name]) then return end
    db.profile.sets[name] = nil
    refreshSetsLabel()
    refreshSetsDropdown()
end


-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function build(pane)
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    pane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 10 })

    Gui:Acquire("Label", pane, { text = "AddOn Manager", variant = "heading" })

    -- Hint line: modifier-key cheatsheet (Phase 3 + 4).
    Gui:Acquire("Label", pane, {
        text = "|cff888888Shift-click = also enable deps  |  Ctrl-click = also disable dependents  |  Alt-click = toggle [L]ock|r",
        variant = "muted",
    })

    -- Pending-changes toolbar.
    local toolbar = Gui:Acquire("Container", pane, { height = 28 })
    toolbar.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    _applyBtn = Gui:Acquire("Button", toolbar, {
        text = "Apply + Reload", variant = "primary", width = 130,
    })
    _applyBtn.Cairn:On("Click", apply)

    _discardBtn = Gui:Acquire("Button", toolbar, {
        text = "Discard", variant = "ghost", width = 90,
    })
    _discardBtn.Cairn:On("Click", discard)

    _pendingLabel = Gui:Acquire("Label", toolbar, {
        text = "no pending changes", variant = "muted",
    })

    -- Named-sets toolbar (Phase 2).
    local setsToolbar = Gui:Acquire("Container", pane, { height = 26 })
    setsToolbar.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    Gui:Acquire("Label", setsToolbar, { text = "Set:" })

    _setNameDropdown = Gui:Acquire("Dropdown", setsToolbar, {
        width          = 160,
        height         = 22,
        options        = {},
        placeholder    = "(saved sets)",
        maxVisibleRows = 10,
    })
    _setNameDropdown.Cairn:On("Changed", function(_, value)
        if _setNameEdit and _setNameEdit.Cairn and value then
            _setNameEdit.Cairn:SetText(value)
        end
    end)

    _setNameEdit = Gui:Acquire("EditBox", setsToolbar, {
        width       = 140,
        height      = 22,
        text        = "",
        placeholder = "Raid / Solo / PvP ...",
    })

    local function readSetName()
        return _setNameEdit and _setNameEdit.Cairn
               and _setNameEdit.Cairn:GetText() or ""
    end

    local saveSetBtn = Gui:Acquire("Button", setsToolbar, {
        text = "Save", variant = "primary", width = 60,
    })
    saveSetBtn.Cairn:On("Click", function() saveSet(readSetName()) end)

    local loadSetBtn = Gui:Acquire("Button", setsToolbar, {
        text = "Load", variant = "default", width = 60,
    })
    loadSetBtn.Cairn:On("Click", function() loadSet(readSetName()) end)

    local deleteSetBtn = Gui:Acquire("Button", setsToolbar, {
        text = "Delete", variant = "danger", width = 70,
    })
    deleteSetBtn.Cairn:On("Click", function() deleteSet(readSetName()) end)

    _setsLabel = Gui:Acquire("Label", pane, {
        text = "no sets saved yet", variant = "muted",
    })

    -- Profiler-disabled banner. Hidden when scriptProfile=1.
    _profilerBanner = Gui:Acquire("Container", pane, {
        bg          = "color.bg.surface",
        border      = "color.border.default",
        borderWidth = 1,
        height      = 30,
    })
    _profilerBanner.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 8, padding = 4 })

    Gui:Acquire("Label", _profilerBanner, {
        text = "|cffffd060CPU profiler disabled.|r Enable to see live CPU columns. Requires /reload.",
    })
    _profilerBannerBtn = Gui:Acquire("Button", _profilerBanner, {
        text = "Enable + Reload", variant = "primary", width = 130,
    })
    _profilerBannerBtn.Cairn:On("Click", function()
        if InCombatLockdown and InCombatLockdown() then return end
        if C_CVar and C_CVar.SetCVar then C_CVar.SetCVar("scriptProfile", "1")
        elseif SetCVar then SetCVar("scriptProfile", "1") end
        if ReloadUI then ReloadUI() end
    end)

    -- Search filter.
    _searchEdit = Gui:Acquire("EditBox", pane, {
        width       = 280,
        height      = 22,
        text        = "",
        placeholder = "Filter by name...",
    })
    _searchEdit.Cairn:On("TextChanged", function(_, text)
        _searchFilter = text or ""
        refreshList()
    end)

    -- Filter chips + Group toggle on the same row. The chips are mutually
    -- exclusive (filter mode); the group toggle is orthogonal.
    local filterRow = Gui:Acquire("Container", pane, { height = 26 })
    filterRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 4, padding = 0 })

    Gui:Acquire("Label", filterRow, { text = "Show:", variant = "muted" })

    _filterChips = {}
    local filterDefs = {
        { mode = "all",      label = "All"      },
        { mode = "enabled",  label = "Enabled"  },
        { mode = "disabled", label = "Disabled" },
        { mode = "loaded",   label = "Loaded"   },
        { mode = "unloaded", label = "Unloaded" },
    }
    for _, def in ipairs(filterDefs) do
        local chip = Gui:Acquire("Button", filterRow, {
            text = def.label, variant = "ghost", width = 78, height = 22,
        })
        chip.Cairn:On("Click", function() setFilter(def.mode) end)
        _filterChips[def.mode] = chip
    end
    updateFilterChips()

    -- Spacer + Group toggle on the right side of the filter row.
    Gui:Acquire("Label", filterRow, { text = "  ", variant = "muted" })
    _groupToggleBtn = Gui:Acquire("Button", filterRow, {
        text = "Group by family", variant = "ghost", width = 130, height = 22,
    })
    _groupToggleBtn.Cairn:On("Click", function() setGrouped(not _grouped) end)

    -- Column headers (Phase 7 sort registry drives the labels).
    local headerRow = Gui:Acquire("Container", pane, {
        bg          = "color.bg.surface",
        border      = "color.border.default",
        borderWidth = 1,
        height      = 24,
    })

    _headerButtons = {}

    _headerButtons.name = Gui:Acquire("Button", headerRow, {
        text = "Addon", variant = "ghost", height = 22,
    })
    _headerButtons.name.Cairn:SetLayoutManual(true)
    _headerButtons.name:ClearAllPoints()
    _headerButtons.name:SetPoint("LEFT",  headerRow, "LEFT",   36, 0)
    _headerButtons.name:SetPoint("RIGHT", headerRow, "RIGHT", -220, 0)
    _headerButtons.name.Cairn:On("Click", function() setSort("name") end)

    _headerButtons.mem = Gui:Acquire("Button", headerRow, {
        text = "Memory", variant = "ghost", height = 22, width = 100,
    })
    _headerButtons.mem.Cairn:SetLayoutManual(true)
    _headerButtons.mem:ClearAllPoints()
    _headerButtons.mem:SetPoint("RIGHT", headerRow, "RIGHT", -110, 0)
    _headerButtons.mem.Cairn:On("Click", function() setSort("mem") end)

    _headerButtons.cpu = Gui:Acquire("Button", headerRow, {
        text = "CPU", variant = "ghost", height = 22, width = 100,
    })
    _headerButtons.cpu.Cairn:SetLayoutManual(true)
    _headerButtons.cpu:ClearAllPoints()
    _headerButtons.cpu:SetPoint("RIGHT", headerRow, "RIGHT", -6, 0)
    _headerButtons.cpu.Cairn:On("Click", function() setSort("cpu") end)

    updateSortHeaders()

    -- Addon list (ScrollFrame). Anchored TOPLEFT under header, BOTTOMRIGHT
    -- to pane corner so window resize re-sizes the list.
    _listScroll = Gui:Acquire("ScrollFrame", pane, {
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
    })
    _listScroll.Cairn:SetLayoutManual(true)
    _listScroll:ClearAllPoints()
    _listScroll:SetPoint("TOPLEFT",     headerRow, "BOTTOMLEFT",  0, -2)
    _listScroll:SetPoint("BOTTOMRIGHT", pane,      "BOTTOMRIGHT", -2, 6)

    _listContent = _listScroll.Cairn:GetContent()
    _listContent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = ROW_GAP, padding = 6 })

    _addonList = gatherAddons()
    buildDepGraph()

    -- Restore group preference from DB (defaults to false).
    if db and db.profile and db.profile.grouped then
        setGrouped(true)
    end

    refreshAll()
    refreshSetsLabel()
    refreshSetsDropdown()
end


-- ---------------------------------------------------------------------------
-- Tab descriptor
-- ---------------------------------------------------------------------------

ns.descriptor = {
    name        = "AddOn Manager",
    title       = "AddOn Manager",
    order       = 90,
    description = "Enable/disable addons, queue changes, see memory + CPU columns.",

    OnTabShow = function(pane, mod)
        if not pane.Cairn._builtOnce then
            pane.Cairn._builtOnce = true
            build(pane)
        else
            refreshAll()
        end
        if C_Timer and C_Timer.NewTicker and not _ticker then
            _ticker = C_Timer.NewTicker(REFRESH_INTERVAL, refreshList)
        end
    end,

    OnTabHide = function(pane, mod)
        if _ticker and _ticker.Cancel then
            _ticker:Cancel()
            _ticker = nil
        end
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


-- Combat handlers - disable Apply during combat, re-enable on regen.
function addon:OnLogin()
    if ns.Events and ns.Events.Subscribe then
        ns.Events:Subscribe("PLAYER_REGEN_DISABLED", refreshToolbar)
        ns.Events:Subscribe("PLAYER_REGEN_ENABLED",  refreshToolbar)
    else
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_REGEN_DISABLED")
        f:RegisterEvent("PLAYER_REGEN_ENABLED")
        f:SetScript("OnEvent", refreshToolbar)
    end
end


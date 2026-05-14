-- Forge_Tables: Lua table inspector.
--
-- v3 scope (this file):
--   * Cairn-Gui TreeView widget renders the current root as an expandable
--     hierarchy with lazy per-level children resolution.
--   * Path navigator (top EditBox + Go) re-roots the tree. Clear unloads.
--   * Filter chips: All / Tables only / Leaves only.
--   * NEW: per-level substring filter (case-insensitive, live-typed) that
--     applies at every depth, including lazy-expanded branches.
--   * NEW: function preview via debug.getinfo - Lua closures show their
--     source file:line; C functions render as "(C)". Cached per function.
--   * Right-click context menu (Copy path, Copy value, Re-root here).
--
-- Out of scope for v3 (queued for v4):
--   * Live refresh tick (re-read tree on a timer).
--   * Value editing.
--   * Userdata / metatable inspection.
--   * Pinned-favorites list.
--
-- Tree build:
--   * Walk eagerly from _currentTable to MAX_BUILD_DEPTH levels deep.
--     For _G this builds ~10k root nodes + their immediate children,
--     about 50k node objects, ~500ms-1s on a typical client. For
--     focused roots like C_Map this is fast.
--   * Cycle detection via visited[table] set so _G._G == _G doesn't
--     loop. Re-visited tables show as leaves with aux noting the
--     cycle.
--   * Beyond MAX_BUILD_DEPTH, table values render as leaves with
--     aux "table (N) - re-root to view". User searches for that
--     path to descend further.

local ADDON, ns = ...
_G.Forge_Tables = ns


Cairn.Register("CTS_Forge_Tables", ns, {
    dbName = "Forge_TablesDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = { profile = {}, global = {} },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Tables"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local STRING_PREVIEW_MAX  = 80
local VALUE_LITERAL_MAX   = 120
local TREE_ROW_HEIGHT     = 18
local TREE_INDENT         = 16
local MAX_NODES_PER_LEVEL = 500   -- cap nodes rendered at any single tree level

-- We no longer pre-walk children eagerly. The root tree is built with
-- just the root's direct keys; table values are marked
-- node.expandable = true (Cairn-Gui Standard MINOR 15) and populated
-- on the TreeView's Toggle event. Walking _G eagerly at depth 2 was
-- doing 500k+ pairs() + SafeCount ops and freezing the client.
--
-- A second cap protects against huge SINGLE levels: _G has ~10k root
-- keys and rendering one row per key is 40k Cairn-Gui widgets. The
-- MAX_NODES_PER_LEVEL cap clamps each level to 500 nodes plus one
-- truncation-marker leaf when the level was actually larger.

-- Layout offsets used by relayout().
local TOP_RESERVED        = 184   -- heading + hint + search row + filter chips + skeleton + filter row + gaps
local BOTTOM_PAD          = 10
local SIDE_PAD            = 10


-- ---------------------------------------------------------------------------
-- Module-scope state
-- ---------------------------------------------------------------------------

local _path           = {}        -- segment names from _G to current root
local _currentTable   = nil       -- resolved table at _path; nil = no tree loaded yet
local _filterMode     = "all"     -- "all" | "tables" | "leaves"
local _searchText     = ""        -- case-insensitive substring filter applied per level
local _errorMsg       = nil
local _currentTree    = nil       -- the array we passed to TreeView; used for
                                  -- node lookup on lazy expansion
local _fnInfoCache    = {}        -- function -> aux preview string. Memoized so
                                  -- debug.getinfo runs once per function across
                                  -- the session.

-- Why _currentTable starts nil instead of _G:
-- Walking _G eagerly to MAX_BUILD_DEPTH on first tab open does two
-- bad things: (1) it's slow (~10k root keys * 2 levels), and (2) some
-- _G values are WoW "secret strings" (locale strings, protected
-- globals). Calling :gsub on a secret string TAINTS the addon and
-- breaks subsequent secure dispatches. User must explicitly navigate
-- before we walk anything.

local _pane
local _searchBox        -- path navigator EditBox (re-roots on Enter)
local _filterBox        -- per-level substring filter EditBox (live)
local _filterClearBtn
local _resetBtn
local _statusLabel
local _filterChips    = {}
local _skeletonBox
local _treeScroll
local _treeView


-- Forward declarations.
local refreshTree
local refreshFilterChips
local navigate


-- ---------------------------------------------------------------------------
-- Path resolution + formatting
-- ---------------------------------------------------------------------------

local function resolvePath(segments)
    local t = _G
    for _, seg in ipairs(segments) do
        if type(t) ~= "table" then return nil end
        t = t[seg]
    end
    return t
end


local function parsePathString(text)
    if not text or text == "" then return {} end
    local segments = {}
    for seg in text:gmatch("[^.]+") do
        if seg ~= "" and seg ~= "_G" then
            segments[#segments + 1] = seg
        end
    end
    return segments
end


local function formatKeySuffix(k)
    if type(k) == "string" then
        if k:match("^[A-Za-z_][A-Za-z0-9_]*$") then
            return "." .. k
        end
        return ("[%q]"):format(k)
    elseif type(k) == "number" then
        return "[" .. tostring(k) .. "]"
    end
    return "[" .. tostring(k) .. "]"
end


local function formatPathAsLua(segments)
    local parts = { "_G" }
    for _, k in ipairs(segments) do
        parts[#parts + 1] = formatKeySuffix(k)
    end
    return table.concat(parts)
end


-- Build a Lua expression string for a given key relative to root path.
-- Used to build node ids in the TreeView so they uniquely identify
-- positions in the tree.
local function pathPlus(basePath, segments)
    local s = basePath
    for _, seg in ipairs(segments) do
        s = s .. formatKeySuffix(seg)
    end
    return s
end


local function formatKeyForDisplay(k)
    if type(k) == "string" then return k end
    return "[" .. tostring(k) .. "]"
end


-- Function preview. debug.getinfo on a Lua closure returns source +
-- linedefined; on a C function it returns what="C" with no useful info.
-- Cached per-function so repeat renders cost one table lookup.
--
-- WoW's in-client Lua sandbox does NOT expose the `debug` library:
-- pcall(debug.getinfo, fn, "S") doesn't help because indexing `debug`
-- (a nil global) errors *before* pcall is invoked. We probe via
-- `type(debug) == "table"` first (reading a missing global yields nil
-- safely; only indexing nil errors). Standalone Lua 5.1 test VMs do
-- have debug, so the guarded path still works there.
local function formatFunctionPreview(fn)
    local cached = _fnInfoCache[fn]
    if cached then return cached end
    local out
    if type(debug) == "table" and type(debug.getinfo) == "function" then
        local ok, info = pcall(debug.getinfo, fn, "S")
        if ok and type(info) == "table" then
            if info.what == "C" then
                out = "|cffd080ff" .. "function|r |cff888888(C)|r"
            elseif info.what == "Lua" then
                out = ("|cffd080ff" .. "function|r |cff888888(%s:%d)|r"):format(
                    info.short_src or "?", info.linedefined or 0)
            end
        end
    end
    if not out then out = "|cffd080ff" .. "function|r" end
    _fnInfoCache[fn] = out
    return out
end


-- Value aux text shown in the TreeView's right column. Tables show key
-- count for drill triage; functions/strings/numbers show a brief tag.
--
-- String values use Cairn_Util.String.SafePreview because some _G
-- strings are WoW "secret strings" (locale entries, protected globals):
-- calling :gsub on them throws and TAINTS the addon for the rest of
-- the session. SafePreview returns nil on those so we render a
-- placeholder instead of poisoning the addon.
local function formatValueAux(v, depthInfo)
    local t = type(v)
    if t == "nil"     then return "|cff888888nil|r" end
    if t == "string"  then
        local CU = LibStub("Cairn-Util-1.0", true)
        local s = CU and CU.String and CU.String.SafePreview
                  and CU.String.SafePreview(v, STRING_PREVIEW_MAX)
        if s == nil then
            return "|cffaaaaaa<secret string>|r"
        end
        return ("|cffffd060\"%s\"|r"):format(s)
    end
    if t == "number"  then return ("|cff80c0ff%s|r"):format(tostring(v)) end
    if t == "boolean" then return ("|cffff80c0%s|r"):format(tostring(v)) end
    if t == "table" then
        -- Do NOT SafeCount on initial build: counting every table value
        -- in a 10k-key root walks each table once which adds up to
        -- 500k+ ops and freezes the client. We display the count later,
        -- after lazy-expansion populates this branch (see
        -- populateChildren / formatValueAuxWithCount). For the initial
        -- render just say "table".
        if depthInfo == "cycle" then
            return "|cffff8060table - cycle|r"
        end
        return "|cff80ff80table|r"
    end
    if t == "function" then return formatFunctionPreview(v) end
    if t == "userdata" then return "|cffaa80ffuserdata|r" end
    return ("|cffaaaaaa%s|r"):format(tostring(v))
end


local function formatValueLiteral(v, keyPath)
    local t = type(v)
    if t == "string"  then return ("%q"):format(v) end
    if t == "number"  then return tostring(v) end
    if t == "boolean" then return tostring(v) end
    if t == "nil"     then return "nil" end
    return keyPath
end


-- ---------------------------------------------------------------------------
-- Skeleton + copy
-- ---------------------------------------------------------------------------

local function showCallSkeleton(text)
    if _skeletonBox and _skeletonBox.Cairn then
        _skeletonBox.Cairn:SetText(tostring(text or ""))
        if _skeletonBox.Cairn.HighlightText then
            _skeletonBox.Cairn:HighlightText()
        end
        if _skeletonBox.Cairn.SetFocus then
            _skeletonBox.Cairn:SetFocus()
        end
    end
end


-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

-- Uses Cairn_Util.Table.SafeKeys to dodge taint-protected tables (some
-- Blizzard internals throw on pairs() from addon code). Returns nil
-- on protected tables; callers treat that as "empty children" and
-- mark the node as a leaf with a placeholder aux.
local function gatherKeys(t)
    local CU = LibStub("Cairn-Util-1.0", true)
    if CU and CU.Table and CU.Table.SafeKeys then
        return CU.Table.SafeKeys(t)
    end
    -- Fallback for installs running an older Cairn-Util.
    local keys = {}
    local ok = pcall(function()
        for k in pairs(t) do keys[#keys + 1] = k end
    end)
    if not ok then return nil end
    table.sort(keys, function(a, b)
        return tostring(a):lower() < tostring(b):lower()
    end)
    return keys
end


local function passesFilter(v)
    if _filterMode == "all" then return true end
    if _filterMode == "tables" then return type(v) == "table" end
    if _filterMode == "leaves" then return type(v) ~= "table" end
    return true
end


-- Per-level substring filter. Empty filter passes everything. Match is
-- case-insensitive on the key cast to string so numeric / mixed-key tables
-- are searchable too (rare but the user can pivot tables look like that).
-- Cheap enough to run on every node during build; no caching needed.
local function passesSearch(k)
    if _searchText == "" then return true end
    return tostring(k):lower():find(_searchText, 1, true) ~= nil
end


-- ---------------------------------------------------------------------------
-- Subtree build (one level only; lazy via Toggle event)
-- ---------------------------------------------------------------------------
-- buildOneLevel walks `t` once and emits one node per direct child.
-- Table values get `expandable = true` (Cairn-Gui Standard MINOR 15)
-- with empty children, so the TreeView shows the [+] indicator but
-- doesn't render anything until populateChildren is called.

local function buildOneLevel(t, parentPath)
    if type(t) ~= "table" then return {} end
    local keys = gatherKeys(t)
    if not keys then return {} end
    local nodes = {}
    local emitted = 0
    local truncated = false

    for _, k in ipairs(keys) do
        local v = t[k]
        -- Both filters apply at every level. The search filter is what
        -- makes deep tables like _G or C_AddOns navigable: instead of
        -- scrolling 10k rows, the user types a fragment to narrow to
        -- a handful. Note populateChildren calls back into buildOneLevel
        -- so newly-expanded branches see the current filter too.
        if passesFilter(v) and passesSearch(k) then
            if emitted >= MAX_NODES_PER_LEVEL then
                truncated = true
                break
            end
            local kSuffix = formatKeySuffix(k)
            local nodePath = parentPath .. kSuffix
            local node = {
                id    = nodePath,
                label = formatKeyForDisplay(k),
                aux   = formatValueAux(v),
                _key  = k,
                _value = v,
                _path = nodePath,
            }
            if type(v) == "table" then
                node.expandable = true
                node.children   = {}
                node._lazyDone  = false
            end
            nodes[#nodes + 1] = node
            emitted = emitted + 1
        end
    end

    if truncated then
        -- A non-expandable marker row so the user sees the cap. Counted
        -- keys total - emitted gives the suppressed-count; the cap means
        -- we already stopped reading t[k] for those, so the count is a
        -- minimum.
        nodes[#nodes + 1] = {
            id    = parentPath .. ".__truncated__",
            label = ("|cffffd060(showing first %d of %d+ keys - narrow via search)|r")
                    :format(emitted, #keys),
            aux   = "",
            _kind = "marker",
        }
    end

    return nodes
end


local function buildTree()
    -- Nil _currentTable means "no nav yet"; return empty tree.
    if not _currentTable then return {} end
    local root = formatPathAsLua(_path)
    return buildOneLevel(_currentTable, root)
end


-- ---------------------------------------------------------------------------
-- Lazy children population
-- ---------------------------------------------------------------------------

-- Walk the tree to find a node by id. Used by the Toggle handler to
-- locate the just-expanded node and populate its children.
local function findNodeById(nodes, id, visiting)
    visiting = visiting or {}
    if visiting[nodes] then return nil end
    visiting[nodes] = true
    for _, n in ipairs(nodes or {}) do
        if n.id == id then return n end
        if n.children and #n.children > 0 then
            local found = findNodeById(n.children, id, visiting)
            if found then return found end
        end
    end
    return nil
end


-- Populate children of a node on first expansion. Once _lazyDone is
-- set, we don't re-walk on re-expansion. If the user wants fresh data
-- they re-root.
local function populateChildren(node)
    if not node or node._lazyDone then return false end
    if type(node._value) ~= "table" then
        node._lazyDone = true
        return false
    end
    node.children = buildOneLevel(node._value, node._path)
    node._lazyDone = true
    -- Update the aux now that we know the actual child count.
    local CU = LibStub("Cairn-Util-1.0", true)
    local n = CU and CU.Table and CU.Table.SafeCount
              and CU.Table.SafeCount(node._value)
    if n then
        node.aux = ("|cff80ff80table (%d)|r"):format(n)
    end
    return true
end


-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

navigate = function(newPath)
    local t = resolvePath(newPath)
    if type(t) ~= "table" then
        _errorMsg = "Path does not resolve to a table: " .. formatPathAsLua(newPath)
        if _statusLabel and _statusLabel.Cairn then
            _statusLabel.Cairn:SetText("|cffff8060" .. _errorMsg .. "|r")
        end
        return
    end
    _errorMsg     = nil
    _path         = newPath
    _currentTable = t
    refreshTree()
end


local function reRootHere(nodePath)
    -- Convert a node's full Lua path back to segment array. nodePath is
    -- something like "_G.C_Map.GetMapInfo" or "_G[5].field".
    -- For v2 we support only the dotted form; bracket form re-rooting
    -- is rare and would need a tokenizer. Anything bracket-shaped falls
    -- back to a search-box prompt.
    local p = nodePath
    if p:sub(1, 2) == "_G" then p = p:sub(3) end
    if p:sub(1, 1) == "." then p = p:sub(2) end
    if p:find("[%[%]]") then
        -- Bracket-keyed path; ask the user to type it manually.
        if _searchBox and _searchBox.Cairn then
            _searchBox.Cairn:SetText(nodePath)
        end
        return
    end
    navigate(parsePathString(p))
end


-- ---------------------------------------------------------------------------
-- Context menu
-- ---------------------------------------------------------------------------

local function showContextMenu(row, node)
    if not node then return end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        showCallSkeleton(node._path or node.id)
        return
    end
    MenuUtil.CreateContextMenu(row.container, function(_, rd)
        rd:CreateTitle("Forge: " .. (node.label or node.id or "?"))
        rd:CreateButton("Copy path", function()
            showCallSkeleton(node._path or node.id)
        end)
        local v = node._value
        local literal = formatValueLiteral(v, node._path or node.id)
        if #literal > VALUE_LITERAL_MAX then
            literal = literal:sub(1, VALUE_LITERAL_MAX) .. "..."
        end
        rd:CreateButton("Copy value", function()
            showCallSkeleton(literal)
        end)
        if type(v) == "table" then
            rd:CreateButton("Re-root here", function()
                reRootHere(node._path or node.id)
            end)
        end
    end)
end


-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

refreshTree = function()
    if not _treeView then return end
    _currentTree = buildTree()
    _treeView.Cairn:SetNodes(_currentTree)

    if _statusLabel and _statusLabel.Cairn then
        if not _currentTable then
            _statusLabel.Cairn:SetText(
                "|cff888888no root - type a path above to load a tree|r")
        else
            -- Count via SafeKeys so a protected root table doesn't taint
            -- the status update. Falls back to "?" when keys is nil.
            local keys = gatherKeys(_currentTable)
            local total = keys and #keys or 0
            local totalText = keys and tostring(total) or "?"
            local visible = _treeView.Cairn:GetVisibleCount() or 0
            _statusLabel.Cairn:SetText(
                ("|cff888888%d visible / %s keys at root %s|r"):format(
                    visible, totalText, formatPathAsLua(_path)))
        end
    end

    if _resetBtn and _resetBtn.Cairn and _resetBtn.Cairn.SetEnabled then
        _resetBtn.Cairn:SetEnabled(_currentTable ~= nil)
    end
end


refreshFilterChips = function()
    if not _filterChips then return end
    for mode, btn in pairs(_filterChips) do
        if btn.Cairn and btn.Cairn.SetVariant then
            btn.Cairn:SetVariant(mode == _filterMode and "primary" or "ghost")
        end
    end
end


local function setFilterMode(mode)
    _filterMode = mode
    refreshFilterChips()
    refreshTree()
end


-- Update the per-level filter and rebuild. Lowercased once here so
-- passesSearch doesn't have to re-lower on every key check.
local function setSearchText(text)
    _searchText = (text or ""):lower()
    if _filterClearBtn and _filterClearBtn.Cairn
       and _filterClearBtn.Cairn.SetEnabled then
        _filterClearBtn.Cairn:SetEnabled(_searchText ~= "")
    end
    refreshTree()
end


-- ---------------------------------------------------------------------------
-- Relayout
-- ---------------------------------------------------------------------------

local function relayout()
    if not (_pane and _treeScroll) then return end
    local paneH = _pane:GetHeight() or 0
    if paneH < 200 then return end
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

    Gui:Acquire("Label", pane, { text = "Tables", variant = "heading" })

    Gui:Acquire("Label", pane, {
        text    = "|cff888888Type a global name or dotted path, then Enter. Click a table row to expand inline; right-click for Copy / Re-root.|r",
        variant = "muted",
    })

    -- Search row.
    local searchRow = Gui:Acquire("Container", pane, { height = 28 })
    searchRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    _searchBox = Gui:Acquire("EditBox", searchRow, {
        width       = 280,
        height      = 22,
        text        = "",
        placeholder = "C_Map  or  C_Map.GetBestMapForUnit  or  _G",
    })
    _searchBox.Cairn:On("EnterPressed", function(_, text)
        navigate(parsePathString(text or ""))
    end)

    local goBtn = Gui:Acquire("Button", searchRow, {
        text = "Go", variant = "primary", width = 60, height = 22,
    })
    goBtn.Cairn:On("Click", function()
        local text = _searchBox.Cairn and _searchBox.Cairn:GetText() or ""
        navigate(parsePathString(text))
    end)

    _resetBtn = Gui:Acquire("Button", searchRow, {
        text = "Clear", variant = "ghost", width = 70, height = 22,
    })
    -- Clear unloads the tree without re-walking _G. The previous
    -- "Reset to _G" approach navigate({}) walked _G again, which is
    -- both slow and risks tainting on secret-string values. User
    -- explicitly types "_G" + Enter if they really want the full root
    -- tree.
    _resetBtn.Cairn:On("Click", function()
        _path = {}
        _currentTable = nil
        refreshTree()
    end)
    if _resetBtn.Cairn.SetEnabled then _resetBtn.Cairn:SetEnabled(false) end

    -- Filter chips row.
    local filterRow = Gui:Acquire("Container", pane, { height = 26 })
    filterRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 4, padding = 0 })

    Gui:Acquire("Label", filterRow, { text = "Show:", variant = "muted" })

    local filterDefs = {
        { mode = "all",    label = "All"     },
        { mode = "tables", label = "Tables"  },
        { mode = "leaves", label = "Leaves"  },
    }
    for _, def in ipairs(filterDefs) do
        local chip = Gui:Acquire("Button", filterRow, {
            text = def.label, variant = "ghost", width = 70, height = 22,
        })
        chip.Cairn:On("Click", function() setFilterMode(def.mode) end)
        _filterChips[def.mode] = chip
    end

    _statusLabel = Gui:Acquire("Label", filterRow, {
        text = "|cff888888root: _G (type a name above to navigate)|r",
        variant = "muted",
    })

    -- Skeleton row.
    local skeletonRow = Gui:Acquire("Container", pane, { height = 26 })
    skeletonRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    Gui:Acquire("Label", skeletonRow, {
        text = "|cff888888Selected:|r", variant = "muted",
    })

    _skeletonBox = Gui:Acquire("EditBox", skeletonRow, {
        width       = 500,
        height      = 22,
        text        = "",
        placeholder = "click a row to load the path here (right-click for Copy menu)",
    })

    -- Per-level filter row. Live substring filter applied as the user
    -- types; clears via the "x" button. Survives lazy expansion because
    -- populateChildren rebuilds through buildOneLevel which respects
    -- _searchText.
    local filterRow2 = Gui:Acquire("Container", pane, { height = 28 })
    filterRow2.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    Gui:Acquire("Label", filterRow2, {
        text = "Filter:", variant = "muted",
    })

    _filterBox = Gui:Acquire("EditBox", filterRow2, {
        width       = 280,
        height      = 22,
        text        = "",
        placeholder = "type to narrow visible keys (case-insensitive substring)",
    })
    _filterBox.Cairn:On("TextChanged", function(_, text)
        setSearchText(text)
    end)
    _filterBox.Cairn:On("EscapePressed", function()
        if _filterBox.Cairn then _filterBox.Cairn:SetText("") end
        setSearchText("")
    end)

    _filterClearBtn = Gui:Acquire("Button", filterRow2, {
        text = "x", variant = "ghost", width = 28, height = 22,
    })
    _filterClearBtn.Cairn:On("Click", function()
        if _filterBox.Cairn then _filterBox.Cairn:SetText("") end
        setSearchText("")
    end)
    if _filterClearBtn.Cairn.SetEnabled then
        _filterClearBtn.Cairn:SetEnabled(false)
    end

    -- TreeView wrapped in ScrollFrame.
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

    -- Click loads the full path into the skeleton. The Click event
    -- carries the original node so we can hand its _path back to the
    -- skeleton box for Ctrl+C.
    _treeView.Cairn:On("Click", function(_, nodeId, node)
        showCallSkeleton(node._path or node.id)
    end)

    -- Lazy expansion: when a branch is expanded for the first time,
    -- walk its table into children + refresh so the TreeView sees them.
    -- Collapse fires Toggle too (expanded=false); we ignore that.
    _treeView.Cairn:On("Toggle", function(_, nodeId, expanded)
        if not expanded then return end
        local node = findNodeById(_currentTree, nodeId)
        if node and not node._lazyDone then
            if populateChildren(node) then
                _treeView.Cairn:Refresh()
            end
        end
    end)

    -- Sync TreeView height into ScrollFrame content height so the
    -- scrollbar reflects current expansion state.
    _treeView:HookScript("OnSizeChanged", function()
        if _treeScroll.Cairn and _treeScroll.Cairn.SetContentHeight then
            _treeScroll.Cairn:SetContentHeight(
                math.max(40, _treeView:GetHeight() or 40))
        end
    end)

    -- Right-click context menu attached at TreeView level. The TreeView
    -- doesn't expose right-click directly; we listen on the ScrollFrame
    -- and look up which row was under the cursor at click time.
    -- For v2 simplicity, route right-click off the skeleton box: it
    -- always shows the last-clicked node, so right-clicking it after
    -- a left-click is the affordance.
    -- (Full row-level right-click would need a TreeView API change.)

    pane:HookScript("OnSizeChanged", relayout)
    relayout()

    -- Initial: no tree loaded until user types something. _G has ~10k
    -- root keys; auto-loading would be slow even with MAX_BUILD_DEPTH=2.
    setFilterMode(_filterMode)
end


-- ---------------------------------------------------------------------------
-- Tab descriptor
-- ---------------------------------------------------------------------------

ns.descriptor = {
    name        = "Tables",
    title       = "Tables",
    order       = 30,
    description = "Inspect any Lua table by name; expand sub-tables inline.",

    OnTabShow = function(pane, mod)
        if not pane.Cairn._builtOnce then
            pane.Cairn._builtOnce = true
            build(pane)
        end
        relayout()
        -- Re-resolve in case the target changed under us. Cheap when
        -- _path is empty (no nav has happened yet).
        if #_path > 0 then
            _currentTable = resolvePath(_path)
        end
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

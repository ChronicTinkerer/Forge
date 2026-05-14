-- Forge_Logs: viewer for Cairn-Log entries.
--
-- v1 scope (this file):
--   * Reads Cairn-Log:GetEntries() snapshot + applies UI filters: source
--     (All / each registered logger), category (All / (uncategorized) /
--     any discovered sub-logger category), min level (TRACE..ERROR),
--     substring search on the message body.
--   * Sort mode: newest-first (default), oldest-first, or grouped by source.
--   * Each visible row pooled from a Container with timestamp + colored
--     level tag + source + message labels. Click a row to open a copy
--     popup with the full entry detail (Window-DIALOG strata).
--   * Refresh re-snapshots Cairn.Log; Clear calls Cairn.Log:Clear.
--   * All filter state persisted to db.profile so /reload preserves view.
--   * Live tail (toggle on toolbar): subscribes to Cairn.Log:OnAppend
--     and triggers a debounced refresh ~200ms after the most recent
--     append. Bursts collapse to one render at the trailing edge so a
--     chatty logger can't beat up CPU.
--
--   * Pause-when-scrolled-away: when live is on AND the user has
--     scrolled away from the live edge (top for newest sort, bottom
--     for oldest sort), refreshes are held and a chip surfaces with
--     "N new -- click to jump". Resume happens on chip click OR when
--     the user scrolls back to the live edge manually. Source-grouped
--     sort skips the feature since there's no single "newest" row.
--   * CSV export of the visible window: the Export button dumps the
--     current filtered+sorted snapshot (the same _entries list the
--     panel is showing) as RFC-4180 CSV into the copy popup. WoW has
--     no clipboard API so the round-trip is Ctrl-A + Ctrl-C inside the
--     popup's EditBox.
--   * Category sub-logger filter: a dropdown of "All",
--     "(uncategorized)", and any discovered category. Discovery walks
--     the ring buffer so new categories appear after a Refresh / tab
--     re-show without /reload. Filter is client-side because the lib's
--     GetEntries filter.category can't express "uncategorized".
--   * Tap arbitrary WoW events: /forge logstap EVENT_NAME toggles a
--     tap that pipes the event's args into Cairn.Log under
--     source="events" with category=EVENT_NAME, so the existing filter
--     dropdowns work. /forge logstaps lists active taps. Persisted to
--     db.global.activeTaps so taps survive /reload. RegisterEvent on
--     unknown event names silently no-ops (no error gating), which is
--     intentional: maintaining a known-events allowlist would be huge
--     and version-sensitive.
--
-- Out of scope for v1 (queued for v2):
--   * (nothing currently)

local ADDON, ns = ...
_G.Forge_Logs = ns


Cairn.Register("CTS_Forge_Logs", ns, {
    dbName = "Forge_LogsDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = {
        profile = {
            selectedSource   = "All",
            selectedCategory = "All",  -- "All" / "(uncategorized)" / specific name
            minLevel         = "TRACE",  -- show everything by default
            searchText       = "",
            sortMode         = "newest",
            liveTail         = false,  -- auto-refresh on Cairn.Log append
        },
        global = {
            -- Active WoW event taps. Keys are event names, value is true.
            -- Survives /reload and profile switches because this is a
            -- debugging-tool state ("what events am I watching?") rather
            -- than a per-character preference.
            activeTaps = {},
        },
    },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Logs"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local ROW_HEIGHT          = 16
local MAX_VISIBLE_ROWS    = 500    -- safety cap; tail buffer is 1000 by default

local CHIP_ROW_HEIGHT     = 22     -- reserved space for the pause-chip row
                                   -- (occupied whether visible or not so
                                   --  toggling the chip doesn't reshape layout)

local TOP_RESERVED        = 132    -- heading + hint + toolbar + chip-row + gaps
local BOTTOM_PAD          = 10
local SIDE_PAD            = 10


-- Level color palette. Cairn.Log exposes LEVEL_COLORS but those are AABBGGRR
-- hex strings; we just convert to the |cAARRGGBB form for SetText.
local LEVEL_TO_COLOR = {
    ERROR = "|cffff5050",
    WARN  = "|cffffaa00",
    INFO  = "|cffffffff",
    DEBUG = "|cffb0b0b0",
    TRACE = "|cff888888",
}

local LEVELS_ORDER = { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }


-- ---------------------------------------------------------------------------
-- Module-scope state
-- ---------------------------------------------------------------------------

local _entries        = {}      -- last filtered snapshot (display order)
local _selectedEntry  = nil

-- Sentinel used both as the dropdown option label AND the
-- db.profile.selectedCategory value when the user wants entries with
-- no category. One source of truth keeps the compare logic simple
-- (`category == UNCATEGORIZED_LABEL`).
local UNCATEGORIZED_LABEL = "(uncategorized)"

local _pane
local _sourceDropdown
local _categoryDropdown
local _levelDropdown
local _sortDropdown
local _searchBox
local _refreshBtn
local _clearBtn
local _exportBtn
local _liveBtn
local _statusLabel
local _scroll
local _scrollContent
local _rowPool        = {}

local _copyPopup
local _copyEditBox

-- Live-tail state.
--   _liveListenerID: token from Cairn.Log:OnAppend, nil when unsubscribed.
--   _renderScheduled: debounce guard. Set when a refresh is queued via
--     C_Timer.After; cleared inside that timer's callback. Bursts of
--     append events arriving while a render is queued no-op cheaply.
--   _paused: true when live tail is holding renders because the user has
--     scrolled away from the live edge (where newest entries sit).
--   _newSinceLastRender: count of entries that arrived since the last
--     time we either rendered them or cleared the chip. Drives the chip
--     copy ("N new -- click to jump").
local _liveListenerID
local _renderScheduled    = false
local _paused             = false
local _newSinceLastRender = 0
local _pauseChip          = nil
local DEBOUNCE_DELAY      = 0.2


-- Forward declarations.
local refresh
local showCopyPopup    -- defined further down; acquireRow's OnMouseUp captures it
local setLiveBtnText   -- defined below; subscribeLive/unsubscribeLive call it
local subscribeLive    -- defined below; build() + toggle handler call it
local unsubscribeLive  -- defined below; build() + toggle handler + OnTabHide call it
local exitPause        -- defined below; sort/clear/toggle handlers reset pause
local jumpToLiveEdge   -- defined below; chip click + Scroll handler use it


-- ---------------------------------------------------------------------------
-- Cairn.Log helpers
-- ---------------------------------------------------------------------------

local function libLog()
    -- Prefer LibStub-vended; fall back to the global table for forward compat.
    local L = LibStub and LibStub("Cairn-Log-1.0", true)
    if L then return L end
    return _G.Cairn_Log
end


-- ---------------------------------------------------------------------------
-- Event tap (push WoW events into Cairn.Log under source="events")
-- ---------------------------------------------------------------------------
-- A user-controlled mechanism for piping arbitrary WoW events into the log
-- stream. Useful for ad-hoc debugging without sprinkling print() calls
-- across the codebase. Taps survive /reload via db.global.activeTaps.
--
-- Args become the message: tostring()-joined with ", ". Some events
-- (notably COMBAT_LOG_EVENT_UNFILTERED post-6.0) deliver no direct args
-- and require CombatLogGetCurrentEventInfo() instead. We don't special-
-- case that; users wanting CLEU detail should write a dedicated handler.
--
-- Sub-loggers per event name are cached to avoid the table-allocation
-- churn that would happen if every event fire created a new
-- log:Category(event) instance.

local _eventTapFrame
local _subLoggers = {}     -- [event] -> cached Cairn.Log sub-logger


local function eventTapLog()
    local L = libLog()
    if not L then return nil end
    -- Idempotent: re-grabs the same logger on every call (cheap).
    return L:New("events")
end


local function getEventSubLogger(event)
    local sub = _subLoggers[event]
    if sub then return sub end
    local base = eventTapLog()
    if not base then return nil end
    sub = base:Category(event)
    _subLoggers[event] = sub
    return sub
end


-- Format event args into a single readable string. Joins with ", ";
-- emits "(no args)" when nothing was passed so empty fires still show up
-- as a clear entry rather than a blank message.
local function fmtEventArgs(...)
    local n = select("#", ...)
    if n == 0 then return "(no args)" end
    local parts = {}
    for i = 1, n do
        parts[i] = tostring(select(i, ...))
    end
    return table.concat(parts, ", ")
end


local function onTappedEvent(_, event, ...)
    local logger = getEventSubLogger(event)
    if not logger then return end
    -- Single-arg call path (no string.format) -- the formatted message
    -- might contain % from item links / spell names etc., which would
    -- otherwise blow up the fmt pass.
    logger:Info(fmtEventArgs(...))
end


local function ensureTapFrame()
    if _eventTapFrame then return _eventTapFrame end
    _eventTapFrame = CreateFrame("Frame")
    _eventTapFrame:SetScript("OnEvent", onTappedEvent)
    return _eventTapFrame
end


-- Active-taps storage. Keys are event names. db.global guarantees the
-- table exists by the time these helpers run (Cairn.Register applies
-- dbDefaults before OnInit).
local function activeTapsTable()
    return db and db.global and db.global.activeTaps
end


local function tapEvent(event)
    if type(event) ~= "string" or event == "" then return false end
    local taps = activeTapsTable()
    if not taps then return false end
    if taps[event] then return false end  -- already tapping
    local f = ensureTapFrame()
    -- RegisterEvent on unknown events silently no-ops in current WoW;
    -- if the user typoes the name, the entry will simply never fire.
    -- Tradeoff vs gating with a known-events allowlist (would be huge
    -- and version-sensitive).
    f:RegisterEvent(event)
    taps[event] = true
    return true
end


local function untapEvent(event)
    if type(event) ~= "string" or event == "" then return false end
    local taps = activeTapsTable()
    if not taps then return false end
    if not taps[event] then return false end
    if _eventTapFrame then _eventTapFrame:UnregisterEvent(event) end
    taps[event] = nil
    return true
end


local function listActiveTaps()
    local taps = activeTapsTable()
    local out = {}
    if not taps then return out end
    for event in pairs(taps) do
        out[#out + 1] = event
    end
    table.sort(out)
    return out
end


-- Restore the persisted set of taps on addon load. Called from
-- addon:OnInit AFTER Cairn.Register has populated db.global from the
-- defaults / saved variables.
local function restoreActiveTaps()
    local taps = activeTapsTable()
    if not taps then return end
    local f = ensureTapFrame()
    for event in pairs(taps) do
        if type(event) == "string" and event ~= "" then
            f:RegisterEvent(event)
        end
    end
end


-- Collect known source names: every registered logger + a synthetic
-- "All". Also keeps the currently-selected source pinned even if its
-- logger is gone (matches getCategories' selection-preservation pattern).
local function getSources()
    local out, seen = { "All" }, { ["All"] = true }

    local selected = db and db.profile.selectedSource
    if selected and not seen[selected] then
        seen[selected] = true
        out[#out + 1] = selected
    end

    local L = libLog()
    if L and L.loggers then
        for name in pairs(L.loggers) do
            if not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
    end
    table.sort(out, function(a, b)
        if a == "All" then return true end
        if b == "All" then return false end
        return a:lower() < b:lower()
    end)
    return out
end


-- Collect category names by walking the ring buffer. Categories are
-- discovered dynamically (Cairn-Log doesn't maintain a registry like it
-- does for sources) so a category appears in the dropdown the moment
-- any entry has used it. "All" and "(uncategorized)" are always present
-- regardless of buffer contents -- both are valid filter intents even
-- against an empty / partially-populated buffer.
--
-- Also always preserves the user's currently-selected category in the
-- list, even if no live entries match it -- otherwise the Dropdown's
-- SetOptions would clear the selection when entries with that category
-- roll off the ring. "0 visible" feedback is better than silently
-- resetting the user's filter.
local function getCategories()
    local out  = { "All", UNCATEGORIZED_LABEL }
    local seen = { ["All"] = true, [UNCATEGORIZED_LABEL] = true }

    local selected = db and db.profile.selectedCategory
    if selected and not seen[selected] then
        seen[selected] = true
        out[#out + 1] = selected
    end

    local L = libLog()
    if L and L.entries then
        -- Use pairs over the ring storage (sparse if the buffer hasn't
        -- wrapped yet) rather than walking _count-bounded indices --
        -- works correctly whether the ring is fresh, partial, or full.
        for _, e in pairs(L.entries) do
            if e then
                local c = e.category
                if c and c ~= "" and not seen[c] then
                    seen[c] = true
                    out[#out + 1] = c
                end
            end
        end
    end
    table.sort(out, function(a, b)
        -- Pinned order: All > (uncategorized) > rest alphabetically.
        if a == "All" then return true end
        if b == "All" then return false end
        if a == UNCATEGORIZED_LABEL then return true end
        if b == UNCATEGORIZED_LABEL then return false end
        return a:lower() < b:lower()
    end)
    return out
end


-- Format a timestamp as HH:MM:SS. Cairn.Log entries use time() values.
local function fmtTime(ts)
    if not ts then return "??:??:??" end
    if date then return date("%H:%M:%S", ts) end
    return tostring(ts)
end


local function fmtLevel(level)
    local color = LEVEL_TO_COLOR[level] or "|cffaaaaaa"
    return ("%s%-5s|r"):format(color, level or "?")
end


-- ---------------------------------------------------------------------------
-- Entry collection + filter + sort
-- ---------------------------------------------------------------------------

local function collectEntries()
    local L = libLog()
    if not (L and L.GetEntries) then return {} end

    local source     = db and db.profile.selectedSource or "All"
    local minLevel   = db and db.profile.minLevel       or "TRACE"
    local searchText = (db and db.profile.searchText    or ""):lower()

    -- GetEntries filter handles source + minLevel server-side; we apply
    -- search client-side because GetEntries doesn't expose a message
    -- substring filter.
    local filter = { level = minLevel, limit = MAX_VISIBLE_ROWS }
    if source ~= "All" then filter.source = source end

    local rows = L:GetEntries(filter) or {}

    -- Category filter: applied client-side because GetEntries's
    -- filter.category is an exact-match-only string (it can't express
    -- "(uncategorized)"). The cost is one extra pass over the already-
    -- source/level-narrowed result set, which is bounded by
    -- MAX_VISIBLE_ROWS so it stays cheap.
    local category = db and db.profile.selectedCategory or "All"
    if category ~= "All" then
        local kept = {}
        local wantNil = (category == UNCATEGORIZED_LABEL)
        for _, e in ipairs(rows) do
            local match
            if wantNil then
                match = (e.category == nil or e.category == "")
            else
                match = (e.category == category)
            end
            if match then kept[#kept + 1] = e end
        end
        rows = kept
    end

    if searchText ~= "" then
        local kept = {}
        for _, e in ipairs(rows) do
            if e.message and e.message:lower():find(searchText, 1, true) then
                kept[#kept + 1] = e
            end
        end
        rows = kept
    end

    -- GetEntries returns newest-first by default (it walks the ring from
    -- head-1 backwards). Re-sort if the user wants oldest-first or grouped.
    local mode = db and db.profile.sortMode or "newest"
    if mode == "oldest" then
        local n = #rows
        for i = 1, math.floor(n / 2) do
            rows[i], rows[n - i + 1] = rows[n - i + 1], rows[i]
        end
    elseif mode == "source" then
        table.sort(rows, function(a, b)
            local sa, sb = a.source or "", b.source or ""
            if sa ~= sb then return sa < sb end
            return (a.timestamp or 0) > (b.timestamp or 0)
        end)
    end

    return rows
end


-- ---------------------------------------------------------------------------
-- Row pool
-- ---------------------------------------------------------------------------

local function acquireRow(Gui, idx)
    local existing = _rowPool[idx]
    if existing and existing.container then
        existing.container:Show()
        return existing
    end

    local row = {}
    row.container = Gui:Acquire("Container", _scrollContent, { height = ROW_HEIGHT })
    row.container:EnableMouse(true)

    row.timeLabel = Gui:Acquire("Label", row.container, { text = "", variant = "muted" })
    row.timeLabel.Cairn:SetLayoutManual(true)
    row.timeLabel:ClearAllPoints()
    row.timeLabel:SetPoint("LEFT", row.container, "LEFT", 4, 0)
    row.timeLabel:SetWidth(70)

    row.levelLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.levelLabel.Cairn:SetLayoutManual(true)
    row.levelLabel:ClearAllPoints()
    row.levelLabel:SetPoint("LEFT", row.container, "LEFT", 76, 0)
    row.levelLabel:SetWidth(50)

    row.msgLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.msgLabel.Cairn:SetLayoutManual(true)
    row.msgLabel:ClearAllPoints()
    row.msgLabel:SetPoint("LEFT",  row.container, "LEFT",  130, 0)
    row.msgLabel:SetPoint("RIGHT", row.container, "RIGHT", -22, 0)

    -- Click loads entry into the copy popup. showCopyPopup resolves via
    -- the forward-declared upvalue at file top.
    row.container:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        if row._entry then
            _selectedEntry = row._entry
            showCopyPopup()
        end
    end)

    _rowPool[idx] = row
    return row
end


local function hideExtraRows(fromIndex)
    for i = fromIndex, #_rowPool do
        if _rowPool[i] and _rowPool[i].container then
            _rowPool[i].container:Hide()
        end
    end
end


-- ---------------------------------------------------------------------------
-- Copy popup (entry detail + CSV export)
-- ---------------------------------------------------------------------------
-- The same popup serves both flows: clicking a row dumps the entry's full
-- detail, clicking Export dumps the visible window as CSV. Title swaps
-- on each show via Cairn-Gui Window:SetTitle.

local function buildEntryDetail(e)
    if not e then return "(no entry selected)" end
    local lines = {
        ("timestamp: %s (raw: %s)"):format(fmtTime(e.timestamp), tostring(e.timestamp or "?")),
        ("level:     %s"):format(tostring(e.level or "?")),
        ("source:    %s"):format(tostring(e.source or "?")),
    }
    if e.category and e.category ~= "" then
        lines[#lines + 1] = ("category:  %s"):format(tostring(e.category))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = tostring(e.message or "(no message)")
    return table.concat(lines, "\n")
end


-- CSV escape per RFC 4180: a field is quoted whenever it contains a
-- comma, a double-quote, or a newline; quotes inside are doubled.
-- Most log fields don't need quoting; messages often do.
local function csvEscape(value)
    local s = tostring(value or "")
    if s:find('[,"\n\r]') then
        s = '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end


-- Render the current entry list as CSV. Timestamp uses a sortable
-- spreadsheet-friendly form ("YYYY-MM-DD HH:MM:SS") rather than the
-- HH:MM:SS clock copy used in the panel rows, so the export round-trips
-- cleanly when opened in Excel / a data-frame.
local function entriesToCSV(entries)
    local lines = { "timestamp,source,category,level,message" }
    if not entries then return table.concat(lines, "\n") end
    for _, e in ipairs(entries) do
        local ts
        if e.timestamp and date then
            ts = date("%Y-%m-%d %H:%M:%S", e.timestamp)
        else
            ts = tostring(e.timestamp or "")
        end
        lines[#lines + 1] = table.concat({
            csvEscape(ts),
            csvEscape(e.source),
            csvEscape(e.category),
            csvEscape(e.level),
            csvEscape(e.message),
        }, ",")
    end
    return table.concat(lines, "\n")
end


local function buildCopyPopup()
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local win = Gui:Acquire("Window", UIParent, {
        title    = "Log entry detail",
        width    = 560,
        height   = 320,
        strata   = "DIALOG",
        closable = true,
        movable  = true,
    })
    win:Hide()
    win:ClearAllPoints()
    win:SetPoint("CENTER")

    local content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 8 })

    Gui:Acquire("Label", content, {
        text    = "Ctrl-A to select, Ctrl-C to copy.",
        variant = "muted",
    })

    local eb = Gui:Acquire("EditBox", content, {
        width     = 540,
        height    = 230,
        multiline = true,
        text      = "",
    })

    local closeBtn = Gui:Acquire("Button", content, {
        text = "Close", variant = "ghost", width = 80, height = 22,
    })
    closeBtn.Cairn:On("Click", function() win:Hide() end)
    win.Cairn:On("Close", function() win:Hide() end)

    _copyPopup   = win
    _copyEditBox = eb
end


-- Assigned (not `local function`) so the forward-declared upvalue at file
-- top resolves correctly inside acquireRow's earlier-defined OnMouseUp.
--
-- Args (both optional, no-arg call preserves the original row-detail flow):
--   text  - string to load into the popup's EditBox. Defaults to the
--           selected entry's detail rendering (preserves backward
--           compat with ns.UI.ShowCopyPopup and row-click callers).
--   title - titlebar text for this show. Defaults to "Log entry detail"
--           when text was also nil; otherwise stays as whatever it was
--           last set to (callers passing text should pass title too).
showCopyPopup = function(text, title)
    if not _copyPopup then buildCopyPopup() end
    if not _copyPopup then return end
    if text == nil then
        text  = buildEntryDetail(_selectedEntry)
        title = title or "Log entry detail"
    end
    if title and _copyPopup.Cairn and _copyPopup.Cairn.SetTitle then
        _copyPopup.Cairn:SetTitle(title)
    end
    if _copyEditBox and _copyEditBox.Cairn then
        _copyEditBox.Cairn:SetText(text or "")
    end
    _copyPopup:Show()
    _copyPopup:Raise()
end


-- ---------------------------------------------------------------------------
-- Refresh + render
-- ---------------------------------------------------------------------------

refresh = function()
    if not _scrollContent then return end
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    _entries = collectEntries()

    if _statusLabel and _statusLabel.Cairn then
        local L = libLog()
        local total = (L and L._count) or 0
        _statusLabel.Cairn:SetText(("|cff888888%d visible / %d total|r")
            :format(#_entries, total))
    end

    for i, e in ipairs(_entries) do
        local row = acquireRow(Gui, i)
        row._entry = e
        row.timeLabel.Cairn:SetText("|cff888888" .. fmtTime(e.timestamp) .. "|r")
        row.levelLabel.Cairn:SetText(fmtLevel(e.level))
        local msg = tostring(e.message or "(empty)")
        -- Source prefix renders as orange "Source:" or, when a sub-logger
        -- category is present, "Source/category:" with the category
        -- rendered grey. Concat (not format) to avoid the hex-digit-into-
        -- text footgun: a literal like "|cffaabbccfoo|r" can swallow chars.
        local prefix
        if e.source then
            if e.category and e.category ~= "" then
                prefix = "|cffd87f3a" .. e.source .. "|r"
                      .. "|cff888888/" .. e.category .. "|r"
                      .. "|cffd87f3a:|r "
            else
                prefix = "|cffd87f3a" .. e.source .. ":|r "
            end
        else
            prefix = ""
        end
        row.msgLabel.Cairn:SetText(prefix .. msg)
    end
    hideExtraRows(#_entries + 1)

    -- ScrollFrame content height = visible rows * row height + small pad.
    if _scroll and _scroll.Cairn and _scroll.Cairn.SetContentHeight then
        _scroll.Cairn:SetContentHeight(
            math.max(40, #_entries * (ROW_HEIGHT + 2) + 4))
    end
end


-- ---------------------------------------------------------------------------
-- Relayout
-- ---------------------------------------------------------------------------

local function relayout()
    if not (_pane and _scroll) then return end
    _scroll:ClearAllPoints()
    _scroll:SetPoint("TOPLEFT",     _pane, "TOPLEFT",      SIDE_PAD, -TOP_RESERVED)
    _scroll:SetPoint("BOTTOMRIGHT", _pane, "BOTTOMRIGHT", -SIDE_PAD,  BOTTOM_PAD)
end


-- ---------------------------------------------------------------------------
-- Dropdown helpers
-- ---------------------------------------------------------------------------
-- Cairn-Gui Dropdown expects { values = { {value, label}, ... } }. We
-- rebuild the source dropdown each time refresh() is called so newly
-- created loggers appear without a /reload.

local function makeChoices(arr)
    local out = {}
    for _, v in ipairs(arr) do
        out[#out + 1] = { value = v, label = v }
    end
    return out
end


-- Compare two ordered string lists for value-equality. Used as a guard
-- in refresh*Choices so a live-tail tick that didn't actually discover
-- new options is free of layout work (Dropdown.SetOptions invalidates
-- parent layout unconditionally, which would jiggle the toolbar on
-- every refresh otherwise).
local function listsEqual(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end


-- Extract current option values from a dropdown's options table for
-- comparison. Dropdown options are {value, label} tables; values are
-- what we sort/dedup on so that's what we compare.
local function dropdownValues(dd)
    local out = {}
    if not (dd and dd.Cairn and dd.Cairn.GetOptions) then return out end
    local opts = dd.Cairn:GetOptions() or {}
    for i, o in ipairs(opts) do
        out[i] = o.value
    end
    return out
end


local function refreshSourceChoices()
    if not (_sourceDropdown and _sourceDropdown.Cairn) then return end
    if not _sourceDropdown.Cairn.SetOptions then return end
    local fresh = getSources()
    if listsEqual(dropdownValues(_sourceDropdown), fresh) then return end
    _sourceDropdown.Cairn:SetOptions(makeChoices(fresh))
end


-- Mirror of refreshSourceChoices for the category dropdown. Categories
-- are discovered by walking the ring buffer, so this needs to run
-- whenever new entries arrive (live tail) in addition to the explicit
-- Refresh / OnTabShow paths.
local function refreshCategoryChoices()
    if not (_categoryDropdown and _categoryDropdown.Cairn) then return end
    if not _categoryDropdown.Cairn.SetOptions then return end
    local fresh = getCategories()
    if listsEqual(dropdownValues(_categoryDropdown), fresh) then return end
    _categoryDropdown.Cairn:SetOptions(makeChoices(fresh))
end


-- ---------------------------------------------------------------------------
-- Live tail
-- ---------------------------------------------------------------------------
-- Two-layer flow:
--
-- 1. DEBOUNCE. The append listener fires inside Cairn.Log's pushEntry,
--    once per logged message. Rendering on every append would burn CPU
--    on a chatty source. We debounce: the first append schedules a
--    C_Timer.After(DEBOUNCE_DELAY); subsequent appends while that timer
--    is pending no-op. Net effect: K appends within DEBOUNCE_DELAY render
--    once at the trailing edge.
--
-- 2. PAUSE-WHEN-SCROLLED-AWAY. Live updates while the user is reading
--    older entries push their place around (newest sort: rows shift
--    down; oldest sort: max-scroll grows beyond their position). Both
--    interrupt reading. We detect "user at the live edge" (top for
--    newest sort, bottom for oldest sort; the source-grouped sort has
--    no single live edge so the feature is skipped there) and hold the
--    refresh when they're not. A chip surfaces ("N new -- click to
--    jump") so they know updates are pending and can resume on demand.
--    When they scroll back to the live edge manually, the Scroll
--    handler also auto-resumes.

local function sortSupportsPause()
    local mode = db and db.profile.sortMode or "newest"
    -- "source" groups by source then by time within each source; the
    -- "newest entry overall" position depends on which source it belongs
    -- to. No single live edge -> skip pause behavior; just render.
    return mode == "newest" or mode == "oldest"
end


local function isAtLiveEdge()
    if not (_scroll and _scroll.Cairn) then return true end
    local mode = db and db.profile.sortMode or "newest"
    local scroll = _scroll.Cairn:GetVerticalScroll() or 0
    if mode == "newest" then
        -- Live edge is the top; small tolerance for sub-pixel rounding.
        return scroll <= 2
    elseif mode == "oldest" then
        -- Live edge is the bottom: viewport-aligned max scroll.
        local h = _scroll.Cairn:GetContentHeight() or 0
        local viewport = _scroll:GetHeight() or 0
        local maxScroll = math.max(0, h - viewport)
        return scroll >= maxScroll - 2
    end
    return true   -- source-grouped sort: treat as always-at-edge
end


local function updatePauseChip()
    if not (_pauseChip and _pauseChip.Cairn) then return end
    if _paused and _newSinceLastRender > 0 then
        _pauseChip.Cairn:SetText(
            ("%d new -- click to jump"):format(_newSinceLastRender))
        _pauseChip:Show()
    else
        _pauseChip:Hide()
    end
end


-- After a "follow the live edge" refresh in oldest-sort mode, the newly-
-- added entries pushed the bottom further down, so scroll(=oldMax) is
-- no longer at the live edge. Restore it. Newest sort needs no help --
-- scroll=0 stays at top regardless.
local function pinToLiveEdgeAfterRefresh()
    if not (_scroll and _scroll.Cairn) then return end
    local mode = db and db.profile.sortMode or "newest"
    if mode == "oldest" then
        _scroll.Cairn:ScrollToBottom()
    end
end


exitPause = function()
    _paused = false
    _newSinceLastRender = 0
    updatePauseChip()
end


jumpToLiveEdge = function()
    if not (_scroll and _scroll.Cairn) then return end
    local mode = db and db.profile.sortMode or "newest"
    -- Order matters: clear pause state FIRST so the Scroll handler that
    -- fires from ScrollToTop/Bottom sees _paused=false and skips its
    -- own resume path (would otherwise refresh() twice).
    _paused = false
    _newSinceLastRender = 0
    if mode == "oldest" then
        _scroll.Cairn:ScrollToBottom()
    else
        _scroll.Cairn:ScrollToTop()
    end
    pcall(refresh)
    pinToLiveEdgeAfterRefresh()
    updatePauseChip()
end


local function onAppendDebounced(_entry)
    -- Count every append eagerly (cheap; one integer add). The debounced
    -- timer reads this counter when it fires to decide chip copy and
    -- whether to render.
    _newSinceLastRender = _newSinceLastRender + 1

    if _renderScheduled then return end
    _renderScheduled = true
    C_Timer.After(DEBOUNCE_DELAY, function()
        -- Pause path: holding refresh, just update the chip.
        if sortSupportsPause() and not isAtLiveEdge() then
            _paused = true
            updatePauseChip()
            _renderScheduled = false
            return
        end

        -- Render path: at the live edge (or sort mode skips pause).
        -- Clear counter + pause state BEFORE refresh so a Scroll event
        -- from content-height-change can't re-enter the resume branch.
        _newSinceLastRender = 0
        _paused = false
        -- Re-discover dropdown options before rendering. The guards in
        -- refreshSourceChoices / refreshCategoryChoices make this free
        -- when nothing changed, so we pay the layout cost only when a
        -- new source or category actually appeared in the buffer.
        refreshSourceChoices()
        refreshCategoryChoices()
        pcall(refresh)
        pinToLiveEdgeAfterRefresh()
        updatePauseChip()
        _renderScheduled = false
    end)
end


subscribeLive = function()
    if _liveListenerID then return end  -- already subscribed
    local L = libLog()
    if not (L and L.OnAppend) then return end
    _liveListenerID = L:OnAppend(onAppendDebounced)
    setLiveBtnText()
end


unsubscribeLive = function()
    if not _liveListenerID then return end
    local L = libLog()
    if L and L.OffAppend then L:OffAppend(_liveListenerID) end
    _liveListenerID = nil
    -- Clear pause state on unsubscribe so the chip doesn't stay visible
    -- after Live is turned off. A queued debounce timer (if any) is
    -- harmless to let fire: with no listener it can't be re-armed, and
    -- its render either no-ops or shows current state.
    exitPause()
    setLiveBtnText()
end


setLiveBtnText = function()
    if not (_liveBtn and _liveBtn.Cairn) then return end
    local on = db and db.profile.liveTail
    _liveBtn.Cairn:SetText(on and "Live: on" or "Live: off")
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

    Gui:Acquire("Label", pane, { text = "Logs", variant = "heading" })

    Gui:Acquire("Label", pane, {
        text    = "|cff888888Live view of Cairn.Log entries. "
                  .. "Filter by source / min level / substring. Click a "
                  .. "row to copy its full detail.|r",
        variant = "muted",
    })

    -- Toolbar: source, category, level, sort, search, refresh, clear, export, live, status.
    local toolbar = Gui:Acquire("Container", pane, { height = 28 })
    toolbar.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    -- Filter dropdowns use Cairn-Gui Dropdown's opts.label field-label
    -- (Standard MINOR=17+) so each control self-documents inline. No
    -- separate Label widgets needed.
    _sourceDropdown = Gui:Acquire("Dropdown", toolbar, {
        label    = "Source",
        width    = 170,
        height   = 22,
        options  = makeChoices(getSources()),
        selected = db.profile.selectedSource,
    })
    _sourceDropdown.Cairn:On("Changed", function(_, val)
        db.profile.selectedSource = val
        refresh()
    end)

    -- Category filter. Options are recomputed from the ring buffer so
    -- new categories appear without a /reload (when the user clicks
    -- Refresh or re-shows the tab). Width fits typical category names
    -- ("net", "render", "data") plus the "(uncategorized)" label.
    _categoryDropdown = Gui:Acquire("Dropdown", toolbar, {
        label    = "Category",
        width    = 190,
        height   = 22,
        options  = makeChoices(getCategories()),
        selected = db.profile.selectedCategory,
    })
    _categoryDropdown.Cairn:On("Changed", function(_, val)
        db.profile.selectedCategory = val
        refresh()
    end)

    _levelDropdown = Gui:Acquire("Dropdown", toolbar, {
        label    = "Level",
        width    = 130,
        height   = 22,
        options  = makeChoices(LEVELS_ORDER),
        selected = db.profile.minLevel,
    })
    _levelDropdown.Cairn:On("Changed", function(_, val)
        db.profile.minLevel = val
        refresh()
    end)

    _sortDropdown = Gui:Acquire("Dropdown", toolbar, {
        label    = "Sort",
        width    = 140,
        height   = 22,
        options  = makeChoices({ "newest", "oldest", "source" }),
        selected = db.profile.sortMode,
    })
    _sortDropdown.Cairn:On("Changed", function(_, val)
        db.profile.sortMode = val
        -- Sort change re-locates the "live edge" (top vs bottom). Clear
        -- the pause counter so the user sees a fresh state in the new
        -- ordering rather than a stale "12 new" chip referring to entries
        -- that may already be visible in the new sort.
        exitPause()
        refresh()
        pinToLiveEdgeAfterRefresh()
    end)

    _searchBox = Gui:Acquire("EditBox", toolbar, {
        width       = 200,
        height      = 22,
        text        = db.profile.searchText or "",
        placeholder = "Filter message text...",
    })
    _searchBox.Cairn:On("TextChanged", function(_, text)
        db.profile.searchText = text or ""
        refresh()
    end)

    _refreshBtn = Gui:Acquire("Button", toolbar, {
        text = "Refresh", variant = "ghost", width = 80, height = 22,
    })
    _refreshBtn.Cairn:On("Click", function()
        refreshSourceChoices()
        refreshCategoryChoices()
        -- A manual Refresh click is an explicit "give me fresh data"
        -- request -- drop any pending pause state so a stale "N new"
        -- chip doesn't linger after the user has seen the refresh.
        exitPause()
        refresh()
    end)

    _clearBtn = Gui:Acquire("Button", toolbar, {
        text = "Clear", variant = "ghost", width = 70, height = 22,
    })
    _clearBtn.Cairn:On("Click", function()
        local L = libLog()
        if L and L.Clear then L:Clear() end
        -- Clear wipes the buffer; any "N new" tally refers to entries
        -- that no longer exist. Drop the pause state.
        exitPause()
        refresh()
    end)

    -- Export: dumps the current visible window (post-filter, post-sort)
    -- as CSV into the copy popup. WoW has no clipboard API so this is the
    -- standard "select-all + Ctrl-C" round-trip. We capture _entries
    -- (the snapshot the user is looking at) rather than re-fetching, so
    -- "Export what I see" matches what's on screen even mid-pause.
    _exportBtn = Gui:Acquire("Button", toolbar, {
        text = "Export", variant = "ghost", width = 70, height = 22,
    })
    _exportBtn.Cairn:On("Click", function()
        showCopyPopup(entriesToCSV(_entries), "CSV export")
    end)

    -- Live tail toggle. Click flips db.profile.liveTail, then
    -- subscribes or unsubscribes accordingly. The actual subscribe call
    -- only succeeds when the tab is built+shown, so we also (un)subscribe
    -- on tab show/hide further down to keep listener count == 1 only
    -- when the user is actually looking at the panel.
    _liveBtn = Gui:Acquire("Button", toolbar, {
        text = "Live: off", variant = "ghost", width = 80, height = 22,
    })
    _liveBtn.Cairn:On("Click", function()
        db.profile.liveTail = not db.profile.liveTail
        if db.profile.liveTail then
            subscribeLive()
            -- Immediate refresh on enable so the user sees current state
            -- without having to wait for the next append.
            refresh()
        else
            unsubscribeLive()
        end
    end)

    _statusLabel = Gui:Acquire("Label", toolbar, {
        text = "|cff888888loading...|r", variant = "muted",
    })

    -- Chip row: fixed-height container sitting between the toolbar and
    -- the scroll viewport. The button inside it is shown only while the
    -- live tail is paused (user scrolled off the live edge with new
    -- entries pending). The row claims CHIP_ROW_HEIGHT whether visible
    -- or not so the layout doesn't jiggle on show/hide.
    local chipRow = Gui:Acquire("Container", pane, { height = CHIP_ROW_HEIGHT })

    _pauseChip = Gui:Acquire("Button", chipRow, {
        text    = "0 new -- click to jump",
        variant = "ghost",
        width   = 220,
        height  = 20,
    })
    _pauseChip.Cairn:SetLayoutManual(true)
    _pauseChip:ClearAllPoints()
    _pauseChip:SetPoint("CENTER", chipRow, "CENTER", 0, 0)
    _pauseChip:Hide()
    _pauseChip.Cairn:On("Click", function() jumpToLiveEdge() end)

    -- ScrollFrame holds the rows. Manual-anchored to fill remaining space.
    _scroll = Gui:Acquire("ScrollFrame", pane, {
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
    })
    _scroll.Cairn:SetLayoutManual(true)

    -- Auto-resume the live tail when the user scrolls back to the live
    -- edge manually (without clicking the chip). The guard order
    -- (_paused first) keeps the handler a one-line skip in the common
    -- case where pause isn't in effect. We also re-check liveTail in
    -- case the user toggled it off while paused (unsubscribeLive sets
    -- _paused=false via exitPause, but defending against ordering
    -- changes elsewhere is cheap).
    _scroll.Cairn:On("Scroll", function()
        if not _paused then return end
        if not (db and db.profile.liveTail) then return end
        if isAtLiveEdge() then
            _newSinceLastRender = 0
            _paused = false
            pcall(refresh)
            pinToLiveEdgeAfterRefresh()
            updatePauseChip()
        end
    end)

    _scrollContent = _scroll.Cairn:GetContent()
    _scrollContent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 2, padding = 4 })

    pane:HookScript("OnSizeChanged", relayout)
    relayout()

    refresh()
end


-- Expose for external callers (Forge.Slash subcommands etc.).
ns.UI = {
    ShowCopyPopup   = function() showCopyPopup() end,
    Refresh         = function() refresh() end,
    SubscribeLive   = function() subscribeLive() end,
    UnsubscribeLive = function() unsubscribeLive() end,
    -- Returns the current filtered+sorted snapshot as RFC-4180 CSV.
    -- Useful for slash commands or other Forge sub-addons that want
    -- the CSV string without opening the panel.
    ExportCSV       = function() return entriesToCSV(_entries) end,
    -- Event-tap helpers. Each accepts/returns the same shapes as the
    -- internal helpers (string event names, plain table of names).
    TapEvent        = function(event) return tapEvent(event) end,
    UntapEvent      = function(event) return untapEvent(event) end,
    ListActiveTaps  = function() return listActiveTaps() end,
}


-- ---------------------------------------------------------------------------
-- Tab descriptor
-- ---------------------------------------------------------------------------

ns.descriptor = {
    name        = "Logs",
    title       = "Logs",
    order       = 60,
    description = "Cairn.Log entry viewer with source / level / search filters.",

    OnTabShow = function(pane, mod)
        if not pane.Cairn._builtOnce then
            pane.Cairn._builtOnce = true
            build(pane)
        end
        relayout()
        refreshSourceChoices()
        refreshCategoryChoices()
        refresh()
        -- Re-subscribe to live tail if user had it on. We always
        -- unsubscribe on hide (below), so we re-subscribe on every show
        -- when liveTail is true. Cost of churning the listener entry is
        -- trivial; benefit is zero listener work when the tab isn't open.
        setLiveBtnText()
        if db and db.profile.liveTail then
            subscribeLive()
        end
    end,

    OnTabHide = function(pane, mod)
        -- Always unsubscribe on hide. Live-tail callbacks doing
        -- refresh() against a hidden panel would be wasted work — the
        -- user can't see it and we'd just be paying the cost of
        -- GetEntries + label SetText for nothing.
        unsubscribeLive()
    end,
}


-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function addon:OnInit()
    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end

    -- Restore any persisted event taps. Runs after Cairn.Register has
    -- bound db.global to saved variables, so taps survive /reload.
    restoreActiveTaps()

    if Forge and Forge.Slash and Forge.Slash.Sub then
        Forge.Slash:Sub("logsclear", function()
            local L = libLog()
            if L and L.Clear then L:Clear() end
            refresh()
        end, "clear the Cairn.Log ring buffer")

        -- /forge logstap EVENT_NAME -- toggles a WoW event tap. New
        -- entries land in Cairn.Log under source="events" with
        -- category=EVENT_NAME so the existing filter dropdowns work.
        Forge.Slash:Sub("logstap", function(arg)
            local event = arg and arg:match("^%s*(%S+)%s*$")
            if not event or event == "" then
                print("|cff80c0ff[Forge_Logs]|r usage: /forge logstap EVENT_NAME")
                return
            end
            if activeTapsTable() and activeTapsTable()[event] then
                untapEvent(event)
                print(("|cff80c0ff[Forge_Logs]|r untapped %s"):format(event))
            else
                tapEvent(event)
                print(("|cff80c0ff[Forge_Logs]|r tapping %s"):format(event))
            end
        end, "toggle a WoW event tap (entries land under source=events)")

        -- /forge logstaps -- list currently active event taps.
        Forge.Slash:Sub("logstaps", function()
            local taps = listActiveTaps()
            if #taps == 0 then
                print("|cff80c0ff[Forge_Logs]|r no active event taps")
                return
            end
            print(("|cff80c0ff[Forge_Logs]|r %d active tap(s):"):format(#taps))
            for _, e in ipairs(taps) do
                print("  " .. e)
            end
        end, "list active Forge_Logs event taps")
    end
end

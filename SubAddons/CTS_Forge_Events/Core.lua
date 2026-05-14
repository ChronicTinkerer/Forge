-- Forge_Events: live event-rate leaderboard + multi-event tail args log.
--
-- v2 scope (this file):
--   * Top half: top-N events by count over the last WINDOW_SECONDS,
--     sorted descending, with a per-row bar visualizing rate.
--   * Bottom half: multi-event tail. Clicking a leaderboard row toggles
--     that event's membership in the tail set; the log interleaves
--     entries from all tailed events with stable per-event color coding.
--   * Untail (toggle off) purges that event's entries from the log so
--     the visible log only reflects what's actively being captured.
--   * "Clear tails" wipes all tails at once; Pause / Reset unchanged.
--
-- Layout:
--   * Heading / hint / toolbar / "Leaderboard" label are Stack-laid at
--     the top of the pane.
--   * The two ScrollFrames and the tail header are SetLayoutManual'd
--     and anchored to the pane edges directly. A relayout() function
--     hooked to pane OnSizeChanged splits the remaining vertical space
--     50/50 between leaderboard and tail. Fixed heights here would let
--     the tail panel bust through the bottom of the Forge window.
--   * Row content right-anchors leave 22px of margin so labels and bars
--     don't kiss the scrollbar gutter.
--
-- Sampling strategy:
--   * One hidden Frame registers ALL events via RegisterAllEvents().
--     The OnEvent hot path increments an integer in _currentSecond[name]
--     and, only when name is in _tailedEvents, allocates a small args table
--     for the log. Lazy formatting at draw time keeps the hot path cheap
--     during combat (which can fire 1k+ events/sec).
--   * A 1s ticker advances the ring buffer (push _currentSecond into the
--     head slot, reset the accumulator). Ticker runs always, even when
--     the tab is hidden, so counts stay accurate across tab switches.
--   * UI refresh is gated on _isTabVisible so a hidden tab uses no CPU
--     past the cheap counter-increment.
--
-- Top-N selection:
--   * Computed every tick by summing each event's ring across all slots.
--     For ~500 distinct event names per session that's a few thousand
--     adds per second; trivial.

local ADDON, ns = ...
_G.Forge_Events = ns


Cairn.Register("CTS_Forge_Events", ns, {
    dbName = "Forge_EventsDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = { profile = {}, global = {} },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Events"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local SAMPLE_INTERVAL    = 1     -- seconds per leaderboard tick
local WINDOW_SECONDS     = 60    -- ring buffer length per event
local TOP_N              = 15    -- visible leaderboard rows
local TAIL_MAX           = 50    -- max entries in the tail log
local LEADER_ROW_HEIGHT  = 18
local TAIL_ROW_HEIGHT    = 16

-- Layout offsets used by relayout(). These approximate the height of the
-- Stack-laid top section (heading + hint + toolbar + leaderboard label +
-- gaps) and the manually-anchored tail header. If the top section grows,
-- bump TOP_RESERVED rather than letting the leaderboard creep upward.
local TOP_RESERVED       = 110   -- px from pane top down to leaderboard scroll start
local TAIL_HEADER_H      = 28
local BOTTOM_PAD         = 10
local SIDE_PAD           = 10
local SECTION_GAP        = 6
local ROW_RIGHT_MARGIN   = 22    -- px of right padding inside rows (scrollbar gutter + a bit)


-- ---------------------------------------------------------------------------
-- Module-scope state
-- ---------------------------------------------------------------------------

local _ticker
local _eventCounts   = {}   -- name -> { v1..vWINDOW_SECONDS } ring of per-second counts
local _currentSecond = {}   -- accumulator for the in-progress second; flushed by tick()
local _ringHead      = 1    -- next write slot, 1..WINDOW_SECONDS
local _ringCount     = 0    -- valid samples (capped at WINDOW_SECONDS)
local _tailedEvents  = {}   -- set: { [eventName] = true, ... }. v2 multi-tail.
local _tailLog       = {}   -- array, newest first, { ts, event, args = {n=N, ...} }.
                            -- Interleaved across all tailed events; entries from
                            -- an untailed event get purged on toggle-off so the
                            -- log only reflects what's actively being captured.
local _eventColors   = {}   -- name -> {r,g,b}. Memoized so a given event keeps
                            -- the same color across all renders of its tail row.
local _paused        = false
local _isTabVisible  = false

-- Widgets (populated in build()).
local _pane                  -- pane Frame (set in build() for relayout())
local _pauseBtn
local _resetBtn
local _statusLabel
local _leaderboardScroll
local _leaderboardContent
local _leaderRows = {}      -- index -> { container, nameLabel, countLabel, rateLabel, barBg, barFill }
local _tailHeaderRow
local _tailHeaderLabel
local _clearTailBtn
local _untailBtn
local _tailScroll
local _tailContent
local _tailRows   = {}      -- index -> { container, tsLabel, argsLabel }


-- Forward declarations.
local refreshLeaderboard
local refreshTail
local refreshToolbar


-- ---------------------------------------------------------------------------
-- Event capture
-- ---------------------------------------------------------------------------
-- Hidden frame with RegisterAllEvents. Modern WoW (interface 120005)
-- allows it on any Frame; standard pattern for event monitors.

local _eventFrame = CreateFrame("Frame", "Forge_EventsListenerFrame")
_eventFrame:Hide()

_eventFrame:SetScript("OnEvent", function(self, event, ...)
    if _paused then return end

    _currentSecond[event] = (_currentSecond[event] or 0) + 1

    -- Multi-tail: cheap set lookup, no allocation when not tailed. Combat
    -- can fire 1k+ events/sec, so the common-case "not tailed" branch
    -- has to bail immediately.
    if _tailedEvents[event] then
        local n = select("#", ...)
        local args = { ... }
        args.n = n
        table.insert(_tailLog, 1, {
            ts    = GetTime and GetTime() or 0,
            event = event,
            args  = args,
        })
        while #_tailLog > TAIL_MAX do _tailLog[#_tailLog] = nil end
        if _isTabVisible then refreshTail() end
    end
end)


-- ---------------------------------------------------------------------------
-- Ring buffer
-- ---------------------------------------------------------------------------

local function advanceRing()
    for name, ring in pairs(_eventCounts) do
        ring[_ringHead] = _currentSecond[name] or 0
    end
    -- Newly-seen events: create a zero-filled ring so the chart shows
    -- it entering from zero rather than carrying a stale value.
    for name, c in pairs(_currentSecond) do
        if not _eventCounts[name] then
            local ring = {}
            for i = 1, WINDOW_SECONDS do ring[i] = 0 end
            ring[_ringHead] = c
            _eventCounts[name] = ring
        end
    end
    _currentSecond = {}
    _ringHead = (_ringHead % WINDOW_SECONDS) + 1
    if _ringCount < WINDOW_SECONDS then _ringCount = _ringCount + 1 end
end


local function sumRing(ring)
    local s = 0
    for i = 1, WINDOW_SECONDS do s = s + (ring[i] or 0) end
    return s
end


local function ringReset()
    _eventCounts   = {}
    _currentSecond = {}
    _ringHead      = 1
    _ringCount     = 0
    _tailLog       = {}
    _tailedEvents  = {}
end


-- ---------------------------------------------------------------------------
-- Top-N selection
-- ---------------------------------------------------------------------------

local function computeTopN()
    local rows = {}
    for name, ring in pairs(_eventCounts) do
        local total = sumRing(ring)
        if total > 0 then
            rows[#rows + 1] = { name = name, total = total }
        end
    end
    table.sort(rows, function(a, b)
        if a.total == b.total then return a.name < b.name end
        return a.total > b.total
    end)
    while #rows > TOP_N do rows[#rows] = nil end
    return rows
end


-- ---------------------------------------------------------------------------
-- Tail log: arg formatting
-- ---------------------------------------------------------------------------
-- Lazy: only stringify when we draw. Combat-time hot path stays cheap.

local function formatArg(v)
    local t = type(v)
    if t == "nil"     then return "|cff888888nil|r" end
    if t == "string"  then return ("|cffffd060\"%s\"|r"):format(v) end
    if t == "number"  then return ("|cff80c0ff%s|r"):format(tostring(v)) end
    if t == "boolean" then return ("|cffff80c0%s|r"):format(tostring(v)) end
    if t == "table"   then return ("|cff80ff80table|r:" .. tostring(v):sub(8)) end
    return ("|cffaaaaaa%s|r"):format(tostring(v))
end


local function formatArgs(args)
    if not args or args.n == 0 then return "(no args)" end
    local parts = {}
    for i = 1, args.n do parts[i] = formatArg(args[i]) end
    return table.concat(parts, "  ")
end


local function formatTimestamp(t)
    -- Seconds precision is enough; sub-second isn't useful when events
    -- are batched into 1s buckets anyway.
    local secs = math.floor(t)
    local h = math.floor(secs / 3600) % 24
    local m = math.floor(secs / 60) % 60
    local s = secs % 60
    return ("%02d:%02d:%02d"):format(h, m, s)
end


-- Event color palette + cheap deterministic hash. Each tailed event gets
-- a stable color across renders so the eye can pick out interleaved
-- entries at a glance. 8 colors is enough for the realistic multi-tail
-- case (~3-5 events); collisions past that are tolerable.
local TAIL_PALETTE = {
    { 0.40, 0.85, 1.00 },   -- cyan
    { 1.00, 0.75, 0.30 },   -- amber
    { 0.65, 1.00, 0.50 },   -- lime
    { 1.00, 0.50, 0.80 },   -- pink
    { 0.80, 0.60, 1.00 },   -- violet
    { 1.00, 1.00, 0.50 },   -- yellow
    { 0.50, 0.90, 0.80 },   -- teal
    { 1.00, 0.80, 0.50 },   -- peach
}

local function eventColor(name)
    local cached = _eventColors[name]
    if cached then return cached end
    -- Sum-of-bytes hash, mod a prime to spread well, then mod palette size.
    -- Lua's hashing is unspecified across versions; rolling our own keeps
    -- the color stable across /reload.
    local h = 0
    for i = 1, #name do h = (h + string.byte(name, i)) % 9973 end
    local color = TAIL_PALETTE[(h % #TAIL_PALETTE) + 1]
    _eventColors[name] = color
    return color
end


local function eventColorEscape(name)
    local c = eventColor(name)
    return ("|cff%02x%02x%02x"):format(
        math.floor(c[1] * 255),
        math.floor(c[2] * 255),
        math.floor(c[3] * 255))
end


-- ---------------------------------------------------------------------------
-- Tailing
-- ---------------------------------------------------------------------------

-- Purge log entries for a specific event. Used when an event is untailed
-- so the visible log only reflects what's actively being captured. Walks
-- the array in reverse so table.remove doesn't shift indices we haven't
-- yet visited.
local function purgeTailLogFor(event)
    for i = #_tailLog, 1, -1 do
        if _tailLog[i].event == event then
            table.remove(_tailLog, i)
        end
    end
end


local function toggleTailedEvent(name)
    if not name or name == "" then return end
    if _tailedEvents[name] then
        _tailedEvents[name] = nil
        purgeTailLogFor(name)
    else
        _tailedEvents[name] = true
    end
    if _isTabVisible then
        refreshLeaderboard()
        refreshTail()
    end
end


-- Clear the active tail set + the log. Used by the "Clear tails" button
-- and by Reset. The set wipe is what makes future OnEvent fires no-op
-- back to the cheap-counter path.
local function clearTailedEvents()
    _tailedEvents = {}
    _tailLog      = {}
    if _isTabVisible then
        refreshLeaderboard()
        refreshTail()
    end
end


-- Clear only the log, leaving the tail set intact. New fires will refill.
local function clearTailLog()
    _tailLog = {}
    if _isTabVisible then refreshTail() end
end


-- ---------------------------------------------------------------------------
-- Leaderboard rendering
-- ---------------------------------------------------------------------------

local function acquireLeaderRow(Gui, index)
    local existing = _leaderRows[index]
    if existing and existing.container then
        existing.container:Show()
        return existing
    end

    local row = {}
    row.container = Gui:Acquire("Container", _leaderboardContent, {
        bg          = "color.bg.surface",
        border      = "color.border.default",
        borderWidth = 1,
        height      = LEADER_ROW_HEIGHT,
    })
    row.container:EnableMouse(true)

    row.nameLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.nameLabel.Cairn:SetLayoutManual(true)
    row.nameLabel:ClearAllPoints()
    row.nameLabel:SetPoint("LEFT",  row.container, "LEFT",   6, 0)
    -- Leave room for count + rate + bar + scrollbar gutter on the right.
    row.nameLabel:SetPoint("RIGHT", row.container, "RIGHT", -(180 + ROW_RIGHT_MARGIN), 0)

    row.countLabel = Gui:Acquire("Label", row.container, {
        text = "", variant = "muted",
    })
    row.countLabel.Cairn:SetLayoutManual(true)
    row.countLabel:ClearAllPoints()
    row.countLabel:SetPoint("RIGHT", row.container, "RIGHT", -(100 + ROW_RIGHT_MARGIN), 0)
    row.countLabel:SetWidth(80)

    row.rateLabel = Gui:Acquire("Label", row.container, {
        text = "", variant = "muted",
    })
    row.rateLabel.Cairn:SetLayoutManual(true)
    row.rateLabel:ClearAllPoints()
    row.rateLabel:SetPoint("RIGHT", row.container, "RIGHT", -ROW_RIGHT_MARGIN, 0)
    row.rateLabel:SetWidth(90)

    -- Bar viz: full-row-height faint background fill so the bar reads as
    -- a horizontal data viz, not a 2px line. Foreground fill scales to
    -- total / topTotal.
    row.barBg = row.container:CreateTexture(nil, "BACKGROUND")
    row.barBg:SetColorTexture(0.15, 0.15, 0.18, 0.5)
    row.barBg:SetPoint("BOTTOMRIGHT", row.container, "BOTTOMRIGHT", -ROW_RIGHT_MARGIN, 2)
    row.barBg:SetSize(160, 4)

    row.barFill = row.container:CreateTexture(nil, "ARTWORK")
    row.barFill:SetColorTexture(0.40, 0.85, 1.00, 0.85)
    row.barFill:SetPoint("BOTTOMRIGHT", row.barBg, "BOTTOMRIGHT", 0, 0)
    row.barFill:SetSize(0, 4)

    row.container:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        if row._eventName then
            toggleTailedEvent(row._eventName)
        end
    end)

    _leaderRows[index] = row
    return row
end


local function hideExtraLeaderRows(fromIndex)
    for i = fromIndex, #_leaderRows do
        if _leaderRows[i] and _leaderRows[i].container then
            _leaderRows[i].container:Hide()
        end
    end
end


refreshLeaderboard = function()
    if not _leaderboardContent then return end
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local top = computeTopN()
    local maxTotal = (top[1] and top[1].total) or 1
    local windowSpan = math.max(1, _ringCount)

    for i, entry in ipairs(top) do
        local row = acquireLeaderRow(Gui, i)
        row._eventName = entry.name

        local isTailed = _tailedEvents[entry.name] and true or false
        local arrow = isTailed and "|cffffd060>|r " or "  "
        row.nameLabel.Cairn:SetText(arrow .. entry.name)

        -- Use actual sampled span until the ring fills, then "60s".
        row.countLabel.Cairn:SetText(("%d in %ds"):format(entry.total, windowSpan))
        row.rateLabel.Cairn:SetText(("%.1f /s"):format(entry.total / windowSpan))

        local frac = entry.total / maxTotal
        if frac < 0.02 then frac = 0.02 end
        row.barFill:SetSize(160 * frac, 4)

        if row.container.Cairn and row.container.Cairn.DrawRect then
            local bg = isTailed and "color.bg.button" or "color.bg.surface"
            row.container.Cairn:DrawRect("bg", bg)
        end
    end
    hideExtraLeaderRows(#top + 1)

    if _leaderboardScroll and _leaderboardScroll.Cairn
       and _leaderboardScroll.Cairn.SetContentHeight then
        _leaderboardScroll.Cairn:SetContentHeight(
            math.max(40, #top * (LEADER_ROW_HEIGHT + 2)))
    end
end


-- ---------------------------------------------------------------------------
-- Tail rendering
-- ---------------------------------------------------------------------------

local function acquireTailRow(Gui, index)
    local existing = _tailRows[index]
    if existing and existing.container then
        existing.container:Show()
        return existing
    end

    local row = {}
    row.container = Gui:Acquire("Container", _tailContent, {
        height = TAIL_ROW_HEIGHT,
    })

    row.tsLabel = Gui:Acquire("Label", row.container, {
        text = "", variant = "muted",
    })
    row.tsLabel.Cairn:SetLayoutManual(true)
    row.tsLabel:ClearAllPoints()
    row.tsLabel:SetPoint("LEFT", row.container, "LEFT", 4, 0)
    row.tsLabel:SetWidth(70)

    row.argsLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.argsLabel.Cairn:SetLayoutManual(true)
    row.argsLabel:ClearAllPoints()
    row.argsLabel:SetPoint("LEFT",  row.container, "LEFT",   76, 0)
    row.argsLabel:SetPoint("RIGHT", row.container, "RIGHT", -ROW_RIGHT_MARGIN, 0)

    _tailRows[index] = row
    return row
end


local function hideExtraTailRows(fromIndex)
    for i = fromIndex, #_tailRows do
        if _tailRows[i] and _tailRows[i].container then
            _tailRows[i].container:Hide()
        end
    end
end


refreshTail = function()
    if not _tailContent then return end
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    -- Count active tails. `next()` is O(1) for the empty check; the
    -- count loop only runs when we need the number for the header.
    local hasAny  = next(_tailedEvents) ~= nil
    local tailCnt = 0
    for _ in pairs(_tailedEvents) do tailCnt = tailCnt + 1 end

    if _tailHeaderLabel and _tailHeaderLabel.Cairn then
        if tailCnt == 0 then
            _tailHeaderLabel.Cairn:SetText(
                "|cff888888Click leaderboard rows to tail events. "
                .. "Multiple events can be tailed at once.|r")
        elseif tailCnt == 1 then
            local name = next(_tailedEvents)
            _tailHeaderLabel.Cairn:SetText(
                "|cffffd060Tailing:|r " .. eventColorEscape(name)
                .. name .. "|r")
        else
            _tailHeaderLabel.Cairn:SetText(
                ("|cffffd060Tailing %d events|r"):format(tailCnt))
        end
    end

    if _untailBtn and _untailBtn.Cairn and _untailBtn.Cairn.SetEnabled then
        _untailBtn.Cairn:SetEnabled(hasAny)
    end
    if _clearTailBtn and _clearTailBtn.Cairn and _clearTailBtn.Cairn.SetEnabled then
        _clearTailBtn.Cairn:SetEnabled(#_tailLog > 0)
    end

    if not hasAny or #_tailLog == 0 then
        hideExtraTailRows(1)
        if _tailScroll and _tailScroll.Cairn
           and _tailScroll.Cairn.SetContentHeight then
            _tailScroll.Cairn:SetContentHeight(40)
        end
        return
    end

    for i = 1, #_tailLog do
        local entry = _tailLog[i]
        local row = acquireTailRow(Gui, i)
        row.tsLabel.Cairn:SetText(formatTimestamp(entry.ts))
        -- Color-coded event-name prefix lets you eyeball-group interleaved
        -- entries from multiple tails. Args are still lazy-formatted at
        -- draw time so high-frequency tails don't pay until the user looks.
        row.argsLabel.Cairn:SetText(
            eventColorEscape(entry.event) .. entry.event .. "|r  "
            .. formatArgs(entry.args))
    end
    hideExtraTailRows(#_tailLog + 1)

    if _tailScroll and _tailScroll.Cairn
       and _tailScroll.Cairn.SetContentHeight then
        _tailScroll.Cairn:SetContentHeight(
            math.max(40, #_tailLog * (TAIL_ROW_HEIGHT + 2)))
    end
end


-- ---------------------------------------------------------------------------
-- Toolbar
-- ---------------------------------------------------------------------------

refreshToolbar = function()
    if _pauseBtn and _pauseBtn.Cairn then
        _pauseBtn.Cairn:SetText(_paused and "Resume" or "Pause")
    end
    if _statusLabel and _statusLabel.Cairn then
        if _paused then
            _statusLabel.Cairn:SetText("|cffffd060paused|r")
        else
            local count = 0
            for _ in pairs(_eventCounts) do count = count + 1 end
            _statusLabel.Cairn:SetText(
                ("|cff888888tracking %d events|r"):format(count))
        end
    end
end


local function setPaused(paused)
    _paused = paused and true or false
    refreshToolbar()
end


local function doReset()
    ringReset()  -- also wipes _tailedEvents
    _tailLog = {}
    if _isTabVisible then
        refreshLeaderboard()
        refreshTail()
        refreshToolbar()
    end
end


-- ---------------------------------------------------------------------------
-- Tick (always running)
-- ---------------------------------------------------------------------------

local function tick()
    advanceRing()
    if _isTabVisible then
        refreshLeaderboard()
        refreshToolbar()
    end
end


-- ---------------------------------------------------------------------------
-- Relayout (split remaining pane height 50/50 between the two scrolls)
-- ---------------------------------------------------------------------------
-- Both ScrollFrames + the tail header are SetLayoutManual'd so Stack
-- doesn't try to position them. We anchor everything from the pane edges
-- so the layout flexes with window resizes and never busts the bottom.

local function relayout()
    if not (_pane and _leaderboardScroll and _tailHeaderRow and _tailScroll) then
        return
    end
    local paneH = _pane:GetHeight() or 0
    if paneH < 200 then return end

    local available = paneH - TOP_RESERVED - TAIL_HEADER_H - BOTTOM_PAD - (SECTION_GAP * 2)
    if available < 100 then available = 100 end
    local leaderH = math.floor(available * 0.5)
    local tailTopOffset = TOP_RESERVED + leaderH + SECTION_GAP
    local tailScrollTopOffset = tailTopOffset + TAIL_HEADER_H + SECTION_GAP

    _leaderboardScroll:ClearAllPoints()
    _leaderboardScroll:SetPoint("TOPLEFT",     _pane, "TOPLEFT",   SIDE_PAD, -TOP_RESERVED)
    _leaderboardScroll:SetPoint("BOTTOMRIGHT", _pane, "TOPRIGHT", -SIDE_PAD, -(TOP_RESERVED + leaderH))

    _tailHeaderRow:ClearAllPoints()
    _tailHeaderRow:SetPoint("TOPLEFT",  _pane, "TOPLEFT",   SIDE_PAD, -tailTopOffset)
    _tailHeaderRow:SetPoint("TOPRIGHT", _pane, "TOPRIGHT", -SIDE_PAD, -tailTopOffset)
    _tailHeaderRow:SetHeight(TAIL_HEADER_H)

    _tailScroll:ClearAllPoints()
    _tailScroll:SetPoint("TOPLEFT",     _pane, "TOPLEFT",      SIDE_PAD, -tailScrollTopOffset)
    _tailScroll:SetPoint("BOTTOMRIGHT", _pane, "BOTTOMRIGHT", -SIDE_PAD,  BOTTOM_PAD)
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

    Gui:Acquire("Label", pane, { text = "Events", variant = "heading" })

    Gui:Acquire("Label", pane, {
        text    = "|cff888888Top events by count over the rolling window. "
                  .. "Click rows to tail args (multiple at once; click again to untail).|r",
        variant = "muted",
    })

    -- Toolbar: Pause / Reset / status.
    local toolbar = Gui:Acquire("Container", pane, { height = 28 })
    toolbar.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    _pauseBtn = Gui:Acquire("Button", toolbar, {
        text = "Pause", variant = "primary", width = 90,
    })
    _pauseBtn.Cairn:On("Click", function() setPaused(not _paused) end)

    _resetBtn = Gui:Acquire("Button", toolbar, {
        text = "Reset", variant = "ghost", width = 80,
    })
    _resetBtn.Cairn:On("Click", doReset)

    _statusLabel = Gui:Acquire("Label", toolbar, {
        text = "|cff888888tracking 0 events|r", variant = "muted",
    })

    Gui:Acquire("Label", pane, {
        text = "|cff80c0ffLeaderboard|r", variant = "muted",
    })

    -- Leaderboard ScrollFrame (manual anchor).
    _leaderboardScroll = Gui:Acquire("ScrollFrame", pane, {
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
    })
    _leaderboardScroll.Cairn:SetLayoutManual(true)
    _leaderboardContent = _leaderboardScroll.Cairn:GetContent()
    _leaderboardContent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 2, padding = 4 })

    -- Tail header (manual anchor).
    _tailHeaderRow = Gui:Acquire("Container", pane, { height = TAIL_HEADER_H })
    _tailHeaderRow.Cairn:SetLayoutManual(true)
    _tailHeaderRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    _tailHeaderLabel = Gui:Acquire("Label", _tailHeaderRow, {
        text = "|cff888888Click a leaderboard row to tail an event.|r",
    })

    _clearTailBtn = Gui:Acquire("Button", _tailHeaderRow, {
        text = "Clear", variant = "ghost", width = 70, height = 22,
    })
    _clearTailBtn.Cairn:On("Click", clearTailLog)

    -- "Clear tails" wipes all active tails + the log. Single-event untail
    -- happens by clicking the leaderboard row again (toggle semantics);
    -- this button is the "drop everything" shortcut.
    _untailBtn = Gui:Acquire("Button", _tailHeaderRow, {
        text = "Clear tails", variant = "ghost", width = 90, height = 22,
    })
    _untailBtn.Cairn:On("Click", clearTailedEvents)

    -- Tail ScrollFrame (manual anchor).
    _tailScroll = Gui:Acquire("ScrollFrame", pane, {
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
    })
    _tailScroll.Cairn:SetLayoutManual(true)
    _tailContent = _tailScroll.Cairn:GetContent()
    _tailContent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 2, padding = 4 })

    pane:HookScript("OnSizeChanged", relayout)
    relayout()

    refreshToolbar()
    refreshLeaderboard()
    refreshTail()
end


-- ---------------------------------------------------------------------------
-- Tab descriptor
-- ---------------------------------------------------------------------------

ns.descriptor = {
    name        = "Events",
    title       = "Events",
    order       = 40,
    description = "Live event-rate leaderboard with click-to-tail args log.",

    OnTabShow = function(pane, mod)
        if not pane.Cairn._builtOnce then
            pane.Cairn._builtOnce = true
            build(pane)
        end
        _isTabVisible = true
        relayout()
        refreshToolbar()
        refreshLeaderboard()
        refreshTail()
    end,

    OnTabHide = function(pane, mod)
        _isTabVisible = false
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


function addon:OnLogin()
    _eventFrame:RegisterAllEvents()
    if C_Timer and C_Timer.NewTicker and not _ticker then
        _ticker = C_Timer.NewTicker(SAMPLE_INTERVAL, tick)
    end
end

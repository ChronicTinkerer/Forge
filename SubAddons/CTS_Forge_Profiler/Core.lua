-- Forge_Profiler: live CPU + memory time-series chart for the top-5 addons.
--
-- v2 scope (this file):
--   * CPU / Memory toggle (segmented two-button): single chart frame, two
--     parallel ring buffers, instant switch with no re-sample wait.
--   * Click-to-pin legend rows; pinned addons survive top-N churn and
--     persist across /reload via db.profile.pinned.
--   * CSV export popup (Window-at-DIALOG strata): header + per-sample row.
--   * Carries v1: top-N peak-in-window, Pause/Reset, profiler-off banner,
--     ticker-cancel-on-hide, auto Y-axis with headroom.
--
-- Out of scope for v2 (queued for v3):
--   * Configurable WINDOW_SECONDS / SAMPLE_INTERVAL.
--   * Per-addon CPU/mem breakdown drill-down (per-function profile).
--
-- Sampling strategy:
--   * Every SAMPLE_INTERVAL seconds while the tab is visible, poll every
--     loaded addon's C_AddOnProfiler.RecentAverageTime and write the
--     values into per-addon ring buffers of WINDOW_SECONDS slots.
--   * Top-N selection uses peak-in-window instead of current snapshot.
--     A one-frame spike won't bump someone off the chart for the rest of
--     the window, which keeps the legend readable.
--   * Ticker is cancelled in OnTabHide so the tab uses zero CPU when not
--     visible. Samples are preserved across hide/show.
--
-- Chart drawing:
--   * Raw Frame as canvas (the Cairn-Gui Container's underlying Frame).
--   * chartFrame:CreateLine() per segment, pooled across redraws to
--     avoid leaking Line objects on every tick.
--   * Lines anchored BOTTOMLEFT-relative so x=0 is the oldest sample
--     and x=width is the newest; chart appears to scroll right-to-left.

local ADDON, ns = ...
_G.Forge_Profiler = ns


Cairn.Register("CTS_Forge_Profiler", ns, {
    dbName = "Forge_ProfilerDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = {
        profile = { pinned = {} },  -- pinned addon names, set semantics
        global  = {},
    },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Profiler"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local SAMPLE_INTERVAL = 1       -- seconds per chart sample
local WINDOW_SECONDS  = 60      -- ring buffer length
local TOP_N           = 5       -- visible addon series (+1 Total line)
local CHART_HEIGHT    = 200     -- px
local LINE_THICKNESS  = 1.5
local Y_HEADROOM      = 1.2     -- top-of-chart = peak * Y_HEADROOM


-- Series colors: 5 addon slots + Total. RGB triples in 0..1 range.
-- Chosen for distinguishability on the default dark Cairn-Gui surface;
-- Total is white to read as the "sum / reference" line.
local SERIES_COLORS = {
    { 0.40, 0.85, 1.00 },   -- cyan
    { 1.00, 0.75, 0.30 },   -- amber
    { 0.65, 1.00, 0.50 },   -- lime
    { 1.00, 0.50, 0.80 },   -- pink
    { 0.80, 0.60, 1.00 },   -- violet
    { 1.00, 1.00, 1.00 },   -- white (Total)
}
local TOTAL_SLOT = 6


-- ---------------------------------------------------------------------------
-- Module-scope state
-- ---------------------------------------------------------------------------

local _ticker
local _samples    = {}          -- CPU: name -> { v1..vWINDOW_SECONDS } ring
local _totals     = {}          -- CPU: Total ring buffer
local _memSamples = {}          -- Memory: name -> ring (kb)
local _memTotals  = {}          -- Memory: Total ring buffer (kb)
local _ringHead   = 1           -- shared write slot for both rings, 1..WINDOW_SECONDS
local _ringCount  = 0           -- valid samples (capped at WINDOW_SECONDS)
local _topNames   = {}          -- ordered array of up to TOP_N addon names
local _paused     = false
local _mode       = "cpu"       -- active view: "cpu" | "mem". Both rings keep
                                -- sampling either way; only display flips.
local _pinned     = {}          -- name -> true. Rebound to db.profile.pinned
                                -- in build() so every mutation auto-persists
                                -- via the SV-alias upvalue trick.

-- Widgets (populated in build()).
local _pauseBtn
local _resetBtn
local _statusLabel
local _profilerBanner
local _profilerBannerBtn
local _chartContainer
local _yMaxLabel
local _yMaxUnit                 -- "ms" / "kb" label next to peak readout
local _modeCpuBtn               -- segmented toggle: CPU
local _modeMemBtn               -- segmented toggle: Memory
local _legendRows = {}          -- index 1..TOP_N+1 (last = Total)
local _linePool   = {}          -- pool of Line objects on the chart frame


-- Forward declarations.
local refreshLegend
local refreshBanner


-- ---------------------------------------------------------------------------
-- CPU sampling (matches the Forge_AddonManager helpers)
-- ---------------------------------------------------------------------------

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


-- Memory usage is a snapshot-style API: WoW caches the per-addon totals
-- only when UpdateAddOnMemoryUsage is called. Without the refresh, every
-- read returns the same stale value forever (this is the #1 footgun other
-- addons hit). We call it once per tick before the per-addon loop.
local function refreshMemoryCache()
    if C_AddOns and C_AddOns.UpdateAddOnMemoryUsage then
        C_AddOns.UpdateAddOnMemoryUsage()
    elseif UpdateAddOnMemoryUsage then
        UpdateAddOnMemoryUsage()
    end
end


-- Returns memory in kb. Defends against both the C_AddOns namespace and
-- the legacy global so the addon works across the 11.0 transition.
local function readMemKb(name)
    if C_AddOns and C_AddOns.GetAddOnMemoryUsage then
        local ok, value = pcall(C_AddOns.GetAddOnMemoryUsage, name)
        if ok and value then return value end
    end
    if GetAddOnMemoryUsage then
        local ok, value = pcall(GetAddOnMemoryUsage, name)
        if ok and value then return value end
    end
    return nil
end


-- ---------------------------------------------------------------------------
-- Mode helpers (CPU vs Memory)
-- ---------------------------------------------------------------------------
-- Centralising the "which ring is active" branch in these helpers keeps the
-- chart/legend/CSV code mode-agnostic; only sampling writes to both rings
-- by name. Adding a third metric later (e.g. encounter time) would mean
-- extending these four helpers, not chasing dozens of branches.

local function currentSamples()
    return _mode == "mem" and _memSamples or _samples
end

local function currentTotals()
    return _mode == "mem" and _memTotals or _totals
end

local function unitLabel()
    return _mode == "mem" and "kb" or "ms"
end

local function formatValue(v)
    if _mode == "mem" then return ("%.1f kb"):format(v or 0) end
    return ("%.2f ms"):format(v or 0)
end


-- Returns array of currently-loaded addon names. We sample only loaded
-- ones because unloaded addons report 0 ms anyway and including them
-- would just add noise to the top-N search.
local function gatherLoadedAddons()
    local out = {}
    local count = (C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns()) or 0
    for i = 1, count do
        local name
        if C_AddOns and C_AddOns.GetAddOnInfo then
            name = C_AddOns.GetAddOnInfo(i)
        end
        local loaded = name and C_AddOns and C_AddOns.IsAddOnLoaded
                       and C_AddOns.IsAddOnLoaded(name)
        if loaded then out[#out + 1] = name end
    end
    return out
end


-- ---------------------------------------------------------------------------
-- Ring buffer
-- ---------------------------------------------------------------------------
-- _samples[name][i] is the i-th slot in a fixed-size ring of WINDOW_SECONDS.
-- _ringHead is the slot that will be written next; (_ringHead-1 with wrap)
-- is the newest sample. Using a head pointer rather than table.remove(t, 1)
-- keeps writes O(1) and avoids per-tick garbage churn.

local function newestIndex()
    return _ringHead == 1 and WINDOW_SECONDS or _ringHead - 1
end


-- Writes one slot across both rings on the same tick. cpuValues / memValues
-- are name->value dicts (only addons reporting non-zero in either metric
-- appear). Both rings share _ringHead so a sample at index N in CPU is
-- temporally aligned with the same index in Memory.
local function ringWriteAll(cpuValues, cpuTotal, memValues, memTotal)
    -- Existing rings: write current value or 0 (drop-outs visibly fall).
    for name, ring in pairs(_samples) do
        ring[_ringHead] = cpuValues[name] or 0
    end
    for name, ring in pairs(_memSamples) do
        ring[_ringHead] = memValues[name] or 0
    end
    -- Newly-seen addons get a pre-zeroed ring so the line enters from the
    -- baseline rather than from whatever value happens to be at _ringHead.
    -- An addon may be new to one metric and not the other (rare but possible
    -- when GetAddOnMemoryUsage briefly returns nil), so both checks are
    -- independent.
    for name, v in pairs(cpuValues) do
        if not _samples[name] then
            local ring = {}
            for i = 1, WINDOW_SECONDS do ring[i] = 0 end
            ring[_ringHead] = v
            _samples[name] = ring
        end
    end
    for name, v in pairs(memValues) do
        if not _memSamples[name] then
            local ring = {}
            for i = 1, WINDOW_SECONDS do ring[i] = 0 end
            ring[_ringHead] = v
            _memSamples[name] = ring
        end
    end
    _totals[_ringHead]    = cpuTotal
    _memTotals[_ringHead] = memTotal
    _ringHead = (_ringHead % WINDOW_SECONDS) + 1
    if _ringCount < WINDOW_SECONDS then _ringCount = _ringCount + 1 end
end


-- Returns ring contents in oldest-to-newest order. Used by the chart
-- renderer. When the ring isn't full yet, only the populated slots
-- are returned (length < WINDOW_SECONDS).
local function ringOldestToNewest(ring)
    local out = {}
    if _ringCount < WINDOW_SECONDS then
        for i = 1, _ringCount do out[i] = ring[i] or 0 end
        return out
    end
    local k = 1
    for i = _ringHead, WINDOW_SECONDS do out[k] = ring[i] or 0; k = k + 1 end
    for i = 1, _ringHead - 1 do out[k] = ring[i] or 0; k = k + 1 end
    return out
end


local function ringReset()
    _samples    = {}
    _totals     = {}
    _memSamples = {}
    _memTotals  = {}
    _ringHead   = 1
    _ringCount  = 0
    for i = 1, WINDOW_SECONDS do _totals[i] = 0; _memTotals[i] = 0 end
    _topNames = {}
end


-- ---------------------------------------------------------------------------
-- Top-N selection (peak-in-window for stability)
-- ---------------------------------------------------------------------------

-- Top-N peaks the active mode's ring. Switching CPU<->Memory picks a
-- different top-5 because the "hottest" metric differs; tick() recomputes
-- every second anyway, but we also recompute on toggle for instant feedback.
--
-- Pin semantics: pinned addons always occupy the leading slots (up to
-- TOP_N), ordered among themselves by peak. Non-pinned addons compete for
-- the remaining slots. If pins >= TOP_N, non-pinned aren't shown. This
-- lets the user "stick" an addon they want to watch even when it isn't
-- hot enough to make the natural top-5.
local function computeTopN()
    local source = currentSamples()
    local pinned, others = {}, {}
    for name, ring in pairs(source) do
        local peak = 0
        for i = 1, WINDOW_SECONDS do
            local v = ring[i] or 0
            if v > peak then peak = v end
        end
        local row = { name = name, peak = peak }
        if _pinned[name] then
            pinned[#pinned + 1] = row
        else
            others[#others + 1] = row
        end
    end
    local function byPeakDesc(a, b)
        if a.peak == b.peak then return a.name < b.name end
        return a.peak > b.peak
    end
    table.sort(pinned, byPeakDesc)
    table.sort(others, byPeakDesc)

    local out = {}
    for i = 1, math.min(TOP_N, #pinned) do out[i] = pinned[i].name end
    local slot = #out + 1
    for i = 1, #others do
        if slot > TOP_N then break end
        out[slot] = others[i].name
        slot = slot + 1
    end
    return out
end


-- ---------------------------------------------------------------------------
-- Chart rendering
-- ---------------------------------------------------------------------------

local function acquireLine()
    for _, line in ipairs(_linePool) do
        if not line.__inUse then
            line.__inUse = true
            line:Show()
            return line
        end
    end
    local line = _chartContainer:CreateLine(nil, "ARTWORK")
    line:SetThickness(LINE_THICKNESS)
    line.__inUse = true
    table.insert(_linePool, line)
    return line
end


local function releaseAllLines()
    for _, line in ipairs(_linePool) do
        line.__inUse = false
        line:Hide()
    end
end


-- Plot one series across the chart area. samples[] is the value list in
-- oldest-to-newest order. Skips when there are fewer than 2 points (a
-- line segment needs two endpoints).
local function plotSeries(samples, color, yMax)
    if #samples < 2 then return end
    local cw = _chartContainer:GetWidth() or 0
    local ch = _chartContainer:GetHeight() or 0
    if cw < 4 or ch < 4 then return end

    -- Newest sample sits at x = cw. As new samples arrive, older ones
    -- slide left, giving the right-to-left scroll feel users expect
    -- from a live monitor.
    local stride = (#samples > 1) and (cw / (#samples - 1)) or cw
    local function yFor(v)
        if yMax <= 0 then return 0 end
        local clipped = math.min(v, yMax)
        return (clipped / yMax) * ch
    end

    for i = 1, #samples - 1 do
        local x1, y1 = (i - 1) * stride, yFor(samples[i])
        local x2, y2 =  i      * stride, yFor(samples[i + 1])
        local line = acquireLine()
        line:SetColorTexture(color[1], color[2], color[3], 0.9)
        line:ClearAllPoints()
        line:SetStartPoint("BOTTOMLEFT", x1, y1)
        line:SetEndPoint  ("BOTTOMLEFT", x2, y2)
    end
end


local function redrawChart()
    if not _chartContainer then return end
    releaseAllLines()

    local source = currentSamples()
    local totals = currentTotals()

    if _ringCount < 2 then
        if _yMaxLabel and _yMaxLabel.Cairn then
            _yMaxLabel.Cairn:SetText(formatValue(0))
        end
        return
    end

    -- Y max across visible series + Total so every line fits.
    local yMax = 0
    for _, name in ipairs(_topNames) do
        local ring = source[name]
        if ring then
            for j = 1, WINDOW_SECONDS do
                local v = ring[j] or 0
                if v > yMax then yMax = v end
            end
        end
    end
    for j = 1, WINDOW_SECONDS do
        local v = totals[j] or 0
        if v > yMax then yMax = v end
    end
    yMax = yMax * Y_HEADROOM
    -- Floor the axis so a flat-at-zero chart still produces visible
    -- baseline lines instead of dividing by ~0.
    if yMax < 0.1 then yMax = 0.1 end

    -- Total first (behind), then top-N on top so addon lines aren't
    -- occluded by the brighter Total trace.
    plotSeries(ringOldestToNewest(totals), SERIES_COLORS[TOTAL_SLOT], yMax)
    for i, name in ipairs(_topNames) do
        local ring = source[name]
        if ring then
            plotSeries(ringOldestToNewest(ring), SERIES_COLORS[i], yMax)
        end
    end

    if _yMaxLabel and _yMaxLabel.Cairn then
        _yMaxLabel.Cairn:SetText(formatValue(yMax))
    end
end


-- ---------------------------------------------------------------------------
-- Sampling tick
-- ---------------------------------------------------------------------------

local function tick()
    if _paused then return end
    refreshMemoryCache()  -- WoW snapshot: must precede the read loop
    local loaded   = gatherLoadedAddons()
    local cpuVals  = {}
    local memVals  = {}
    local cpuTotal = 0
    local memTotal = 0
    for _, name in ipairs(loaded) do
        local ms = readCpuRecentMs(name)
        if ms and ms > 0 then
            cpuVals[name] = ms
            cpuTotal = cpuTotal + ms
        end
        local kb = readMemKb(name)
        if kb and kb > 0 then
            memVals[name] = kb
            memTotal = memTotal + kb
        end
    end
    ringWriteAll(cpuVals, cpuTotal, memVals, memTotal)
    _topNames = computeTopN()
    redrawChart()
    refreshLegend()
end


-- ---------------------------------------------------------------------------
-- Legend
-- ---------------------------------------------------------------------------

refreshLegend = function()
    local newest = newestIndex()
    local source = currentSamples()
    local totals = currentTotals()
    for i = 1, TOP_N do
        local row = _legendRows[i]
        if row then
            local name  = _topNames[i]
            local color = SERIES_COLORS[i]
            if name then
                row.swatch:SetColorTexture(color[1], color[2], color[3], 1.0)
                -- Pin glyph "*" in amber prefixes the name. Unpinned rows
                -- show a single-space prefix so the name x-position is
                -- stable across pin/unpin (no jiggle on click).
                local prefix = _pinned[name]
                    and "|cffffd060*|r "
                    or  "  "
                row.label.Cairn:SetText(prefix .. name)
                local ring = source[name]
                local current = ring and ring[newest] or 0
                row.value.Cairn:SetText(formatValue(current))
                row.container:Show()
            else
                row.container:Hide()
            end
        end
    end
    local totalRow = _legendRows[TOP_N + 1]
    if totalRow then
        local color = SERIES_COLORS[TOTAL_SLOT]
        totalRow.swatch:SetColorTexture(color[1], color[2], color[3], 1.0)
        totalRow.label.Cairn:SetText("Total")
        local current = totals[newest] or 0
        totalRow.value.Cairn:SetText(formatValue(current))
        totalRow.container:Show()
    end
end


-- ---------------------------------------------------------------------------
-- Banner + buttons
-- ---------------------------------------------------------------------------

refreshBanner = function()
    if not _profilerBanner then return end
    if profilerEnabled() then
        _profilerBanner:Hide()
    else
        _profilerBanner:Show()
    end
end


local function setPaused(paused)
    _paused = paused and true or false
    if _pauseBtn and _pauseBtn.Cairn then
        _pauseBtn.Cairn:SetText(_paused and "Resume" or "Pause")
    end
    if _statusLabel and _statusLabel.Cairn then
        _statusLabel.Cairn:SetText(_paused and "|cffffd060paused|r"
                                            or "|cff888888sampling...|r")
    end
end


-- Mode toggle. Reflects the active mode visually as a segmented two-button:
-- the active mode uses the `primary` variant; the inactive uses `ghost`.
-- After flipping, we recompute top-N from the new ring and redraw immediately
-- so the user doesn't have to wait a tick for the visible state to catch up.
local function refreshModeButtons()
    if _modeCpuBtn and _modeCpuBtn.Cairn then
        _modeCpuBtn.Cairn:SetVariant(_mode == "cpu" and "primary" or "ghost")
    end
    if _modeMemBtn and _modeMemBtn.Cairn then
        _modeMemBtn.Cairn:SetVariant(_mode == "mem" and "primary" or "ghost")
    end
    if _yMaxUnit and _yMaxUnit.Cairn then
        _yMaxUnit.Cairn:SetText("|cff888888peak " .. unitLabel() .. ":|r")
    end
end


local function setMode(mode)
    if mode ~= "cpu" and mode ~= "mem" then return end
    if _mode == mode then return end
    _mode = mode
    refreshModeButtons()
    _topNames = computeTopN()
    redrawChart()
    refreshLegend()
end


-- Toggle pinned state for an addon. Mutation persists automatically because
-- _pinned is aliased to db.profile.pinned in build() (SV-alias upvalue trick).
-- We recompute top-N + redraw so the chart updates immediately rather than
-- waiting up to SAMPLE_INTERVAL for the next tick to catch up.
local function togglePin(name)
    if not name or name == "" then return end
    if _pinned[name] then
        _pinned[name] = nil
    else
        _pinned[name] = true
    end
    _topNames = computeTopN()
    redrawChart()
    refreshLegend()
end


local function doReset()
    ringReset()
    releaseAllLines()
    redrawChart()
    refreshLegend()
end


-- ---------------------------------------------------------------------------
-- CSV export
-- ---------------------------------------------------------------------------
-- Tick-major layout (one row per addon per tick, then a __TOTAL__ row) is
-- what pandas / Excel pivot tables expect. # comment lines hold the capture
-- metadata; pandas `comment="#"` and most spreadsheet importers tolerate
-- them. Addon names are unquoted because Blizzard's loader rejects names
-- containing commas or quotes, so a naive split-on-comma is safe.

local _csvPopup
local _csvEditBox

local function buildCsv()
    local lines = {}
    lines[#lines + 1] = "# Forge_Profiler export"
    lines[#lines + 1] = "# captured: " .. (date and date("%Y-%m-%d %H:%M:%S") or "?")
    lines[#lines + 1] = ("# window: %ds, sample_interval: %ds, samples: %d"):format(
                          WINDOW_SECONDS, SAMPLE_INTERVAL, _ringCount)
    lines[#lines + 1] = "tick,addon,cpu_ms,memory_kb"

    if _ringCount < 1 then
        lines[#lines + 1] = "# (no samples yet; open the tab and let it run "
                            .. "for a few seconds, then re-export)"
        return table.concat(lines, "\n")
    end

    -- Union the addon name sets across both rings so an addon that only
    -- reports CPU (or only memory) still appears once with zeros in the
    -- missing column.
    local nameSet = {}
    for n in pairs(_samples)    do nameSet[n] = true end
    for n in pairs(_memSamples) do nameSet[n] = true end
    local sortedNames = {}
    for n in pairs(nameSet) do sortedNames[#sortedNames + 1] = n end
    table.sort(sortedNames)

    -- Pre-compute oldest-to-newest views so we don't repeat the wrap-around
    -- math for every tick * every addon.
    local cpuOrder, memOrder = {}, {}
    for _, n in ipairs(sortedNames) do
        cpuOrder[n] = _samples[n]    and ringOldestToNewest(_samples[n])    or nil
        memOrder[n] = _memSamples[n] and ringOldestToNewest(_memSamples[n]) or nil
    end
    local totalCpuOrder = ringOldestToNewest(_totals)
    local totalMemOrder = ringOldestToNewest(_memTotals)

    for t = 1, _ringCount do
        for _, n in ipairs(sortedNames) do
            local cpu = (cpuOrder[n] and cpuOrder[n][t]) or 0
            local mem = (memOrder[n] and memOrder[n][t]) or 0
            lines[#lines + 1] = ("%d,%s,%.4f,%.2f"):format(t, n, cpu, mem)
        end
        local tc = totalCpuOrder[t] or 0
        local tm = totalMemOrder[t] or 0
        lines[#lines + 1] = ("%d,__TOTAL__,%.4f,%.2f"):format(t, tc, tm)
    end

    return table.concat(lines, "\n")
end


local function buildCsvPopup()
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local win = Gui:Acquire("Window", UIParent, {
        title    = "Export profiler data",
        width    = 560,
        height   = 360,
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
        text    = "Ctrl-A to select all, Ctrl-C to copy. Paste into a .csv "
                  .. "file or a spreadsheet. # lines are header metadata.",
        variant = "muted",
    })

    local eb = Gui:Acquire("EditBox", content, {
        width     = 540,
        height    = 270,
        multiline = true,
        text      = "",
    })

    local closeBtn = Gui:Acquire("Button", content, {
        text = "Close", variant = "ghost", width = 80, height = 22,
    })
    closeBtn.Cairn:On("Click", function() win:Hide() end)
    win.Cairn:On("Close", function() win:Hide() end)

    _csvPopup   = win
    _csvEditBox = eb
end


local function showCsvPopup()
    if not _csvPopup then buildCsvPopup() end
    if not _csvPopup then return end  -- Cairn-Gui not loaded
    if _csvEditBox and _csvEditBox.Cairn then
        _csvEditBox.Cairn:SetText(buildCsv())
    end
    _csvPopup:Show()
    _csvPopup:Raise()
end


-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function build(pane)
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    -- SV-alias upvalue trick: rebind the module-scope _pinned to the
    -- saved-variable table so every _pinned[name] = ... write goes
    -- straight to db.profile.pinned, no per-mutation save call needed.
    -- Defensive init guards against a freshly-created profile that
    -- predates the v2 dbDefaults change.
    if ns.db and ns.db.profile then
        if type(ns.db.profile.pinned) ~= "table" then
            ns.db.profile.pinned = {}
        end
        _pinned = ns.db.profile.pinned
    end

    pane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 10 })

    Gui:Acquire("Label", pane, { text = "Profiler", variant = "heading" })

    Gui:Acquire("Label", pane, {
        text    = "|cff888888Top 5 addons by peak in the last "
                  .. WINDOW_SECONDS .. "s (CPU ms or memory kb). Samples "
                  .. "every " .. SAMPLE_INTERVAL .. "s while this tab is open.|r",
        variant = "muted",
    })

    -- Toolbar: Pause / Reset / status label.
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

    -- Segmented CPU/Memory toggle. Variant swap is the visual cue for
    -- which mode is active; both buttons stay clickable so a user can
    -- bounce between them without arrow-tabbing.
    _modeCpuBtn = Gui:Acquire("Button", toolbar, {
        text = "CPU", variant = "primary", width = 60,
    })
    _modeCpuBtn.Cairn:On("Click", function() setMode("cpu") end)

    _modeMemBtn = Gui:Acquire("Button", toolbar, {
        text = "Memory", variant = "ghost", width = 72,
    })
    _modeMemBtn.Cairn:On("Click", function() setMode("mem") end)

    local exportBtn = Gui:Acquire("Button", toolbar, {
        text = "Export", variant = "ghost", width = 80,
    })
    exportBtn.Cairn:On("Click", showCsvPopup)

    _statusLabel = Gui:Acquire("Label", toolbar, {
        text = "|cff888888sampling...|r", variant = "muted",
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
        text = "|cffffd060CPU profiler disabled.|r Enable to see live samples. Requires /reload.",
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

    -- Y-max readout sits above the chart so users know what the top of
    -- the chart represents at a glance. The unit segment is its own label
    -- so refreshModeButtons can flip "peak ms" <-> "peak kb" without a
    -- rebuild of the whole row.
    local axisRow = Gui:Acquire("Container", pane, { height = 18 })
    axisRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })
    _yMaxUnit = Gui:Acquire("Label", axisRow, {
        text = "|cff888888peak ms:|r", variant = "muted",
    })
    _yMaxLabel = Gui:Acquire("Label", axisRow, { text = formatValue(0) })

    -- Chart canvas. Lines are CreateLine'd on the container's raw Frame.
    _chartContainer = Gui:Acquire("Container", pane, {
        bg          = "color.bg.surface",
        border      = "color.border.default",
        borderWidth = 1,
        height      = CHART_HEIGHT,
    })
    -- Redraw on resize so a window-stretch reshapes the lines instead
    -- of leaving them anchored to the old width.
    _chartContainer:HookScript("OnSizeChanged", function()
        redrawChart()
    end)

    -- Legend: TOP_N addon rows + 1 Total row. Each row has a colored
    -- swatch (raw Texture), the addon name, and current ms reading.
    local legendBox = Gui:Acquire("Container", pane, {
        height = (TOP_N + 1) * 18 + 8,
    })
    legendBox.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 2, padding = 4 })

    for i = 1, TOP_N + 1 do
        local rowC = Gui:Acquire("Container", legendBox, { height = 16 })
        rowC.Cairn:SetLayout("Stack",
            { direction = "horizontal", gap = 6, padding = 0 })
        local swatch = rowC:CreateTexture(nil, "ARTWORK")
        swatch:SetSize(14, 10)
        swatch:SetColorTexture(0.5, 0.5, 0.5, 1.0)
        -- Anchor manually because raw textures aren't laid by Stack.
        swatch:SetPoint("LEFT", rowC, "LEFT", 4, 0)

        local labelInset = Gui:Acquire("Label", rowC, { text = "  " })
        labelInset.Cairn:SetText("    ") -- spacer so the name doesn't kiss the swatch

        local label = Gui:Acquire("Label", rowC, { text = "" })
        local value = Gui:Acquire("Label", rowC, {
            text = "", variant = "muted",
        })

        -- Make addon rows clickable for pin/unpin. Skip the Total row
        -- (index TOP_N+1) because pinning the Total line is meaningless.
        -- Closure captures `i` so the click handler always reads the
        -- current name from _topNames[i] rather than whatever name
        -- happened to be in this slot at build time.
        if i <= TOP_N then
            local idx = i
            rowC:EnableMouse(true)
            rowC:SetScript("OnMouseUp", function(self, button)
                if button ~= "LeftButton" then return end
                local n = _topNames[idx]
                if n then togglePin(n) end
            end)
        end

        _legendRows[i] = {
            container = rowC,
            swatch    = swatch,
            label     = label,
            value     = value,
        }
        rowC:Hide()  -- shown after first tick populates _topNames
    end

    Gui:Acquire("Label", pane, {
        text    = "|cff666666Click a row to pin/unpin "
                  .. "(pinned rows stay visible even when not in the top 5).|r",
        variant = "muted",
    })

    refreshBanner()
    refreshLegend()
    refreshModeButtons()
end


-- ---------------------------------------------------------------------------
-- Tab descriptor
-- ---------------------------------------------------------------------------

ns.descriptor = {
    name        = "Profiler",
    title       = "Profiler",
    order       = 91,
    description = "Live CPU time-series for the top 5 hottest addons.",

    OnTabShow = function(pane, mod)
        if not pane.Cairn._builtOnce then
            pane.Cairn._builtOnce = true
            build(pane)
        else
            refreshBanner()
            refreshLegend()
            redrawChart()
        end
        if C_Timer and C_Timer.NewTicker and not _ticker then
            _ticker = C_Timer.NewTicker(SAMPLE_INTERVAL, tick)
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
    if Forge and Forge.Slash and Forge.Slash.Sub then
        Forge.Slash:Sub("profilerexport", showCsvPopup,
            "open a dialog with the captured CPU+memory samples as CSV")
    end
end

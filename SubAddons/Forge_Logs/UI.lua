-- Forge_Logs.UI: per-source log viewer with virtualized rendering.
--
-- Layout:
--   +-----------+--------------------------------------+
--   | Sources   | [Level] [Search ...] [Copy] [Export] |
--   |  All      +--------------------------------------+
--   |  Cairn    | [time] [LVL] source: message         |
--   |  ...      |   ...                                |
--   +-----------+--------------------------------------+

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H        = 28
local ROW_H            = 16
local PAD              = 6
local SOURCES_W        = 140
local VISIBLE_ROW_BUFFER = 60

-- Cairn.Log gives us level constants/colors.
local Log = Cairn and Cairn.Log
local LEVEL_NAMES  = (Log and Log.LEVEL_NAMES)  or { [1]="ERROR",[2]="WARN",[3]="INFO",[4]="DEBUG",[5]="TRACE" }
local LEVEL_COLORS = (Log and Log.LEVEL_COLORS) or { [1]="FFFF4040",[2]="FFFFAA00",[3]="FFFFFFFF",[4]="FFB0B0B0",[5]="FF888888" }
local LEVELS       = (Log and Log.LEVELS)       or { ERROR=1, WARN=2, INFO=3, DEBUG=4, TRACE=5 }

local _activeMod
local _logUnsub

local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

local function fmtTime(ts)
    if not ts then return "?" end
    if date then return date("%H:%M:%S", ts) end
    return tostring(ts)
end

-- ----- Filtering --------------------------------------------------------
local function getFilteredEntries()
    if not (Log and Log.GetEntries) then return {} end
    local source = ns.GetSelectedSource()
    local minLevel = ns.GetMinLevel()
    local search = (ns.GetSearchText() or ""):lower()
    local entries = Log:GetEntries(function(e)
        if source ~= "All" and e.source ~= source then return false end
        if (e.level or 5) > minLevel then return false end  -- higher number = lower priority
        if search ~= "" then
            if not (e.message and e.message:lower():find(search, 1, true)) then
                return false
            end
        end
        return true
    end)

    -- Apply sort. Cairn.Log:GetEntries returns entries oldest-first (it
    -- walks the ring from bufferHead). With sortMode = "newest", we
    -- reverse so the latest activity is at the top of the list -- the
    -- right default once the ring buffer wraps and old archived entries
    -- would otherwise mask current activity.
    local mode = ns.GetSortMode and ns.GetSortMode() or "newest"
    if mode == "newest" then
        local n = #entries
        for i = 1, math.floor(n / 2) do
            entries[i], entries[n - i + 1] = entries[n - i + 1], entries[i]
        end
    elseif mode == "source" then
        -- Group by source name, newest within each source.
        table.sort(entries, function(a, b)
            local sa, sb = a.source or "", b.source or ""
            if sa ~= sb then return sa < sb end
            return (a.ts or 0) > (b.ts or 0)
        end)
    end
    -- "oldest" -> leave as-is (already oldest-first from GetEntries).

    return entries
end

-- ----- Source discovery -------------------------------------------------
local function getSources()
    local seen = { ["All"] = true }
    local out  = { "All" }
    if Log and Log.loggers then
        for name in pairs(Log.loggers) do
            if not seen[name] then seen[name] = true; out[#out + 1] = name end
        end
    end
    -- Also seed sources from any addon that registered with Cairn.Addon.
    if Cairn and Cairn.Addon and Cairn.Addon.registry then
        for name in pairs(Cairn.Addon.registry) do
            if not seen[name] then seen[name] = true; out[#out + 1] = name end
        end
    end
    table.sort(out, function(a, b)
        if a == "All" then return true end
        if b == "All" then return false end
        return a < b
    end)
    return out
end

-- ----- Build the tab UI -------------------------------------------------
local function buildSourceRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H + 2)

    local sel = row:CreateTexture(nil, "BACKGROUND", nil, -2)
    sel:SetColorTexture(0.85, 0.50, 0.20, 0.35); sel:SetAllPoints(); sel:Hide()
    row._sel = sel

    local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    hov:SetColorTexture(0.45, 0.32, 0.15, 0.30); hov:SetAllPoints(); hov:Hide()
    row._hov = hov

    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", row, "LEFT", 6, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetMaxLines(1)
    row._fs = fs

    row:SetScript("OnEnter", function(self) self._hov:Show() end)
    row:SetScript("OnLeave", function(self) self._hov:Hide() end)
    return row
end

local function buildLogRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    local fs = row:CreateFontString(nil, "OVERLAY", "ChatFontSmall")
    fs:SetPoint("LEFT", row, "LEFT", 4, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetMaxLines(1)
    row._fs = fs
    return row
end

function UI.Build(parent, mod)
    _activeMod = mod
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- Acquire Cairn-Gui-Core once for the whole UI. Falsy if the widget kit
    -- failed to load; each section below has a fallback path.
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    -- ===== Toolbar =====================================================
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  4, -4)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    bar:SetHeight(TOOLBAR_H)

    -- Helper for the four toolbar buttons. Migrated to Cairn-Gui-Core Button
    -- widget; each call returns a frame the next button can SetPoint LEFT-of.
    -- Falls back to UIPanelButtonTemplate if the kit didn't load.
    --
    -- Cairn-Gui Button gotcha: `widget:SetText` writes to the widget's own
    -- FontString (set via SetFontString), so |cff...|r color codes work
    -- exactly like on a UIPanelButtonTemplate.
    local function makeButton(label, w, h, anchorTo, dx)
        local b = Gui and Gui:Create("Button")
        if b then
            b:SetParent(bar)
            b:ClearAllPoints()
            b:SetWidth(w)
            b:SetHeight(h)
            b:SetPoint("LEFT", anchorTo, "RIGHT", dx, 0)
            b:SetText(label)
            return b, b.frame
        end
        local raw = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
        raw:SetSize(w, h)
        raw:SetPoint("LEFT", anchorTo, "RIGHT", dx, 0)
        raw:SetText(label)
        return raw, raw
    end

    -- Helper to subscribe to OnClick across both backends. Widget exposes
    -- FireEvent("OnClick", button, ...); raw frame uses SetScript.
    local function onClick(btn, fn)
        if btn.SetEventListener then
            btn:SetEventListener("OnClick", function(_, _, button)
                fn(button)
            end)
        else
            btn:SetScript("OnClick", function(_, button)
                fn(button)
            end)
        end
    end

    -- Level cycling button: cycles ERROR -> WARN -> INFO -> DEBUG -> TRACE.
    -- This is the only button anchored to bar:LEFT (not RIGHT-of previous);
    -- makeButton hardcodes the chained-right pattern, so we re-anchor here.
    -- ObjectBase passes SetPoint/ClearAllPoints through to the inner frame,
    -- so the same calls work on both widget and raw fallback paths.
    --
    -- We give it a non-empty initial label ("LEVEL") instead of "". On the
    -- Diesal Button, creating with an empty FontString and then SetText'ing
    -- a colored string later was leaving the button completely unrendered
    -- in a real test session -- starting non-empty avoids whatever the
    -- empty-state path is doing.
    local levelBtn, levelFrame = makeButton("LEVEL", 80, 22, bar, 4)
    levelBtn:ClearAllPoints()
    levelBtn:SetPoint("LEFT", bar, "LEFT", 4, 0)
    local function refreshLevelLabel()
        local lvl = ns.GetMinLevel() or 5
        local name = LEVEL_NAMES[lvl] or "?"
        -- LEVEL_COLORS values are already 8-hex AARRGGBB, so use `|c` (not
        -- `|cff`) to avoid double-alpha. Past bug: `|cff`+`FF888888` made the
        -- parser eat 8 hex as color (ffFF8888) and leak the trailing `88` as
        -- displayed text -- the level button rendered as `88TRACE+`.
        levelBtn:SetText("|c" .. (LEVEL_COLORS[lvl] or "ffffffff") .. name .. "+|r")
    end
    onClick(levelBtn, function()
        local lvl = (ns.GetMinLevel() or 5) - 1
        if lvl < 1 then lvl = 5 end
        ns.SetMinLevel(lvl)
        refreshLevelLabel()
        UI.Refresh()
    end)
    refreshLevelLabel()
    mod._levelBtn = levelBtn

    -- Search box. Migrated to Cairn-Gui-Core Input widget. The widget owns
    -- its own background/highlight/outline styling (track-* / editBox-* style
    -- sheet inside Input.lua), so we drop the BackdropTemplate frame and the
    -- explicit FontObject; widget defaults handle both. We keep the hint
    -- FontString as a sibling on `bar` because the widget doesn't expose a
    -- placeholder API.
    --
    -- Notable widget gap: Cairn-Gui Input fires OnEnterPressed/OnEscapePressed
    -- /OnEditFocusGained/OnEditFocusLost via FireEvent, but NOT OnTextChanged.
    -- We hook the inner editBox directly to get live filtering.
    local search = Gui and Gui:Create("Input")
    if search then
        search:SetParent(bar)
        search:ClearAllPoints()
        -- Anchor to levelFrame (the real Frame), not levelBtn (widget table).
        search:SetPoint("LEFT", levelFrame, "RIGHT", 6, 0)
        search:SetWidth(180)
        search:SetHeight(22)
        search:SetText(ns.GetSearchText() or "")

        -- Live filter on every keystroke.
        search.editBox:HookScript("OnTextChanged", function(self)
            ns.SetSearchText(self:GetText() or "")
            UI.Refresh()
        end)
        -- Esc clears the filter and unfocuses (widget already handles
        -- ClearFocus internally on Esc, so we just clear text + refresh).
        search:SetEventListener("OnEscapePressed", function()
            search:SetText("")
            ns.SetSearchText("")
            UI.Refresh()
        end)

        -- Hint FontString lives on the bar (not on the widget) so we can
        -- still toggle it via focus events.
        local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("LEFT", search.frame, "LEFT", 8, 0)
        hint:SetText("Search messages...")
        if (ns.GetSearchText() or "") ~= "" then hint:Hide() end
        search:SetEventListener("OnEditFocusGained", function() hint:Hide() end)
        search:SetEventListener("OnEditFocusLost", function()
            if (search:GetText() or "") == "" then hint:Show() end
        end)

        mod._search    = search
        mod._searchHint = hint
    else
        -- Defensive fallback: Cairn-Gui-Core didn't load. Reconstruct the
        -- old BackdropTemplate + raw EditBox so the toolbar still functions.
        local searchBg = CreateFrame("Frame", nil, bar, "BackdropTemplate")
        searchBg:SetSize(180, 22)
        searchBg:SetPoint("LEFT", levelBtn, "RIGHT", 6, 0)
        searchBg:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        searchBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
        searchBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
        local sf = CreateFrame("EditBox", nil, searchBg)
        sf:SetMultiLine(false); sf:SetAutoFocus(false)
        sf:SetFontObject("ChatFontNormal")
        sf:SetPoint("LEFT", 6, 0); sf:SetPoint("RIGHT", -6, 0); sf:SetHeight(18)
        sf:SetText(ns.GetSearchText() or "")
        sf:SetScript("OnTextChanged", function(self) ns.SetSearchText(self:GetText() or ""); UI.Refresh() end)
        sf:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText(""); ns.SetSearchText(""); UI.Refresh() end)
        local hint = searchBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("LEFT", 8, 0); hint:SetText("Search messages...")
        sf:SetScript("OnEditFocusGained", function() hint:Hide() end)
        sf:SetScript("OnEditFocusLost",  function(self)
            if (self:GetText() or "") == "" then hint:Show() end
        end)
        mod._search = sf
    end
    -- Anchor the rest of the toolbar to whatever the search frame ended up as.
    local searchAnchor = (mod._search and mod._search.frame) or mod._search

    -- Three remaining buttons. Each call returns (widget-or-frame, frame) so
    -- the next button anchors to the previous one's actual frame regardless
    -- of which backend it ended up on.
    local copyBtn, copyFrame     = makeButton("Copy",       60, 22, searchAnchor, 6)
    onClick(copyBtn, function() UI.OpenCopyDialog() end)

    local exportBtn, exportFrame = makeButton("Export CSV", 70, 22, copyFrame,    4)
    onClick(exportBtn, function() UI.ExportCSV() end)

    local clearBtn, clearFrame   = makeButton("Clear",      60, 22, exportFrame,  4)
    onClick(clearBtn, function()
        if Log and Log.Clear then Log:Clear(); UI.Refresh() end
    end)

    -- Sort cycling button. Cycles through Latest first / Oldest first /
    -- By source. Default ("newest") puts the most recent activity at the
    -- top of the list -- the right answer once Cairn.Log's ring buffer
    -- has wrapped (otherwise stale archived entries from prior sessions
    -- would mask current activity at the natural oldest-first iteration
    -- order).
    local SORT_LABELS = {
        newest = "Sort: Latest",
        oldest = "Sort: Oldest",
        source = "Sort: Source",
    }
    local SORT_NEXT = { newest = "oldest", oldest = "source", source = "newest" }
    local sortBtn, sortFrame     = makeButton("Sort: Latest", 100, 22, clearFrame, 4)
    local function refreshSortLabel()
        local m = ns.GetSortMode and ns.GetSortMode() or "newest"
        sortBtn:SetText(SORT_LABELS[m] or SORT_LABELS.newest)
    end
    onClick(sortBtn, function()
        local m = ns.GetSortMode and ns.GetSortMode() or "newest"
        ns.SetSortMode(SORT_NEXT[m] or "newest")
        refreshSortLabel()
        UI.Refresh()
        -- Snap scroll to top so the user actually sees the new ordering.
        if mod._logsScrollFrame and mod._logsScrollFrame.SetVerticalScroll then
            mod._logsScrollFrame:SetVerticalScroll(0)
        end
    end)
    refreshSortLabel()
    mod._sortBtn = sortBtn

    -- Count label on the right edge.
    local countFs = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countFs:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    countFs:SetTextColor(0.85, 0.7, 0.4, 1)
    mod._countFs = countFs

    -- ===== Sources pane (left) =========================================
    local sourcesBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    sourcesBg:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -PAD)
    sourcesBg:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 4)
    sourcesBg:SetWidth(SOURCES_W)
    sourcesBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    sourcesBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    sourcesBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    -- Sources scroll. Migrated to Cairn-Gui-Core ScrollFrame; widget's content
    -- frame is exposed as `mod._sourcesContent` so refreshSources can keep
    -- using the same SetHeight idiom. The ObjectBase.GetWidth pass-through
    -- means `mod._sourcesScroll:GetWidth()` works in both backends.
    local sourcesGui = Gui and Gui:Create("ScrollFrame")
    if sourcesGui then
        sourcesGui:SetParent(sourcesBg)
        sourcesGui:ClearAllPoints()
        sourcesGui:SetPoint("TOPLEFT",     sourcesBg, "TOPLEFT",      6, -6)
        sourcesGui:SetPoint("BOTTOMRIGHT", sourcesBg, "BOTTOMRIGHT", -2,  6)
        mod._sourcesScroll  = sourcesGui
        mod._sourcesContent = sourcesGui.content
    else
        -- Defensive fallback: original UIPanelScrollFrameTemplate path.
        local sourcesScroll = CreateFrame("ScrollFrame", nil, sourcesBg, "UIPanelScrollFrameTemplate")
        sourcesScroll:SetPoint("TOPLEFT", 6, -6)
        sourcesScroll:SetPoint("BOTTOMRIGHT", -22, 6)
        local sourcesContent = CreateFrame("Frame", nil, sourcesScroll)
        sourcesContent:SetSize(1, 1)
        sourcesScroll:SetScrollChild(sourcesContent)
        mod._sourcesScroll  = sourcesScroll
        mod._sourcesContent = sourcesContent
    end
    mod._sourceRows = {}

    -- ===== Logs pane (right, virtualized) =============================
    local logsBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    logsBg:SetPoint("TOPLEFT", sourcesBg, "TOPRIGHT", PAD, 0)
    logsBg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    logsBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    logsBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    logsBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    -- Logs scroll. Migrated to Cairn-Gui-Core ScrollFrame, BUT we keep our
    -- own virtualized row rendering on top of `widget.content` (the kit
    -- doesn't ship a virtualized list and Cairn.Log can hold thousands of
    -- entries). Two handles are stored on `mod`:
    --   _logsScroll      -- the high-level surface (widget OR raw frame)
    --   _logsScrollFrame -- the inner Blizzard ScrollFrame in BOTH paths;
    --                       used for GetVerticalScroll / GetHeight / GetWidth
    --                       / HookScript / UpdateScrollChildRect, all of
    --                       which the widget doesn't expose at the top level.
    local logsGui = Gui and Gui:Create("ScrollFrame")
    if logsGui then
        logsGui:SetParent(logsBg)
        logsGui:ClearAllPoints()
        logsGui:SetPoint("TOPLEFT",     logsBg, "TOPLEFT",      6, -6)
        logsGui:SetPoint("BOTTOMRIGHT", logsBg, "BOTTOMRIGHT", -2,  6)
        mod._logsScroll      = logsGui
        mod._logsScrollFrame = logsGui.scrollFrame
        mod._logsContent     = logsGui.content
    else
        local logsScroll = CreateFrame("ScrollFrame", nil, logsBg, "UIPanelScrollFrameTemplate")
        logsScroll:SetPoint("TOPLEFT", 6, -6)
        logsScroll:SetPoint("BOTTOMRIGHT", -28, 6)
        local logsContent = CreateFrame("Frame", nil, logsScroll)
        logsContent:SetSize(1, 1)
        logsScroll:SetScrollChild(logsContent)
        mod._logsScroll      = logsScroll
        mod._logsScrollFrame = logsScroll
        mod._logsContent     = logsContent
    end
    mod._logRows = {}

    -- HookScript layers on top of the widget's own SetScript handlers so we
    -- don't clobber the kit's scrollbar bookkeeping.
    mod._logsScrollFrame:HookScript("OnVerticalScroll", function() UI.RenderVisibleWindow() end)
    mod._logsScrollFrame:HookScript("OnSizeChanged",    function() UI.RenderVisibleWindow() end)

    -- Subscribe to new log entries so the panel refreshes live.
    if Log and Log.OnNewEntry then
        _logUnsub = Log:OnNewEntry(function() UI.Refresh() end)
    end

    UI.Refresh()
end

-- ----- Source list rendering --------------------------------------------
local function refreshSources()
    local mod = _activeMod
    if not mod then return end
    local sources = getSources()
    local selected = ns.GetSelectedSource() or "All"

    for _, row in ipairs(mod._sourceRows) do row:Hide() end
    local y = 0
    for i, name in ipairs(sources) do
        local row = mod._sourceRows[i]
        if not row then
            row = buildSourceRow(mod._sourcesContent)
            mod._sourceRows[i] = row
        end
        row._name = name
        row._fs:SetText(name == "All" and "|cffd87f3aAll|r" or name)
        if name == selected then row._sel:Show() else row._sel:Hide() end
        row:SetScript("OnClick", function(self)
            ns.SetSelectedSource(self._name)
            UI.Refresh()
        end)
        row:ClearAllPoints()
        row:SetWidth((mod._sourcesScroll:GetWidth() or 120) - 4)
        row:SetPoint("TOPLEFT", mod._sourcesContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + (ROW_H + 2)
    end
    if y < 1 then y = 1 end
    mod._sourcesContent:SetHeight(y)
    -- Only the raw UIPanelScrollFrameTemplate path needs an explicit
    -- UpdateScrollChildRect call. The Cairn-Gui widget reacts to content
    -- height via its OnScrollRangeChanged handler.
    if mod._sourcesScroll.UpdateScrollChildRect then
        mod._sourcesScroll:UpdateScrollChildRect()
    end
end

-- ----- Log row rendering (virtualized) ---------------------------------
local function fmtEntry(e)
    -- LEVEL_COLORS values are 8-hex AARRGGBB, so format as `|c%s` (no extra
    -- `ff`). The grey timestamp prefix needs only RGB so we use `|cffaaaaaa`
    -- there. Past bug: `|cff%s` with an 8-hex color leaked the last 2 hex
    -- as displayed text -- log lines started with `FF[...] INFO`, `00[...]
    -- WARN`, etc.
    local color = LEVEL_COLORS[e.level or 3] or "FFFFFFFF"
    local lvlName = LEVEL_NAMES[e.level or 3] or "?"
    local source = e.source or "?"
    local msg = e.message or ""
    return string.format("|c%s[%s] %s|r |cffaaaaaa%s:|r %s",
        color, fmtTime(e.ts), lvlName, source, escapeBars(msg))
end

function UI.RecomputeVisible()
    local mod = _activeMod
    if not mod then return end
    mod._visible = getFilteredEntries() or {}
end

function UI.RenderVisibleWindow()
    local mod = _activeMod
    if not (mod and mod._logsContent and mod._visible) then return end

    local total = #mod._visible
    mod._logsContent:SetHeight(math.max(1, total * ROW_H))

    -- Use the inner Blizzard ScrollFrame for the low-level reads. Works for
    -- both the widget-backed and raw paths.
    local sf        = mod._logsScrollFrame
    local scrollY   = sf:GetVerticalScroll() or 0
    local viewportH = sf:GetHeight() or 0
    local viewportW = sf:GetWidth() or 0
    local firstIdx  = math.max(1, math.floor(scrollY / ROW_H) + 1)
    local rowsToShow = math.min(
        VISIBLE_ROW_BUFFER,
        math.ceil(viewportH / ROW_H) + 2,
        total - firstIdx + 1
    )

    for _, row in ipairs(mod._logRows) do row:Hide() end

    for i = 1, math.max(0, rowsToShow) do
        local idx = firstIdx + i - 1
        local entry = mod._visible[idx]
        if not entry then break end

        local row = mod._logRows[i]
        if not row then
            row = buildLogRow(mod._logsContent)
            mod._logRows[i] = row
        end
        row._fs:SetText(fmtEntry(entry))
        row:ClearAllPoints()
        row:SetWidth(viewportW - 8)
        row:SetPoint("TOPLEFT", mod._logsContent, "TOPLEFT", 0, -((idx - 1) * ROW_H))
        row:Show()
    end

    -- UpdateScrollChildRect is a Blizzard ScrollFrame method; safe on both
    -- paths since `_logsScrollFrame` is always a real ScrollFrame.
    sf:UpdateScrollChildRect()
    if mod._countFs then
        mod._countFs:SetText(string.format("%d entries", total))
    end
end

function UI.Refresh()
    refreshSources()
    UI.RecomputeVisible()
    UI.RenderVisibleWindow()
end

function UI.OnTabShow(mod)
    _activeMod = mod
    UI.Refresh()
end

-- ----- Copy / Export ---------------------------------------------------
local function buildLogText()
    local entries = getFilteredEntries() or {}
    local lines = {}
    for _, e in ipairs(entries) do
        lines[#lines + 1] = string.format("[%s] %s %s: %s",
            fmtTime(e.ts), LEVEL_NAMES[e.level or 3] or "?", e.source or "?", e.message or "")
    end
    return table.concat(lines, "\n")
end

local function buildCSV()
    local entries = getFilteredEntries() or {}
    local lines = { '"timestamp","level","source","message"' }
    for _, e in ipairs(entries) do
        local msg = (e.message or ""):gsub('"', '""')
        lines[#lines + 1] = string.format('"%s","%s","%s","%s"',
            fmtTime(e.ts), LEVEL_NAMES[e.level or 3] or "?", e.source or "?", msg)
    end
    return table.concat(lines, "\n")
end

function UI.OpenCopyDialog()
    local text = buildLogText()
    if Forge and Forge.ShowCopyDialog then
        Forge.ShowCopyDialog("Forge Logs - " .. (ns.GetSelectedSource() or "All"), text,
            "Ctrl-A to select all, Ctrl-C to copy.")
    end
end

function UI.ExportCSV()
    local text = buildCSV()
    if Forge and Forge.ShowCopyDialog then
        Forge.ShowCopyDialog("Forge Logs CSV - " .. (ns.GetSelectedSource() or "All"), text,
            "Ctrl-A to select all, Ctrl-C to copy. Save as .csv to open in Excel/Sheets.")
    end
end

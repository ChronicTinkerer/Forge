-- Forge_CairnInspect.UI: the entire visualization surface in one file.
--
-- Layout (top to bottom):
--   Toolbar:   [Refresh] [Pause] [DevToggle] [Search:____]
--   Body row:  Tree (left ~40%) | Detail / Dump panel (right ~60%)
--   Stats:     live counters from Stats:Snapshot, refreshed on timer
--   EventLog:  scrolling list of recent events from EventLog:Tail
--
-- Refresh model:
--   A single OnUpdate ticker drives all live panels. Interval comes from
--   `statsRefreshSec` in the saved profile. Pausing freezes the
--   accumulator without disabling the ticker (so unpause picks up
--   immediately on the next interval).
--
-- Selection model:
--   `mod._selected` holds the currently selected widget.Cairn. Tree
--   rows highlight the selected entry. The detail panel shows that
--   widget's :Dump() output. Click-to-highlight on screen is wired via
--   a transient tan tint texture parented to the selected widget's
--   frame; the tint shows for 0.6s after selection then fades.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H    = 28
local STATS_H      = 96
local EVENTLOG_H   = 200
local PAD          = 6
local TREE_FRAC    = 0.40
local ROW_H        = 18
local BTN_W        = 70
local BTN_H        = 22
local SEARCH_W     = 160
local DETAIL_LINE_H = 16

local _activeMod  -- module instance from the Forge tab system

-- ----- Helpers ----------------------------------------------------------

local function trim(s) return (tostring(s or "")):match("^%s*(.-)%s*$") or "" end
local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

-- Best-effort getter for the Cairn-Gui-2.0 Core. Tolerant of pre-load
-- timing so :Build can render an empty UI even if Cairn-Gui hasn't
-- loaded yet.
local function getCore()
    return LibStub and LibStub("Cairn-Gui-2.0", true)
end

-- Turn a plain table into a sorted list of "key  value" lines, suitable
-- for the detail (Dump) panel. Returns an array of strings.
local function flattenForDisplay(t, indent)
    indent = indent or ""
    local out = {}
    if type(t) ~= "table" then
        out[1] = indent .. tostring(t)
        return out
    end
    -- Sort keys for stable output. String keys first, then numeric.
    local strKeys, numKeys = {}, {}
    for k in pairs(t) do
        if type(k) == "string" then strKeys[#strKeys + 1] = k
        else                         numKeys[#numKeys + 1] = k end
    end
    table.sort(strKeys)
    table.sort(numKeys)
    for _, k in ipairs(strKeys) do
        local v = t[k]
        if type(v) == "table" then
            out[#out + 1] = indent .. tostring(k) .. " = {"
            local sub = flattenForDisplay(v, indent .. "  ")
            for _, line in ipairs(sub) do out[#out + 1] = line end
            out[#out + 1] = indent .. "}"
        else
            out[#out + 1] = indent .. tostring(k) .. " = " .. tostring(v)
        end
    end
    for _, k in ipairs(numKeys) do
        local v = t[k]
        out[#out + 1] = indent .. "[" .. tostring(k) .. "] = " .. tostring(v)
    end
    return out
end

-- ----- Tree data --------------------------------------------------------
-- Build a flat list of {cairn, depth, type} entries by walking the
-- Inspector. Filtered by mod._treeFilter (substring match on _type).

local function buildTreeRows(mod)
    local Core = getCore()
    if not (Core and Core.Inspector) then return {} end
    local rows = {}
    local filter = (mod and mod._treeFilter or ""):lower()
    Core.Inspector:WalkAll(function(cairn, depth)
        local typeName = tostring(cairn._type or "?")
        if filter == "" or typeName:lower():find(filter, 1, true) then
            rows[#rows + 1] = { cairn = cairn, depth = depth, type = typeName }
        end
    end)
    return rows
end

-- ----- Highlight overlay ------------------------------------------------
-- Quick tan tint on the selected widget's frame. Fades after a short
-- window so the user can find the widget visually without leaving a
-- permanent overlay. Reuses one texture; not pooled per widget.

local function flashHighlight(cairn)
    if not (cairn and cairn._frame) then return end
    local frame = cairn._frame
    if not _activeMod then return end
    if not _activeMod._highlightTex then
        local tex = frame:CreateTexture(nil, "OVERLAY")
        tex:SetTexture("Interface\\Buttons\\WHITE8x8")
        tex:SetVertexColor(0.85, 0.50, 0.20, 0.45)
        tex:SetAllPoints(frame)
        _activeMod._highlightTex = tex
    else
        local tex = _activeMod._highlightTex
        tex:SetParent(frame)
        tex:ClearAllPoints()
        tex:SetAllPoints(frame)
        tex:Show()
    end
    -- Fade out after 0.6s. Use C_Timer.After if available.
    if C_Timer and C_Timer.After then
        C_Timer.After(0.6, function()
            if _activeMod and _activeMod._highlightTex then
                _activeMod._highlightTex:Hide()
            end
        end)
    end
end

-- ----- Toolbar ----------------------------------------------------------

local function buildToolbar(parent, mod)
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetPoint("TOPLEFT",  parent, "TOPLEFT",  PAD, -PAD)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD, -PAD)
    bar:SetHeight(TOOLBAR_H)
    mod._toolbar = bar

    local function makeBtn(label, w, onClick)
        local b
        if Gui then
            b = Gui:Create("Button")
            b:SetParent(bar); b:ClearAllPoints()
            b:SetWidth(w); b:SetHeight(BTN_H); b:SetText(label)
            if onClick then b:SetEventListener("OnClick", function() onClick() end) end
            return b, b.frame
        else
            local raw = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
            raw:SetSize(w, BTN_H); raw:SetText(label)
            if onClick then raw:SetScript("OnClick", onClick) end
            return raw, raw
        end
    end

    -- Refresh: forces tree + stats + eventlog pull.
    local refreshW, refreshFrame = makeBtn("Refresh", BTN_W, function() UI.RefreshAll(mod) end)
    refreshW:ClearAllPoints()
    refreshW:SetPoint("LEFT", bar, "LEFT", 0, 0)

    -- Pause: freezes the auto-refresh ticker. Stats and EventLog stop
    -- updating; tree stays as-is. Click again to resume.
    local pauseW, pauseFrame = makeBtn("Pause", BTN_W, function()
        ns.db.profile.statsPaused    = not ns.db.profile.statsPaused
        ns.db.profile.eventLogPaused = ns.db.profile.statsPaused  -- shared toggle
        UI.RefreshToolbarLabels(mod)
    end)
    pauseW:ClearAllPoints()
    pauseW:SetPoint("LEFT", refreshFrame, "RIGHT", 4, 0)
    mod._pauseBtn = pauseW

    -- Dev toggle: flips Cairn.DevAPI on/off.
    local devW, devFrame = makeBtn("Dev: off", BTN_W + 16, function()
        local Core = getCore()
        if Core and Core.DevAPI then
            Core.DevAPI:Toggle()
            UI.RefreshToolbarLabels(mod)
        end
    end)
    devW:ClearAllPoints()
    devW:SetPoint("LEFT", pauseFrame, "RIGHT", 4, 0)
    mod._devBtn = devW

    -- Fake combat toggle (Decision 8): flips Cairn.Gui.Combat fake-combat
    -- flag so the combat queue treats us as in-combat. Lets consumers
    -- test the queue / drain path without actually getting into a fight.
    local fcW, fcFrame = makeBtn("Fake Combat: off", BTN_W + 56, function()
        local Core = getCore()
        if Core and Core.Combat then
            Core.Combat:SetFakeCombat(not Core.Combat:IsFakeCombat())
            UI.RefreshToolbarLabels(mod)
        end
    end)
    fcW:ClearAllPoints()
    fcW:SetPoint("LEFT", devFrame, "RIGHT", 4, 0)
    mod._fakeCombatBtn = fcW

    -- Subscribe to Dev changes so the label stays in sync if some other
    -- code (slash command, Forge_Console snippet) toggles it.
    local Core = getCore()
    if Core and Core.DevAPI and Core.DevAPI.OnChange then
        mod._devUnsub = Core.DevAPI:OnChange(function() UI.RefreshToolbarLabels(mod) end)
    end

    -- Search: filters tree rows by widget type substring. Live as you type.
    local searchLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetText("Search:")
    searchLabel:SetPoint("LEFT", fcFrame, "RIGHT", 12, 0)

    local search = CreateFrame("EditBox", nil, bar, "InputBoxTemplate")
    search:SetSize(SEARCH_W, BTN_H - 4)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    search:SetAutoFocus(false)
    search:SetFontObject("ChatFontNormal")
    search:SetText(ns.db.profile.treeFilter or "")
    search:SetScript("OnTextChanged", function(self)
        ns.db.profile.treeFilter = self:GetText() or ""
        mod._treeFilter = ns.db.profile.treeFilter
        UI.RefreshTree(mod)
    end)
    search:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    mod._searchInput = search

    UI.RefreshToolbarLabels(mod)
end

function UI.RefreshToolbarLabels(mod)
    if mod._pauseBtn then
        local label = ns.db.profile.statsPaused and "Resume" or "Pause"
        if mod._pauseBtn.SetText then mod._pauseBtn:SetText(label) end
    end
    if mod._devBtn then
        local Core = getCore()
        local on = Core and Core.DevAPI and Core.DevAPI:IsEnabled()
        local label = "Dev: " .. (on and "ON" or "off")
        if mod._devBtn.SetText then mod._devBtn:SetText(label) end
    end
    if mod._fakeCombatBtn then
        local Core = getCore()
        local on = Core and Core.Combat and Core.Combat:IsFakeCombat()
        local label = "Fake Combat: " .. (on and "ON" or "off")
        if mod._fakeCombatBtn.SetText then mod._fakeCombatBtn:SetText(label) end
    end
end

-- ----- Tree pane --------------------------------------------------------

local function buildTreePane(parent, mod)
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    mod._treeBg = bg

    local scroll, content
    if Gui then
        scroll = Gui:Create("ScrollFrame")
        scroll:SetParent(bg); scroll:ClearAllPoints()
        scroll:SetPoint("TOPLEFT",     bg, "TOPLEFT",      6, -6)
        scroll:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -2,  6)
        content = scroll.content
        mod._treeScroll = scroll
        mod._treeScrollFrame = scroll.scrollFrame or scroll
    else
        scroll = CreateFrame("ScrollFrame", nil, bg, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",     6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -28, 6)
        content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1)
        scroll:SetScrollChild(content)
        mod._treeScroll = scroll
        mod._treeScrollFrame = scroll
    end
    mod._treeContent = content
    mod._treeRows    = {}
end

local function renderTreeRow(parent, index, entry, mod)
    local row = parent._rows and parent._rows[index]
    if not row then
        row = CreateFrame("Button", nil, parent)
        row:SetHeight(ROW_H)
        row:RegisterForClicks("LeftButtonUp")

        local sel = row:CreateTexture(nil, "BACKGROUND", nil, -2)
        sel:SetColorTexture(0.85, 0.50, 0.20, 0.30)
        sel:SetAllPoints()
        sel:Hide()
        row._sel = sel

        local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
        hov:SetColorTexture(0.45, 0.32, 0.15, 0.25)
        hov:SetAllPoints()
        hov:Hide()
        row._hov = hov

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT",  row, "LEFT",  6, 0)
        text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        text:SetMaxLines(1)
        row._text = text

        row:SetScript("OnEnter", function(self) self._hov:Show() end)
        row:SetScript("OnLeave", function(self) self._hov:Hide() end)
        parent._rows = parent._rows or {}
        parent._rows[index] = row
    end
    return row
end

function UI.RefreshTree(mod)
    if not (mod and mod._treeContent) then return end
    local content = mod._treeContent
    local rows = buildTreeRows(mod)
    mod._treeRowsData = rows

    -- Hide rows beyond the new row count (pool reuse).
    if content._rows then
        for i = #rows + 1, #content._rows do
            content._rows[i]:Hide()
        end
    end

    local y = 0
    for i, entry in ipairs(rows) do
        local row = renderTreeRow(content, i, entry, mod)
        local indent = string.rep("  ", entry.depth)
        local marker = (mod._selected == entry.cairn) and "|cffd87f3a* |r" or "  "
        row._text:SetText(marker .. indent .. entry.type)
        row._sel:SetShown(mod._selected == entry.cairn)
        row._cairn = entry.cairn

        row:SetScript("OnClick", function(self)
            mod._selected = self._cairn
            UI.RefreshTree(mod)
            UI.RefreshDetail(mod)
            flashHighlight(self._cairn)
        end)

        row:ClearAllPoints()
        local sf = mod._treeScrollFrame or mod._treeScroll
        local w = (sf and sf.GetWidth and sf:GetWidth() or 200) - 24
        row:SetWidth(w)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        row:Show()
        y = y + ROW_H
    end
    if y < 1 then y = 1 end
    content:SetHeight(y)
    if mod._treeScrollFrame and mod._treeScrollFrame.UpdateScrollChildRect then
        mod._treeScrollFrame:UpdateScrollChildRect()
    end
end

-- ----- Detail (Dump) pane ----------------------------------------------

local function buildDetailPane(parent, mod)
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    mod._detailBg = bg

    local scroll, content
    if Gui then
        scroll = Gui:Create("ScrollFrame")
        scroll:SetParent(bg); scroll:ClearAllPoints()
        scroll:SetPoint("TOPLEFT",     bg, "TOPLEFT",      6, -6)
        scroll:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -2,  6)
        content = scroll.content
        mod._detailScroll      = scroll
        mod._detailScrollFrame = scroll.scrollFrame or scroll
    else
        scroll = CreateFrame("ScrollFrame", nil, bg, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",     6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -28, 6)
        content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1)
        scroll:SetScrollChild(content)
        mod._detailScroll      = scroll
        mod._detailScrollFrame = scroll
    end
    mod._detailContent = content

    local text = content:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    text:SetJustifyH("LEFT"); text:SetJustifyV("TOP")
    text:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -4)
    text:SetWordWrap(false)
    text:SetText("(select a widget in the tree)")
    mod._detailText = text
end

function UI.RefreshDetail(mod)
    if not mod._detailText then return end
    local cairn = mod._selected
    if not cairn then
        mod._detailText:SetText("|cffaaaaaa(select a widget in the tree)|r")
    else
        local dump = (cairn.Dump and cairn:Dump()) or { _err = "no Dump method" }
        local lines = flattenForDisplay(dump)
        local header = string.format("|cffd87f3a%s|r", tostring(cairn._type or "?"))
        table.insert(lines, 1, header)
        mod._detailText:SetText(table.concat(lines, "\n"))
    end
    -- Update content height for scroll range.
    local sf = mod._detailScrollFrame
    local w = (sf and sf.GetWidth and sf:GetWidth() or 300) - 8
    mod._detailText:SetWidth(math.max(1, w))
    local h = (mod._detailText:GetStringHeight() or 0) + 8
    mod._detailContent:SetSize(math.max(1, w), math.max(1, h))
    if sf and sf.UpdateScrollChildRect then sf:UpdateScrollChildRect() end
end

-- ----- Stats pane -------------------------------------------------------

local function buildStatsPane(parent, mod)
    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    mod._statsBg = bg

    local text = bg:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    text:SetJustifyH("LEFT"); text:SetJustifyV("TOP")
    text:SetPoint("TOPLEFT", bg, "TOPLEFT", 8, -6)
    text:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -8, 6)
    text:SetWordWrap(true)
    mod._statsText = text
end

function UI.RefreshStats(mod)
    if not mod._statsText then return end
    local Core = getCore()
    if not (Core and Core.Stats) then
        mod._statsText:SetText("|cffaaaaaa(Cairn.Stats not loaded)|r")
        return
    end
    local s = Core.Stats:Snapshot()
    local lines = {
        string.format("|cffd87f3aAnimations|r  added: %d   completed: %d   active: %d",
            s.animations.added, s.animations.completed, s.animations.active),
        string.format("|cffd87f3aLayout|r       recomputes: %d", s.layout.recomputes),
        string.format("|cffd87f3aPrimitives|r   rect: %d   border: %d   icon: %d",
            s.primitives.rect.draws, s.primitives.border.draws, s.primitives.icon.draws),
        string.format("|cffd87f3aEvents|r       dispatches: %d", s.events.dispatches),
        string.format("|cffd87f3aPool|r         total in pool: %d", s.pool._total or 0),
        string.format("|cffd87f3aEventLog|r     %s   %d / %d entries",
            s.eventLog.enabled and "|cff55ff55on|r" or "|cffff5555off|r",
            s.eventLog.count, s.eventLog.capacity),
    }
    mod._statsText:SetText(table.concat(lines, "\n"))
end

-- ----- EventLog pane ----------------------------------------------------

local function buildEventLogPane(parent, mod)
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    mod._eventLogBg = bg

    -- Mini-toolbar inside the EventLog pane: filter input + buttons.
    local subbar = CreateFrame("Frame", nil, bg)
    subbar:SetPoint("TOPLEFT",  bg, "TOPLEFT",   6, -6)
    subbar:SetPoint("TOPRIGHT", bg, "TOPRIGHT", -6, -6)
    subbar:SetHeight(BTN_H)

    local filterLabel = subbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("LEFT", subbar, "LEFT", 0, 0)
    filterLabel:SetText("Events:")

    local filter = CreateFrame("EditBox", nil, subbar, "InputBoxTemplate")
    filter:SetSize(160, BTN_H - 4)
    filter:SetPoint("LEFT", filterLabel, "RIGHT", 8, 0)
    filter:SetAutoFocus(false)
    filter:SetFontObject("ChatFontNormal")
    filter:SetText(ns.db.profile.eventLogFilter or "")
    filter:SetScript("OnTextChanged", function(self)
        ns.db.profile.eventLogFilter = self:GetText() or ""
        UI.RefreshEventLog(mod)
    end)
    filter:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

    local function makeMiniBtn(label, onClick)
        local raw = CreateFrame("Button", nil, subbar, "UIPanelButtonTemplate")
        raw:SetSize(60, BTN_H); raw:SetText(label)
        if onClick then raw:SetScript("OnClick", onClick) end
        return raw
    end
    local enableBtn = makeMiniBtn("Enable", function()
        local Core = getCore()
        if not (Core and Core.EventLog) then return end
        if Core.EventLog:IsEnabled() then Core.EventLog:Disable()
        else                              Core.EventLog:Enable() end
        UI.RefreshEventLogToolbar(mod)
    end)
    enableBtn:SetPoint("RIGHT", subbar, "RIGHT", 0, 0)
    mod._eventEnableBtn = enableBtn

    local clearBtn = makeMiniBtn("Clear", function()
        local Core = getCore()
        if Core and Core.EventLog then Core.EventLog:Clear() end
        UI.RefreshEventLog(mod)
    end)
    clearBtn:SetPoint("RIGHT", enableBtn, "LEFT", -4, 0)

    -- Scrolling list area below the sub-toolbar.
    local scroll, content
    if Gui then
        scroll = Gui:Create("ScrollFrame")
        scroll:SetParent(bg); scroll:ClearAllPoints()
        scroll:SetPoint("TOPLEFT",     subbar, "BOTTOMLEFT",  0,  -4)
        scroll:SetPoint("BOTTOMRIGHT", bg,     "BOTTOMRIGHT", -2,  6)
        content = scroll.content
        mod._eventScroll      = scroll
        mod._eventScrollFrame = scroll.scrollFrame or scroll
    else
        scroll = CreateFrame("ScrollFrame", nil, bg, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",     subbar, "BOTTOMLEFT", 0, -4)
        scroll:SetPoint("BOTTOMRIGHT", -28, 6)
        content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1)
        scroll:SetScrollChild(content)
        mod._eventScroll      = scroll
        mod._eventScrollFrame = scroll
    end
    mod._eventContent = content

    local text = content:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    text:SetJustifyH("LEFT"); text:SetJustifyV("TOP")
    text:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -4)
    text:SetWordWrap(false)
    mod._eventText = text

    UI.RefreshEventLogToolbar(mod)
end

function UI.RefreshEventLogToolbar(mod)
    if not mod._eventEnableBtn then return end
    local Core = getCore()
    local on = Core and Core.EventLog and Core.EventLog:IsEnabled()
    mod._eventEnableBtn:SetText(on and "Disable" or "Enable")
end

function UI.RefreshEventLog(mod)
    if not mod._eventText then return end
    local Core = getCore()
    if not (Core and Core.EventLog) then
        mod._eventText:SetText("|cffaaaaaa(Cairn.EventLog not loaded)|r")
        return
    end
    local entries = Core.EventLog:Tail(200)
    local filter = (ns.db.profile.eventLogFilter or ""):lower()

    local lines = {}
    for _, e in ipairs(entries) do
        local label = string.format("%s:%s", e.widgetType or "?", e.event or "?")
        if filter == "" or label:lower():find(filter, 1, true) then
            lines[#lines + 1] = string.format(
                "|cffaaaaaa%6.2f|r  |cffd87f3a%-14s|r %-22s |cff7f7f7f(%d args)|r",
                e.t or 0, escapeBars(e.widgetType or "?"), escapeBars(e.event or "?"),
                e.argCount or 0)
        end
    end
    if #lines == 0 then
        mod._eventText:SetText("|cffaaaaaa(no entries; enable EventLog and trigger some events)|r")
    else
        mod._eventText:SetText(table.concat(lines, "\n"))
    end

    -- Update content size + auto-scroll to bottom (when not paused).
    local sf = mod._eventScrollFrame
    local w = (sf and sf.GetWidth and sf:GetWidth() or 400) - 8
    mod._eventText:SetWidth(math.max(1, w))
    local h = (mod._eventText:GetStringHeight() or 0) + 8
    mod._eventContent:SetSize(math.max(1, w), math.max(1, h))
    if sf and sf.UpdateScrollChildRect then sf:UpdateScrollChildRect() end
    if sf and sf.SetVerticalScroll and not ns.db.profile.eventLogPaused then
        sf:SetVerticalScroll(sf:GetVerticalScrollRange() or 0)
    end
end

-- ----- Refresh orchestration --------------------------------------------

function UI.RefreshAll(mod)
    UI.RefreshTree(mod)
    UI.RefreshDetail(mod)
    UI.RefreshStats(mod)
    UI.RefreshEventLog(mod)
    UI.RefreshToolbarLabels(mod)
end

-- Single OnUpdate ticker drives all live panels. Tree is NOT refreshed
-- on the timer (it's structural; refresh is explicit via Refresh button
-- or after a flashHighlight). Stats and EventLog refresh per interval
-- when not paused.

local function buildRefreshTicker(parent, mod)
    if mod._ticker then return end
    local f = CreateFrame("Frame", nil, parent)
    local accum = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        if not mod._frame or not mod._frame:IsShown() then return end
        accum = accum + elapsed
        local interval = ns.db.profile.statsRefreshSec or 0.5
        if accum < interval then return end
        accum = 0
        if not ns.db.profile.statsPaused then
            UI.RefreshStats(mod)
        end
        if not ns.db.profile.eventLogPaused then
            UI.RefreshEventLog(mod)
        end
    end)
    mod._ticker = f
end

-- ----- Layout: stitch all panels together ------------------------------
-- Heights are absolute for stats + eventlog; the tree+detail row stretches
-- to fill the remaining vertical space.

local function placePanels(parent, mod)
    local toolbar    = mod._toolbar
    local treeBg     = mod._treeBg
    local detailBg   = mod._detailBg
    local statsBg    = mod._statsBg
    local eventLogBg = mod._eventLogBg
    if not (toolbar and treeBg and detailBg and statsBg and eventLogBg) then return end

    -- Stats pinned to where? Above EventLog. EventLog pinned to bottom.
    eventLogBg:ClearAllPoints()
    eventLogBg:SetPoint("BOTTOMLEFT",  parent, "BOTTOMLEFT",  PAD,  PAD)
    eventLogBg:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD, PAD)
    eventLogBg:SetHeight(EVENTLOG_H)

    statsBg:ClearAllPoints()
    statsBg:SetPoint("BOTTOMLEFT",  eventLogBg, "TOPLEFT",   0, PAD)
    statsBg:SetPoint("BOTTOMRIGHT", eventLogBg, "TOPRIGHT",  0, PAD)
    statsBg:SetHeight(STATS_H)

    -- Tree: from below toolbar to above stats; left ~40% width.
    treeBg:ClearAllPoints()
    treeBg:SetPoint("TOPLEFT",    toolbar, "BOTTOMLEFT", 0, -PAD)
    treeBg:SetPoint("BOTTOMLEFT", statsBg, "TOPLEFT",    0,  PAD)
    -- Width set as fraction of parent; computed once + reflowed if parent resizes.
    local function reflowTreeWidth()
        local pw = parent:GetWidth() or 800
        treeBg:SetWidth(math.max(120, (pw - 2 * PAD) * TREE_FRAC))
    end
    parent:HookScript("OnSizeChanged", reflowTreeWidth)
    reflowTreeWidth()

    -- Detail: from below toolbar to above stats; sits to the right of tree.
    detailBg:ClearAllPoints()
    detailBg:SetPoint("TOPLEFT",     treeBg, "TOPRIGHT",    PAD, 0)
    detailBg:SetPoint("BOTTOMRIGHT", statsBg, "TOPRIGHT",   0,   PAD)
end

-- ----- Build / OnTabShow / OnTabHide -----------------------------------

function UI.Build(parent, mod)
    _activeMod = mod

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- Initial filter values from saved profile.
    mod._treeFilter = ns.db.profile.treeFilter or ""

    buildToolbar(frame, mod)
    buildTreePane(frame, mod)
    buildDetailPane(frame, mod)
    buildStatsPane(frame, mod)
    buildEventLogPane(frame, mod)
    placePanels(frame, mod)
    buildRefreshTicker(frame, mod)

    -- Auto-enable the EventLog on first build so the user sees data
    -- immediately. Configurable via ns.db.profile.autoEnableLog.
    if ns.db.profile.autoEnableLog then
        local Core = getCore()
        if Core and Core.EventLog and not Core.EventLog:IsEnabled() then
            Core.EventLog:Enable()
        end
    end

    UI.RefreshAll(mod)
end

function UI.OnTabShow(mod)
    _activeMod = mod
    UI.RefreshAll(mod)
end

function UI.OnTabHide(mod)
    -- Nothing to clean up actively. The ticker self-suspends because its
    -- script bails when mod._frame is hidden.
end

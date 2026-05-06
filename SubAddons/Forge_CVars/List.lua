-- Forge_CVars.List: virtualized scroll list for the ~3000-row CVar table.
--
-- C_Console returns thousands of entries. Per `wow_script_execution_limit`
-- we cannot materialize them all as live frames at once, so List uses a row
-- pool sized to (visible rows + buffer). Pool rows are repositioned and
-- repainted as the user scrolls.
--
-- The scroll itself uses `Cairn-Gui-Core-1.0` `ScrollFrame` (with a
-- `UIPanelScrollFrameTemplate` fallback for when the kit isn't loaded).
-- Per-row Edit / Reset / Copy buttons use `Cairn-Gui-Core-1.0` `Button`
-- (with a `UIPanelButtonTemplate` fallback). The row container itself is
-- a plain `Frame` since Cairn-Gui doesn't define a "row" widget — same
-- pattern Forge_AddonManager uses for its addon-list rows.
--
-- Public API:
--   ns.List.Build(parent)            -- builds the frame as a child of `parent`
--   ns.List.SetData(filteredIndices) -- swaps the data source
--   ns.List.Refresh()                -- re-paint visible rows
--   ns.List.GetFrame()               -- returns the underlying scrollFrame
--   ns.List.SetCallbacks({onEdit, onReset, onCopy})

local ADDON, ns = ...

local List = {}
ns.List = List

-- Layout constants.
local ROW_HEIGHT       = 22
local POOL_BUFFER      = 4
local COL_RISK_W       = 14
local COL_NAME_F       = 0.36
local COL_CUR_F        = 0.16
local COL_DEF_F        = 0.16
local COL_TYPE_F       = 0.10
local COL_BTN_W        = 50

-- Internal state.
local _scrollWidget          -- Cairn-Gui ScrollFrame widget OR raw fallback
local _scrollFrame           -- the underlying Blizzard ScrollFrame
local _content               -- the content frame (scrollWidget.content or raw)
local _rowPool         = {}
local _dataIndices     = {}
local _onEditClicked
local _onResetClicked
local _onCopyClicked

-- --------------------------------------------------------------------------
-- Row factory. The row Frame is a positioning container; the action
-- buttons inside use Cairn-Gui Button.
-- --------------------------------------------------------------------------
local function buildRow(parent)
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:EnableMouse(true)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    row._bg = bg

    -- Risk "!" indicator. Per `wow_color_escape_format` we use `|cff` + 6 hex.
    local risk = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    risk:SetPoint("LEFT", row, "LEFT", 4, 0)
    risk:SetWidth(COL_RISK_W)
    risk:SetJustifyH("CENTER")
    risk:SetText("|cffff8c00!|r")
    risk:Hide()
    row._risk = risk

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetJustifyH("LEFT"); name:SetWordWrap(false)
    row._name = name

    local cur = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cur:SetJustifyH("LEFT"); cur:SetWordWrap(false)
    row._current = cur

    local def = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    def:SetJustifyH("LEFT"); def:SetWordWrap(false)
    row._default = def

    local typ = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    typ:SetJustifyH("LEFT"); typ:SetWordWrap(false)
    row._type = typ

    -- Action buttons. Cairn-Gui Button when available, raw fallback otherwise.
    local function makeRowBtn(label, onClick)
        local widget = Gui and Gui:Create("Button")
        if widget then
            widget:SetParent(row); widget:ClearAllPoints()
            widget:SetWidth(COL_BTN_W); widget:SetHeight(ROW_HEIGHT - 4)
            widget:SetText(label)
            widget:SetEventListener("OnClick", onClick)
            return widget, widget.frame
        else
            local raw = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            raw:SetSize(COL_BTN_W, ROW_HEIGHT - 4)
            raw:SetText(label)
            raw:SetScript("OnClick", function() onClick() end)
            return raw, raw
        end
    end

    local editW, editF = makeRowBtn("Edit", function()
        if _onEditClicked and row._cvarName then _onEditClicked(row._cvarName, row) end
    end)
    local resetW, resetF = makeRowBtn("Reset", function()
        if _onResetClicked and row._cvarName then _onResetClicked(row._cvarName, row) end
    end)
    local copyW, copyF = makeRowBtn("Copy", function()
        if _onCopyClicked and row._cvarName then _onCopyClicked(row._cvarName, row) end
    end)
    row._editBtn,  row._editFrame  = editW,  editF
    row._resetBtn, row._resetFrame = resetW, resetF
    row._copyBtn,  row._copyFrame  = copyW,  copyF

    return row
end

-- --------------------------------------------------------------------------
-- Position + size every region inside the row given the current row width.
-- Per `cairn_gui_widget_as_anchor`, button SetPoint targets are the
-- underlying frames (.frame) when the widget is Cairn, else the raw frame.
-- --------------------------------------------------------------------------
local function layoutRow(row, rowWidth)
    local nameW = math.floor(rowWidth * COL_NAME_F)
    local curW  = math.floor(rowWidth * COL_CUR_F)
    local defW  = math.floor(rowWidth * COL_DEF_F)
    local typW  = math.floor(rowWidth * COL_TYPE_F)
    local x = COL_RISK_W + 6

    row._name:ClearAllPoints();    row._name:SetPoint("LEFT", row, "LEFT", x, 0); row._name:SetWidth(nameW); x = x + nameW + 6
    row._current:ClearAllPoints(); row._current:SetPoint("LEFT", row, "LEFT", x, 0); row._current:SetWidth(curW); x = x + curW + 6
    row._default:ClearAllPoints(); row._default:SetPoint("LEFT", row, "LEFT", x, 0); row._default:SetWidth(defW); x = x + defW + 6
    row._type:ClearAllPoints();    row._type:SetPoint("LEFT", row, "LEFT", x, 0); row._type:SetWidth(typW); x = x + typW + 6

    -- Buttons pinned to the right side: Copy, Reset, Edit (right-to-left).
    local rx = -4
    row._copyFrame:ClearAllPoints();  row._copyFrame:SetPoint("RIGHT", row, "RIGHT", rx, 0); rx = rx - COL_BTN_W - 4
    row._resetFrame:ClearAllPoints(); row._resetFrame:SetPoint("RIGHT", row, "RIGHT", rx, 0); rx = rx - COL_BTN_W - 4
    row._editFrame:ClearAllPoints();  row._editFrame:SetPoint("RIGHT", row, "RIGHT", rx, 0)
end

-- --------------------------------------------------------------------------
-- Paint a row from a snapshot entry index.
-- --------------------------------------------------------------------------
local function paintRow(row, dataIdx)
    local snapshotIdx = _dataIndices[dataIdx]
    if not snapshotIdx then row:Hide(); return end
    local entry = ns.Snapshot and ns.Snapshot.GetAll()[snapshotIdx] or nil
    if not entry then row:Hide(); return end

    row._cvarName = entry.name
    row._name:SetText(entry.name)

    local cur = ns.Snapshot.GetCurrent(entry.name)
    local def = ns.Snapshot.GetDefault(entry.name)
    row._current:SetText(cur ~= nil and tostring(cur) or "|cff666666--|r")
    row._default:SetText(def ~= nil and tostring(def) or "|cff666666--|r")
    row._type:SetText(entry.commandType or "")

    local isRisky    = ns.RiskyList and ns.RiskyList.IsRisky(entry.name)
    local isModified = ns.Snapshot.IsModified(entry.name)
    if isRisky then
        row._name:SetTextColor(1, 0.55, 0)
    elseif isModified then
        row._name:SetTextColor(0.5, 1, 0.5)
    else
        row._name:SetTextColor(1, 1, 1)
    end
    row._risk:SetShown(isRisky and true or false)

    if (dataIdx % 2) == 0 then
        row._bg:SetColorTexture(1, 1, 1, 0.03)
    else
        row._bg:SetColorTexture(1, 1, 1, 0.00)
    end
end

-- --------------------------------------------------------------------------
-- Pool sizing + visible-row computation.
-- --------------------------------------------------------------------------
local function ensurePoolSize(targetSize)
    while #_rowPool < targetSize do
        local row = buildRow(_content)
        _rowPool[#_rowPool + 1] = row
    end
end

local function updateVisible()
    if not _scrollFrame then return end
    local sw = _scrollFrame:GetWidth()  or 600
    local sh = _scrollFrame:GetHeight() or 200
    local offset = _scrollFrame:GetVerticalScroll() or 0

    local visibleRows = math.ceil(sh / ROW_HEIGHT)
    local poolSize    = visibleRows + POOL_BUFFER
    ensurePoolSize(poolSize)

    local total = #_dataIndices
    local contentH = math.max(1, total * ROW_HEIGHT)
    if _scrollWidget and _scrollWidget.SetContentHeight then
        _scrollWidget:SetContentHeight(contentH)
    elseif _content then
        _content:SetSize(sw, contentH)
    end

    local firstVisible = math.floor(offset / ROW_HEIGHT) + 1
    local firstPool    = math.max(1, firstVisible - math.floor(POOL_BUFFER / 2))

    for i = 1, poolSize do
        local dataIdx = firstPool + i - 1
        local row = _rowPool[i]
        if dataIdx >= 1 and dataIdx <= total then
            row:SetWidth(sw)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",  _content, "TOPLEFT",  0, -((dataIdx - 1) * ROW_HEIGHT))
            row:SetPoint("TOPRIGHT", _content, "TOPLEFT", sw, -((dataIdx - 1) * ROW_HEIGHT))
            layoutRow(row, sw)
            paintRow(row, dataIdx)
            row:Show()
        else
            row:Hide()
        end
    end
end

-- --------------------------------------------------------------------------
-- Public API.
-- --------------------------------------------------------------------------
function List.Build(parent)
    if _scrollFrame then return _scrollFrame end
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    local sw = Gui and Gui:Create("ScrollFrame")
    if sw then
        sw:SetParent(parent); sw:ClearAllPoints()
        sw:SetPoint("TOPLEFT",     parent, "TOPLEFT",     0, 0)
        sw:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
        _scrollWidget = sw
        _scrollFrame  = sw.scrollFrame
        _content      = sw.content
    else
        local raw = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
        raw:SetPoint("TOPLEFT",     parent, "TOPLEFT",     0, 0)
        raw:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)
        local content = CreateFrame("Frame", nil, raw)
        content:SetSize(raw:GetWidth(), 1)
        raw:SetScrollChild(content)
        _scrollFrame = raw
        _content     = content
    end

    _scrollFrame:HookScript("OnVerticalScroll", function(self, off)
        if self.UpdateScrollChildRect then self:UpdateScrollChildRect() end
        updateVisible()
    end)
    _scrollFrame:HookScript("OnSizeChanged", function() updateVisible() end)
    _scrollFrame:HookScript("OnShow",        function() updateVisible() end)

    return _scrollFrame
end

function List.SetData(filteredIndices)
    _dataIndices = filteredIndices or {}
    if _scrollFrame then _scrollFrame:SetVerticalScroll(0) end
    updateVisible()
end

function List.Refresh()
    updateVisible()
end

function List.GetFrame()
    return _scrollFrame
end

function List.SetCallbacks(opts)
    opts = opts or {}
    _onEditClicked  = opts.onEdit  or _onEditClicked
    _onResetClicked = opts.onReset or _onResetClicked
    _onCopyClicked  = opts.onCopy  or _onCopyClicked
end

-- Forge_APIRef.List: virtualized list of API entries.
--
-- Rows are clickable; click selects the row and fires the onSelect
-- callback with the entry table. Only the visible rows have actual
-- frames (pool sized to visibleRows + buffer); scrolling reuses them.
--
-- Public API:
--   ns.List.Build(parent)
--   ns.List.SetData(rows)         -- rows: array of { fullName, entry }
--   ns.List.Refresh()
--   ns.List.GetFrame()
--   ns.List.SetCallbacks({ onSelect = function(entry, fullName) ... end })
--   ns.List.SelectByFullName(name)

local ADDON, ns = ...

local List = {}
ns.List = List

local ROW_HEIGHT  = 22
local POOL_BUFFER = 4
local TYPE_TAG_W  = 32
local FLAG_TAG_W  = 14

local _scrollWidget
local _scrollFrame
local _content
local _rowPool      = {}
local _data         = {}     -- array of { fullName, entry }
local _onSelect
local _selectedFull           -- the fullName of the selected row
local _selectedRow            -- pointer to the currently-highlighted pool row

-- --------------------------------------------------------------------------
-- Type-tag color and short-form per entry type.
-- --------------------------------------------------------------------------
local function typeTag(entry)
    local t = entry and entry.type or ""
    if t == "function"  then return "|cff88ddfffn|r" end
    if t == "event"     then return "|cffaaffaaev|r" end
    if t == "structure" then return "|cffffd200st|r" end
    return "|cff666666?|r"
end

-- --------------------------------------------------------------------------
-- Row factory.
-- --------------------------------------------------------------------------
local function buildRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    row._bg = bg

    -- Selection highlight (shown only when row is the selected one).
    local sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    sel:SetAllPoints(row)
    sel:SetColorTexture(0.85, 0.50, 0.20, 0.25)
    sel:Hide()
    row._sel = sel

    -- Hover (transient).
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetColorTexture(1, 1, 1, 0.06)

    local flag = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    flag:SetWidth(FLAG_TAG_W); flag:SetJustifyH("CENTER")
    flag:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row._flag = flag

    local tag = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tag:SetWidth(TYPE_TAG_W); tag:SetJustifyH("CENTER")
    tag:SetPoint("RIGHT", flag, "LEFT", -4, 0)
    row._tag = tag

    -- Anchor the name LEFT-to-LEFT and RIGHT-to-LEFT-of-tag so it has a
    -- defined max width. With SetWordWrap(false) the font system clips
    -- anything beyond the width with an ellipsis instead of running over
    -- the type/flag columns when entry names are long.
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetJustifyH("LEFT"); name:SetWordWrap(false)
    name:SetPoint("LEFT",  row, "LEFT",  6, 0)
    name:SetPoint("RIGHT", tag, "LEFT", -6, 0)
    row._name = name

    row:SetScript("OnClick", function(self)
        if not self._fullName then return end
        List.SelectByFullName(self._fullName)
    end)

    return row
end

-- --------------------------------------------------------------------------
-- Selection rendering.
-- --------------------------------------------------------------------------
local function applySelectionPaint()
    if _selectedRow and _selectedRow._sel then _selectedRow._sel:Hide() end
    _selectedRow = nil
    if not _selectedFull then return end
    for _, row in ipairs(_rowPool) do
        if row:IsShown() and row._fullName == _selectedFull then
            row._sel:Show()
            _selectedRow = row
            break
        end
    end
end

-- --------------------------------------------------------------------------
-- Paint a row from a data index.
-- --------------------------------------------------------------------------
local function paintRow(row, dataIdx)
    local datum = _data[dataIdx]
    if not datum then row:Hide(); return end
    local fullName, entry = datum.fullName, datum.entry
    row._fullName = fullName
    row._entry    = entry
    row._name:SetText(fullName)
    row._tag:SetText(typeTag(entry))

    -- Flag column: ! if restricted, (nothing) for may-return-nothing,
    -- removed/deprecated tags, etc. Keep one glyph max for visual quiet.
    if entry and entry.hasRestrictions then
        row._flag:SetText("|cffff5555!|r")
    elseif entry and entry.removed then
        row._flag:SetText("|cff999999x|r")
    elseif entry and entry.deprecated then
        row._flag:SetText("|cffffaa20d|r")
    else
        row._flag:SetText("")
    end

    -- Alternating background.
    if (dataIdx % 2) == 0 then
        row._bg:SetColorTexture(1, 1, 1, 0.03)
    else
        row._bg:SetColorTexture(1, 1, 1, 0.00)
    end

    -- Selection paint.
    if fullName == _selectedFull then
        row._sel:Show()
        _selectedRow = row
    else
        row._sel:Hide()
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
    local sw = _scrollFrame:GetWidth()  or 300
    local sh = _scrollFrame:GetHeight() or 200
    local offset = _scrollFrame:GetVerticalScroll() or 0

    local visibleRows = math.ceil(sh / ROW_HEIGHT)
    local poolSize    = visibleRows + POOL_BUFFER
    ensurePoolSize(poolSize)

    local total = #_data
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
            paintRow(row, dataIdx)
            row:Show()
        else
            row:Hide()
        end
    end

    applySelectionPaint()
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

    _scrollFrame:HookScript("OnVerticalScroll", function(self)
        if self.UpdateScrollChildRect then self:UpdateScrollChildRect() end
        updateVisible()
    end)
    _scrollFrame:HookScript("OnSizeChanged", function() updateVisible() end)
    _scrollFrame:HookScript("OnShow",        function() updateVisible() end)

    return _scrollFrame
end

function List.SetData(rows)
    _data = rows or {}
    if _scrollFrame then _scrollFrame:SetVerticalScroll(0) end
    -- Drop any stale selection that no longer matches a visible row.
    if _selectedFull then
        local stillThere = false
        for _, datum in ipairs(_data) do
            if datum.fullName == _selectedFull then stillThere = true; break end
        end
        if not stillThere then _selectedFull = nil end
    end
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
    _onSelect = opts.onSelect or _onSelect
end

function List.SelectByFullName(fullName)
    _selectedFull = fullName
    -- Re-paint visible rows so selection highlight tracks.
    applySelectionPaint()
    if _onSelect then
        for _, datum in ipairs(_data) do
            if datum.fullName == fullName then
                _onSelect(datum.entry, fullName)
                return
            end
        end
        _onSelect(nil, fullName)
    end
end

function List.GetSelectedFullName()
    return _selectedFull
end

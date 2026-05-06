-- Forge_APIRef.UI: the top-level layout for the APIRef tab.
--
-- Lives inside the Forge main window's content area (`parent` arg). Layout:
--
--   [search_____] [ns: All v] [type: All v] [Load all]   [N entries]
--   ----------------------------------------------------------------------
--   List (left ~40%)                | Detail (right ~60%)
--   ----------------------------------------------------------------------
--
-- All consumer-facing widgets use Cairn-Gui-Core-1.0 (Input, Button,
-- ScrollFrame). The popup shells follow the established Forge_AddonManager
-- pattern: backdrop Frame + Cairn ScrollFrame inside.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H = 28
local PAD       = 6
local BTN_H     = 22
local LIST_FRAC = 0.40   -- left pane fraction of total width
local DIVIDER_W = 4

-- Module-scope handles.
local _frame
local _toolbar, _listArea, _detailArea
local _searchAnchor
local _nsBtn, _typeBtn, _loadAllBtn, _countLabel

-- Filters live in db.profile.ui (mirrors Forge_CVars convention).
local function uiState()
    local p = ns.db and ns.db.profile or nil
    if not p then return {} end
    if p.ui == nil then p.ui = {} end
    return p.ui
end

-- --------------------------------------------------------------------------
-- Tiny chat helper.
-- --------------------------------------------------------------------------
local function out(msg)
    if ns.out then ns.out(msg)
    elseif DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge APIRef:|r " .. tostring(msg))
    end
end

-- --------------------------------------------------------------------------
-- Compute the data rows from currently-loaded modules + active filters.
-- --------------------------------------------------------------------------
local function buildRows()
    local s = uiState()
    local query  = (s.lastSearch or ""):lower()
    local nsFilter   = s.lastNamespace or "All"
    local typeFilter = s.lastType      or "All"

    local rows = {}
    for memberName, entry in (ns.Iter and ns:Iter() or function() return nil end) do
        local nsName = entry.namespace

        -- Display name: events and structures are referred to by bare
        -- name in WoW (RegisterEvent("ZONE_CHANGED"), not
        -- "C_Map.ZONE_CHANGED"; same with structure refs). Functions
        -- always show namespace.name.
        local fullName
        if entry.type == "event" then
            fullName = entry.literalName or entry.name or memberName
        elseif entry.type == "structure" then
            fullName = entry.name or memberName
        else
            fullName = nsName and (nsName .. "." .. (entry.name or memberName))
                              or  (entry.name or memberName)
        end

        local include = true
        if nsFilter ~= "All" and nsName ~= nsFilter then include = false end
        if include and typeFilter ~= "All" and entry.type ~= typeFilter then include = false end
        if include and query ~= "" then
            local hay = fullName:lower()
            if not hay:find(query, 1, true) then include = false end
        end
        if include then
            rows[#rows + 1] = { fullName = fullName, entry = entry }
        end
    end

    table.sort(rows, function(a, b) return a.fullName < b.fullName end)
    return rows
end

function UI.Refresh()
    if not (ns.List and ns.List.SetData) then return end
    local rows = buildRows()
    ns.List.SetData(rows)
    if _countLabel then
        _countLabel:SetText(string.format("|cff888888%d entries|r", #rows))
    end
end

-- --------------------------------------------------------------------------
-- Generic "trigger button + popup" helper, mirroring Forge_CVars pattern.
-- --------------------------------------------------------------------------
local function buildPopupShell(name, w, h)
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(w, h)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.04, 0.94)
    f:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)
    f:EnableMouse(true)
    f:Hide()
    return f
end

local function makeTriggerButton(parent, label, width, onClick)
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local b = Gui and Gui:Create("Button")
    if b then
        b:SetParent(parent); b:ClearAllPoints()
        b:SetWidth(width); b:SetHeight(BTN_H)
        b:SetText(label .. "  |cffd87f3av|r")
        b:SetEventListener("OnClick", onClick)
        return b, b.frame
    else
        local raw = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        raw:SetSize(width, BTN_H)
        raw:SetText(label .. "  v")
        raw:SetScript("OnClick", function() onClick() end)
        return raw, raw
    end
end

local function setBtnLabel(btn, label)
    if not btn then return end
    if btn.SetText then btn:SetText(label .. "  |cffd87f3av|r") end
end

-- Generic popup for selecting a single value out of a list.
local function buildSimpleListPopup(name)
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local f = buildPopupShell(name, 200, 240)
    local sw = Gui and Gui:Create("ScrollFrame")
    if sw then
        sw:SetParent(f); sw:ClearAllPoints()
        sw:SetPoint("TOPLEFT",     f, "TOPLEFT",      4, -4)
        sw:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4,  4)
        f._scroll  = sw
        f._content = sw.content
    else
        local raw = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        raw:SetPoint("TOPLEFT", 4, -4); raw:SetPoint("BOTTOMRIGHT", -22, 4)
        local content = CreateFrame("Frame", nil, raw); content:SetSize(1, 1)
        raw:SetScrollChild(content)
        f._scroll = raw; f._content = content
    end
    f._rows = {}
    return f
end

local function refreshSimpleList(f, items, currentValue, onPick)
    local content = f._content
    for _, row in ipairs(f._rows) do row:Hide() end
    local rowH = 22
    for i, value in ipairs(items) do
        local row = f._rows[i]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(rowH)
            row:RegisterForClicks("LeftButtonUp")
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(row); hl:SetColorTexture(1, 1, 1, 0.08)
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("LEFT", row, "LEFT", 8, 0); text:SetJustifyH("LEFT")
            row._text = text
            f._rows[i] = row
        end
        row:SetWidth((content:GetWidth() or 200) - 8)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -((i - 1) * rowH))
        row._text:SetText(value)
        if value == currentValue then
            row._text:SetTextColor(1, 0.85, 0.40)
        else
            row._text:SetTextColor(0.85, 0.85, 0.85)
        end
        row:SetScript("OnClick", function()
            f:Hide()
            onPick(value)
        end)
        row:Show()
    end
    content:SetHeight(math.max(1, #items * rowH + 8))
end

-- --------------------------------------------------------------------------
-- Namespace popup.
-- --------------------------------------------------------------------------
local _nsPopup
local function toggleNsPopup()
    if not _nsPopup then _nsPopup = buildSimpleListPopup("ForgeAPIRefNsPopup") end
    local f = _nsPopup
    if f:IsShown() then f:Hide(); return end
    local s = uiState()
    local items = { "All" }
    for _, n in ipairs(ns:Namespaces()) do items[#items + 1] = n end
    refreshSimpleList(f, items, s.lastNamespace or "All", function(value)
        s.lastNamespace = value
        setBtnLabel(_nsBtn, "ns: " .. value)
        UI.Refresh()
    end)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", _nsBtn.frame or _nsBtn, "BOTTOMLEFT", 0, -2)
    f:Show()
end

-- --------------------------------------------------------------------------
-- Type popup.
-- --------------------------------------------------------------------------
local TYPE_OPTIONS = { "All", "function", "event", "structure" }
local _typePopup
local function toggleTypePopup()
    if not _typePopup then _typePopup = buildSimpleListPopup("ForgeAPIRefTypePopup") end
    local f = _typePopup
    if f:IsShown() then f:Hide(); return end
    local s = uiState()
    refreshSimpleList(f, TYPE_OPTIONS, s.lastType or "All", function(value)
        s.lastType = value
        setBtnLabel(_typeBtn, "type: " .. value)
        UI.Refresh()
    end)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", _typeBtn.frame or _typeBtn, "BOTTOMLEFT", 0, -2)
    f:Show()
end

-- --------------------------------------------------------------------------
-- Load-all: walk every installed Forge_APIRef-* sibling and LoadAddOn it.
-- --------------------------------------------------------------------------
local function loadAllSiblings()
    if not (C_AddOns and C_AddOns.GetNumAddOns) then return end
    local count = C_AddOns.GetNumAddOns()
    local loaded, skipped, failed = 0, 0, 0
    for i = 1, count do
        local nm = C_AddOns.GetAddOnInfo(i)
        if nm and nm:match("^Forge_APIRef%-") then
            if C_AddOns.IsAddOnLoaded(nm) then
                skipped = skipped + 1
            else
                local ok = C_AddOns.LoadAddOn(nm)
                if ok then loaded = loaded + 1 else failed = failed + 1 end
            end
        end
    end
    out(string.format("Load-all: %d newly loaded, %d already loaded, %d failed.",
        loaded, skipped, failed))
    UI.Refresh()
end

-- --------------------------------------------------------------------------
-- Toolbar.
-- --------------------------------------------------------------------------
local function buildToolbar(parent)
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    bar:SetHeight(TOOLBAR_H)
    _toolbar = bar

    local s = uiState()

    -- Search Input. Per faiap_cairn_gui_compat: HookScript on inner editBox.
    do
        local widget = Gui and Gui:Create("Input")
        if widget then
            widget:SetParent(bar); widget:ClearAllPoints()
            widget:SetWidth(200); widget:SetHeight(BTN_H)
            widget:SetPoint("LEFT", bar, "LEFT", 4, 0)
            widget:SetText(s.lastSearch or "")
            widget.editBox:HookScript("OnTextChanged", function(self)
                s.lastSearch = self:GetText() or ""
                UI.Refresh()
            end)
            widget:SetEventListener("OnEscapePressed", function()
                widget:SetText(""); s.lastSearch = ""; UI.Refresh()
            end)
            _searchAnchor = widget.frame
        else
            local raw = CreateFrame("EditBox", nil, bar, "InputBoxTemplate")
            raw:SetSize(200, BTN_H)
            raw:SetPoint("LEFT", bar, "LEFT", 4, 0)
            raw:SetAutoFocus(false); raw:SetFontObject("ChatFontNormal")
            raw:SetText(s.lastSearch or "")
            raw:SetScript("OnTextChanged", function(self)
                s.lastSearch = self:GetText() or ""; UI.Refresh()
            end)
            raw:SetScript("OnEscapePressed", function(self)
                self:ClearFocus(); self:SetText(""); s.lastSearch = ""; UI.Refresh()
            end)
            _searchAnchor = raw
        end
    end

    -- Namespace filter trigger.
    local nsLabel = "ns: " .. (s.lastNamespace or "All")
    _nsBtn = (function()
        local b, _ = makeTriggerButton(bar, nsLabel, 130, toggleNsPopup)
        b:ClearAllPoints()
        b:SetPoint("LEFT", _searchAnchor, "RIGHT", 6, 0)
        return b
    end)()

    -- Type filter trigger.
    local typeLabel = "type: " .. (s.lastType or "All")
    _typeBtn = (function()
        local b, _ = makeTriggerButton(bar, typeLabel, 130, toggleTypePopup)
        b:ClearAllPoints()
        b:SetPoint("LEFT", _nsBtn.frame or _nsBtn, "RIGHT", 6, 0)
        return b
    end)()

    -- Load-all button.
    do
        local widget = Gui and Gui:Create("Button")
        if widget then
            widget:SetParent(bar); widget:ClearAllPoints()
            widget:SetWidth(80); widget:SetHeight(BTN_H)
            widget:SetPoint("LEFT", _typeBtn.frame or _typeBtn, "RIGHT", 6, 0)
            widget:SetText("Load all")
            widget:SetEventListener("OnClick", loadAllSiblings)
            _loadAllBtn = widget
        else
            local raw = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
            raw:SetSize(80, BTN_H); raw:SetText("Load all")
            raw:SetPoint("LEFT", _typeBtn.frame or _typeBtn, "RIGHT", 6, 0)
            raw:SetScript("OnClick", loadAllSiblings)
            _loadAllBtn = raw
        end
    end

    -- Count status (right-aligned).
    local count = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    count:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    count:SetJustifyH("RIGHT")
    count:SetText("|cff888888-- entries|r")
    _countLabel = count
end

-- --------------------------------------------------------------------------
-- Build the whole tab.
-- --------------------------------------------------------------------------
function UI.Build(parent, mod)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    mod._frame = f
    _frame = f

    buildToolbar(f)

    -- Body: list on left, detail on right, separated by a thin divider.
    local body = CreateFrame("Frame", nil, f)
    body:SetPoint("TOPLEFT",     _toolbar, "BOTTOMLEFT",  0, -PAD)
    body:SetPoint("BOTTOMRIGHT", f,        "BOTTOMRIGHT", 0,  0)

    local list = CreateFrame("Frame", nil, body)
    list:SetPoint("TOPLEFT",    body, "TOPLEFT",    0, 0)
    list:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    list:SetWidth(1)  -- updated below in OnSizeChanged
    _listArea = list

    local divider = body:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.4, 0.3, 0.15, 0.6)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT",    list, "TOPRIGHT",    DIVIDER_W / 2, 0)
    divider:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", DIVIDER_W / 2, 0)

    local detail = CreateFrame("Frame", nil, body)
    detail:SetPoint("TOPLEFT",     list, "TOPRIGHT",     DIVIDER_W, 0)
    detail:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT",  0, 0)
    _detailArea = detail

    -- Track body size; the list pane fraction snaps to LIST_FRAC.
    local function relayout()
        local bw = body:GetWidth() or 600
        list:SetWidth(math.max(120, math.floor(bw * LIST_FRAC) - DIVIDER_W / 2))
    end
    body:HookScript("OnSizeChanged", relayout)
    relayout()

    -- Build the inner widgets.
    if ns.List and ns.List.Build then
        ns.List.Build(list)
        ns.List.SetCallbacks({
            onSelect = function(entry, fullName)
                if ns.Detail and ns.Detail.Render then
                    ns.Detail.Render(entry)
                end
            end,
        })
    end
    if ns.Detail and ns.Detail.Build then
        ns.Detail.Build(detail)
    end

    -- Initial rows + relayout-after-frame for the parent-may-not-be-sized
    -- footgun.
    UI.Refresh()
    if C_Timer and C_Timer.After then
        C_Timer.After(0.05, function()
            relayout()
            if ns.List   and ns.List.Refresh   then ns.List.Refresh()   end
            if ns.Detail and ns.Detail.Render  then ns.Detail.Render(nil) end
        end)
    end
end

function UI.OnTabShow(mod)
    if ns.List and ns.List.Refresh then ns.List.Refresh() end
end

function UI.OnTabHide(mod)
    if _nsPopup   then _nsPopup:Hide()   end
    if _typePopup then _typePopup:Hide() end
end

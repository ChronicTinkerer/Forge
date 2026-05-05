-- Forge_AddonManager.UI: addon list with sortable columns, status filter,
-- text search, named sets, ReloadUI.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H   = 28
local HEADER_H    = 22
local STATUS_H    = 22
local ROW_HEIGHT  = 22
local PAD         = 6
local BTN_HEIGHT  = 22
local BTN_WIDTH   = 70  -- shrunk from 80 to fit toolbar; see Build() comment

-- Cairn-Gui Button toolbar is the active implementation. Vanilla branch in
-- UI.Build is preserved as a fallback if Cairn-Gui-Core-1.0 doesn't load.
-- Misroute reproduced on BOTH backends per Steven 2026-05-04, so the bug is
-- NOT in the button widget. Diagnostics: /run ForgeAMDumpToolbar() prints
-- hitboxes; /run ForgeAMMouseFocus() prints which frame the cursor is over.
local USE_CAIRN_TOOLBAR = true

-- Column definitions: { key, label, x_left, width, sort_value_fn }
local function colVal_name(e)    return (e.title or e.name or ""):lower() end
local function colVal_status(e)
    if ns.Manager.IsLoaded(e.name)        then return 1 end
    if e.isLoD and ns.Manager.IsEnabled(e.name) then return 2 end
    if ns.Manager.IsEnabled(e.name)       then return 3 end
    return 4
end
local function colVal_memory(e)  return -(ns.Manager.MemoryKB(e.name) or 0) end  -- desc by default
local function colVal_version(e) return tostring(e.version or "") end
local function colVal_protect(e) return ns.Manager.IsProtected(e.name) and 0 or 1 end

local COLUMNS = {
    { key = "name",    label = "Name",    width = 260, sort = colVal_name    },
    { key = "status",  label = "Status",  width = 70,  sort = colVal_status  },
    { key = "memory",  label = "Memory",  width = 80,  sort = colVal_memory  },
    { key = "version", label = "Version", width = 90,  sort = colVal_version },
    { key = "protect", label = "P",       width = 24,  sort = colVal_protect },
}

-- `label` is the popup-menu row text (full description). `short` is what
-- shows in the toolbar button when this filter is active; the button is
-- narrower than the popup row, so we abbreviate.
local FILTER_STATUSES = {
    { key = "all",       label = "All addons",                short = "All" },
    { key = "loaded",    label = "Loaded only",               short = "Loaded" },
    { key = "disabled",  label = "Disabled only",             short = "Disabled" },
    { key = "lod",       label = "Load-on-demand only",       short = "LoD" },
    { key = "pending",   label = "Pending (reload required)", short = "Pending" },
    { key = "protected", label = "Protected only",            short = "Protected" },
}

local _activeMod
local _filterText   = ""
local _filterStatus = "all"
local _sortKey      = "name"
local _sortDir      = "asc"

local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

local function statusBadge(entry)
    if ns.Manager.IsLoaded(entry.name) then
        return "|cff80ff80Loaded|r"
    elseif entry.isLoD and ns.Manager.IsEnabled(entry.name) then
        return "|cffffd87fLoD|r"
    elseif ns.Manager.IsEnabled(entry.name) then
        return "|cffaaaaffPending|r"
    else
        return "|cff888888Disabled|r"
    end
end

local function memoryStr(entry)
    local kb = ns.Manager.MemoryKB(entry.name) or 0
    if kb < 0.5 then return "" end
    if kb < 1024 then return string.format("%.1f KB", kb) end
    return string.format("%.2f MB", kb / 1024)
end

local function tooltipFor(entry)
    if not (GameTooltip and entry) then return end
    GameTooltip:ClearLines()
    GameTooltip:AddLine("|cffd87f3a" .. (entry.title or entry.name) .. "|r")
    if entry.version then GameTooltip:AddDoubleLine("Version", tostring(entry.version), 0.85, 0.7, 0.4, 1, 1, 1) end
    if entry.author  then GameTooltip:AddDoubleLine("Author",  tostring(entry.author),  0.85, 0.7, 0.4, 1, 1, 1) end
    if entry.notes   then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(tostring(entry.notes), 1, 1, 1, true)
    end
    local function fmtDepList(list)
        local parts = {}
        for _, d in ipairs(list) do
            local installed = ns.Manager.Get(d)
            local enabled   = installed and ns.Manager.IsEnabled(d)
            local color
            if not installed then color = "ffff8080"
            elseif enabled    then color = "ff80ff80"
            else                   color = "ffffd87f"
            end
            parts[#parts + 1] = "|c" .. color .. d .. "|r"
        end
        return table.concat(parts, ", ")
    end
    local reqDeps = ns.Manager.GetDependencies(entry.name) or {}
    local optDeps = ns.Manager.GetOptionalDependencies(entry.name) or {}
    if #reqDeps > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffaaaaaaRequires:|r " .. fmtDepList(reqDeps), 1, 1, 1, true)
    end
    if #optDeps > 0 then
        GameTooltip:AddLine("|cffaaaaaaOptional:|r " .. fmtDepList(optDeps), 1, 1, 1, true)
    end
    if ns.Manager.IsProtected(entry.name) then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffffd700Protected|r - survives Disable All", 1, 1, 1, true)
    end
    if ns.Manager.IsSelfProtected and ns.Manager.IsSelfProtected(entry.name) then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffff8080Essential|r - cannot be disabled (Forge depends on it)", 1, 1, 1, true)
    end
    GameTooltip:Show()
end

local function passesFilter(entry)
    if _filterText ~= "" then
        local needle = _filterText:lower()
        local nameOk  = entry.name  and entry.name:lower():find(needle, 1, true)
        local titleOk = entry.title and entry.title:lower():find(needle, 1, true)
        if not (nameOk or titleOk) then return false end
    end
    if _filterStatus == "loaded"    then return ns.Manager.IsLoaded(entry.name) end
    if _filterStatus == "disabled"  then return not ns.Manager.IsEnabled(entry.name) end
    if _filterStatus == "lod"       then return entry.isLoD end
    if _filterStatus == "pending"   then
        return ns.Manager.IsEnabled(entry.name) and not ns.Manager.IsLoaded(entry.name) and not entry.isLoD
    end
    if _filterStatus == "protected" then return ns.Manager.IsProtected(entry.name) end
    return true
end

local function sortColFn(key)
    for _, c in ipairs(COLUMNS) do
        if c.key == key then return c.sort end
    end
    return colVal_name
end

local function applySort(list)
    local fn = sortColFn(_sortKey)
    local nameFn = colVal_name
    table.sort(list, function(a, b)
        local va, vb = fn(a), fn(b)
        if va ~= vb then
            if _sortDir == "asc" then return va < vb else return va > vb end
        end
        return nameFn(a) < nameFn(b)
    end)
end

-- ===== Status filter popup ================================================
local function buildFilterPopup()
    local f = CreateFrame("Frame", "ForgeAMFilterPopup", UIParent, "BackdropTemplate")
    f:SetSize(220, 8 + #FILTER_STATUSES * 22 + 8)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    f:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)
    f:Hide()

    f._rows = {}
    for i, opt in ipairs(FILTER_STATUSES) do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(200, 20)
        row:SetPoint("TOPLEFT", 8, -(8 + (i - 1) * 22))

        local hov = row:CreateTexture(nil, "BACKGROUND")
        hov:SetColorTexture(0.45, 0.32, 0.15, 0.30)
        hov:SetAllPoints(); hov:Hide()
        row._hov = hov

        local sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        sel:SetColorTexture(0.85, 0.50, 0.20, 0.30)
        sel:SetAllPoints(); sel:Hide()
        row._sel = sel

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", 4, 0)
        text:SetText(opt.label)
        row._text = text
        row._key = opt.key

        row:SetScript("OnEnter", function(self) self._hov:Show() end)
        row:SetScript("OnLeave", function(self) self._hov:Hide() end)
        row:SetScript("OnClick", function(self)
            _filterStatus = self._key
            f:Hide()
            UI.RefreshFilterButton()
            UI.Refresh()
        end)
        f._rows[i] = row
    end
    return f
end

local function refreshFilterPopup(f)
    for _, row in ipairs(f._rows) do
        row._sel:SetShown(row._key == _filterStatus)
    end
end

function UI.RefreshFilterButton()
    if not (_activeMod and _activeMod._filterBtn) then return end
    local label = "All"
    for _, opt in ipairs(FILTER_STATUSES) do
        if opt.key == _filterStatus then
            label = opt.short or opt.label
            break
        end
    end
    local btn = _activeMod._filterBtn
    -- Cairn-Gui Button writes via SetText; fallback path uses ._label.
    if btn._label then
        btn._label:SetText(label)
    elseif btn.SetText then
        btn:SetText(label .. "  |cffd87f3av|r")
    end
end

-- ===== Sets dropdown popup ================================================
local function refreshSetsDropdown(f)
    for _, row in ipairs(f._rows) do row:Hide() end
    local names = ns.Manager.ListSetNames() or {}
    local y = 0
    local rowParent = f._content
    local widthSrc  = f._scroll
    for i, name in ipairs(names) do
        local row = f._rows[i]
        if not row then
            row = CreateFrame("Button", nil, rowParent)
            row:SetHeight(20)
            local sel = row:CreateTexture(nil, "BACKGROUND", nil, -2)
            sel:SetColorTexture(0.85, 0.50, 0.20, 0.30)
            sel:SetAllPoints(); sel:Hide()
            row._sel = sel
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("LEFT", row, "LEFT", 6, 0)
            text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            text:SetJustifyH("LEFT")
            row._text = text
            row:SetScript("OnEnter", function(self) self._sel:Show() end)
            row:SetScript("OnLeave", function(self) self._sel:Hide() end)
            row:SetScript("OnClick", function(self)
                f:Hide()
                ns.Manager.LoadSet(self._name)
                ns.Manager.Refresh()
                UI.Refresh()
                if StaticPopup_Show then StaticPopup_Show("FORGE_AM_RELOAD") end
            end)
            f._rows[i] = row
        end
        row._name = name
        local set = ns.Manager.GetSets()[name] or {}
        row._text:SetText(string.format("%s   |cffaaaaaa(%d)|r", name, #set))
        row:ClearAllPoints()
        row:SetWidth((widthSrc:GetWidth() or 240) - 24)
        row:SetPoint("TOPLEFT", rowParent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + 20
    end
    if y < 1 then y = 1 end
    f._content:SetHeight(y)
    if f._scroll.UpdateScrollChildRect then
        f._scroll:UpdateScrollChildRect()
    elseif f._scroll.scrollFrame and f._scroll.scrollFrame.UpdateScrollChildRect then
        f._scroll.scrollFrame:UpdateScrollChildRect()
    end
    f._emptyText:SetShown(#names == 0)
end

local function buildSetsDropdown()
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local f = CreateFrame("Frame", "ForgeAMSetsDropdown", UIParent, "BackdropTemplate")
    f:SetSize(260, 240)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    f:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -6)
    title:SetText("Load a set:")

    -- Migrated to Cairn-Gui-Core ScrollFrame with vanilla fallback.
    local scrollGui = Gui and Gui:Create("ScrollFrame")
    if scrollGui then
        scrollGui:SetParent(f); scrollGui:ClearAllPoints()
        scrollGui:SetPoint("TOPLEFT",     f, "TOPLEFT",      6, -22)
        scrollGui:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2,  30)
        f._scroll  = scrollGui
        f._content = scrollGui.content
    else
        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 6, -22)
        scroll:SetPoint("BOTTOMRIGHT", -22, 30)
        f._scroll = scroll
        local content = CreateFrame("Frame", nil, scroll); content:SetSize(1,1); scroll:SetScrollChild(content)
        f._content = content
    end
    f._rows = {}

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("CENTER", f, "CENTER", 0, 0)
    empty:SetText("(no sets saved)")
    empty:Hide()
    f._emptyText = empty

    local closeWidget = Gui and Gui:Create("Button")
    if closeWidget then
        closeWidget:SetParent(f); closeWidget:ClearAllPoints()
        closeWidget:SetWidth(60); closeWidget:SetHeight(20)
        closeWidget:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
        closeWidget:SetText("Close")
        closeWidget:SetEventListener("OnClick", function() f:Hide() end)
    else
        local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        close:SetSize(60, 20)
        close:SetPoint("BOTTOMRIGHT", -6, 6)
        close:SetText("Close")
        close:SetScript("OnClick", function() f:Hide() end)
    end

    return f
end

local function buildNamePrompt()
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetSize(360, 110)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.08, 0.06, 0.04, 0.40)
    f:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)
    f:EnableMouse(true); f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    f._title = title

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 12, -36)
    label:SetText("Name:")

    -- Migrated to Cairn-Gui Input. The widget exposes its inner EditBox at
    -- .editBox; we drive focus / text / scripts through that for the parts
    -- the widget itself doesn't surface (SetFocus, OnEnterPressed handler).
    local eb, ebFrame, ebGetText, ebSetText, ebSetFocus
    local inputWidget = Gui and Gui:Create("Input")
    if inputWidget then
        inputWidget:SetParent(f); inputWidget:ClearAllPoints()
        inputWidget:SetWidth(280); inputWidget:SetHeight(22)
        inputWidget:SetPoint("LEFT", label, "RIGHT", 8, 0)
        eb        = inputWidget
        ebFrame   = inputWidget.frame
        ebGetText = function() return inputWidget:GetText() or "" end
        ebSetText = function(s) inputWidget:SetText(s or "") end
        ebSetFocus = function() inputWidget.editBox:SetFocus() end
    else
        local raw = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        raw:SetSize(280, 22); raw:SetPoint("LEFT", label, "RIGHT", 8, 0); raw:SetAutoFocus(true)
        eb        = raw
        ebFrame   = raw
        ebGetText = function() return raw:GetText() or "" end
        ebSetText = function(s) raw:SetText(s or "") end
        ebSetFocus = function() raw:SetFocus() end
    end
    f._eb         = eb
    f._ebGetText  = ebGetText
    f._ebSetText  = ebSetText
    f._ebSetFocus = ebSetFocus

    -- OK / Cancel buttons. Click on cancel hides; click on OK calls the
    -- runtime-installed ._okHandler so UI._showSetNamePrompt can swap behavior
    -- per call without re-registering scripts on the widget every time.
    local function makeBtn(labelText, anchor)
        local w = Gui and Gui:Create("Button")
        if w then
            w:SetParent(f); w:ClearAllPoints()
            w:SetWidth(80); w:SetHeight(22)
            if anchor.point == "BOTTOMRIGHT" then
                w:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
            else
                w:SetPoint("RIGHT", anchor.to, "LEFT", -6, 0)
            end
            w:SetText(labelText)
            return w, w.frame
        else
            local raw = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            raw:SetSize(80, 22)
            if anchor.point == "BOTTOMRIGHT" then
                raw:SetPoint("BOTTOMRIGHT", -12, 10)
            else
                raw:SetPoint("RIGHT", anchor.to, "LEFT", -6, 0)
            end
            raw:SetText(labelText)
            return raw, raw
        end
    end

    local ok, okFrame = makeBtn("OK", { point = "BOTTOMRIGHT" })
    if ok.SetEventListener then
        ok:SetEventListener("OnClick", function() if f._okHandler then f._okHandler() end end)
    else
        ok:SetScript("OnClick", function() if f._okHandler then f._okHandler() end end)
    end
    f._ok = ok

    local cancel = makeBtn("Cancel", { point = "RIGHT", to = okFrame })
    if cancel.SetEventListener then
        cancel:SetEventListener("OnClick", function() f:Hide() end)
    else
        cancel:SetScript("OnClick", function() f:Hide() end)
    end

    -- Enter / Esc on the inner EditBox dispatch the OK / Cancel actions.
    local innerEb = (inputWidget and inputWidget.editBox) or eb
    innerEb:SetScript("OnEscapePressed", function() f:Hide() end)
    innerEb:HookScript("OnEnterPressed", function() if f._okHandler then f._okHandler() end end)
    return f
end

function UI._showSetNamePrompt(title, defaultText, onAccept)
    local f = ns._namePrompt
    if not f then f = buildNamePrompt(); ns._namePrompt = f end
    f._title:SetText("|cffd87f3a" .. (title or "Set name") .. "|r")
    if f._ok.SetText then f._ok:SetText("OK") end
    f._okHandler = function()
        local v = (f._ebGetText() or ""):match("^%s*(.-)%s*$") or ""
        if v == "" then return end
        f:Hide()
        if onAccept then onAccept(v) end
    end
    f._ebSetText(defaultText or "")
    f:Show(); f._ebSetFocus()
end

-- Static popup for reload prompt.
StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["FORGE_AM_RELOAD"] = StaticPopupDialogs["FORGE_AM_RELOAD"] or {
    text         = "ReloadUI to apply addon changes?",
    button1      = "Reload Now",
    button2      = "Later",
    OnAccept     = function() if ReloadUI then ReloadUI() end end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ===== Builder ===========================================================
function UI.Build(parent, mod)
    _activeMod = mod

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- Acquire Cairn-Gui-Core once for the whole UI; falsy if the kit failed
    -- to load (each migration site below has a defensive vanilla fallback).
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    -- ----- Toolbar -------------------------------------------------------
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  4, -4)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    bar:SetHeight(TOOLBAR_H)

    -- Toolbar layout budget (recap, after the chain-misroute investigation
    -- 2026-05-04): bar is roughly 850 px wide. Search 110 + filter 90 +
    -- 8 action buttons (most 70, reload 90) + gaps + margins must fit. If
    -- you widen any of these and the chain anchors silently overlap, you
    -- get clicks routed to the wrong button.
    --
    -- Search box. Migrated to Cairn-Gui-Core Input. The widget owns its own
    -- background/highlight/outline styling, so we drop the BackdropTemplate.
    -- Notable widget gap: Input fires OnEnterPressed/OnEscapePressed/
    -- OnEditFocus*, but NOT OnTextChanged. Hook the inner editBox directly
    -- for live filtering. searchAnchor downstream points at the real Frame
    -- regardless of which backend won, so chain-anchors stay sane.
    local search, searchAnchor
    do
        local s = Gui and Gui:Create("Input")
        if s then
            s:SetParent(bar); s:ClearAllPoints()
            s:SetWidth(110); s:SetHeight(BTN_HEIGHT)
            s:SetPoint("LEFT", bar, "LEFT", 4, 0)

            s.editBox:HookScript("OnTextChanged", function(self)
                _filterText = self:GetText() or ""
                UI.Refresh()
            end)
            s:SetEventListener("OnEscapePressed", function()
                s:SetText("")
                _filterText = ""
                UI.Refresh()
            end)

            local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            hint:SetPoint("LEFT", s.frame, "LEFT", 8, 0)
            hint:SetText("Filter by name...")
            s:SetEventListener("OnEditFocusGained", function() hint:Hide() end)
            s:SetEventListener("OnEditFocusLost", function()
                if (s:GetText() or "") == "" then hint:Show() end
            end)
            search       = s
            searchAnchor = s.frame
        else
            local searchBg = CreateFrame("Frame", nil, bar, "BackdropTemplate")
            searchBg:SetSize(110, BTN_HEIGHT)
            searchBg:SetPoint("LEFT", bar, "LEFT", 4, 0)
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
            sf:SetPoint("LEFT", 6, 0); sf:SetPoint("RIGHT", -6, 0)
            sf:SetHeight(BTN_HEIGHT - 4); sf:SetTextInsets(0, 0, 0, 0)
            sf:SetScript("OnTextChanged", function(self) _filterText = self:GetText() or ""; UI.Refresh() end)
            sf:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText(""); _filterText = ""; UI.Refresh() end)

            local placeholder = searchBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            placeholder:SetPoint("LEFT", 8, 0); placeholder:SetText("Filter by name...")
            sf:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
            sf:SetScript("OnEditFocusLost", function(self)
                if (self:GetText() or "") == "" then placeholder:Show() end
            end)
            search       = sf
            searchAnchor = searchBg
        end
    end

    -- Status filter dropdown button. Width 90 -- the FILTER_STATUSES table
    -- carries a short-form label per status that's chosen for fitting in
    -- this width; the popup itself uses the full descriptive labels.
    --
    -- Migrated to Cairn-Gui Button: SetText is the active label (so we drop
    -- the separate ._label FontString -- UI.RefreshFilterButton has been
    -- updated to call SetText instead). The trailing chevron is appended to
    -- the label string. Onclick toggles the existing popup unchanged.
    local filterBtn, filterBtnFrame
    do
        local b = Gui and Gui:Create("Button")
        if b then
            b:SetParent(bar); b:ClearAllPoints()
            b:SetWidth(90); b:SetHeight(BTN_HEIGHT)
            b:SetPoint("LEFT", searchAnchor, "RIGHT", 6, 0)
            b:SetText("All")
            b:SetEventListener("OnClick", function()
                if not ns._filterPopup then ns._filterPopup = buildFilterPopup() end
                local f = ns._filterPopup
                if f:IsShown() then f:Hide() return end
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", b.frame, "BOTTOMLEFT", 0, -2)
                refreshFilterPopup(f)
                f:Show()
            end)
            filterBtn, filterBtnFrame = b, b.frame
        else
            local raw = CreateFrame("Button", nil, bar, "BackdropTemplate")
            raw:SetSize(90, BTN_HEIGHT)
            raw:SetPoint("LEFT", searchAnchor, "RIGHT", 6, 0)
            raw:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 8,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            raw:SetBackdropColor(0.05, 0.05, 0.05, 0.40)
            raw:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
            local fLabel = raw:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fLabel:SetPoint("LEFT", 6, 0); fLabel:SetPoint("RIGHT", -22, 0); fLabel:SetJustifyH("LEFT")
            fLabel:SetWordWrap(false); fLabel:SetMaxLines(1)
            raw._label = fLabel
            local fArrow = raw:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fArrow:SetPoint("RIGHT", -6, 0); fArrow:SetText("|cffd87f3av|r")
            raw:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(0.85, 0.50, 0.20, 1) end)
            raw:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.4, 0.3, 0.15, 1) end)
            raw:SetScript("OnClick", function(self)
                if not ns._filterPopup then ns._filterPopup = buildFilterPopup() end
                local f = ns._filterPopup
                if f:IsShown() then f:Hide() return end
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
                refreshFilterPopup(f)
                f:Show()
            end)
            filterBtn, filterBtnFrame = raw, raw
        end
    end
    mod._filterBtn = filterBtn
    UI.RefreshFilterButton()

    -- Right-aligned action buttons. Two variants live here gated on
    -- USE_CAIRN_TOOLBAR (top of file). Vanilla = working today. Cairn-Gui =
    -- the path that exhibited the chain-misroute bug previously; we want to
    -- diagnose it with the dumper at the bottom of UI.Build.
    local reloadBtn, discardBtn, saveSetBtn, loadSetBtn,
          defaultBtn, disableBtn, enableBtn, exportBtn

    -- OnClick handlers (shared between both backends).
    local onReload = function()
        -- Hardware-click context: calling C_AddOns + ReloadUI here is safe.
        if ns.Manager.HasPendingChange() then
            ns.Manager.ApplyPendingChanges()
        elseif ReloadUI then
            ReloadUI()
        end
    end
    local onDiscard = function()
        ns.Manager.ClearPending()
        if UI.RefreshList then UI.RefreshList() end
    end
    local onSaveSet = function()
        UI._showSetNamePrompt("Save Current as Set", "", function(name)
            ns.Manager.SaveCurrentAsSet(name)
            if ns.out then ns.out("saved set '" .. name .. "'.") end
        end)
    end
    local onLoadSet = function()
        if not ns._setsDropdown then ns._setsDropdown = buildSetsDropdown() end
        local f = ns._setsDropdown
        if f:IsShown() then f:Hide() return end
        f:ClearAllPoints(); f:SetPoint("TOPRIGHT", loadSetBtn, "BOTTOMRIGHT", 0, -2)
        refreshSetsDropdown(f); f:Show()
    end
    local onDefault = function() ns.Manager.RestoreDefault(); ns.Manager.Refresh(); UI.Refresh() end
    local onDisable = function() ns.Manager.DisableAll(); ns.Manager.Refresh(); UI.Refresh() end
    local onEnable  = function() ns.Manager.EnableAll();  ns.Manager.Refresh(); UI.Refresh() end
    local onExport  = function()
        if not (Forge and Forge.ShowCopyDialog and Forge.SerializeTable) then return end
        local enabled, protected = {}, {}
        for _, e in ipairs(ns.Manager.GetAll() or {}) do
            if ns.Manager.IsEnabled(e.name) then enabled[#enabled + 1] = e.name end
            if ns.Manager.IsProtected(e.name) then protected[#protected + 1] = e.name end
        end
        local sets = ns.Manager.GetSets() or {}
        local payload = { enabled = enabled, protected = protected, sets = sets }
        local text = "-- Forge AddonManager state export\n-- Snapshot of current addon enable list, protected set, and named sets.\n\nreturn " .. Forge.SerializeTable(payload) .. "\n"
        Forge.ShowCopyDialog("Addon Manager - export state", text,
            string.format("%d enabled / %d protected / %d sets", #enabled, #protected, (function() local n=0 for _ in pairs(sets) do n=n+1 end return n end)()))
    end

    local Gui_OK = USE_CAIRN_TOOLBAR and Gui or nil

    if Gui_OK then
        -- Cairn-Gui Button variant. Each helper returns (widget, frame). The
        -- frame is what other code SetPoints to (popups, etc.). Click handler
        -- goes on the widget via SetEventListener so PlaySound + FireEvent
        -- still run inside the kit.
        local function makeCairnBtn(label, w, h, anchorTo, dx)
            local widget = Gui:Create("Button")
            widget:SetParent(bar)
            widget:ClearAllPoints()
            widget:SetWidth(w)
            widget:SetHeight(h or BTN_HEIGHT)
            widget:SetText(label)
            widget:SetPoint("RIGHT", anchorTo, "LEFT", dx or -4, 0)
            return widget, widget.frame
        end

        local reloadW
        reloadW = Gui:Create("Button")
        reloadW:SetParent(bar)
        reloadW:ClearAllPoints()
        reloadW:SetWidth(90); reloadW:SetHeight(BTN_HEIGHT)
        reloadW:SetText("Apply + Reload")
        reloadW:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
        reloadW:SetEventListener("OnClick", onReload)
        reloadBtn = reloadW.frame
        mod._reloadBtn = reloadBtn

        local discardW
        discardW, discardBtn = makeCairnBtn("Discard", BTN_WIDTH, BTN_HEIGHT, reloadBtn, -6)
        discardW:SetEventListener("OnClick", onDiscard)
        discardBtn:Hide()
        mod._discardBtn = discardBtn

        local saveSetW
        saveSetW, saveSetBtn = makeCairnBtn("Save Set", BTN_WIDTH, BTN_HEIGHT, discardBtn, -6)
        saveSetW:SetEventListener("OnClick", onSaveSet)

        local loadSetW
        loadSetW, loadSetBtn = makeCairnBtn("Load Set", BTN_WIDTH, BTN_HEIGHT, saveSetBtn, -4)
        loadSetW:SetEventListener("OnClick", onLoadSet)

        local defaultW
        defaultW, defaultBtn = makeCairnBtn("Default", 70, BTN_HEIGHT, loadSetBtn, -4)
        defaultW:SetEventListener("OnClick", onDefault)

        local disableW
        -- Label shortened from "Disable All" to "Disable" so it fits in
        -- BTN_WIDTH=70 without clipping.
        disableW, disableBtn = makeCairnBtn("Disable", BTN_WIDTH, BTN_HEIGHT, defaultBtn, -4)
        disableW:SetEventListener("OnClick", onDisable)

        local enableW
        enableW, enableBtn = makeCairnBtn("Enable", BTN_WIDTH, BTN_HEIGHT, disableBtn, -4)
        enableW:SetEventListener("OnClick", onEnable)

        local exportW
        exportW, exportBtn = makeCairnBtn("Export", 70, BTN_HEIGHT, enableBtn, -4)
        exportW:SetEventListener("OnClick", onExport)
    else
        local function makeBtn(parent_, label, w)
            local b = CreateFrame("Button", nil, parent_, "UIPanelButtonTemplate")
            b:SetSize(w or BTN_WIDTH, BTN_HEIGHT); b:SetText(label)
            return b
        end

        reloadBtn = makeBtn(bar, "Apply + Reload")
        reloadBtn:SetSize(90, reloadBtn:GetHeight())
        reloadBtn:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
        reloadBtn:SetScript("OnClick", onReload)
        mod._reloadBtn = reloadBtn

        discardBtn = makeBtn(bar, "Discard")
        discardBtn:SetPoint("RIGHT", reloadBtn, "LEFT", -6, 0)
        discardBtn:SetScript("OnClick", onDiscard)
        discardBtn:Hide()
        mod._discardBtn = discardBtn

        saveSetBtn = makeBtn(bar, "Save Set")
        saveSetBtn:SetPoint("RIGHT", discardBtn, "LEFT", -6, 0)
        saveSetBtn:SetScript("OnClick", onSaveSet)

        loadSetBtn = makeBtn(bar, "Load Set")
        loadSetBtn:SetPoint("RIGHT", saveSetBtn, "LEFT", -4, 0)
        loadSetBtn:SetScript("OnClick", onLoadSet)

        defaultBtn = makeBtn(bar, "Default", 70)
        defaultBtn:SetPoint("RIGHT", loadSetBtn, "LEFT", -4, 0)
        defaultBtn:SetScript("OnClick", onDefault)

        disableBtn = makeBtn(bar, "Disable")
        disableBtn:SetPoint("RIGHT", defaultBtn, "LEFT", -4, 0)
        disableBtn:SetScript("OnClick", onDisable)

        enableBtn = makeBtn(bar, "Enable")
        enableBtn:SetPoint("RIGHT", disableBtn, "LEFT", -4, 0)
        enableBtn:SetScript("OnClick", onEnable)

        exportBtn = makeBtn(bar, "Export", 70)
        exportBtn:SetPoint("RIGHT", enableBtn, "LEFT", -4, 0)
        exportBtn:SetScript("OnClick", onExport)
    end

    -- Stash for the hitbox dumper. Order = visual right-to-left
    -- (matches the chain-anchor order; reloadBtn is rightmost).
    mod._toolbarBtns = {
        { name = "filterBtn",  frame = filterBtn  },
        { name = "exportBtn",  frame = exportBtn  },
        { name = "enableBtn",  frame = enableBtn  },
        { name = "disableBtn", frame = disableBtn },
        { name = "defaultBtn", frame = defaultBtn },
        { name = "loadSetBtn", frame = loadSetBtn },
        { name = "saveSetBtn", frame = saveSetBtn },
        { name = "discardBtn", frame = discardBtn },
        { name = "reloadBtn",  frame = reloadBtn  },
    }
    mod._toolbarBar = bar
    mod._toolbarBackend = Gui_OK and "cairn-gui" or "vanilla"

    -- ----- Header row (clickable column headers for sort) ----------------
    local headerBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    headerBg:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -PAD)
    headerBg:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -PAD)
    headerBg:SetHeight(HEADER_H)
    headerBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    headerBg:SetBackdropColor(0.10, 0.08, 0.04, 0.40)
    headerBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    mod._header = headerBg
    mod._headerLabels = {}

    local function colArrow(key)
        if _sortKey ~= key then return "" end
        return _sortDir == "asc" and "  ^" or "  v"
    end

    -- Layout columns: checkbox space first (24px), then declared columns.
    local cbSpace = 24
    local x = 4 + cbSpace + 4
    for _, col in ipairs(COLUMNS) do
        local btn = CreateFrame("Button", nil, headerBg)
        btn:SetSize(col.width, HEADER_H - 2)
        btn:SetPoint("LEFT", headerBg, "LEFT", x, 0)
        local hov = btn:CreateTexture(nil, "BACKGROUND")
        hov:SetColorTexture(0.45, 0.32, 0.15, 0.30)
        hov:SetAllPoints(); hov:Hide()
        btn:SetScript("OnEnter", function() hov:Show() end)
        btn:SetScript("OnLeave", function() hov:Hide() end)
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", 4, 0); fs:SetJustifyH("LEFT")
        fs:SetTextColor(0.85, 0.7, 0.4, 1)
        btn._fs = fs; btn._key = col.key
        btn:SetScript("OnClick", function(self)
            if _sortKey == self._key then
                _sortDir = (_sortDir == "asc") and "desc" or "asc"
            else
                _sortKey = self._key
                _sortDir = (self._key == "memory") and "desc" or "asc"
            end
            UI.RefreshHeader()
            UI.Refresh()
        end)
        mod._headerLabels[col.key] = btn
        x = x + col.width
    end

    -- ----- List pane -----------------------------------------------------
    local listBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", headerBg, "BOTTOMLEFT", 0, -2)
    listBg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, STATUS_H + PAD)
    listBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    listBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    -- Migrated to Cairn-Gui-Core ScrollFrame. Same backend-OK fallback shape
    -- as Forge_Logs: store both the high-level surface (._scroll) and the
    -- underlying scrollchild (._content). _scroll:GetWidth/UpdateScrollChildRect
    -- are duck-typed so consumer code stays backend-agnostic.
    local scrollGui = Gui and Gui:Create("ScrollFrame")
    if scrollGui then
        scrollGui:SetParent(listBg); scrollGui:ClearAllPoints()
        scrollGui:SetPoint("TOPLEFT",     listBg, "TOPLEFT",      6, -6)
        scrollGui:SetPoint("BOTTOMRIGHT", listBg, "BOTTOMRIGHT", -2,  6)
        mod._scroll  = scrollGui
        mod._content = scrollGui.content
    else
        local scroll = CreateFrame("ScrollFrame", nil, listBg, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -28, 6)
        mod._scroll = scroll
        local content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1); scroll:SetScrollChild(content)
        mod._content = content
    end
    mod._rows = {}

    -- ----- Status bar ----------------------------------------------------
    local status = CreateFrame("Frame", nil, frame)
    status:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  4, 4)
    status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    status:SetHeight(STATUS_H)
    -- Auto-disable-new checkbox: Cairn-Gui CheckBox with vanilla fallback.
    -- Wrap tooltip OnEnter/OnLeave on the inner frame because the widget
    -- only fires kit events; we need actual GameTooltip script handlers.
    local function makeStatusCheck(initialChecked, anchorPoint, anchorTo, anchorRel, dx, onChange, tipLines)
        local cbWidget = Gui and Gui:Create("CheckBox")
        if cbWidget then
            cbWidget:SetParent(status); cbWidget:ClearAllPoints()
            cbWidget:SetWidth(20); cbWidget:SetHeight(20)
            cbWidget:SetPoint(anchorPoint, anchorTo, anchorRel, dx, 0)
            cbWidget.frame:EnableMouse(true)
            if cbWidget.frame.RegisterForClicks then
                cbWidget.frame:RegisterForClicks("AnyUp")
            end
            cbWidget:SetChecked(initialChecked and true or false)
            cbWidget:SetEventListener("OnValueChanged", function(_, _, checked)
                onChange(checked and true or false)
            end)
            cbWidget.frame:HookScript("OnEnter", function(self)
                if not GameTooltip then return end
                GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
                for _, line in ipairs(tipLines) do
                    if line.title then
                        GameTooltip:AddLine("|cffd87f3a" .. line.text .. "|r")
                    else
                        GameTooltip:AddLine(line.text, 1, 1, 1, true)
                    end
                end
                GameTooltip:Show()
            end)
            cbWidget.frame:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
            return cbWidget, cbWidget.frame
        else
            local raw = CreateFrame("CheckButton", nil, status, "UICheckButtonTemplate")
            raw:SetSize(20, 20)
            raw:SetPoint(anchorPoint, anchorTo, anchorRel, dx, 0)
            raw:SetChecked(initialChecked)
            raw:SetScript("OnClick", function(self) onChange(self:GetChecked() and true or false) end)
            raw:SetScript("OnEnter", function(self)
                if not GameTooltip then return end
                GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
                for _, line in ipairs(tipLines) do
                    if line.title then
                        GameTooltip:AddLine("|cffd87f3a" .. line.text .. "|r")
                    else
                        GameTooltip:AddLine(line.text, 1, 1, 1, true)
                    end
                end
                GameTooltip:Show()
            end)
            raw:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
            return raw, raw
        end
    end

    local autoCb, autoCbFrame = makeStatusCheck(
        ns.Manager.IsAutoDisableNew(), "LEFT", status, "LEFT", 0,
        function(v) ns.Manager.SetAutoDisableNew(v) end,
        {
            { title = true, text = "Auto-disable new addons" },
            { text = "When ON, any addon that appears in your AddOns/ folder" },
            { text = "for the first time will be disabled at the next login." },
            { text = "Reload required to take effect after a fresh install." },
        })
    mod._autoNewCb = autoCb

    local autoLabel = status:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoLabel:SetPoint("LEFT", autoCbFrame, "RIGHT", 2, 0)
    autoLabel:SetText("Auto-disable new")
    autoLabel:SetTextColor(0.85, 0.7, 0.4, 1)

    local recCb, recCbFrame = makeStatusCheck(
        ns.Manager.IsRecursiveEnable(), "LEFT", autoLabel, "RIGHT", 16,
        function(v) ns.Manager.SetRecursiveEnable(v) end,
        {
            { title = true, text = "Recursive enable" },
            { text = "When ON, enabling an addon also enables its required" },
            { text = "dependencies. Optional deps trigger a Yes/No prompt." },
        })
    mod._recCb = recCb

    local recLabel = status:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    recLabel:SetPoint("LEFT", recCbFrame, "RIGHT", 2, 0)
    recLabel:SetText("Recursive enable")
    recLabel:SetTextColor(0.85, 0.7, 0.4, 1)

    local statusText = status:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("LEFT", recLabel, "RIGHT", 16, 0)
    statusText:SetTextColor(0.85, 0.7, 0.4, 1)
    mod._statusText = statusText

    if ns.Manager.OnChange then
        mod._unsub = ns.Manager.OnChange(function() UI.Refresh() end)
    end

    UI.RefreshHeader()
    UI.Refresh()
end

function UI.RefreshHeader()
    local mod = _activeMod
    if not mod or not mod._headerLabels then return end
    for _, col in ipairs(COLUMNS) do
        local btn = mod._headerLabels[col.key]
        if btn then
            local active = (col.key == _sortKey)
            local arrow  = active and ((_sortDir == "asc") and "  ^" or "  v") or ""
            btn._fs:SetText(col.label .. arrow)
            btn._fs:SetTextColor(active and 1 or 0.85, active and 0.85 or 0.7, active and 0.5 or 0.4, 1)
        end
    end
end

local function buildRow(parent)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT)

    local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    hov:SetColorTexture(0.45, 0.32, 0.15, 0.20)
    hov:SetAllPoints(); hov:Hide()
    row._hov = hov

    -- Checkbox: Cairn-Gui CheckBox with vanilla fallback. We adapt the API
    -- so the rest of UI.Refresh can keep calling row._cb:SetChecked /
    -- :GetChecked / :Enable / :Disable / :SetAlpha regardless of backend.
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local function applyToggle(checked)
        if not row._entry then return end
        local nm = row._entry.name
        if checked then
            if ns.Manager.IsRecursiveEnable() then
                local result = ns.Manager.EnableWithDeps(nm)
                if result and result.pendingOptional and #result.pendingOptional > 0 then
                    UI.PromptOptional(result.pendingOptional)
                end
            else
                ns.Manager.SetEnabled(nm, true)
            end
        else
            ns.Manager.SetEnabled(nm, false)
        end
    end
    local cbWidget = Gui and Gui:Create("CheckBox")
    if cbWidget then
        cbWidget:SetParent(row); cbWidget:ClearAllPoints()
        cbWidget:SetWidth(20); cbWidget:SetHeight(20)
        cbWidget:SetPoint("LEFT", row, "LEFT", 4, 0)
        cbWidget.frame:EnableMouse(true)
        if cbWidget.frame.RegisterForClicks then
            cbWidget.frame:RegisterForClicks("AnyUp")
        end
        cbWidget:SetEventListener("OnValueChanged", function(_, _, checked)
            applyToggle(checked and true or false)
        end)
        row._cb = cbWidget
    else
        local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        cb:SetSize(20, 20); cb:SetPoint("LEFT", row, "LEFT", 4, 0)
        cb:SetScript("OnClick", function(self) applyToggle(self:GetChecked()) end)
        row._cb = cb
    end

    -- Column FontStrings (positions match COLUMNS).
    row._cols = {}
    local x = 4 + 24 + 4
    for _, col in ipairs(COLUMNS) do
        if col.key == "protect" then
            local btn = CreateFrame("Button", nil, row)
            btn:SetSize(col.width - 4, ROW_HEIGHT - 2)
            btn:SetPoint("LEFT", row, "LEFT", x, 0)
            local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            fs:SetAllPoints(); fs:SetJustifyH("CENTER")
            btn._fs = fs
            btn:SetScript("OnClick", function()
                if row._entry then
                    ns.Manager.SetProtected(row._entry.name, not ns.Manager.IsProtected(row._entry.name))
                end
            end)
            row._cols[col.key] = btn
        else
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("LEFT", row, "LEFT", x, 0)
            fs:SetWidth(col.width - 4)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false); fs:SetMaxLines(1)
            row._cols[col.key] = fs
        end
        x = x + col.width
    end

    row:SetScript("OnEnter", function(self)
        self._hov:Show()
        if self._entry then GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT"); tooltipFor(self._entry) end
    end)
    row:SetScript("OnLeave", function(self) self._hov:Hide(); GameTooltip:Hide() end)
    row:EnableMouse(true)

    return row
end

function UI.Refresh()
    local mod = _activeMod
    if not mod or not mod._content then return end

    local entries = ns.Manager.GetAll() or {}
    local visible = {}
    for _, e in ipairs(entries) do if passesFilter(e) then visible[#visible + 1] = e end end
    applySort(visible)

    for _, row in ipairs(mod._rows) do row:Hide() end

    local y = 0
    for i, entry in ipairs(visible) do
        local row = mod._rows[i] or buildRow(mod._content)
        mod._rows[i] = row
        row._entry = entry
        local selfProt = ns.Manager.IsSelfProtected and ns.Manager.IsSelfProtected(entry.name)
        row._cb:SetChecked(ns.Manager.IsEffectivelyEnabled(entry.name) or selfProt)
        -- ObjectBase doesn't expose SetAlpha; delegate to the inner frame
        -- when present, otherwise call directly (vanilla CheckButton path).
        local cbAlphaTarget = row._cb.frame or row._cb
        if selfProt then
            row._cb:Disable()
            cbAlphaTarget:SetAlpha(0.55)
        else
            row._cb:Enable()
            cbAlphaTarget:SetAlpha(1.0)
        end

        local nameStr = entry.title or entry.name
        if selfProt then nameStr = "|cffd87f3a" .. nameStr .. "  [essential]|r" end
        row._cols.name:SetText(nameStr)
        row._cols.status:SetText(statusBadge(entry))
        row._cols.memory:SetText(memoryStr(entry))
        row._cols.memory:SetTextColor(0.7, 0.7, 0.7, 1)
        row._cols.version:SetText(entry.version or "")
        row._cols.version:SetTextColor(0.6, 0.6, 0.6, 1)
        local prot = ns.Manager.IsProtected(entry.name)
        if selfProt then
            row._cols.protect._fs:SetText("|cffd87f3a@|r")  -- lock glyph
        else
            row._cols.protect._fs:SetText(prot and "|cffffd700*|r" or "|cff444444*|r")
        end

        row:ClearAllPoints()
        row:SetWidth(mod._scroll:GetWidth() - 24)
        row:SetPoint("TOPLEFT", mod._content, "TOPLEFT", 0, -y)
        row:Show()
        y = y + ROW_HEIGHT
    end

    if y < 1 then y = 1 end
    mod._content:SetHeight(y)
    -- UpdateScrollChildRect lives only on the raw Blizzard scrollFrame (or
    -- the kit widget's inner .scrollFrame). Guard so we work on both paths.
    if mod._scroll then
        if mod._scroll.UpdateScrollChildRect then
            mod._scroll:UpdateScrollChildRect()
        elseif mod._scroll.scrollFrame and mod._scroll.scrollFrame.UpdateScrollChildRect then
            mod._scroll.scrollFrame:UpdateScrollChildRect()
        end
    end

    if mod._statusText then
        local total = #entries
        local enabled, mem = 0, 0
        for _, e in ipairs(entries) do
            if ns.Manager.IsEnabled(e.name) then enabled = enabled + 1 end
            mem = mem + (ns.Manager.MemoryKB(e.name) or 0)
        end
        local pending = ns.Manager.PendingCount() or 0
        mod._statusText:SetText(string.format(
            "%d shown   |cff888888|r   %d enabled / %d total   |cff888888|r   %.2f MB%s",
            #visible, enabled, total, mem / 1024,
            pending > 0 and "   |cffff8080(reload required)|r" or ""))
    end

    if mod._reloadBtn then
        local n = ns.Manager.PendingCount() or 0
        if n > 0 then
            mod._reloadBtn:SetText(string.format("Apply (%d) + Reload", n))
        else
            mod._reloadBtn:SetText("Reload UI")
        end
    end
    if mod._discardBtn then
        if ns.Manager.HasPendingChange() then mod._discardBtn:Show() else mod._discardBtn:Hide() end
    end
end

function UI.OnTabShow(mod)
    _activeMod = mod
    ns.Manager.Refresh()
    UI.Refresh()
end


-- ===== Optional dependency prompt =========================================
local _optPopup
local function buildOptPopup()
    local f = CreateFrame("Frame", "ForgeAMOptPopup", UIParent, "BackdropTemplate")
    f:SetSize(420, 320)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.08, 0.06, 0.04, 0.95)
    f:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)
    f:EnableMouse(true)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cffd87f3aOptional dependencies|r")

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    hint:SetPoint("RIGHT", -12, 0)
    hint:SetJustifyH("LEFT"); hint:SetWordWrap(true)
    hint:SetText("These addons are listed as optional dependencies and are installed but disabled. Tick the ones you want to enable.")

    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    local scrollGui = Gui and Gui:Create("ScrollFrame")
    if scrollGui then
        scrollGui:SetParent(f); scrollGui:ClearAllPoints()
        scrollGui:SetPoint("TOPLEFT",     hint, "BOTTOMLEFT", 0, -8)
        scrollGui:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 38)
        f._scroll  = scrollGui
        f._content = scrollGui.content
    else
        local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT",     hint, "BOTTOMLEFT", 0, -8)
        sf:SetPoint("BOTTOMRIGHT", -32, 38)
        f._scroll = sf
        local content = CreateFrame("Frame", nil, sf); content:SetSize(1, 1); sf:SetScrollChild(content)
        f._content = content
    end
    f._rows = {}

    local cancelWidget = Gui and Gui:Create("Button")
    local cancelFrame
    if cancelWidget then
        cancelWidget:SetParent(f); cancelWidget:ClearAllPoints()
        cancelWidget:SetWidth(80); cancelWidget:SetHeight(22)
        cancelWidget:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 8)
        cancelWidget:SetText("Cancel")
        cancelWidget:SetEventListener("OnClick", function() f:Hide() end)
        cancelFrame = cancelWidget.frame
    else
        local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        cancelBtn:SetSize(80, 22); cancelBtn:SetPoint("BOTTOMRIGHT", -12, 8)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetScript("OnClick", function() f:Hide() end)
        cancelFrame = cancelBtn
    end

    local enableWidget = Gui and Gui:Create("Button")
    if enableWidget then
        enableWidget:SetParent(f); enableWidget:ClearAllPoints()
        enableWidget:SetWidth(120); enableWidget:SetHeight(22)
        enableWidget:SetPoint("RIGHT", cancelFrame, "LEFT", -6, 0)
        enableWidget:SetText("Enable selected")
        f._enableBtn = enableWidget
    else
        local enableBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        enableBtn:SetSize(120, 22); enableBtn:SetPoint("RIGHT", cancelFrame, "LEFT", -6, 0)
        enableBtn:SetText("Enable selected")
        f._enableBtn = enableBtn
    end
    return f
end

function UI.PromptOptional(pending)
    if not pending or #pending == 0 then return end
    if not _optPopup then _optPopup = buildOptPopup() end
    local f = _optPopup
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    for _, row in ipairs(f._rows) do row:Hide() end
    local y = 0
    for i, item in ipairs(pending) do
        local row = f._rows[i]
        if not row then
            row = CreateFrame("Frame", nil, f._content)
            row:SetHeight(22)
            local cb, cbFrame
            local cbWidget = Gui and Gui:Create("CheckBox")
            if cbWidget then
                cbWidget:SetParent(row); cbWidget:ClearAllPoints()
                cbWidget:SetWidth(20); cbWidget:SetHeight(20)
                cbWidget:SetPoint("LEFT", row, "LEFT", 4, 0)
                cbWidget.frame:EnableMouse(true)
                if cbWidget.frame.RegisterForClicks then
                    cbWidget.frame:RegisterForClicks("AnyUp")
                end
                cbWidget:SetChecked(true)
                cb, cbFrame = cbWidget, cbWidget.frame
            else
                local raw = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                raw:SetSize(20, 20); raw:SetPoint("LEFT", row, "LEFT", 4, 0)
                raw:SetChecked(true)
                cb, cbFrame = raw, raw
            end
            row._cb = cb
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("LEFT", cbFrame, "RIGHT", 4, 0)
            text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            text:SetJustifyH("LEFT"); text:SetWordWrap(false); text:SetMaxLines(1)
            row._text = text
            f._rows[i] = row
        end
        row._dep = item.dep
        row._cb:SetChecked(true)
        row._text:SetText(string.format("%s   |cffaaaaaa(suggested by %s)|r", item.dep, item.requestor))
        row:ClearAllPoints()
        row:SetWidth((f._scroll:GetWidth() or 380) - 8)
        row:SetPoint("TOPLEFT", f._content, "TOPLEFT", 0, -y)
        row:Show()
        y = y + 24
    end
    if y < 1 then y = 1 end
    f._content:SetHeight(y)
    if f._scroll.UpdateScrollChildRect then
        f._scroll:UpdateScrollChildRect()
    elseif f._scroll.scrollFrame and f._scroll.scrollFrame.UpdateScrollChildRect then
        f._scroll.scrollFrame:UpdateScrollChildRect()
    end

    local function onEnable()
        for _, row in ipairs(f._rows) do
            if row:IsShown() and row._cb and row._cb:GetChecked() and row._dep then
                ns.Manager.SetEnabled(row._dep, true)
            end
        end
        f:Hide()
        if UI.Refresh then UI.Refresh() end
    end
    if f._enableBtn.SetEventListener then
        f._enableBtn:SetEventListener("OnClick", onEnable)
    else
        f._enableBtn:SetScript("OnClick", onEnable)
    end

    f:Show()
end

-- ===== Diagnostics ========================================================
-- Hitbox dumper for the chain-misroute investigation. Prints, for every
-- toolbar element, its visual rect + parent + visibility + frame strata so
-- we can compare what WoW thinks the click target is against what's drawn.
-- Call from chat: /run ForgeAMDumpToolbar()
function _G.ForgeAMDumpToolbar()
    local mod = _activeMod
    if not mod or not mod._toolbarBtns then
        print("|cffff8800ForgeAM|r: toolbar not built yet (open the Addons tab first).")
        return
    end
    local bar = mod._toolbarBar
    print(string.format("|cff88ccffForgeAM toolbar dump|r (backend=%s)", tostring(mod._toolbarBackend or "?")))
    if bar then
        print(string.format("  bar: L=%.1f R=%.1f T=%.1f B=%.1f W=%.1f H=%.1f shown=%s",
            bar:GetLeft() or -1, bar:GetRight() or -1, bar:GetTop() or -1, bar:GetBottom() or -1,
            bar:GetWidth() or -1, bar:GetHeight() or -1, tostring(bar:IsShown())))
    end
    for _, e in ipairs(mod._toolbarBtns) do
        local f = e.frame
        if not f then
            print(string.format("  %-12s : <nil frame>", e.name))
        else
            local p = f:GetParent()
            local pname = (p and (p.GetName and p:GetName())) or tostring(p)
            local L, R, T, B = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
            print(string.format("  %-12s : L=%.1f R=%.1f T=%.1f B=%.1f W=%.1f H=%.1f shown=%s vis=%s strata=%s level=%d parent=%s",
                e.name,
                L or -1, R or -1, T or -1, B or -1,
                f:GetWidth() or -1, f:GetHeight() or -1,
                tostring(f:IsShown()), tostring(f:IsVisible()),
                tostring(f:GetFrameStrata()), f:GetFrameLevel() or -1,
                tostring(pname)))
        end
    end
    print("|cff88ccff--end dump--|r  Now click each button and note which one *actually* fires.")
end

-- Print which frame the mouse is over RIGHT NOW. Hover the misrouting
-- button, then run /run ForgeAMMouseFocus() (use a chat macro or click-bind
-- so the focus is captured at the right moment). If the focused frame is
-- NOT one of the toolbar buttons, that's the click-eater we're looking for.
function _G.ForgeAMMouseFocus()
    local f = GetMouseFoci and GetMouseFoci() or (GetMouseFocus and { GetMouseFocus() }) or {}
    if type(f) ~= "table" then f = { f } end
    if #f == 0 then
        print("|cffff8800ForgeAM|r: no mouse focus.")
        return
    end
    print(string.format("|cff88ccffForgeAM mouse focus|r (%d frame(s) under cursor):", #f))
    for i, fr in ipairs(f) do
        if fr then
            local nm = (fr.GetName and fr:GetName()) or "<unnamed>"
            local pt = fr.GetParent and fr:GetParent()
            local pname = (pt and pt.GetName and pt:GetName()) or tostring(pt)
            local strata = fr.GetFrameStrata and fr:GetFrameStrata() or "?"
            local lvl = fr.GetFrameLevel and fr:GetFrameLevel() or -1
            local L = fr.GetLeft and fr:GetLeft() or -1
            local R = fr.GetRight and fr:GetRight() or -1
            print(string.format("  [%d] %s  strata=%s level=%d  L=%.1f R=%.1f  parent=%s  ref=%s",
                i, tostring(nm), tostring(strata), lvl, L or -1, R or -1, tostring(pname), tostring(fr)))
        end
    end
end

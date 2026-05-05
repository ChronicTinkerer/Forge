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
    _activeMod._filterBtn._label:SetText(label)
end

-- ===== Sets dropdown popup ================================================
local function refreshSetsDropdown(f)
    for _, row in ipairs(f._rows) do row:Hide() end
    local names = ns.Manager.ListSetNames() or {}
    local y = 0
    for i, name in ipairs(names) do
        local row = f._rows[i]
        if not row then
            row = CreateFrame("Button", nil, f._content)
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
        row:SetWidth(f._scroll:GetWidth() - 24)
        row:SetPoint("TOPLEFT", f._content, "TOPLEFT", 0, -y)
        row:Show()
        y = y + 20
    end
    if y < 1 then y = 1 end
    f._content:SetHeight(y)
    f._scroll:UpdateScrollChildRect()
    f._emptyText:SetShown(#names == 0)
end

local function buildSetsDropdown()
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

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -22)
    scroll:SetPoint("BOTTOMRIGHT", -22, 30)
    f._scroll = scroll
    local content = CreateFrame("Frame", nil, scroll); content:SetSize(1,1); scroll:SetScrollChild(content)
    f._content = content
    f._rows = {}

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("CENTER", scroll, "CENTER", 0, 0)
    empty:SetText("(no sets saved)")
    empty:Hide()
    f._emptyText = empty

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(60, 20)
    close:SetPoint("BOTTOMRIGHT", -6, 6)
    close:SetText("Close")
    close:SetScript("OnClick", function() f:Hide() end)

    return f
end

local function buildNamePrompt()
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

    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(280, 22); eb:SetPoint("LEFT", label, "RIGHT", 8, 0); eb:SetAutoFocus(true)
    f._eb = eb

    local ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    ok:SetSize(80, 22); ok:SetPoint("BOTTOMRIGHT", -12, 10)
    f._ok = ok

    local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancel:SetSize(80, 22); cancel:SetPoint("RIGHT", ok, "LEFT", -6, 0); cancel:SetText("Cancel")
    cancel:SetScript("OnClick", function() f:Hide() end)

    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    eb:SetScript("OnEnterPressed", function() ok:Click() end)
    return f
end

function UI._showSetNamePrompt(title, defaultText, onAccept)
    local f = ns._namePrompt
    if not f then f = buildNamePrompt(); ns._namePrompt = f end
    f._title:SetText("|cffd87f3a" .. (title or "Set name") .. "|r")
    f._ok:SetText("OK")
    f._ok:SetScript("OnClick", function()
        local v = (f._eb:GetText() or ""):match("^%s*(.-)%s*$") or ""
        if v == "" then return end
        f:Hide()
        if onAccept then onAccept(v) end
    end)
    f._eb:SetText(defaultText or "")
    f:Show(); f._eb:SetFocus()
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

    -- ----- Toolbar -------------------------------------------------------
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  4, -4)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    bar:SetHeight(TOOLBAR_H)

    -- Search box. (Cairn-Gui Input migration tried this session along with
    -- a button refactor; click misrouting surfaced -- clicks on the right
    -- toolbar buttons were dispatched to filterBtn 8 buttons away. Theory
    -- was an ObjectBase.SetParent nil-intermediate issue but direct
    -- SetParent didn't fix it. Reverted to vanilla while we investigate
    -- with proper runtime diagnostics next session.)
    -- Toolbar layout budget (recap, after the chain-misroute investigation
    -- 2026-05-04): bar is roughly 850 px wide. Search 110 + filter 90 +
    -- 8 action buttons (most 70, reload 90) + gaps + margins must fit. If
    -- you widen any of these and the chain anchors silently overlap, you
    -- get clicks routed to the wrong button (the older filterBtn layout
    -- bug -- it overlapped exportBtn / enableBtn / disableBtn).
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

    local search = CreateFrame("EditBox", nil, searchBg)
    search:SetMultiLine(false); search:SetAutoFocus(false)
    search:SetFontObject("ChatFontNormal")
    search:SetPoint("LEFT", 6, 0); search:SetPoint("RIGHT", -6, 0)
    search:SetHeight(BTN_HEIGHT - 4); search:SetTextInsets(0, 0, 0, 0)
    search:SetScript("OnTextChanged", function(self) _filterText = self:GetText() or ""; UI.Refresh() end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText(""); _filterText = ""; UI.Refresh() end)

    local placeholder = searchBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", 8, 0); placeholder:SetText("Filter by name...")
    search:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    search:SetScript("OnEditFocusLost", function(self)
        if (self:GetText() or "") == "" then placeholder:Show() end
    end)

    -- Status filter dropdown button. Width 90 -- the FILTER_STATUSES table
    -- carries a short-form label per status that's chosen for fitting in
    -- this width; the popup itself uses the full descriptive labels.
    local filterBtn = CreateFrame("Button", nil, bar, "BackdropTemplate")
    filterBtn:SetSize(90, BTN_HEIGHT)
    filterBtn:SetPoint("LEFT", searchBg, "RIGHT", 6, 0)
    filterBtn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    filterBtn:SetBackdropColor(0.05, 0.05, 0.05, 0.40)
    filterBtn:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    local fLabel = filterBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fLabel:SetPoint("LEFT", 6, 0); fLabel:SetPoint("RIGHT", -22, 0); fLabel:SetJustifyH("LEFT")
    fLabel:SetWordWrap(false); fLabel:SetMaxLines(1)
    filterBtn._label = fLabel
    local fArrow = filterBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fArrow:SetPoint("RIGHT", -6, 0); fArrow:SetText("|cffd87f3av|r")
    filterBtn:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(0.85, 0.50, 0.20, 1) end)
    filterBtn:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.4, 0.3, 0.15, 1) end)
    filterBtn:SetScript("OnClick", function(self)
        if not ns._filterPopup then ns._filterPopup = buildFilterPopup() end
        local f = ns._filterPopup
        if f:IsShown() then f:Hide() return end
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        refreshFilterPopup(f)
        f:Show()
    end)
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

    local Gui_OK = USE_CAIRN_TOOLBAR and (LibStub and LibStub("Cairn-Gui-Core-1.0", true)) or nil

    if Gui_OK then
        -- Cairn-Gui Button variant. Each helper returns (widget, frame). The
        -- frame is what other code SetPoints to (popups, etc.). Click handler
        -- goes on the widget via SetEventListener so PlaySound + FireEvent
        -- still run inside the kit.
        local Gui = Gui_OK
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

    local scroll = CreateFrame("ScrollFrame", nil, listBg, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -28, 6)
    mod._scroll = scroll

    local content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1); scroll:SetScrollChild(content)
    mod._content = content
    mod._rows = {}

    -- ----- Status bar ----------------------------------------------------
    local status = CreateFrame("Frame", nil, frame)
    status:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  4, 4)
    status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    status:SetHeight(STATUS_H)
    local autoCb = CreateFrame("CheckButton", nil, status, "UICheckButtonTemplate")
    autoCb:SetSize(20, 20)
    autoCb:SetPoint("LEFT", status, "LEFT", 0, 0)
    autoCb:SetChecked(ns.Manager.IsAutoDisableNew())
    autoCb:SetScript("OnClick", function(self)
        ns.Manager.SetAutoDisableNew(self:GetChecked() and true or false)
    end)
    autoCb:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("|cffd87f3aAuto-disable new addons|r")
        GameTooltip:AddLine("When ON, any addon that appears in your AddOns/ folder", 1, 1, 1, true)
        GameTooltip:AddLine("for the first time will be disabled at the next login.", 1, 1, 1, true)
        GameTooltip:AddLine("Reload required to take effect after a fresh install.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    autoCb:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    mod._autoNewCb = autoCb

    local autoLabel = status:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoLabel:SetPoint("LEFT", autoCb, "RIGHT", 2, 0)
    autoLabel:SetText("Auto-disable new")
    autoLabel:SetTextColor(0.85, 0.7, 0.4, 1)

    local recCb = CreateFrame("CheckButton", nil, status, "UICheckButtonTemplate")
    recCb:SetSize(20, 20)
    recCb:SetPoint("LEFT", autoLabel, "RIGHT", 16, 0)
    recCb:SetChecked(ns.Manager.IsRecursiveEnable())
    recCb:SetScript("OnClick", function(self)
        ns.Manager.SetRecursiveEnable(self:GetChecked() and true or false)
    end)
    recCb:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("|cffd87f3aRecursive enable|r")
        GameTooltip:AddLine("When ON, enabling an addon also enables its required", 1, 1, 1, true)
        GameTooltip:AddLine("dependencies. Optional deps trigger a Yes/No prompt.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    recCb:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    mod._recCb = recCb

    local recLabel = status:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    recLabel:SetPoint("LEFT", recCb, "RIGHT", 2, 0)
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

    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(20, 20); cb:SetPoint("LEFT", row, "LEFT", 4, 0)
    cb:SetScript("OnClick", function(self)
        if not row._entry then return end
        local nm = row._entry.name
        if self:GetChecked() then
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
    end)
    row._cb = cb

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
        if selfProt then
            row._cb:Disable()
            row._cb:SetAlpha(0.55)
        else
            row._cb:Enable()
            row._cb:SetAlpha(1.0)
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
    if mod._scroll then mod._scroll:UpdateScrollChildRect() end

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

    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     hint, "BOTTOMLEFT", 0, -8)
    sf:SetPoint("BOTTOMRIGHT", -32, 38)
    f._scroll = sf
    local content = CreateFrame("Frame", nil, sf); content:SetSize(1, 1); sf:SetScrollChild(content)
    f._content = content
    f._rows = {}

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetSize(80, 22); cancelBtn:SetPoint("BOTTOMRIGHT", -12, 8)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() f:Hide() end)

    local enableBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    enableBtn:SetSize(120, 22); enableBtn:SetPoint("RIGHT", cancelBtn, "LEFT", -6, 0)
    enableBtn:SetText("Enable selected")
    f._enableBtn = enableBtn
    return f
end

function UI.PromptOptional(pending)
    if not pending or #pending == 0 then return end
    if not _optPopup then _optPopup = buildOptPopup() end
    local f = _optPopup

    for _, row in ipairs(f._rows) do row:Hide() end
    local y = 0
    for i, item in ipairs(pending) do
        local row = f._rows[i]
        if not row then
            row = CreateFrame("Frame", nil, f._content)
            row:SetHeight(22)
            local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            cb:SetSize(20, 20); cb:SetPoint("LEFT", row, "LEFT", 4, 0)
            cb:SetChecked(true)
            row._cb = cb
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
            text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            text:SetJustifyH("LEFT"); text:SetWordWrap(false); text:SetMaxLines(1)
            row._text = text
            f._rows[i] = row
        end
        row._dep = item.dep
        row._cb:SetChecked(true)
        row._text:SetText(string.format("%s   |cffaaaaaa(suggested by %s)|r", item.dep, item.requestor))
        row:ClearAllPoints()
        row:SetWidth(f._scroll:GetWidth() - 8)
        row:SetPoint("TOPLEFT", f._content, "TOPLEFT", 0, -y)
        row:Show()
        y = y + 24
    end
    if y < 1 then y = 1 end
    f._content:SetHeight(y)
    f._scroll:UpdateScrollChildRect()

    f._enableBtn:SetScript("OnClick", function()
        for _, row in ipairs(f._rows) do
            if row:IsShown() and row._cb and row._cb:GetChecked() and row._dep then
                ns.Manager.SetEnabled(row._dep, true)
            end
        end
        f:Hide()
        if UI.Refresh then UI.Refresh() end
    end)

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

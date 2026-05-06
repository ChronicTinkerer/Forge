-- Forge_CVars.UI: the top-level layout for the CVars tab.
--
-- Lives inside the Forge main window's content area (the `parent` arg to
-- Build is Forge.Window's contentArea). Owns:
--
--   [search] [Cat: All v] [x] Modified only       [Refresh] [last-refresh]
--   ----------------------------------------------------------------------
--   List (virtualized rows; built by ns.List.Build)
--   ----------------------------------------------------------------------
--   Profile: [<dropdown>] [New] [Save] [Apply] [Export] [Import]
--
-- All consumer-facing widgets go through `Cairn-Gui-Core-1.0` (Input, Button,
-- CheckBox, ScrollFrame). For dropdowns we follow the established
-- Forge_AddonManager pattern: a Cairn Button as the trigger plus a popup
-- frame that uses a Cairn ScrollFrame internally.
--
-- Each Gui call has a raw-frame fallback for the case where Cairn-Gui-Core
-- failed to load — same shape as Forge_Console / Forge_AddonManager.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H = 28
local FOOTER_H  = 28
local PAD       = 6
local BTN_H     = 22

-- --------------------------------------------------------------------------
-- Tiny chat helper.
-- --------------------------------------------------------------------------
local function out(msg)
    if ns.out then ns.out(msg)
    elseif DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge CVars:|r " .. tostring(msg))
    end
end

-- --------------------------------------------------------------------------
-- Module-scope handles populated by Build.
-- --------------------------------------------------------------------------
local _frame
local _toolbar, _footer, _listArea
local _searchAnchor, _categoryBtn, _modifiedCheck, _refreshStatus
local _profileBtn
local _saveBtn, _applyBtn, _exportBtn

local function uiState()
    local p = ns.db and ns.db.profile or nil
    if not p then return {} end
    if p.ui == nil then p.ui = {} end
    return p.ui
end

-- --------------------------------------------------------------------------
-- Refresh.
-- --------------------------------------------------------------------------
function UI.RefreshList()
    if not (ns.Snapshot and ns.List) then return end
    local s = uiState()
    local indices = ns.Snapshot.Filter({
        query        = s.lastSearch or "",
        category     = s.lastCategory or "All",
        modifiedOnly = s.showModifiedOnly,
        sort         = s.sort or "name",
        sortDir      = s.sortDir or "asc",
    })
    ns.List.SetData(indices)

    if _refreshStatus and ns.Snapshot.RefreshedAt() then
        local t = ns.Snapshot.RefreshedAt()
        local age = math.max(0, ((time and time()) or 0) - t)
        _refreshStatus:SetText(string.format(
            "|cff888888%d shown / %d total - refreshed %ds ago|r",
            #indices, #ns.Snapshot.GetAll(), age))
    end
end

local function refreshProfileButtons()
    local active = ns.Profiles and ns.Profiles.Active() or nil
    local hasActive = (active ~= nil and ns.Profiles.Get(active) ~= nil)
    -- Cairn Button:Disable / Enable on the widget itself; raw button uses
    -- :SetEnabled on the frame.
    local function setEnabled(b, on)
        if not b then return end
        if b.Enable and b.Disable then
            if on then b:Enable() else b:Disable() end
        else
            b:SetEnabled(on)
        end
    end
    setEnabled(_saveBtn,   hasActive)
    setEnabled(_applyBtn,  hasActive)
    setEnabled(_exportBtn, hasActive)
end

-- --------------------------------------------------------------------------
-- Generic Cairn-Button + popup-list helper. Returns the Button widget (Cairn
-- or raw) plus its underlying frame for anchor use.
--
-- buildPopup(popupFrame) is called once on first open to populate static
-- chrome (close button, scroll, etc.).
-- refreshPopup(popupFrame) is called every time the popup opens to rebuild
-- the row list against current data.
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

-- --------------------------------------------------------------------------
-- Category popup.
-- --------------------------------------------------------------------------
local _categoryPopup
local function refreshCategoryPopup(f)
    if not (f and f._content) then return end
    local content = f._content
    f._rows = f._rows or {}
    for _, row in ipairs(f._rows) do row:Hide() end
    local cats = ns.Snapshot and ns.Snapshot.Categories() or { "All" }
    local s = uiState()
    local rowH = 22
    for i, cat in ipairs(cats) do
        local row = f._rows[i]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(rowH)
            row:RegisterForClicks("LeftButtonUp")
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(row)
            hl:SetColorTexture(1, 1, 1, 0.08)
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("LEFT", row, "LEFT", 8, 0)
            text:SetJustifyH("LEFT")
            row._text = text
            f._rows[i] = row
        end
        row:SetWidth((content:GetWidth() or 200) - 8)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -((i - 1) * rowH))
        row._text:SetText(cat)
        if cat == (s.lastCategory or "All") then
            row._text:SetTextColor(1, 0.85, 0.40)
        else
            row._text:SetTextColor(0.85, 0.85, 0.85)
        end
        row:SetScript("OnClick", function()
            s.lastCategory = cat
            setBtnLabel(_categoryBtn, cat)
            f:Hide()
            UI.RefreshList()
        end)
        row:Show()
    end
    content:SetHeight(math.max(1, #cats * rowH + 8))
end

local function buildCategoryPopup()
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local f = buildPopupShell("ForgeCVarsCategoryPopup", 180, 260)

    local scrollGui = Gui and Gui:Create("ScrollFrame")
    if scrollGui then
        scrollGui:SetParent(f); scrollGui:ClearAllPoints()
        scrollGui:SetPoint("TOPLEFT",     f, "TOPLEFT",      4, -4)
        scrollGui:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4,  4)
        f._scroll  = scrollGui
        f._content = scrollGui.content
    else
        local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 4, -4); sf:SetPoint("BOTTOMRIGHT", -22, 4)
        local content = CreateFrame("Frame", nil, sf); content:SetSize(1, 1)
        sf:SetScrollChild(content)
        f._scroll = sf; f._content = content
    end
    return f
end

local function toggleCategoryPopup()
    if not _categoryPopup then _categoryPopup = buildCategoryPopup() end
    local f = _categoryPopup
    if f:IsShown() then f:Hide(); return end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", _categoryBtn.frame or _categoryBtn, "BOTTOMLEFT", 0, -2)
    refreshCategoryPopup(f)
    f:Show()
end

-- --------------------------------------------------------------------------
-- Profile popup.
-- --------------------------------------------------------------------------
local _profilePopup
local function refreshProfilePopup(f)
    if not (f and f._content and ns.Profiles) then return end
    local content = f._content
    f._rows = f._rows or {}
    for _, row in ipairs(f._rows) do row:Hide() end
    local list = { "(none)" }
    for _, n in ipairs(ns.Profiles.List()) do list[#list + 1] = n end
    local active = ns.Profiles.Active()
    local rowH = 22
    for i, label in ipairs(list) do
        local row = f._rows[i]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(rowH)
            row:RegisterForClicks("LeftButtonUp")
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(row)
            hl:SetColorTexture(1, 1, 1, 0.08)
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("LEFT", row, "LEFT", 8, 0)
            row._text = text
            f._rows[i] = row
        end
        row:SetWidth((content:GetWidth() or 200) - 8)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -((i - 1) * rowH))
        row._text:SetText(label)
        local isActive = (label == "(none)" and active == nil) or (label == active)
        row._text:SetTextColor(isActive and 1 or 0.85, isActive and 0.85 or 0.85, isActive and 0.40 or 0.85)
        row:SetScript("OnClick", function()
            if label == "(none)" then
                ns.Profiles.SetActive(nil)
                setBtnLabel(_profileBtn, "(none)")
            else
                ns.Profiles.SetActive(label)
                setBtnLabel(_profileBtn, label)
            end
            f:Hide()
            refreshProfileButtons()
        end)
        row:Show()
    end
    content:SetHeight(math.max(1, #list * rowH + 8))
end

local function buildProfilePopup()
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local f = buildPopupShell("ForgeCVarsProfilePopup", 200, 240)
    local scrollGui = Gui and Gui:Create("ScrollFrame")
    if scrollGui then
        scrollGui:SetParent(f); scrollGui:ClearAllPoints()
        scrollGui:SetPoint("TOPLEFT",     f, "TOPLEFT",      4, -4)
        scrollGui:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4,  4)
        f._scroll  = scrollGui
        f._content = scrollGui.content
    else
        local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 4, -4); sf:SetPoint("BOTTOMRIGHT", -22, 4)
        local content = CreateFrame("Frame", nil, sf); content:SetSize(1, 1)
        sf:SetScrollChild(content)
        f._scroll = sf; f._content = content
    end
    return f
end

local function toggleProfilePopup()
    if not _profilePopup then _profilePopup = buildProfilePopup() end
    local f = _profilePopup
    if f:IsShown() then f:Hide(); return end
    f:ClearAllPoints()
    f:SetPoint("BOTTOMLEFT", _profileBtn.frame or _profileBtn, "TOPLEFT", 0, 2)
    refreshProfilePopup(f)
    f:Show()
end

-- --------------------------------------------------------------------------
-- Name prompt (used by New / Save As). Cairn Input + Button widgets inside
-- a small backdrop Frame (matches Forge_AddonManager buildNamePrompt).
-- --------------------------------------------------------------------------
local _namePrompt
local function buildNamePrompt()
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetSize(360, 110); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.08, 0.06, 0.04, 0.95)
    f:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)
    f:EnableMouse(true); f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    f._title = title

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 12, -36)
    label:SetText("Name:")

    local inputWidget = Gui and Gui:Create("Input")
    local ebGetText, ebSetText, ebSetFocus, innerEb
    if inputWidget then
        inputWidget:SetParent(f); inputWidget:ClearAllPoints()
        inputWidget:SetWidth(280); inputWidget:SetHeight(22)
        inputWidget:SetPoint("LEFT", label, "RIGHT", 8, 0)
        ebGetText = function() return inputWidget:GetText() or "" end
        ebSetText = function(s) inputWidget:SetText(s or "") end
        ebSetFocus = function() inputWidget.editBox:SetFocus() end
        innerEb = inputWidget.editBox
        f._input = inputWidget
    else
        local raw = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        raw:SetSize(280, 22); raw:SetPoint("LEFT", label, "RIGHT", 8, 0)
        raw:SetAutoFocus(true)
        ebGetText = function() return raw:GetText() or "" end
        ebSetText = function(s) raw:SetText(s or "") end
        ebSetFocus = function() raw:SetFocus() end
        innerEb = raw
        f._input = raw
    end
    f._ebGetText  = ebGetText
    f._ebSetText  = ebSetText
    f._ebSetFocus = ebSetFocus

    local function makeBtn(labelText, onClick)
        local b = Gui and Gui:Create("Button")
        if b then
            b:SetParent(f); b:ClearAllPoints()
            b:SetWidth(80); b:SetHeight(22)
            b:SetText(labelText)
            b:SetEventListener("OnClick", onClick)
            return b, b.frame
        else
            local raw = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            raw:SetSize(80, 22); raw:SetText(labelText)
            raw:SetScript("OnClick", onClick)
            return raw, raw
        end
    end

    local function fireOk()
        local v = (f._ebGetText() or ""):match("^%s*(.-)%s*$") or ""
        if v == "" then return end
        f:Hide()
        if f._okHandler then f._okHandler(v) end
    end

    local ok, okFrame = makeBtn("OK", fireOk)
    ok:ClearAllPoints(); ok:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
    f._ok = ok

    local cancel = makeBtn("Cancel", function() f:Hide() end)
    cancel:ClearAllPoints(); cancel:SetPoint("RIGHT", okFrame, "LEFT", -6, 0)

    innerEb:SetScript("OnEscapePressed", function() f:Hide() end)
    innerEb:HookScript("OnEnterPressed", fireOk)
    return f
end

local function showNamePrompt(titleText, defaultText, onAccept)
    if not _namePrompt then _namePrompt = buildNamePrompt() end
    local f = _namePrompt
    f._title:SetText("|cffd87f3a" .. (titleText or "Name") .. "|r")
    f._okHandler = onAccept
    f._ebSetText(defaultText or "")
    f:Show()
    f._ebSetFocus()
end

-- Reload-required prompt stays as StaticPopup since it's a Blizzard system
-- dialog, not a custom UI shell. Equivalent to Forge_AddonManager's
-- FORGE_AM_RELOAD popup.
StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["FORGE_CVARS_RELOAD_PROMPT"] = StaticPopupDialogs["FORGE_CVARS_RELOAD_PROMPT"] or {
    text         = "%d CVars applied. Some require /reload to take effect.",
    button1      = "Reload",
    button2      = "Later",
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    OnAccept     = function() ReloadUI() end,
    preferredIndex = 3,
}

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

    -- Search box (Cairn Input). Per Forge_AddonManager pattern, hook the
    -- inner editBox for OnTextChanged since the widget itself doesn't
    -- expose that event.
    local searchAnchor
    do
        local widget = Gui and Gui:Create("Input")
        if widget then
            widget:SetParent(bar); widget:ClearAllPoints()
            widget:SetWidth(180); widget:SetHeight(BTN_H)
            widget:SetPoint("LEFT", bar, "LEFT", 4, 0)
            widget:SetText(s.lastSearch or "")
            widget.editBox:HookScript("OnTextChanged", function(self)
                s.lastSearch = self:GetText() or ""
                UI.RefreshList()
            end)
            widget:SetEventListener("OnEscapePressed", function()
                widget:SetText(""); s.lastSearch = ""; UI.RefreshList()
            end)
            searchAnchor = widget.frame
        else
            local raw = CreateFrame("EditBox", nil, bar, "InputBoxTemplate")
            raw:SetSize(180, BTN_H)
            raw:SetPoint("LEFT", bar, "LEFT", 4, 0)
            raw:SetAutoFocus(false); raw:SetFontObject("ChatFontNormal")
            raw:SetText(s.lastSearch or "")
            raw:SetScript("OnTextChanged", function(self)
                s.lastSearch = self:GetText() or ""; UI.RefreshList()
            end)
            raw:SetScript("OnEscapePressed", function(self)
                self:ClearFocus(); self:SetText(""); s.lastSearch = ""; UI.RefreshList()
            end)
            searchAnchor = raw
        end
    end
    _searchAnchor = searchAnchor

    -- Category trigger button (opens category popup).
    local catBtn, catBtnFrame = makeTriggerButton(bar, s.lastCategory or "All", 130, toggleCategoryPopup)
    catBtn:ClearAllPoints()
    catBtn:SetPoint("LEFT", searchAnchor, "RIGHT", 6, 0)
    _categoryBtn = catBtn

    -- Modified-only checkbox (Cairn CheckBox).
    local check
    do
        local widget = Gui and Gui:Create("CheckBox")
        if widget then
            widget:SetParent(bar); widget:ClearAllPoints()
            widget:SetWidth(20); widget:SetHeight(20)
            widget:SetPoint("LEFT", catBtnFrame, "RIGHT", 8, 0)
            widget:SetChecked(s.showModifiedOnly and true or false)
            widget:SetEventListener("OnValueChanged", function(_, _, checked)
                s.showModifiedOnly = checked and true or false
                UI.RefreshList()
            end)
            check = widget
        else
            local raw = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
            raw:SetSize(20, 20)
            raw:SetPoint("LEFT", catBtnFrame, "RIGHT", 8, 0)
            raw:SetChecked(s.showModifiedOnly and true or false)
            raw:SetScript("OnClick", function(self)
                s.showModifiedOnly = self:GetChecked() and true or false
                UI.RefreshList()
            end)
            check = raw
        end
    end
    _modifiedCheck = check
    local checkLbl = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    checkLbl:SetPoint("LEFT", check.frame or check, "RIGHT", 4, 0)
    checkLbl:SetText("Modified only")

    -- Refresh button.
    local refreshBtn
    do
        local widget = Gui and Gui:Create("Button")
        if widget then
            widget:SetParent(bar); widget:ClearAllPoints()
            widget:SetWidth(80); widget:SetHeight(BTN_H)
            widget:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
            widget:SetText("Refresh")
            widget:SetEventListener("OnClick", function()
                if ns.Snapshot then ns.Snapshot.Refresh() end
                UI.RefreshList()
            end)
            refreshBtn = widget
        else
            local raw = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
            raw:SetSize(80, BTN_H)
            raw:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
            raw:SetText("Refresh")
            raw:SetScript("OnClick", function()
                if ns.Snapshot then ns.Snapshot.Refresh() end
                UI.RefreshList()
            end)
            refreshBtn = raw
        end
    end

    -- Last-refresh status text, anchored to the left of Refresh.
    local stat = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    stat:SetPoint("RIGHT", refreshBtn.frame or refreshBtn, "LEFT", -8, 0)
    stat:SetJustifyH("RIGHT")
    _refreshStatus = stat
end

-- --------------------------------------------------------------------------
-- Footer.
-- --------------------------------------------------------------------------
local function buildFooter(parent)
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetPoint("BOTTOMLEFT",  parent, "BOTTOMLEFT",  0, 0)
    bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    bar:SetHeight(FOOTER_H)
    _footer = bar

    local label = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", bar, "LEFT", 12, 0)
    label:SetText("Profile:")

    local active = ns.Profiles and ns.Profiles.Active() or nil
    local profBtn, profBtnFrame = makeTriggerButton(bar, active or "(none)", 160, toggleProfilePopup)
    profBtn:ClearAllPoints()
    profBtn:SetPoint("LEFT", label, "RIGHT", 6, 0)
    _profileBtn = profBtn

    local function makeFooterBtn(text, onClick)
        local widget = Gui and Gui:Create("Button")
        if widget then
            widget:SetParent(bar); widget:ClearAllPoints()
            widget:SetWidth(70); widget:SetHeight(BTN_H)
            widget:SetText(text)
            widget:SetEventListener("OnClick", onClick)
            return widget, widget.frame
        else
            local raw = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
            raw:SetSize(70, BTN_H); raw:SetText(text)
            raw:SetScript("OnClick", onClick)
            return raw, raw
        end
    end

    local newBtn, newF       = makeFooterBtn("New", function()
        showNamePrompt("New profile", "", function(nm)
            local entries = ns.Profiles.CaptureCurrentDiffs()
            local ok, err = ns.Profiles.Save(nm, entries)
            if ok then
                ns.Profiles.SetActive(nm)
                setBtnLabel(_profileBtn, nm)
                refreshProfileButtons()
                local n = 0; for _ in pairs(entries) do n = n + 1 end
                out(string.format("saved profile '%s' (%d modified CVars).", nm, n))
            else
                out("save failed: " .. tostring(err))
            end
        end)
    end)
    newBtn:ClearAllPoints(); newBtn:SetPoint("LEFT", profBtnFrame, "RIGHT", 4, 0)

    local saveBtn, saveF     = makeFooterBtn("Save", function()
        local active2 = ns.Profiles.Active()
        if not active2 then out("no active profile to save into.") return end
        local entries = ns.Profiles.CaptureCurrentDiffs()
        local ok, err = ns.Profiles.Save(active2, entries)
        if ok then
            local n = 0; for _ in pairs(entries) do n = n + 1 end
            out(string.format("updated profile '%s' (%d modified CVars).", active2, n))
        else
            out("save failed: " .. tostring(err))
        end
    end)
    saveBtn:ClearAllPoints(); saveBtn:SetPoint("LEFT", newF, "RIGHT", 4, 0)
    _saveBtn = saveBtn

    local applyBtn, applyF   = makeFooterBtn("Apply", function()
        local active2 = ns.Profiles.Active()
        if not active2 then out("no active profile to apply.") return end
        local applied, failed, needsReload = ns.Profiles.Apply(active2)
        out(string.format("applied profile '%s': %d ok, %d failed.", active2, applied, #failed))
        for _, fail in ipairs(failed) do
            out(string.format("  fail: %s = %s (%s)", fail.name, tostring(fail.value), tostring(fail.err)))
        end
        UI.RefreshList()
        if needsReload then StaticPopup_Show("FORGE_CVARS_RELOAD_PROMPT", applied) end
    end)
    applyBtn:ClearAllPoints(); applyBtn:SetPoint("LEFT", saveF, "RIGHT", 4, 0)
    _applyBtn = applyBtn

    local exportBtn, exportF = makeFooterBtn("Export", function()
        local active2 = ns.Profiles.Active()
        if not active2 then out("no active profile to export.") return end
        local block = ns.Profiles.ToConsoleBlock(active2)
        if Forge and Forge.ShowCopyDialog then
            Forge.ShowCopyDialog("Export profile: " .. active2, block,
                "Ctrl-A, Ctrl-C to copy.")
        else
            out("Forge.ShowCopyDialog unavailable.")
        end
    end)
    exportBtn:ClearAllPoints(); exportBtn:SetPoint("LEFT", applyF, "RIGHT", 4, 0)
    _exportBtn = exportBtn

    local importBtn          = makeFooterBtn("Import", function()
        out("Import: paste a /console SetCVar block in chat, or use Export to dump current and edit by hand. (Real paste dialog deferred.)")
    end)
    importBtn:ClearAllPoints(); importBtn:SetPoint("LEFT", exportF, "RIGHT", 4, 0)

    refreshProfileButtons()
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
    buildFooter(f)

    local listArea = CreateFrame("Frame", nil, f)
    listArea:SetPoint("TOPLEFT",     _toolbar, "BOTTOMLEFT",  0, -PAD)
    listArea:SetPoint("BOTTOMRIGHT", _footer,  "TOPRIGHT",    0,  PAD)
    _listArea = listArea
    f._listArea = listArea

    if ns.List and ns.List.Build then
        ns.List.Build(listArea)
        ns.List.SetCallbacks({
            onEdit = function(name)
                ns.EditModal.Open(name, function(ok, err, value)
                    if ok then
                        out(string.format("set %s = %s", name, tostring(value)))
                    elseif err and err ~= "cancelled" then
                        out(string.format("set %s failed: %s", name, tostring(err)))
                    end
                    UI.RefreshList()
                end)
            end,
            onReset = function(name)
                local ok, err = ns.EditModal.ResetToDefault(name)
                if ok then out(string.format("reset %s to default.", name))
                else        out(string.format("reset %s failed: %s", name, tostring(err))) end
                UI.RefreshList()
            end,
            onCopy = function(name)
                local cur = ns.Snapshot.GetCurrent(name) or ""
                local block = string.format("/console SetCVar %s %s", name, cur)
                if Forge and Forge.ShowCopyDialog then
                    Forge.ShowCopyDialog("Copy CVar: " .. name, block,
                        "Ctrl-A, Ctrl-C to copy.")
                end
            end,
        })
    end

    if ns.Snapshot and ns.Snapshot.Refresh then
        ns.Snapshot.Refresh()
        if #ns.Snapshot.GetAll() == 0 then
            out("|cffff8c00CVar snapshot is empty.|r The console API returned no entries. Try Refresh or /reload.")
        end
    end
    UI.RefreshList()

    -- Schedule a relayout next frame: parent window may not have computed
    -- its real size at Build-time, leaving rows at width 0 on first paint.
    C_Timer.After(0.05, function()
        if ns.List and ns.List.Refresh then ns.List.Refresh() end
    end)
end

-- --------------------------------------------------------------------------
-- Lifecycle hooks.
-- --------------------------------------------------------------------------
function UI.OnTabShow(mod)
    if ns.List and ns.List.Refresh then ns.List.Refresh() end
end

function UI.OnTabHide(mod)
    if _categoryPopup then _categoryPopup:Hide() end
    if _profilePopup  then _profilePopup:Hide()  end
end

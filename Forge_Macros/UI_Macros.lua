-- Forge_Macros.UI_Macros: the basic Macros panel (Account + Character lists,
-- name field, icon picker placeholder, body editor, drag-to-bar, char counter).

local ADDON, ns = ...

local M = {}
ns.UI_Macros = M

local LIST_W       = 220
local ROW_H        = 22
local TOP_H        = 32
local BTN_W        = 80
local BTN_H        = 22
local PAD          = 6

local _activeMod
local _activeKind = "account"   -- "account" or "character"
local _selectedIndex            -- macro index, or nil

local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

-- Build the right-side editor pane.
local function buildEditor(parent, mod)
    local pane = CreateFrame("Frame", nil, parent)
    pane:SetPoint("TOPLEFT",     parent, "TOPLEFT",     LIST_W + PAD, 0)
    pane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    mod._editorPane = pane

    -- Top row: icon button | Name editbox.
    local iconBtn = CreateFrame("Button", nil, pane)
    iconBtn:SetSize(36, 36)
    iconBtn:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
    local iconTex = iconBtn:CreateTexture(nil, "ARTWORK")
    iconTex:SetAllPoints()
    iconTex:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    mod._iconTex = iconTex
    iconBtn:SetScript("OnClick", function() M.OpenIconPicker(mod) end)
    -- Tooltip hint.
    iconBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffd87f3aIcon|r", 1, 1, 1)
        GameTooltip:AddLine("Click to change. Type an icon name in the picker.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    iconBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    mod._iconBtn = iconBtn

    local nameLabel = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", iconBtn, "TOPRIGHT", 8, -2)
    nameLabel:SetText("Name")

    local nameEB = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    nameEB:SetSize(220, 20)
    nameEB:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 6, -2)
    nameEB:SetAutoFocus(false)
    mod._nameEB = nameEB

    -- Char counter, top-right.
    local counter = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    counter:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, -8)
    counter:SetTextColor(0.85, 0.7, 0.4, 1)
    mod._counter = counter

    -- Body editor (multi-line ScrollFrame + EditBox).
    local bg = CreateFrame("Frame", nil, pane, "BackdropTemplate")
    bg:SetPoint("TOPLEFT", iconBtn, "BOTTOMLEFT", 0, -PAD)
    bg:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, BTN_H + PAD + 4)
    bg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    local sf = CreateFrame("ScrollFrame", nil, bg, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -28, 6)

    local body = CreateFrame("EditBox", nil, sf)
    body:SetMultiLine(true)
    body:SetAutoFocus(false)
    body:SetFontObject("ChatFontNormal")
    body:SetWidth(420)
    body:SetTextInsets(2, 2, 2, 2)
    sf:SetScrollChild(body)
    mod._bodyEB = body

    body:SetScript("OnTextChanged", function(self)
        local n = #(self:GetText() or "")
        if mod._counter then
            local color = n > 255 and "ffff4040" or (n > 240 and "ffffaa00" or "ffd87f3a")
            mod._counter:SetText(string.format("|c%s%d / 255|r", color, n))
        end
    end)
    body:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Bottom bar: Save, Delete, Drag-to-bar.
    local saveBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    saveBtn:SetSize(BTN_W, BTN_H)
    saveBtn:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 0, 0)
    saveBtn:SetText("Save")
    saveBtn:SetScript("OnClick", function() M.SaveCurrent(mod) end)

    local delBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    delBtn:SetSize(BTN_W, BTN_H)
    delBtn:SetPoint("LEFT", saveBtn, "RIGHT", 4, 0)
    delBtn:SetText("Delete")
    delBtn:SetScript("OnClick", function() M.DeleteCurrent(mod) end)

    local dragBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    dragBtn:SetSize(120, BTN_H)
    dragBtn:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
    dragBtn:SetText("Pick up to bar")
    dragBtn:SetScript("OnClick", function() if _selectedIndex then ns.MacroAPI.Pickup(_selectedIndex) end end)

    return pane
end

local function buildList(parent, mod)
    local pane = CreateFrame("Frame", nil, parent)
    pane:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    pane:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    pane:SetWidth(LIST_W)

    -- Tab strip: Account / Character.
    local accBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    accBtn:SetSize(LIST_W / 2 - 2, 22)
    accBtn:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
    accBtn:SetText("Account")
    accBtn:SetScript("OnClick", function() _activeKind = "account"; _selectedIndex = nil; M.Refresh() end)
    mod._accBtn = accBtn

    local charBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    charBtn:SetSize(LIST_W / 2 - 2, 22)
    charBtn:SetPoint("LEFT", accBtn, "RIGHT", 4, 0)
    charBtn:SetText("Character")
    charBtn:SetScript("OnClick", function() _activeKind = "character"; _selectedIndex = nil; M.Refresh() end)
    mod._charBtn = charBtn

    -- New button beneath.
    local newBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    newBtn:SetSize(LIST_W, 22)
    newBtn:SetPoint("TOPLEFT", accBtn, "BOTTOMLEFT", 0, -PAD)
    newBtn:SetText("+ New macro")
    newBtn:SetScript("OnClick", function() M.NewMacro(mod) end)

    -- Scrollable list.
    local listBg = CreateFrame("Frame", nil, pane, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", newBtn, "BOTTOMLEFT", 0, -PAD)
    listBg:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
    listBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    listBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    listBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    local sf = CreateFrame("ScrollFrame", nil, listBg, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -22, 6)
    mod._listScroll = sf
    local content = CreateFrame("Frame", nil, sf); content:SetSize(1,1); sf:SetScrollChild(content)
    mod._listContent = content
    mod._listRows = {}

    return pane
end

local function refreshTabs(mod)
    local function paint(btn, active)
        if not btn then return end
        if active then btn:LockHighlight() else btn:UnlockHighlight() end
    end
    paint(mod._accBtn, _activeKind == "account")
    paint(mod._charBtn, _activeKind == "character")
end

function M.Refresh()
    local mod = _activeMod
    if not mod or not mod._listContent then return end

    refreshTabs(mod)

    local entries
    if _activeKind == "account" then
        entries = ns.MacroAPI.AccountMacros()
    else
        entries = ns.MacroAPI.CharacterMacros()
    end

    for _, row in ipairs(mod._listRows) do row:Hide() end

    local y = 0
    for i, entry in ipairs(entries) do
        local row = mod._listRows[i]
        if not row then
            row = CreateFrame("Button", nil, mod._listContent)
            row:SetHeight(ROW_H)
            local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
            hov:SetColorTexture(0.45, 0.32, 0.15, 0.30)
            hov:SetAllPoints(); hov:Hide()
            row._hov = hov
            local sel = row:CreateTexture(nil, "BACKGROUND", nil, -2)
            sel:SetColorTexture(0.85, 0.50, 0.20, 0.35)
            sel:SetAllPoints(); sel:Hide()
            row._sel = sel
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", row, "LEFT", 4, 0)
            icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
            row._icon = icon
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
            text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            text:SetJustifyH("LEFT"); text:SetWordWrap(false); text:SetMaxLines(1)
            row._text = text
            row:SetScript("OnEnter", function(self) self._hov:Show() end)
            row:SetScript("OnLeave", function(self) self._hov:Hide() end)
            row:SetScript("OnClick", function(self) M.Select(self._index) end)
            mod._listRows[i] = row
        end
        row._index = entry.index
        row._icon:SetTexture(entry.icon)
        row._text:SetText(entry.name)
        row._sel:SetShown(entry.index == _selectedIndex)
        row:ClearAllPoints()
        row:SetWidth(mod._listScroll:GetWidth() - 24)
        row:SetPoint("TOPLEFT", mod._listContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + ROW_H
    end

    if y < 1 then y = 1 end
    mod._listContent:SetHeight(y)
    mod._listScroll:UpdateScrollChildRect()

    -- Refresh editor with current selection.
    M.RefreshEditor()
end

function M.Select(index)
    _selectedIndex = index
    M.Refresh()
end

function M.RefreshEditor()
    local mod = _activeMod
    if not mod or not mod._bodyEB then return end
    if _selectedIndex then
        local m = ns.MacroAPI.Get(_selectedIndex)
        if m then
            mod._iconTex:SetTexture(m.icon)
            mod._nameEB:SetText(m.name or "")
            mod._bodyEB:SetText(m.body or "")
            return
        end
    end
    mod._iconTex:SetTexture(nil)
    mod._nameEB:SetText("")
    mod._bodyEB:SetText("")
    if mod._counter then mod._counter:SetText("|cffd87f3a0 / 255|r") end
end

function M.SaveCurrent(mod)
    if not _selectedIndex then return end
    local m = ns.MacroAPI.Get(_selectedIndex)
    if not m then return end
    local newName = mod._nameEB:GetText() or m.name
    local newBody = mod._bodyEB:GetText() or m.body
    ns.MacroAPI.Edit(_selectedIndex, newName, m.icon, newBody)
    if ns.out then ns.out("saved macro '" .. newName .. "'.") end
    M.Refresh()
end

function M.DeleteCurrent(mod)
    if not _selectedIndex then return end
    local m = ns.MacroAPI.Get(_selectedIndex)
    if not m then return end
    ns.MacroAPI.Delete(_selectedIndex)
    if ns.out then ns.out("deleted macro '" .. (m.name or "?") .. "'.") end
    _selectedIndex = nil
    M.Refresh()
end

function M.NewMacro(mod)
    local name = "NewMacro" .. math.random(1000, 9999)
    local icon = "INV_Misc_QuestionMark"
    local body = "/say Hello"
    local idx = ns.MacroAPI.Create(name, icon, body, _activeKind == "character")
    if idx then
        _selectedIndex = idx
        if ns.out then ns.out("created macro '" .. name .. "' (#" .. idx .. ").") end
        M.Refresh()
    else
        if ns.out then ns.out("create failed (slots full?).") end
    end
end

function M.OpenIconPicker(mod)
    -- Tier 1 placeholder: simple text prompt for an icon name. A grid picker
    -- is significant UI work; defer to v0.2.
    if not (Forge and Forge.ShowCopyDialog) then return end
    local m = _selectedIndex and ns.MacroAPI.Get(_selectedIndex)
    if not m then return end
    -- Simple approach: show a popup explaining the workaround (use slash for now).
    if ns.out then
        ns.out("|cffaaaaaaicon picker is v0.2. For now, edit the macro in WoW's native UI to change the icon.|r")
    end
end

function M.Build(parent, mod)
    _activeMod = mod
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._macrosPanel = frame
    buildList(frame, mod)
    buildEditor(frame, mod)
    M.Refresh()
end

function M.Show(mod)
    _activeMod = mod
    if mod._macrosPanel then mod._macrosPanel:Show() end
    M.Refresh()
end

function M.Hide(mod)
    if mod._macrosPanel then mod._macrosPanel:Hide() end
end

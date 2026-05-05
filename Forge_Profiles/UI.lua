-- Forge_Profiles.UI: cross-addon profile manager tab.
--
-- Layout:
--   +-----------------------------------------------------+
--   | [Save current as set...]  [Apply set: dropdown]     |
--   +-----------------------------------------------------+
--   | Addon                  Current     Switch to:       |
--   | -------------------------------------------------   |
--   | Forge                  Default     [dropdown]       |
--   | Forge_Console          MyChar-...  [dropdown]       |
--   | ...                                                  |
--   +-----------------------------------------------------+

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H  = 28
local ROW_H      = 22
local PAD        = 6
local NAME_W     = 220
local CURRENT_W  = 140

local _activeMod

local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

-- ----- Build ------------------------------------------------------------
local function buildAddonRow(parent, mod)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)

    local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    hov:SetColorTexture(0.45, 0.32, 0.15, 0.20); hov:SetAllPoints(); hov:Hide()
    row._hov = hov
    row:SetScript("OnEnter", function(self) self._hov:Show() end)
    row:SetScript("OnLeave", function(self) self._hov:Hide() end)

    -- SV name (addon identifier).
    local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameFs:SetPoint("LEFT", row, "LEFT", 6, 0)
    nameFs:SetWidth(NAME_W); nameFs:SetJustifyH("LEFT"); nameFs:SetWordWrap(false); nameFs:SetMaxLines(1)
    nameFs:SetTextColor(0.85, 0.7, 0.4, 1)
    row._nameFs = nameFs

    -- Current profile.
    local curFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    curFs:SetPoint("LEFT", nameFs, "RIGHT", 8, 0)
    curFs:SetWidth(CURRENT_W); curFs:SetJustifyH("LEFT"); curFs:SetWordWrap(false); curFs:SetMaxLines(1)
    row._curFs = curFs

    -- Switch dropdown (UIDropDownMenu via DropDownList template).
    local dd = CreateFrame("Frame", nil, row, "UIDropDownMenuTemplate")
    dd:SetPoint("LEFT", curFs, "RIGHT", 0, -2)
    UIDropDownMenu_SetWidth(dd, 140)
    row._dd = dd

    return row
end

local function refreshRow(row, info)
    row._nameFs:SetText(info.svName)
    row._curFs:SetText(escapeBars(tostring(info.current or "?")))

    UIDropDownMenu_SetText(row._dd, "Switch to...")
    UIDropDownMenu_Initialize(row._dd, function(self, level)
        if level ~= 1 then return end
        for _, profileName in ipairs(info.profiles or {}) do
            local entry = UIDropDownMenu_CreateInfo()
            entry.text  = profileName
            entry.value = profileName
            entry.func  = function()
                ns.SwitchProfile(info.svName, profileName)
                UI.Refresh()
            end
            entry.checked = (profileName == info.current)
            UIDropDownMenu_AddButton(entry, level)
        end

        -- Separator + "New profile..." action. Cairn.DB's SetProfile
        -- auto-creates a profile with defaults when the name doesn't
        -- exist, so the prompt only needs to collect a name.
        local sep = UIDropDownMenu_CreateInfo()
        sep.text         = ""
        sep.disabled     = true
        sep.notCheckable = true
        UIDropDownMenu_AddButton(sep, level)

        local newEntry = UIDropDownMenu_CreateInfo()
        newEntry.text         = "|cffd87f3a+ New profile...|r"
        newEntry.notCheckable = true
        newEntry.func         = function()
            UI._showNewProfilePrompt(info.svName)
        end
        UIDropDownMenu_AddButton(newEntry, level)
    end)
end

function UI.Build(parent, mod)
    _activeMod = mod
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- ===== Toolbar =====================================================
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  4, -4)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    bar:SetHeight(TOOLBAR_H)

    -- Save-as-set button: Cairn-Gui Button with vanilla fallback. The
    -- "Apply set..." dropdown stays on Blizzard's UIDropDownMenuTemplate
    -- because it's a native menu construct -- migrating to Cairn-Gui
    -- DropDown/ComboBox is a separate API change.
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local saveBtn, saveBtnFrame
    do
        local b = Gui and Gui:Create("Button")
        if b then
            b:SetParent(bar); b:ClearAllPoints()
            b:SetWidth(160); b:SetHeight(22); b:SetText("Save as set...")
            b:SetPoint("LEFT", bar, "LEFT", 4, 0)
            b:SetEventListener("OnClick", function() UI._showSetNamePrompt() end)
            saveBtn, saveBtnFrame = b, b.frame
        else
            local raw = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
            raw:SetSize(160, 22); raw:SetPoint("LEFT", bar, "LEFT", 4, 0); raw:SetText("Save as set...")
            raw:SetScript("OnClick", function() UI._showSetNamePrompt() end)
            saveBtn, saveBtnFrame = raw, raw
        end
    end

    -- "Apply set" dropdown.
    local applyDd = CreateFrame("Frame", nil, bar, "UIDropDownMenuTemplate")
    applyDd:SetPoint("LEFT", saveBtnFrame, "RIGHT", 4, -2)
    UIDropDownMenu_SetWidth(applyDd, 160)
    UIDropDownMenu_SetText(applyDd, "Apply set...")
    UIDropDownMenu_Initialize(applyDd, function(self, level)
        if level ~= 1 then return end
        local names = ns.ListSetNames()
        if #names == 0 then
            local entry = UIDropDownMenu_CreateInfo()
            entry.text = "(no sets saved)"
            entry.disabled = true
            UIDropDownMenu_AddButton(entry, level)
            return
        end
        for _, n in ipairs(names) do
            local entry = UIDropDownMenu_CreateInfo()
            entry.text = n
            entry.func = function()
                local ok, applied = ns.LoadSet(n)
                if ok and ns.out then
                    ns.out(string.format("loaded set '%s' (%d addons updated).", n, applied))
                end
                UI.Refresh()
            end
            UIDropDownMenu_AddButton(entry, level)
            local del = UIDropDownMenu_CreateInfo()
            del.text = "    delete"
            del.notCheckable = true
            del.func = function()
                ns.DeleteSet(n)
                if ns.out then ns.out("deleted set '" .. n .. "'.") end
                UI.Refresh()
            end
            UIDropDownMenu_AddButton(del, level)
        end
    end)
    mod._applyDd = applyDd

    local countFs = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countFs:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    countFs:SetTextColor(0.85, 0.7, 0.4, 1)
    mod._countFs = countFs

    -- ===== Header row =================================================
    local header = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    header:SetPoint("TOPLEFT",  bar, "BOTTOMLEFT",  0, -PAD)
    header:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -PAD)
    header:SetHeight(20)
    header:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        tile = true, tileSize = 16, edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    header:SetBackdropColor(0.04, 0.04, 0.04, 0.55)
    local h1 = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h1:SetPoint("LEFT", header, "LEFT", 6, 0); h1:SetText("|cffd87f3aAddon|r")
    local h2 = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h2:SetPoint("LEFT", h1, "LEFT", NAME_W + 8, 0); h2:SetText("|cffd87f3aCurrent profile|r")
    local h3 = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h3:SetPoint("LEFT", h2, "LEFT", CURRENT_W, 0); h3:SetText("|cffd87f3aSwitch|r")

    -- ===== Scrollable list ============================================
    local listBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    listBg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    listBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    listBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    -- Migrated to Cairn-Gui-Core ScrollFrame. _listScrollFrame stores the
    -- inner Blizzard scrollFrame (same on both backends) for
    -- UpdateScrollChildRect calls.
    local listScroll = Gui and Gui:Create("ScrollFrame")
    if listScroll then
        listScroll:SetParent(listBg); listScroll:ClearAllPoints()
        listScroll:SetPoint("TOPLEFT",     listBg, "TOPLEFT",      6, -6)
        listScroll:SetPoint("BOTTOMRIGHT", listBg, "BOTTOMRIGHT", -2,  6)
        mod._listScroll       = listScroll
        mod._listContent      = listScroll.content
        mod._listScrollFrame  = listScroll.scrollFrame or listScroll
    else
        local scroll = CreateFrame("ScrollFrame", nil, listBg, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -28, 6)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(1, 1)
        scroll:SetScrollChild(content)
        mod._listScroll       = scroll
        mod._listContent      = content
        mod._listScrollFrame  = scroll
    end
    mod._rows        = {}

    UI.Refresh()
end

function UI.Refresh()
    local mod = _activeMod
    if not mod or not mod._listContent then return end
    local list = ns.ListAddons()

    for _, row in ipairs(mod._rows) do row:Hide() end

    local y = 0
    for i, info in ipairs(list) do
        local row = mod._rows[i]
        if not row then
            row = buildAddonRow(mod._listContent, mod)
            mod._rows[i] = row
        end
        refreshRow(row, info)
        row:ClearAllPoints()
        row:SetWidth((mod._listScroll:GetWidth() or 600) - 8)
        row:SetPoint("TOPLEFT", mod._listContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + ROW_H
    end
    if y < 1 then y = 1 end
    mod._listContent:SetHeight(y)
    local sf = mod._listScrollFrame or mod._listScroll
    if sf and sf.UpdateScrollChildRect then sf:UpdateScrollChildRect() end

    if mod._countFs then
        local nSets = #ns.ListSetNames()
        mod._countFs:SetText(string.format("%d addons   %d sets", #list, nSets))
    end
end

function UI.OnTabShow(mod)
    _activeMod = mod
    UI.Refresh()
end

-- ----- "Save as set..." prompt -----------------------------------------
function UI._showSetNamePrompt()
    if not StaticPopupDialogs then return end
    StaticPopupDialogs["FORGE_PROFILES_SETNAME"] = {
        text         = "Name for this profile set:",
        button1      = "Save",
        button2      = "Cancel",
        hasEditBox   = true,
        maxLetters   = 40,
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
        OnAccept     = function(self)
            local name = self.editBox:GetText() or ""
            name = name:match("^%s*(.-)%s*$")
            if name ~= "" then
                ns.SaveCurrentAsSet(name)
                if ns.out then ns.out("saved profile set '" .. name .. "'.") end
                UI.Refresh()
            end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            if parent and parent.button1 then parent.button1:Click() end
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    }
    StaticPopup_Show("FORGE_PROFILES_SETNAME")
end

-- ----- "+ New profile..." prompt for a single addon --------------------
function UI._showNewProfilePrompt(svName)
    if not StaticPopupDialogs then return end
    StaticPopupDialogs["FORGE_PROFILES_NEW"] = {
        text         = "Name for new profile in '" .. tostring(svName) .. "':",
        button1      = "Create + switch",
        button2      = "Cancel",
        hasEditBox   = true,
        maxLetters   = 40,
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
        OnAccept     = function(self)
            local name = self.editBox:GetText() or ""
            name = name:match("^%s*(.-)%s*$")
            if name == "" then return end
            -- SwitchProfile delegates to Cairn.DB:SetProfile, which
            -- auto-creates the profile (with defaults) if the name
            -- doesn't already exist. Same call covers both create-new
            -- and switch-to-existing.
            local ok = ns.SwitchProfile(svName, name)
            if ok and ns.out then
                ns.out(string.format("created + switched %s to profile '%s'.", svName, name))
            end
            UI.Refresh()
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            if parent and parent.button1 then parent.button1:Click() end
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    }
    StaticPopup_Show("FORGE_PROFILES_NEW")
end

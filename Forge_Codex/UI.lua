-- Forge_Codex.UI: catalog browser with module list + virtualized entry list.
--
-- Layout:
--   +-----------+--------------------------------------+
--   | Modules   | [Search ...........] [N entries]    |
--   |  Stats    +--------------------------------------+
--   |  Items    | [id] label  - subtitle               |
--   |  ...      | ...                                   |
--   +-----------+--------------------------------------+

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H        = 28
local ROW_H            = 18
local PAD              = 6
local MODULES_W        = 160
local VISIBLE_ROW_BUFFER = 60
local MAX_RESULTS      = 5000   -- soft cap on entries returned per module view

local _activeMod

local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

-- ----- Stats helpers ---------------------------------------------------
local function buildStatsText()
    local names = ns.ListModuleNames()
    local lines = { "|cffd87f3aLibCodex catalog|r  |cffaaaaaa" .. #names .. " modules|r", "" }
    local total = 0

    -- Cache counts (single ModuleCount call per module). Wrap in pcall so a
    -- failing module's count error doesn't kill the whole stats build.
    local counts = {}
    for _, n in ipairs(names) do
        local ok, c = pcall(ns.ModuleCount, n)
        counts[n] = (ok and type(c) == "number") and c or 0
    end

    table.sort(names, function(a, b) return (counts[a] or 0) > (counts[b] or 0) end)
    for _, n in ipairs(names) do
        local c = counts[n] or 0
        total = total + c
        lines[#lines + 1] = string.format("|cffffe6a8%-22s|r |cffaaaaaa%d|r", n, c)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("|cffd87f3aTotal entries:|r %d", total)
    return table.concat(lines, "\n")
end

-- ----- Entry formatting -------------------------------------------------
local function fmtEntry(e)
    if type(e) ~= "table" then return tostring(e) end
    local id    = e.id or e.key or "?"
    local label = e.label or e.name or "(no label)"
    local sub
    -- Pick a reasonable subtitle field per module.
    if e.zone        then sub = e.zone
    elseif e.quality then sub = "q=" .. tostring(e.quality)
    elseif e.level   then sub = "lvl=" .. tostring(e.level)
    elseif e.title   then sub = e.title end
    local left = string.format("|cffaaaaaa[%s]|r |cffffe6a8%s|r",
        tostring(id), escapeBars(label))
    if sub then
        return left .. "  |cff888888" .. escapeBars(sub) .. "|r"
    end
    return left
end

-- ----- Build UI --------------------------------------------------------
local function buildModuleRow(parent)
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

local function buildEntryRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)

    local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    hov:SetColorTexture(0.45, 0.32, 0.15, 0.30); hov:SetAllPoints(); hov:Hide()
    row._hov = hov

    local fs = row:CreateFontString(nil, "OVERLAY", "ChatFontSmall")
    fs:SetPoint("LEFT", row, "LEFT", 4, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetMaxLines(1)
    row._fs = fs

    row:SetScript("OnEnter", function(self)
        self._hov:Show()
        if self._entry and GameTooltip then UI.ShowEntryTooltip(self) end
    end)
    row:SetScript("OnLeave", function(self)
        self._hov:Hide()
        if GameTooltip then GameTooltip:Hide() end
    end)
    row:SetScript("OnClick", function(self)
        if self._entry then UI.ShowEntryDetail(self._entry) end
    end)
    return row
end

-- ----- Entry detail popup ---------------------------------------------
-- Format the entry's full field set as readable, copy-ready text.
local function fmtFieldValue(v, depth)
    depth = depth or 0
    if depth > 4 then return "..." end
    local t = type(v)
    if t == "string"  then return string.format("%q", v) end
    if t == "number"  then return tostring(v) end
    if t == "boolean" then return tostring(v) end
    if t == "nil"     then return "nil" end
    if t == "table" then
        local parts = {}
        local n = 0
        for k, vv in pairs(v) do
            n = n + 1
            if n > 12 then parts[#parts + 1] = "..."; break end
            local ks = (type(k) == "string") and k or ("[" .. tostring(k) .. "]")
            parts[#parts + 1] = ks .. " = " .. fmtFieldValue(vv, depth + 1)
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return tostring(v)
end

function UI.ShowEntryDetail(entry)
    if type(entry) ~= "table" then return end
    local id    = entry.id   or entry.key  or "?"
    local label = entry.label or entry.name or "(no label)"
    local title = string.format("Codex entry [%s] %s", tostring(id), tostring(label))

    -- Sort field names for stable display.
    local keys = {}
    for k in pairs(entry) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)

    local lines = {
        string.format("[%s] %s", tostring(id), tostring(label)),
        "",
    }
    for _, k in ipairs(keys) do
        lines[#lines + 1] = string.format("%s = %s", k, fmtFieldValue(entry[k]))
    end
    local text = table.concat(lines, "\n")

    if Forge and Forge.ShowCopyDialog then
        Forge.ShowCopyDialog(title, text,
            "Ctrl-A to select all, Ctrl-C to copy.")
    end
end

function UI.ShowEntryTooltip(row)
    local e = row._entry
    if type(e) ~= "table" or not GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(string.format("[%s] %s", tostring(e.id or e.key or "?"),
        tostring(e.label or e.name or "")))
    -- Show every field on the entry, sorted, in dim text.
    local keys = {}
    for k in pairs(e) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        if k ~= "id" and k ~= "label" then
            local v = e[k]
            local t = type(v)
            local disp
            if t == "table" then disp = "{...}"
            elseif t == "string" then disp = (#v > 60) and (v:sub(1, 57) .. "...") or v
            else disp = tostring(v) end
            GameTooltip:AddLine("|cffd87f3a" .. k .. ":|r " .. tostring(disp), 1, 1, 1, true)
        end
    end
    GameTooltip:Show()
end

function UI.Build(parent, mod)
    _activeMod = mod
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- Acquire Cairn-Gui-Core once for the whole UI; falsy if the kit failed
    -- to load (each migration site below has a vanilla fallback).
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    -- ----- Migration helpers ----------------------------------------------
    -- Each helper returns the high-level surface (widget OR raw frame). For
    -- chain-anchoring callers also need the underlying Frame; those helpers
    -- return (widgetOrRaw, frame) pairs.
    local function makeInput(parentFrame, w, h, hintText, onChange, onEnter)
        local s = Gui and Gui:Create("Input")
        if s then
            s:SetParent(parentFrame); s:ClearAllPoints()
            s:SetWidth(w); s:SetHeight(h)
            if onChange then
                s.editBox:HookScript("OnTextChanged", function(this) onChange(this:GetText() or "") end)
            end
            if onEnter then
                s:SetEventListener("OnEnterPressed", function()
                    onEnter(s:GetText() or "")
                    s.editBox:ClearFocus()
                end)
            end
            s:SetEventListener("OnEscapePressed", function() s:SetText("") end)
            local hint
            if hintText then
                hint = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                hint:SetPoint("LEFT", s.frame, "LEFT", 8, 0)
                hint:SetText(hintText)
                s:SetEventListener("OnEditFocusGained", function() hint:Hide() end)
                s:SetEventListener("OnEditFocusLost",  function()
                    if (s:GetText() or "") == "" then hint:Show() end
                end)
            end
            return s, s.frame, hint
        else
            local bg = CreateFrame("Frame", nil, parentFrame, "BackdropTemplate")
            bg:SetSize(w, h)
            bg:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 8,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            bg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
            bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
            local raw = CreateFrame("EditBox", nil, bg)
            raw:SetMultiLine(false); raw:SetAutoFocus(false)
            raw:SetFontObject("ChatFontNormal")
            raw:SetPoint("LEFT", 6, 0); raw:SetPoint("RIGHT", -6, 0); raw:SetHeight(h - 4)
            if onChange then raw:SetScript("OnTextChanged", function(self) onChange(self:GetText() or "") end) end
            if onEnter  then raw:SetScript("OnEnterPressed", function(self) onEnter(self:GetText() or ""); self:ClearFocus() end) end
            raw:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText("") end)
            local hint
            if hintText then
                hint = bg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                hint:SetPoint("LEFT", 8, 0); hint:SetText(hintText)
                raw:SetScript("OnEditFocusGained", function() hint:Hide() end)
                raw:SetScript("OnEditFocusLost",  function(self)
                    if (self:GetText() or "") == "" then hint:Show() end
                end)
            end
            -- Return raw with .frame = bg so callers using widget.frame still work.
            raw.frame = bg
            return raw, bg, hint
        end
    end
    local function makeButton(parentFrame, label, w, h, onClick)
        local b = Gui and Gui:Create("Button")
        if b then
            b:SetParent(parentFrame); b:ClearAllPoints()
            b:SetWidth(w); b:SetHeight(h)
            b:SetText(label)
            if onClick then b:SetEventListener("OnClick", function() onClick() end) end
            return b, b.frame
        else
            local raw = CreateFrame("Button", nil, parentFrame, "UIPanelButtonTemplate")
            raw:SetSize(w, h); raw:SetText(label)
            if onClick then raw:SetScript("OnClick", onClick) end
            return raw, raw
        end
    end
    local function makeScroll(parentFrame, anchorOffsetTL, anchorOffsetBR)
        local s = Gui and Gui:Create("ScrollFrame")
        if s then
            s:SetParent(parentFrame); s:ClearAllPoints()
            s:SetPoint("TOPLEFT",     parentFrame, "TOPLEFT",     anchorOffsetTL[1], anchorOffsetTL[2])
            s:SetPoint("BOTTOMRIGHT", parentFrame, "BOTTOMRIGHT", anchorOffsetBR[1], anchorOffsetBR[2])
            return s, s.content
        else
            local raw = CreateFrame("ScrollFrame", nil, parentFrame, "UIPanelScrollFrameTemplate")
            raw:SetPoint("TOPLEFT",     anchorOffsetTL[1], anchorOffsetTL[2])
            raw:SetPoint("BOTTOMRIGHT", anchorOffsetBR[1] - 22, anchorOffsetBR[2])
            local content = CreateFrame("Frame", nil, raw); content:SetSize(1,1); raw:SetScrollChild(content)
            return raw, content
        end
    end
    local function safeUpdateScrollRect(s)
        if not s then return end
        if s.UpdateScrollChildRect then s:UpdateScrollChildRect()
        elseif s.scrollFrame and s.scrollFrame.UpdateScrollChildRect then
            s.scrollFrame:UpdateScrollChildRect()
        end
    end
    mod._safeUpdateScrollRect = safeUpdateScrollRect

    -- ===== Toolbar (right pane top) ====================================
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  MODULES_W + PAD * 2, -4)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    bar:SetHeight(TOOLBAR_H)
    mod._toolbar = bar

    local search, searchFrame = makeInput(bar, 220, 22, "Search this module...",
        function(text) ns.SetSearchText(text); UI.Refresh() end, nil)
    search:ClearAllPoints()
    search:SetPoint("LEFT", bar, "LEFT", 4, 0)
    if search.SetText then search:SetText(ns.GetSearchText() or "") end
    mod._search = search

    local countFs = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countFs:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    countFs:SetTextColor(0.85, 0.7, 0.4, 1)
    mod._countFs = countFs

    -- ===== Modules pane (left) ========================================
    local modulesBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    modulesBg:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -4)
    modulesBg:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 4)
    modulesBg:SetWidth(MODULES_W)
    modulesBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    modulesBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    modulesBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    local modulesScroll, modulesContent = makeScroll(modulesBg, { 6, -6 }, { -2, 6 })
    mod._modulesScroll  = modulesScroll
    mod._modulesContent = modulesContent
    mod._moduleRows     = {}

    -- ===== Right pane: stats text OR virtualized entry list =========
    local rightBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    rightBg:SetPoint("TOPLEFT",     bar,     "BOTTOMLEFT",  0, -PAD)
    rightBg:SetPoint("BOTTOMRIGHT", frame,   "BOTTOMRIGHT", -4, 4)
    rightBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    rightBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    rightBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    -- Stats text view (filling the right pane)
    local statsScroll, statsContent = makeScroll(rightBg, { 6, -6 }, { -2, 6 })
    local statsText = statsContent:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    statsText:SetJustifyH("LEFT"); statsText:SetJustifyV("TOP")
    statsText:SetPoint("TOPLEFT", statsContent, "TOPLEFT", 4, -4)
    statsText:SetWordWrap(true)
    if statsText.SetMaxLines then statsText:SetMaxLines(0) end  -- 0 = unlimited
    mod._statsScroll  = statsScroll
    mod._statsContent = statsContent
    mod._statsText    = statsText

    -- Virtualized entry-list view (also filling the right pane; toggled).
    -- The widget exposes the underlying Blizzard ScrollFrame at .scrollFrame
    -- (also stored as _entriesScrollFrame) for HookScript / GetVerticalScroll
    -- / UpdateScrollChildRect.
    local entriesScroll, entriesContent = makeScroll(rightBg, { 6, -6 }, { -2, 6 })
    mod._entriesScroll      = entriesScroll
    mod._entriesContent     = entriesContent
    mod._entriesScrollFrame = entriesScroll.scrollFrame or entriesScroll
    mod._entryRows          = {}

    mod._entriesScrollFrame:HookScript("OnVerticalScroll", function() UI.RenderEntryWindow() end)
    mod._entriesScrollFrame:HookScript("OnSizeChanged",    function() UI.RenderEntryWindow() end)

    -- ----- Cross-module Search panel -----
    local searchPanel = CreateFrame("Frame", nil, rightBg)
    searchPanel:SetPoint("TOPLEFT", 6, -6)
    searchPanel:SetPoint("BOTTOMRIGHT", -6, 6)
    searchPanel:Hide()
    mod._searchPanel = searchPanel

    local searchAllInput, searchInputFrame = makeInput(searchPanel, 260, 22, nil, nil,
        function(text) UI.RunCrossSearch(text) end)
    searchAllInput:ClearAllPoints()
    searchAllInput:SetPoint("TOPLEFT", searchPanel, "TOPLEFT", 4, -4)
    mod._searchAllInput = searchAllInput

    local searchAllBtnW, searchAllBtnFrame = makeButton(searchPanel, "Search", 70, 22,
        function() UI.RunCrossSearch(searchAllInput:GetText() or "") end)
    searchAllBtnW:ClearAllPoints()
    searchAllBtnW:SetPoint("LEFT", searchInputFrame, "RIGHT", 4, 0)

    -- Results scroll: anchor to searchInputFrame's BOTTOMLEFT.
    local searchResultsScroll = Gui and Gui:Create("ScrollFrame")
    local searchResultsContent
    if searchResultsScroll then
        searchResultsScroll:SetParent(searchPanel); searchResultsScroll:ClearAllPoints()
        searchResultsScroll:SetPoint("TOPLEFT",     searchInputFrame, "BOTTOMLEFT", 0, -8)
        searchResultsScroll:SetPoint("BOTTOMRIGHT", searchPanel, "BOTTOMRIGHT", -2, 0)
        searchResultsContent = searchResultsScroll.content
    else
        searchResultsScroll = CreateFrame("ScrollFrame", nil, searchPanel, "UIPanelScrollFrameTemplate")
        searchResultsScroll:SetPoint("TOPLEFT", searchInputFrame, "BOTTOMLEFT", 0, -8)
        searchResultsScroll:SetPoint("BOTTOMRIGHT", searchPanel, "BOTTOMRIGHT", -22, 0)
        searchResultsContent = CreateFrame("Frame", nil, searchResultsScroll)
        searchResultsContent:SetSize(1, 1)
        searchResultsScroll:SetScrollChild(searchResultsContent)
    end
    local searchResultsText = searchResultsContent:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    searchResultsText:SetJustifyH("LEFT"); searchResultsText:SetJustifyV("TOP")
    searchResultsText:SetPoint("TOPLEFT", searchResultsContent, "TOPLEFT", 4, -4)
    searchResultsText:SetWordWrap(false)
    searchResultsText:SetText("|cffaaaaaaType a query and press Enter to search every module.|r")
    mod._searchResultsScroll  = searchResultsScroll
    mod._searchResultsContent = searchResultsContent
    mod._searchResultsText    = searchResultsText

    -- ----- Where panel (item drop lookup) -----
    local wherePanel = CreateFrame("Frame", nil, rightBg)
    wherePanel:SetPoint("TOPLEFT", 6, -6)
    wherePanel:SetPoint("BOTTOMRIGHT", -6, 6)
    wherePanel:Hide()
    mod._wherePanel = wherePanel

    local whereInput, whereInputFrame = makeInput(wherePanel, 150, 22, nil, nil,
        function(text) UI.RunWhere(tonumber(text)) end)
    whereInput:ClearAllPoints()
    whereInput:SetPoint("TOPLEFT", wherePanel, "TOPLEFT", 4, -4)
    -- Numeric-only typing: enforced on the inner EditBox.
    local innerWhereEb = (whereInput.editBox) or whereInput
    if innerWhereEb.SetNumeric then innerWhereEb:SetNumeric(true) end
    mod._whereInput = whereInput

    local whereLookupBtnW, whereLookupBtnFrame = makeButton(wherePanel, "Lookup", 80, 22,
        function() UI.RunWhere(tonumber(whereInput:GetText() or "")) end)
    whereLookupBtnW:ClearAllPoints()
    whereLookupBtnW:SetPoint("LEFT", whereInputFrame, "RIGHT", 4, 0)

    local whereLabel = wherePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    whereLabel:SetPoint("LEFT", whereLookupBtnFrame, "RIGHT", 8, 0)
    whereLabel:SetText("itemID -> drop sources")

    local whereScroll = Gui and Gui:Create("ScrollFrame")
    local whereContent
    if whereScroll then
        whereScroll:SetParent(wherePanel); whereScroll:ClearAllPoints()
        whereScroll:SetPoint("TOPLEFT",     whereInputFrame, "BOTTOMLEFT",  0, -8)
        whereScroll:SetPoint("BOTTOMRIGHT", wherePanel, "BOTTOMRIGHT", -2, 0)
        whereContent = whereScroll.content
    else
        whereScroll = CreateFrame("ScrollFrame", nil, wherePanel, "UIPanelScrollFrameTemplate")
        whereScroll:SetPoint("TOPLEFT", whereInputFrame, "BOTTOMLEFT", 0, -8)
        whereScroll:SetPoint("BOTTOMRIGHT", wherePanel, "BOTTOMRIGHT", -22, 0)
        whereContent = CreateFrame("Frame", nil, whereScroll)
        whereContent:SetSize(1, 1)
        whereScroll:SetScrollChild(whereContent)
    end
    local whereText = whereContent:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    whereText:SetJustifyH("LEFT"); whereText:SetJustifyV("TOP")
    whereText:SetPoint("TOPLEFT", whereContent, "TOPLEFT", 4, -4)
    whereText:SetWordWrap(false)
    whereText:SetText("|cffaaaaaaEnter an itemID and press Enter.|r")
    mod._whereScroll  = whereScroll
    mod._whereContent = whereContent
    mod._whereText    = whereText

    -- ----- Settings panel -----
    local settingsPanel = CreateFrame("Frame", nil, rightBg)
    settingsPanel:SetPoint("TOPLEFT", 6, -6)
    settingsPanel:SetPoint("BOTTOMRIGHT", -6, 6)
    settingsPanel:Hide()
    mod._settingsPanel = settingsPanel

    local sHeader = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sHeader:SetPoint("TOPLEFT", 8, -4)
    sHeader:SetText("LibCodex toggles  |cffaaaaaa(persist via LibCodexDB)|r")

    local function makeCheckbox(parent, label, anchorY, getter, setter)
        local cb, cbFrame
        local widget = Gui and Gui:Create("CheckBox")
        if widget then
            widget:SetParent(parent); widget:ClearAllPoints()
            widget:SetWidth(22); widget:SetHeight(22)
            widget:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, anchorY)
            widget.frame:EnableMouse(true)
            if widget.frame.RegisterForClicks then widget.frame:RegisterForClicks("AnyUp") end
            widget:SetChecked(getter() and true or false)
            widget:SetEventListener("OnValueChanged", function(_, _, checked)
                setter(checked and true or false)
            end)
            cb, cbFrame = widget, widget.frame
        else
            local raw = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
            raw:SetSize(22, 22)
            raw:SetPoint("TOPLEFT", 12, anchorY)
            raw:SetChecked(getter() and true or false)
            raw:SetScript("OnClick", function(self) setter(self:GetChecked() and true or false) end)
            cb, cbFrame = raw, raw
        end
        local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", cbFrame, "RIGHT", 2, 0)
        lbl:SetText(label)
        return cb
    end

    mod._echoCb = makeCheckbox(settingsPanel, "Echo LibCodex log to chat", -28,
        ns.LC_GetEcho, ns.LC_SetEcho)
    mod._verboseCb = makeCheckbox(settingsPanel, "Runtime verbose mode (logs every capture)", -56,
        ns.LC_GetVerbose, ns.LC_SetVerbose)
    mod._autoscanCb = makeCheckbox(settingsPanel, "Auto-scan nameplates (every 5s)", -84,
        ns.LC_GetAutoScan, ns.LC_SetAutoScan)

    local friendlyBtnW, friendlyBtnFrame = makeButton(settingsPanel,
        "Enable friendly NPC nameplates", 240, 22, function()
            local ok, changed = ns.LC_EnableFriendlyNameplates()
            if ok then
                ns.out(changed and "friendly nameplate CVars set." or "already enabled.")
            else
                ns.out("LibCodex.Runtime not available.")
            end
        end)
    friendlyBtnW:ClearAllPoints()
    friendlyBtnW:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", 12, -116)

    -- ----- Actions panel -----
    local actionsPanel = CreateFrame("Frame", nil, rightBg)
    actionsPanel:SetPoint("TOPLEFT", 6, -6)
    actionsPanel:SetPoint("BOTTOMRIGHT", -6, 6)
    actionsPanel:Hide()
    mod._actionsPanel = actionsPanel

    local aHeader = actionsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    aHeader:SetPoint("TOPLEFT", 8, -4)
    aHeader:SetText("One-click actions")

    local function makeAction(parent, label, desc, anchorY, fn)
        local btnW, btnFrame = makeButton(parent, label, 200, 22, fn)
        btnW:ClearAllPoints()
        btnW:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, anchorY)
        local d = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        d:SetPoint("LEFT", btnFrame, "RIGHT", 12, 0)
        d:SetText(desc)
    end

    makeAction(actionsPanel, "Run Manual Scan",
        "Sweep nameplates + bags + target/focus right now", -28,
        function()
            local ok, r = ns.LC_ScanNow()
            if ok and type(r) == "table" then
                ns.out(string.format("Scan: %d bag items, %d units, realms %d->%d",
                    r.bagItemsCaptured or 0, (r.unitsRead and #r.unitsRead) or 0,
                    r.realmsBefore or 0, r.realmsAfter or 0))
            else
                ns.out("ScanNow not available.")
            end
        end)
    makeAction(actionsPanel, "Force Save",
        "Flush current catalog into LibCodexDB now", -56,
        function()
            if ns.LC_ForceSave() then ns.out("Forced save. /reload to flush to disk.") end
        end)
    makeAction(actionsPanel, "Refresh Stats",
        "Recompute the Stats view", -84,
        function() UI.Refresh() end)
    makeAction(actionsPanel, "Reload UI",
        "Standard /reload (writes SavedVariables to disk)", -112,
        function() ReloadUI() end)

    UI.Refresh()
end

-- ----- Modules list rendering ------------------------------------------
-- Pseudo-modules that aren't real LibCodex collections; they're built-in
-- views (Stats, Search, Where, Actions, Settings). The "@" prefix avoids
-- collisions with real LibCodex module names (LibCodex has a "Stats" enum
-- module, which would otherwise alias the special view).
local SPECIAL_ITEMS = {
    { key = "@stats",    label = "|cffd87f3aStats|r" },
    { key = "@search",   label = "|cffd87f3aSearch all|r" },
    { key = "@where",    label = "|cffd87f3aWhere|r" },
    { key = "@actions",  label = "|cffd87f3aActions|r" },
    { key = "@settings", label = "|cffd87f3aSettings|r" },
}
local function isSpecial(key)
    for _, s in ipairs(SPECIAL_ITEMS) do if s.key == key then return true end end
    return false
end

local function refreshModules()
    local mod = _activeMod
    if not mod then return end
    local names = ns.ListModuleNames()
    -- Special items first (Stats, Search, Where, Actions, Settings), then modules.
    local items = {}
    for _, s in ipairs(SPECIAL_ITEMS) do items[#items + 1] = s.key end
    for _, n in ipairs(names) do items[#items + 1] = n end
    local selected = ns.GetSelectedModule() or "Stats"

    for _, row in ipairs(mod._moduleRows) do row:Hide() end
    local y = 0
    for i, name in ipairs(items) do
        local row = mod._moduleRows[i]
        if not row then
            row = buildModuleRow(mod._modulesContent)
            mod._moduleRows[i] = row
        end
        row._name = name
        local specialLabel
        for _, s in ipairs(SPECIAL_ITEMS) do
            if s.key == name then specialLabel = s.label; break end
        end
        if specialLabel then
            row._fs:SetText(specialLabel)
        else
            row._fs:SetText(string.format("%s  |cffaaaaaa%d|r", name, ns.ModuleCount(name)))
        end
        if name == selected then row._sel:Show() else row._sel:Hide() end
        row:SetScript("OnClick", function(self)
            ns.SetSelectedModule(self._name)
            UI.Refresh()
        end)
        row:ClearAllPoints()
        row:SetWidth((mod._modulesScroll:GetWidth() or 140) - 4)
        row:SetPoint("TOPLEFT", mod._modulesContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + (ROW_H + 2)
    end
    if y < 1 then y = 1 end
    mod._modulesContent:SetHeight(y)
    if mod._safeUpdateScrollRect then mod._safeUpdateScrollRect(mod._modulesScroll) end
end

-- ----- Entry list rendering (virtualized) ------------------------------
function UI.RenderEntryWindow()
    local mod = _activeMod
    if not (mod and mod._entriesContent and mod._entries) then return end
    local total = #mod._entries
    mod._entriesContent:SetHeight(math.max(1, total * ROW_H))

    -- The widget's GetWidth pass-through works, but GetVerticalScroll lives
    -- only on the inner Blizzard scrollFrame. _entriesScrollFrame points at
    -- that on both backends.
    local sf        = mod._entriesScrollFrame or mod._entriesScroll
    local scrollY   = sf:GetVerticalScroll() or 0
    local viewportH = sf:GetHeight() or 0
    local firstIdx  = math.max(1, math.floor(scrollY / ROW_H) + 1)
    local rowsToShow = math.min(
        VISIBLE_ROW_BUFFER,
        math.ceil(viewportH / ROW_H) + 2,
        total - firstIdx + 1
    )

    for _, row in ipairs(mod._entryRows) do row:Hide() end

    for i = 1, math.max(0, rowsToShow) do
        local idx = firstIdx + i - 1
        local entry = mod._entries[idx]
        if not entry then break end

        local row = mod._entryRows[i]
        if not row then
            row = buildEntryRow(mod._entriesContent)
            mod._entryRows[i] = row
        end
        row._entry = entry
        row._fs:SetText(fmtEntry(entry))
        row:ClearAllPoints()
        row:SetWidth((mod._entriesScroll:GetWidth() or 400) - 8)
        row:SetPoint("TOPLEFT", mod._entriesContent, "TOPLEFT", 0, -((idx - 1) * ROW_H))
        row:Show()
    end

    sf:UpdateScrollChildRect()
end

-- ----- Top-level refresh -----------------------------------------------
local function hideAllRightPanels(mod)
    if mod._statsScroll    then mod._statsScroll:Hide()    end
    if mod._entriesScroll  then mod._entriesScroll:Hide()  end
    if mod._searchPanel    then mod._searchPanel:Hide()    end
    if mod._wherePanel     then mod._wherePanel:Hide()     end
    if mod._settingsPanel  then mod._settingsPanel:Hide()  end
    if mod._actionsPanel   then mod._actionsPanel:Hide()   end
end

function UI.Refresh()
    local mod = _activeMod
    if not mod then return end
    refreshModules()

    local selected = ns.GetSelectedModule() or "@stats"
    hideAllRightPanels(mod)

    if selected == "@stats" then
        if mod._statsScroll then mod._statsScroll:Show() end
        if mod._statsText then
            local txt = buildStatsText()
            local function applyStatsLayout()
                if not (_activeMod and _activeMod._statsScroll and _activeMod._statsText) then return end
                local w = math.max(1, (_activeMod._statsScroll:GetWidth() or 0) - 8)
                _activeMod._statsText:SetWidth(w)            -- size the FontString first
                _activeMod._statsText:SetText(txt)           -- then set text so it lays out
                local h = math.max(1, (_activeMod._statsText:GetStringHeight() or 0) + 12)
                _activeMod._statsContent:SetSize(w, h)
                if _activeMod._safeUpdateScrollRect then
                    _activeMod._safeUpdateScrollRect(_activeMod._statsScroll)
                end
            end
            applyStatsLayout()
            -- Defer one tick so the layout is recomputed after the scroll
            -- frame has actually been shown and sized.
            if C_Timer and C_Timer.After then
                C_Timer.After(0, applyStatsLayout)
            end
        end
        if mod._countFs then mod._countFs:SetText("") end

    elseif selected == "@search" then
        if mod._searchPanel then mod._searchPanel:Show() end
        if mod._countFs then mod._countFs:SetText("cross-module search") end

    elseif selected == "@where" then
        if mod._wherePanel then mod._wherePanel:Show() end
        if mod._countFs then mod._countFs:SetText("itemID -> drop sources") end

    elseif selected == "@settings" then
        if mod._settingsPanel then mod._settingsPanel:Show() end
        -- Sync checkbox states with current LibCodex flags.
        if mod._echoCb     then mod._echoCb:SetChecked(ns.LC_GetEcho() and true or false)         end
        if mod._verboseCb  then mod._verboseCb:SetChecked(ns.LC_GetVerbose() and true or false)   end
        if mod._autoscanCb then mod._autoscanCb:SetChecked(ns.LC_GetAutoScan() and true or false) end
        if mod._countFs then mod._countFs:SetText("LibCodex toggles") end

    elseif selected == "@actions" then
        if mod._actionsPanel then mod._actionsPanel:Show() end
        if mod._countFs then mod._countFs:SetText("one-click actions") end

    else
        -- Real module: entry browse view.
        if mod._entriesScroll then
            mod._entriesScroll:Show()
            -- Reset scroll position when switching modules so the new
            -- module's first entry isn't off-screen at the top. Drive
            -- the inner Blizzard scrollFrame; widget doesn't expose
            -- SetVerticalScroll directly.
            local sf = mod._entriesScrollFrame or mod._entriesScroll
            if sf.SetVerticalScroll then sf:SetVerticalScroll(0) end
        end
        local search = ns.GetSearchText() or ""
        mod._entries = ns.GetEntries(selected, search, MAX_RESULTS) or {}
        if mod._countFs then
            local total = ns.ModuleCount(selected)
            local shown = #mod._entries
            if search ~= "" then
                mod._countFs:SetText(string.format("%d hits in %s (of %d)", shown, selected, total))
            elseif shown < total then
                mod._countFs:SetText(string.format("%d shown / %d total in %s", shown, total, selected))
            else
                mod._countFs:SetText(string.format("%d entries in %s", total, selected))
            end
        end
        UI.RenderEntryWindow()
        -- Defer one extra render in case the scroll's GetHeight returns 0
        -- on the very first Show() (frame layout not settled yet).
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function() UI.RenderEntryWindow() end)
        end
    end
end

function UI.OnTabShow(mod)
    _activeMod = mod
    UI.Refresh()
end

-- ----- Cross-module search -----
function UI.RunCrossSearch(query)
    local mod = _activeMod
    if not mod or not mod._searchResultsText then return end
    query = (query or ""):match("^%s*(.-)%s*$")
    if query == "" then
        mod._searchResultsText:SetText("|cffaaaaaaType a query and press Enter to search every module.|r")
        return
    end
    local results = ns.LC_SearchAll(query)
    local moduleNames = {}
    for n in pairs(results) do moduleNames[#moduleNames + 1] = n end
    table.sort(moduleNames)

    if #moduleNames == 0 then
        mod._searchResultsText:SetText("|cffff8080No matches for '" .. query .. "'|r")
    else
        local lines = {}
        local total = 0
        for _, name in ipairs(moduleNames) do
            local r = results[name]
            total = total + r.hits
            lines[#lines + 1] = string.format("|cffd87f3a%s|r |cffaaaaaa(%d matches)|r", name, r.hits)
            local shown = 0
            for _, e in ipairs(r.entries) do
                if shown >= 10 then
                    lines[#lines + 1] = string.format("  |cff666666... %d more|r", r.hits - 10)
                    break
                end
                lines[#lines + 1] = string.format("  |cffaaaaaa[%s]|r |cffffe6a8%s|r",
                    tostring(e.id or e.key or "?"), tostring(e.label or e.name or ""))
                shown = shown + 1
            end
            lines[#lines + 1] = ""
        end
        lines[#lines + 1] = string.format("|cffd87f3aTotal:|r %d matches across %d modules", total, #moduleNames)
        mod._searchResultsText:SetText(table.concat(lines, "\n"))
    end
    -- Resize scroll content.
    local h = (mod._searchResultsText:GetStringHeight() or 0) + 12
    local w = (mod._searchResultsScroll:GetWidth() or 400) - 8
    mod._searchResultsContent:SetSize(w, h)
    if mod._safeUpdateScrollRect then mod._safeUpdateScrollRect(mod._searchResultsScroll) end
end

-- ----- Where lookup -----
function UI.RunWhere(itemID)
    local mod = _activeMod
    if not mod or not mod._whereText then return end
    if not itemID then
        mod._whereText:SetText("|cffaaaaaaEnter a numeric itemID.|r")
        return
    end
    local entry, drops = ns.LC_GetItemDrops(itemID)
    if not entry then
        mod._whereText:SetText("|cffff8080" .. tostring(drops) .. "|r")
        local h = mod._whereText:GetStringHeight() + 12
        local w = (mod._whereScroll:GetWidth() or 400) - 8
        mod._whereContent:SetSize(w, h)
        if mod._safeUpdateScrollRect then mod._safeUpdateScrollRect(mod._whereScroll) end
        return
    end
    local lines = { string.format("|cffd87f3a[%d]|r |cffffe6a8%s|r", itemID,
        tostring(entry.label or entry.name or "?")) }
    if drops and next(drops) then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cffd87f3aDrop sources:|r"
        for _, s in pairs(drops) do
            local pct = (s.outof and s.outof > 0)
                and string.format(" %.1f%%", (s.count or 0) / s.outof * 100) or ""
            lines[#lines + 1] = string.format("  %s |cffaaaaaa[%s]|r %s  |cff7fdfffx%d%s|r",
                s.kind or "?", tostring(s.sourceID or "?"),
                tostring(s.sourceLabel or s.sourceName or "?"),
                s.count or 0, pct)
            if s.locations then
                for _, loc in ipairs(s.locations) do
                    lines[#lines + 1] = string.format("      |cff666666map %d at (%.2f, %.2f) x%d|r",
                        loc.mapID or 0, loc.x or 0, loc.y or 0, loc.count or 1)
                end
            end
        end
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cffaaaaaa(no drop history captured yet)|r"
    end
    mod._whereText:SetText(table.concat(lines, "\n"))
    local h = mod._whereText:GetStringHeight() + 12
    local w = (mod._whereScroll:GetWidth() or 400) - 8
    mod._whereContent:SetSize(w, h)
    if mod._safeUpdateScrollRect then mod._safeUpdateScrollRect(mod._whereScroll) end
end

-- Forge_Console.UI: Cube-inspired scripting workspace.
--
-- Layout (top to bottom):
--   Toolbar:  [Snippet ▼] [+] [-] [Auto-run] ......... [Run] [Clear]
--   Editor:   big multi-line EditBox in a ScrollFrame   (most of the height)
--   Output:   smaller ScrollFrame underneath             (~150px)
--
-- Workflow:
--   * One always-current snippet. Editor shows / edits its code in place.
--   * Switching the dropdown auto-saves the current snippet first.
--   * [+] prompts for a name, adds a blank snippet, switches to it.
--   * [-] deletes the current snippet (with confirm), switches to first remaining.
--   * Auto-run: per-character toggle; flagged snippets run on PLAYER_LOGIN.
--   * Run / F5 executes the editor content. Output appears in the log pane.
--   * Output pane is read-only; uses the same pretty-print as before.
--
-- Persistence is handled in Core.lua. UI.SaveCurrent flushes the editor's
-- text into the current snippet via ns.SaveSnippet.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H   = 28
local OUTPUT_H    = 150
local PAD         = 6
local BTN_WIDTH   = 60
local BTN_HEIGHT  = 22
local DROPDOWN_W  = 200

local _activeMod  -- the live module instance from the Forge tab

-- ----- Output helpers ----------------------------------------------------
local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

function UI.AppendOutput(mod, lines, color)
    if not mod._outputText then return end
    local buf = mod._outputText:GetText() or ""
    local sep = (buf == "") and "" or "\n"
    for _, line in ipairs(lines or {}) do
        local esc = escapeBars(line)
        if color then
            buf = buf .. sep .. "|c" .. color .. esc .. "|r"
        else
            buf = buf .. sep .. esc
        end
        sep = "\n"
    end
    mod._outputText:SetText(buf)
    if mod._reflowOutput then mod._reflowOutput() end
    -- GetVerticalScrollRange / SetVerticalScroll live only on the inner
    -- Blizzard scrollFrame; widget doesn't surface them.
    local sf = mod._outputScrollFrame or mod._outputScroll
    if sf and sf.SetVerticalScroll then
        local maxScroll = sf:GetVerticalScrollRange() or 0
        sf:SetVerticalScroll(maxScroll)
    end
end

function UI.ClearOutput(mod)
    if mod._outputText then
        mod._outputText:SetText("")
        if mod._reflowOutput then mod._reflowOutput() end
    end
end

-- ----- Editor helpers ----------------------------------------------------
function UI.GetEditor()
    if not (_activeMod and _activeMod._editor) then return "" end
    return _activeMod._editor:GetText() or ""
end

function UI.SetEditor(text)
    if not (_activeMod and _activeMod._editor) then return end
    _activeMod._editor:SetText(text or "")
    _activeMod._editor:SetCursorPosition(0)
    if _activeMod._editorScroll then
        _activeMod._editorScroll:SetVerticalScroll(0)
    end
end

-- Save current editor content into the currently-selected snippet.
function UI.SaveCurrent(mod)
    mod = mod or _activeMod
    if not (mod and mod._editor) then return end
    local name = ns.GetCurrentSnippet()
    if not name then return end
    ns.SaveSnippet(name, mod._editor:GetText() or "")
end

-- Load the currently-selected snippet's text into the editor.
function UI.LoadCurrent(mod)
    mod = mod or _activeMod
    if not (mod and mod._editor) then return end
    local name = ns.GetCurrentSnippet()
    local code = name and ns.LoadSnippet(name) or ""
    UI.SetEditor(code)
    UI.RefreshAutoRun()
    UI.RefreshDropdown()
end

-- Switch to a different snippet (saving current first).
function UI.SwitchTo(name)
    if not name then return end
    UI.SaveCurrent()
    if not ns.SetCurrentSnippet(name) then return end
    UI.LoadCurrent()
end

-- ----- Run ---------------------------------------------------------------
function UI.RunEditor(mod)
    mod = mod or _activeMod
    if not mod then return end
    local code = UI.GetEditor()
    if code:match("^%s*$") then return end

    UI.SaveCurrent(mod)

    UI.AppendOutput(mod, { "> run " .. (ns.GetCurrentSnippet() or "?") }, "ffd87f3a")

    local ok, lines = ns.Eval.Run(code)
    UI.AppendOutput(mod, lines, ok and "ffaaaaaa" or "ffff4040")
end

-- ----- Dropdown widget ---------------------------------------------------
local function buildDropdown(parent, mod)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(DROPDOWN_W, BTN_HEIGHT)
    btn:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    btn:SetBackdropColor(0.05, 0.05, 0.05, 0.40)
    btn:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT",  btn, "LEFT",  6, 0)
    label:SetPoint("RIGHT", btn, "RIGHT", -22, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetMaxLines(1)
    btn._label = label

    local arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    arrow:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
    arrow:SetText("|cffd87f3av|r")

    btn:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(0.85, 0.50, 0.20, 1) end)
    btn:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.4, 0.3, 0.15, 1) end)

    btn:SetScript("OnClick", function(self)
        if ns._dropdownList and ns._dropdownList:IsShown() then
            ns._dropdownList:Hide()
            return
        end
        UI.ShowDropdownList(self)
    end)

    return btn
end

local function refreshDropdownList(f)
    for _, row in ipairs(f._rows) do row:Hide() end

    local names = ns.ListSnippets() or {}
    local current = ns.GetCurrentSnippet()
    local y = 0
    for i, name in ipairs(names) do
        local row = f._rows[i]
        if not row then
            row = CreateFrame("Button", nil, f._content)
            row:SetHeight(20)

            local sel = row:CreateTexture(nil, "BACKGROUND", nil, -2)
            sel:SetColorTexture(0.85, 0.50, 0.20, 0.35)
            sel:SetAllPoints()
            sel:Hide()
            row._sel = sel

            local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
            hov:SetColorTexture(0.45, 0.32, 0.15, 0.30)
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
            row:SetScript("OnClick", function(self)
                f:Hide()
                UI.SwitchTo(self._name)
            end)
            f._rows[i] = row
        end
        row._name = name
        row._sel:SetShown(name == current)
        row._hov:Hide()
        local s = ns.GetSnippet(name)
        local autoMark = (s and s.autorun and s.autorun[ns.CharKey()]) and "  |cffaaffaaauto|r" or ""
        local marker   = (name == current) and "|cffd87f3a* |r" or "  "
        row._text:SetText(string.format("%s%s   |cffaaaaaa(%d)|r%s",
            marker, name, s and #(s.code or "") or 0, autoMark))
        row:ClearAllPoints()
        row:SetWidth(f._scroll:GetWidth() - 24)
        row:SetPoint("TOPLEFT", f._content, "TOPLEFT", 0, -y)
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
end

function UI.ShowDropdownList(anchorBtn)
    local f = ns._dropdownList
    if not f then
        local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
        f = CreateFrame("Frame", "ForgeConsoleDropdownList", UIParent, "BackdropTemplate")
        f:SetSize(DROPDOWN_W + 24, 240)
        f:SetFrameStrata("DIALOG")
        f:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        f:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
        f:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)
        f:EnableMouse(true)
        f:SetScript("OnHide", function() end)

        local scrollGui = Gui and Gui:Create("ScrollFrame")
        if scrollGui then
            scrollGui:SetParent(f); scrollGui:ClearAllPoints()
            scrollGui:SetPoint("TOPLEFT",     f, "TOPLEFT",      6, -6)
            scrollGui:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2,  6)
            f._scroll  = scrollGui
            f._content = scrollGui.content
        else
            local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
            scroll:SetPoint("TOPLEFT",     6, -6)
            scroll:SetPoint("BOTTOMRIGHT", -22, 6)
            local content = CreateFrame("Frame", nil, scroll)
            content:SetSize(1, 1)
            scroll:SetScrollChild(content)
            f._scroll  = scroll
            f._content = content
        end

        f._rows = {}
        ns._dropdownList = f
    end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", anchorBtn, "BOTTOMLEFT", 0, -2)
    refreshDropdownList(f)
    f:Show()
end

function UI.RefreshDropdown()
    if not (_activeMod and _activeMod._dropdown) then return end
    _activeMod._dropdown._label:SetText(ns.GetCurrentSnippet() or "(none)")
    if ns._dropdownList and ns._dropdownList:IsShown() then
        refreshDropdownList(ns._dropdownList)
    end
end

function UI.RefreshAutoRun()
    if not (_activeMod and _activeMod._autoCb) then return end
    local name = ns.GetCurrentSnippet()
    _activeMod._autoCb:SetChecked(name and ns.IsAutoRun(name) or false)
end

-- ----- Add / Delete / Save popups ----------------------------------------
local function buildSimplePopup(title)
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetSize(360, 110)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.08, 0.06, 0.04, 0.40)
    f:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)
    f:EnableMouse(true)
    f:Hide()

    local titleFs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleFs:SetPoint("TOPLEFT", 12, -10)
    titleFs:SetText("|cffd87f3a" .. title .. "|r")
    f._title = titleFs

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 12, -36)
    f._label = label

    -- EditBox kept as InputBoxTemplate -- gives a compact framed look for
    -- name prompts and matches the existing style. Future work could swap
    -- to Cairn-Gui Input but the visual difference (Cairn Input is wider
    -- and dark-styled) is a behavior change, not a fix.
    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(280, 22)
    eb:SetAutoFocus(true)
    f._eb = eb

    -- OK / Cancel buttons via Cairn-Gui Button with vanilla fallback.
    local function popupBtn(labelText, onClick, anchorOpts)
        local b = Gui and Gui:Create("Button")
        if b then
            b:SetParent(f); b:ClearAllPoints()
            b:SetWidth(80); b:SetHeight(22)
            if anchorOpts.point == "BOTTOMRIGHT" then
                b:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
            else
                b:SetPoint("RIGHT", anchorOpts.to, "LEFT", -6, 0)
            end
            b:SetText(labelText)
            if onClick then b:SetEventListener("OnClick", function() onClick() end) end
            return b, b.frame
        else
            local raw = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            raw:SetSize(80, 22)
            if anchorOpts.point == "BOTTOMRIGHT" then
                raw:SetPoint("BOTTOMRIGHT", -12, 10)
            else
                raw:SetPoint("RIGHT", anchorOpts.to, "LEFT", -6, 0)
            end
            raw:SetText(labelText)
            if onClick then raw:SetScript("OnClick", onClick) end
            return raw, raw
        end
    end

    -- The OK button's OnClick handler is set per-call via showAddPrompt, so
    -- we install a thunk that delegates to f._okHandler at click time.
    local ok, okFrame = popupBtn("OK", function()
        if f._okHandler then f._okHandler() end
    end, { point = "BOTTOMRIGHT" })
    f._ok = ok
    f._okFrame = okFrame

    popupBtn("Cancel", function() f:Hide() end, { point = "RIGHT", to = okFrame })

    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    eb:SetScript("OnEnterPressed", function() if f._okHandler then f._okHandler() end end)

    return f
end

local function showAddPrompt()
    local f = ns._addPopup
    if not f then
        f = buildSimplePopup("New Snippet")
        f._label:SetText("Name:")
        f._eb:SetPoint("LEFT", f._label, "RIGHT", 8, 0)
        if f._ok.SetText then f._ok:SetText("Create") end
        ns._addPopup = f
    end

    f._okHandler = function()
        local name = (f._eb:GetText() or ""):match("^%s*(.-)%s*$") or ""
        if name == "" then return end
        if ns.GetSnippet(name) then
            if ns.out then ns.out("snippet '" .. name .. "' already exists.") end
            return
        end
        ns.SaveSnippet(name, "")
        ns.SetCurrentSnippet(name)
        UI.LoadCurrent()
        f:Hide()
    end

    f._eb:SetText("")
    f:Show()
    f._eb:SetFocus()
end

local function showDeleteConfirm()
    local cur = ns.GetCurrentSnippet()
    if not cur then return end
    local f = ns._delPopup
    if not f then
        local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
        f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        f:SetSize(380, 120)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0.08, 0.06, 0.04, 0.40)
        f:SetBackdropBorderColor(1, 0.30, 0.15, 1)
        f:EnableMouse(true)
        f:Hide()

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 12, -10)
        title:SetText("|cffff8080Delete Snippet|r")

        local body = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        body:SetPoint("TOPLEFT", 12, -38)
        body:SetPoint("RIGHT", -12, 0)
        body:SetJustifyH("LEFT")
        body:SetJustifyV("TOP")
        body:SetWordWrap(true)
        f._body = body

        -- Delete + Cancel via Cairn-Gui Button with vanilla fallback.
        local function popupBtn(labelText, anchorOpts)
            local b = Gui and Gui:Create("Button")
            if b then
                b:SetParent(f); b:ClearAllPoints()
                b:SetWidth(80); b:SetHeight(22); b:SetText(labelText)
                if anchorOpts.point == "BOTTOMRIGHT" then
                    b:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
                else
                    b:SetPoint("RIGHT", anchorOpts.to, "LEFT", -6, 0)
                end
                return b, b.frame
            else
                local raw = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
                raw:SetSize(80, 22); raw:SetText(labelText)
                if anchorOpts.point == "BOTTOMRIGHT" then
                    raw:SetPoint("BOTTOMRIGHT", -12, 10)
                else
                    raw:SetPoint("RIGHT", anchorOpts.to, "LEFT", -6, 0)
                end
                return raw, raw
            end
        end

        local del, delFrame = popupBtn("Delete", { point = "BOTTOMRIGHT" })
        f._del = del

        local cancel = popupBtn("Cancel", { point = "RIGHT", to = delFrame })
        if cancel.SetEventListener then
            cancel:SetEventListener("OnClick", function() f:Hide() end)
        else
            cancel:SetScript("OnClick", function() f:Hide() end)
        end

        ns._delPopup = f
    end

    f._body:SetText("Delete the snippet '" .. cur .. "'?\nThis cannot be undone.")
    local function doDelete()
        ns.DeleteSnippet(cur)
        UI.LoadCurrent()
        f:Hide()
    end
    if f._del.SetEventListener then
        f._del:SetEventListener("OnClick", doDelete)
    else
        f._del:SetScript("OnClick", doDelete)
    end
    f:Show()
end

-- ----- Main builder ------------------------------------------------------
function UI.Build(parent, mod)
    _activeMod = mod

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- Acquire Cairn-Gui-Core once. Each migration site falls back to vanilla
    -- if the kit failed to load.
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local function makeBtn(parentFrame, label, w, h, onClick)
        local b = Gui and Gui:Create("Button")
        if b then
            b:SetParent(parentFrame); b:ClearAllPoints()
            b:SetWidth(w); b:SetHeight(h); b:SetText(label)
            if onClick then b:SetEventListener("OnClick", function() onClick() end) end
            return b, b.frame
        else
            local raw = CreateFrame("Button", nil, parentFrame, "UIPanelButtonTemplate")
            raw:SetSize(w, h); raw:SetText(label)
            if onClick then raw:SetScript("OnClick", onClick) end
            return raw, raw
        end
    end

    -- ===== Top toolbar ===================================================
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  4, -4)
    toolbar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    toolbar:SetHeight(TOOLBAR_H)

    local dropdown = buildDropdown(toolbar, mod)
    dropdown:SetPoint("LEFT", toolbar, "LEFT", 4, 0)
    mod._dropdown = dropdown

    local addBtnW, addBtnFrame = makeBtn(toolbar, "+", BTN_HEIGHT, BTN_HEIGHT, showAddPrompt)
    addBtnW:ClearAllPoints()
    addBtnW:SetPoint("LEFT", dropdown, "RIGHT", 4, 0)

    local delBtnW, delBtnFrame = makeBtn(toolbar, "-", BTN_HEIGHT, BTN_HEIGHT, showDeleteConfirm)
    delBtnW:ClearAllPoints()
    delBtnW:SetPoint("LEFT", addBtnFrame, "RIGHT", 2, 0)

    -- Auto-run checkbox: Cairn-Gui CheckBox with vanilla fallback.
    local autoCb, autoCbFrame
    do
        local widget = Gui and Gui:Create("CheckBox")
        if widget then
            widget:SetParent(toolbar); widget:ClearAllPoints()
            widget:SetWidth(22); widget:SetHeight(22)
            widget:SetPoint("LEFT", delBtnFrame, "RIGHT", 12, 0)
            widget.frame:EnableMouse(true)
            if widget.frame.RegisterForClicks then widget.frame:RegisterForClicks("AnyUp") end
            widget:SetEventListener("OnValueChanged", function(_, _, checked)
                local name = ns.GetCurrentSnippet()
                if not name then return end
                ns.SetAutoRun(name, checked and true or false)
            end)
            autoCb, autoCbFrame = widget, widget.frame
        else
            local raw = CreateFrame("CheckButton", nil, toolbar, "UICheckButtonTemplate")
            raw:SetSize(22, 22)
            raw:SetPoint("LEFT", delBtnFrame, "RIGHT", 12, 0)
            raw:SetScript("OnClick", function(self)
                local name = ns.GetCurrentSnippet()
                if not name then return end
                ns.SetAutoRun(name, self:GetChecked() and true or false)
            end)
            autoCb, autoCbFrame = raw, raw
        end
    end
    mod._autoCb = autoCb
    local autoLabel = toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoLabel:SetPoint("LEFT", autoCbFrame, "RIGHT", 2, 0)
    autoLabel:SetText("Auto-run on login")

    -- Right-aligned: Run, Clear, Export.
    local runBtnW, runBtnFrame = makeBtn(toolbar, "Run", BTN_WIDTH, BTN_HEIGHT, function() UI.RunEditor(mod) end)
    runBtnW:ClearAllPoints()
    runBtnW:SetPoint("RIGHT", toolbar, "RIGHT", -4, 0)

    local clearBtnW, clearBtnFrame = makeBtn(toolbar, "Clear", BTN_WIDTH, BTN_HEIGHT, function() UI.ClearOutput(mod) end)
    clearBtnW:ClearAllPoints()
    clearBtnW:SetPoint("RIGHT", runBtnFrame, "LEFT", -4, 0)

    local exportBtnW, exportBtnFrame = makeBtn(toolbar, "Export", BTN_WIDTH, BTN_HEIGHT, function()
        if not (Forge and Forge.ShowCopyDialog and Forge.SerializeTable) then return end
        local snippets = {}
        for _, name in ipairs(ns.ListSnippets()) do
            snippets[name] = ns.GetSnippet(name)
        end
        local text = "-- Forge Console snippets export\n-- Paste into a Lua console (e.g. /forge console) or load via SVs.\n\nreturn " .. Forge.SerializeTable(snippets) .. "\n"
        Forge.ShowCopyDialog("Console - export all snippets", text,
            "Ctrl-A to select all, Ctrl-C to copy. " .. tostring(#ns.ListSnippets()) .. " snippets.")
    end)
    exportBtnW:ClearAllPoints()
    exportBtnW:SetPoint("RIGHT", clearBtnFrame, "LEFT", -4, 0)

    -- ===== Code editor =====================================================
    -- Migrated to Cairn-Gui-Core ScrollingEditBox. Two gotchas to know:
    --   1. The widget hooks the inner editBox's OnEditFocusLost to do
    --      `editBox:SetText(self.settings.text)` -- a "commit on Enter" reset.
    --      For a free-form code editor we need every keystroke to persist, so
    --      we hook OnTextChanged on the inner editBox and write the live
    --      string back into widget.settings.text. With that in place, focus-
    --      loss reads the same string the user already sees, and the reset
    --      is a no-op visually.
    --   2. The widget's outer .frame has no chrome of its own (background +
    --      border are styled internally). We keep the existing parchment
    --      BackdropTemplate around it as visual decoration.
    --
    -- The widget exposes `.editBox` for direct access; `mod._editor` keeps
    -- pointing at that EditBox so all GetText/SetText/etc. consumer code
    -- elsewhere in this file still works.
    local editorBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    editorBg:SetPoint("TOPLEFT",     toolbar, "BOTTOMLEFT",  0, -PAD)
    editorBg:SetPoint("BOTTOMRIGHT", frame,   "BOTTOMRIGHT", -4, OUTPUT_H + PAD + 4)
    editorBg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    editorBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    editorBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    local editorWidget = Gui and Gui:Create("ScrollingEditBox")
    if editorWidget then
        editorWidget:SetParent(editorBg); editorWidget:ClearAllPoints()
        editorWidget:SetPoint("TOPLEFT",     editorBg, "TOPLEFT",      6, -6)
        editorWidget:SetPoint("BOTTOMRIGHT", editorBg, "BOTTOMRIGHT", -2,  6)

        -- Wire the inner editBox to the same surface we exposed before.
        local eb = editorWidget.editBox
        eb:SetFontObject("ChatFontNormal")
        eb:SetTextInsets(2, 2, 2, 2)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        -- KEY: keep the widget's settings.text in sync with every keystroke
        -- so the OnEditFocusLost reset doesn't blow away unsaved typing.
        eb:HookScript("OnTextChanged", function(self)
            editorWidget.settings.text = self:GetText() or ""
        end)

        mod._editorWidget = editorWidget
        mod._editor       = eb
        mod._editorScroll = editorWidget.scrollFrame  -- preserved for SetVerticalScroll(0) callers
    else
        -- Defensive vanilla fallback path (kit failed to load).
        local editorScroll = CreateFrame("ScrollFrame", nil, editorBg, "UIPanelScrollFrameTemplate")
        editorScroll:SetPoint("TOPLEFT",     6, -6)
        editorScroll:SetPoint("BOTTOMRIGHT", -28, 6)
        mod._editorScroll = editorScroll

        local editor = CreateFrame("EditBox", nil, editorScroll)
        editor:SetMultiLine(true)
        editor:SetAutoFocus(false)
        editor:SetFontObject("ChatFontNormal")
        editor:SetTextInsets(2, 2, 2, 2)
        editor:SetWidth(600)
        editor:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        editor:SetScript("OnTextChanged", function() end)
        editorScroll:SetScrollChild(editor)
        mod._editor = editor

        local function reflowEditor()
            local w = (editorScroll:GetWidth() or 0) - 4
            if w < 1 then w = 1 end
            editor:SetWidth(w)
        end
        editorScroll:SetScript("OnSizeChanged", reflowEditor)
        reflowEditor()
    end

    -- ===== Output / log pane ============================================
    local outputBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    outputBg:SetPoint("TOPLEFT",     editorBg, "BOTTOMLEFT",  0, -PAD)
    outputBg:SetPoint("BOTTOMRIGHT", frame,    "BOTTOMRIGHT", -4, 4)
    outputBg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    outputBg:SetBackdropColor(0.05, 0.05, 0.05, 0.40)
    outputBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    -- Migrated to Cairn-Gui-Core ScrollFrame. _outputScrollFrame points at
    -- the inner Blizzard scrollFrame (same on both backends) for the few
    -- low-level reads (GetVerticalScrollRange / SetVerticalScroll / GetWidth /
    -- GetHeight / UpdateScrollChildRect) that the widget doesn't surface.
    local outputScroll, outputContent
    do
        local s = Gui and Gui:Create("ScrollFrame")
        if s then
            s:SetParent(outputBg); s:ClearAllPoints()
            s:SetPoint("TOPLEFT",     outputBg, "TOPLEFT",      6, -6)
            s:SetPoint("BOTTOMRIGHT", outputBg, "BOTTOMRIGHT", -2,  6)
            outputScroll  = s
            outputContent = s.content
            mod._outputScroll      = s
            mod._outputScrollFrame = s.scrollFrame or s
        else
            local raw = CreateFrame("ScrollFrame", nil, outputBg, "UIPanelScrollFrameTemplate")
            raw:SetPoint("TOPLEFT",     6, -6)
            raw:SetPoint("BOTTOMRIGHT", -28, 6)
            local content = CreateFrame("Frame", nil, raw); content:SetSize(1, 1); raw:SetScrollChild(content)
            outputScroll  = raw
            outputContent = content
            mod._outputScroll      = raw
            mod._outputScrollFrame = raw
        end
    end
    mod._outputContent = outputContent

    local outputText = outputContent:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    outputText:SetJustifyH("LEFT")
    outputText:SetJustifyV("TOP")
    outputText:SetPoint("TOPLEFT", outputContent, "TOPLEFT", 4, -4)
    outputText:SetWordWrap(true)
    outputText:SetText("")
    mod._outputText = outputText

    local function reflowOutput()
        local sw = outputScroll:GetWidth()  or 0
        local sh = outputScroll:GetHeight() or 0
        local w  = sw - 8
        if w < 1 then w = 1 end
        outputText:SetWidth(w)
        local th = (outputText:GetStringHeight() or 0) + 12
        if th < sh then th = sh end
        outputContent:SetSize(w, th)
        local sf = mod._outputScrollFrame or outputScroll
        if sf.UpdateScrollChildRect then sf:UpdateScrollChildRect() end
    end
    mod._reflowOutput = reflowOutput
    -- Hook via the inner Blizzard scrollFrame so the kit's own SetScript
    -- handlers aren't clobbered. The leading `local sf =` avoids the Lua
    -- parser ambiguity where `(...)` on the next line gets glued to the
    -- previous expression as a function call (took out the Console tab on
    -- 2026-05-05; reflowOutput returned nil and the chained :HookScript
    -- threw "attempt to index a nil value" inside UI.Build, aborting the
    -- entire Console UI).
    local outputSf = mod._outputScrollFrame or outputScroll
    outputSf:HookScript("OnSizeChanged", reflowOutput)
    reflowOutput()

    -- ===== Welcome banner + initial load ================================
    UI.AppendOutput(mod, {
        "Forge Console - in-game scripting workspace",
        "Pick a snippet from the dropdown, edit, click Run.  Switching snippets auto-saves.",
        "Auto-run on login is per-character; toggle via the checkbox or /forge consoleautorun.",
    }, "ff7fbfff")

    UI.LoadCurrent()
end

-- Called by the descriptor whenever the tab becomes visible.
function UI.OnTabShow(mod)
    _activeMod = mod
    UI.LoadCurrent()
end

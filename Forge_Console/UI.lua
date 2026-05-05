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
    if mod._outputScroll then
        local maxScroll = mod._outputScroll:GetVerticalScrollRange() or 0
        mod._outputScroll:SetVerticalScroll(maxScroll)
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
    f._scroll:UpdateScrollChildRect()
end

function UI.ShowDropdownList(anchorBtn)
    local f = ns._dropdownList
    if not f then
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

        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",     6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -22, 6)
        f._scroll = scroll

        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(1, 1)
        scroll:SetScrollChild(content)
        f._content = content

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

    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(280, 22)
    eb:SetAutoFocus(true)
    f._eb = eb

    local ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    ok:SetSize(80, 22)
    ok:SetPoint("BOTTOMRIGHT", -12, 10)
    f._ok = ok

    local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancel:SetSize(80, 22)
    cancel:SetPoint("RIGHT", ok, "LEFT", -6, 0)
    cancel:SetText("Cancel")
    cancel:SetScript("OnClick", function() f:Hide() end)

    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    eb:SetScript("OnEnterPressed", function() ok:Click() end)

    return f
end

local function showAddPrompt()
    local f = ns._addPopup
    if not f then
        f = buildSimplePopup("New Snippet")
        f._label:SetText("Name:")
        f._eb:SetPoint("LEFT", f._label, "RIGHT", 8, 0)
        f._ok:SetText("Create")
        ns._addPopup = f
    end

    f._ok:SetScript("OnClick", function()
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
    end)

    f._eb:SetText("")
    f:Show()
    f._eb:SetFocus()
end

local function showDeleteConfirm()
    local cur = ns.GetCurrentSnippet()
    if not cur then return end
    local f = ns._delPopup
    if not f then
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

        local del = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        del:SetSize(80, 22)
        del:SetPoint("BOTTOMRIGHT", -12, 10)
        del:SetText("Delete")
        f._del = del

        local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        cancel:SetSize(80, 22)
        cancel:SetPoint("RIGHT", del, "LEFT", -6, 0)
        cancel:SetText("Cancel")
        cancel:SetScript("OnClick", function() f:Hide() end)

        ns._delPopup = f
    end

    f._body:SetText("Delete the snippet '" .. cur .. "'?\nThis cannot be undone.")
    f._del:SetScript("OnClick", function()
        ns.DeleteSnippet(cur)
        UI.LoadCurrent()
        f:Hide()
    end)
    f:Show()
end

-- ----- Main builder ------------------------------------------------------
function UI.Build(parent, mod)
    _activeMod = mod

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- ===== Top toolbar ===================================================
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  4, -4)
    toolbar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    toolbar:SetHeight(TOOLBAR_H)

    local dropdown = buildDropdown(toolbar, mod)
    dropdown:SetPoint("LEFT", toolbar, "LEFT", 4, 0)
    mod._dropdown = dropdown

    local addBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    addBtn:SetSize(BTN_HEIGHT, BTN_HEIGHT)
    addBtn:SetPoint("LEFT", dropdown, "RIGHT", 4, 0)
    addBtn:SetText("+")
    addBtn:SetScript("OnClick", showAddPrompt)

    local delBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    delBtn:SetSize(BTN_HEIGHT, BTN_HEIGHT)
    delBtn:SetPoint("LEFT", addBtn, "RIGHT", 2, 0)
    delBtn:SetText("-")
    delBtn:SetScript("OnClick", showDeleteConfirm)

    -- Auto-run checkbox.
    local autoCb = CreateFrame("CheckButton", nil, toolbar, "UICheckButtonTemplate")
    autoCb:SetSize(22, 22)
    autoCb:SetPoint("LEFT", delBtn, "RIGHT", 12, 0)
    autoCb:SetScript("OnClick", function(self)
        local name = ns.GetCurrentSnippet()
        if not name then return end
        ns.SetAutoRun(name, self:GetChecked() and true or false)
    end)
    mod._autoCb = autoCb
    local autoLabel = toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoLabel:SetPoint("LEFT", autoCb, "RIGHT", 2, 0)
    autoLabel:SetText("Auto-run on login")

    -- Right-aligned: Run, Clear.
    local runBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    runBtn:SetSize(BTN_WIDTH, BTN_HEIGHT)
    runBtn:SetPoint("RIGHT", toolbar, "RIGHT", -4, 0)
    runBtn:SetText("Run")
    runBtn:SetScript("OnClick", function() UI.RunEditor(mod) end)

    local clearBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    clearBtn:SetSize(BTN_WIDTH, BTN_HEIGHT)
    clearBtn:SetPoint("RIGHT", runBtn, "LEFT", -4, 0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function() UI.ClearOutput(mod) end)

    local exportBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    exportBtn:SetSize(BTN_WIDTH, BTN_HEIGHT)
    exportBtn:SetPoint("RIGHT", clearBtn, "LEFT", -4, 0)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function()
        if not (Forge and Forge.ShowCopyDialog and Forge.SerializeTable) then return end
        local snippets = {}
        for _, name in ipairs(ns.ListSnippets()) do
            snippets[name] = ns.GetSnippet(name)
        end
        local text = "-- Forge Console snippets export\n-- Paste into a Lua console (e.g. /forge console) or load via SVs.\n\nreturn " .. Forge.SerializeTable(snippets) .. "\n"
        Forge.ShowCopyDialog("Console - export all snippets", text,
            "Ctrl-A to select all, Ctrl-C to copy. " .. tostring(#ns.ListSnippets()) .. " snippets.")
    end)

    -- ===== Code editor (multi-line ScrollFrame + EditBox) =================
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
    editor:SetScript("OnTextChanged", function() end)  -- we save on switch / hide / Run
    -- F5 / Ctrl-S keybindings via OnKeyDown require EnableKeyboard, but that
    -- breaks normal typing. Easier: rely on the Run button + the Ctrl-S
    -- behavior auto-saves on every snippet switch and on every Run.
    editorScroll:SetScrollChild(editor)
    mod._editor = editor

    local function reflowEditor()
        local w = (editorScroll:GetWidth() or 0) - 4
        if w < 1 then w = 1 end
        editor:SetWidth(w)
    end
    editorScroll:SetScript("OnSizeChanged", reflowEditor)
    reflowEditor()

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

    local outputScroll = CreateFrame("ScrollFrame", nil, outputBg, "UIPanelScrollFrameTemplate")
    outputScroll:SetPoint("TOPLEFT",     6, -6)
    outputScroll:SetPoint("BOTTOMRIGHT", -28, 6)
    mod._outputScroll = outputScroll

    local outputContent = CreateFrame("Frame", nil, outputScroll)
    outputContent:SetSize(1, 1)
    outputScroll:SetScrollChild(outputContent)
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
        outputScroll:UpdateScrollChildRect()
    end
    mod._reflowOutput = reflowOutput
    outputScroll:SetScript("OnSizeChanged", reflowOutput)
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

-- Forge_Console.UI: Cairn-Gui-2.0 widget shell.
--
-- Phase 2 layout (top to bottom inside the pane):
--   [heading]
--   [muted help line]
--   [toolbar: Dropdown [+] [-]  ...  Clear  Run]
--   [editor ScrollFrame]      -- ~60% of remaining height
--   [output ScrollFrame]      -- ~40% of remaining height
--
-- Toolbar uses SetLayoutManual on the toolbar Container itself? No -- that
-- would un-position it from pane's Stack. Instead, the toolbar Container
-- has NO layout strategy (Stack doesn't fire on a container without one),
-- so child SetPoint sticks. Left-side widgets anchor to toolbar LEFT, right-
-- side buttons anchor to toolbar RIGHT.

local ADDON, ns = ...

local UI = {}
ns.UI = UI


-- ----- Layout tunables ----------------------------------------------------

local HEADER_RESERVED   = 90   -- rough height of heading + help + toolbar
local OUTPUT_PORTION    = 0.32 -- output pane is ~1/3 of editor+output space
local OUTPUT_MIN_H      = 90
local EDITOR_MIN_H      = 120
local REPL_H            = 26   -- bottom REPL strip height
local SIDE_PAD          = 10
local BOTTOM_PAD        = 10
local GAP               = 6

local DROPDOWN_W        = 200
local SMALL_BTN         = 22


-- ----- Module-scope state -------------------------------------------------

local _pane
local _editorScroll, _editorEdit, _editorContent
local _gutter         -- line-number gutter handle (ns.LineNumbers)
local _outputScroll, _outputContent, _outputText

-- Output buffer is held as a list of pre-rendered lines and re-concat'd
-- into _outputText on every write. Storing as a list lets us cap by line
-- count cheaply (one slice when we cross the cap, not a string scan).
-- 2000 lines at ~80 chars each is ~160KB worst case; SetText on a string
-- of that size is fine. ShowCopyPopup still reads via _outputText:GetText.
local OUTPUT_CAP   = 2000
local _outputLines = {}

-- Error transcript. Survives Clear, persists to ns.db.global.errors via
-- the alias trick in UI.Build (same as REPL history). Each entry is a
-- single pre-formatted string with a timestamp + source label so it's
-- self-contained for export. ShowErrorsPopup serializes the list.
local ERROR_CAP   = 500
local _errorLines = {}
local _replBg, _replInput, _replPrompt
local _runBtn, _clearBtn, _copyBtn
local _dropdown
local _modLabel       -- "* modified" indicator next to dropdown
local _lockBtn        -- toolbar lock toggle
local _autoCb         -- autorun-on-login checkbox
local _addPopup, _delPopup, _switchPopup
local _copyPopup, _exportPopup, _errorsPopup
local _ctxMenu        -- right-click context menu for dropdown rows
local _mod  -- live module ref from Forge tab system

-- One-time-per-snippet-per-session record so the lock warning doesn't
-- spam every keystroke. Resets implicitly on /reload (Lua state fresh).
local _lockWarnedThisSession = {}

-- REPL history. Native EditBox SetHistoryLines + AddHistoryLine does NOT
-- auto-bind Up/Down on a raw EditBox in modern retail; the arrow keys
-- get eaten by cursor movement before any handler sees them. So we hook
-- OnArrowPressed and walk our own list. _replHistPos is nil for "live
-- editing" or 1..#_replHistory when the user has navigated into the past.
--
-- _replHistory starts as an empty module-scope fallback; UI.Build aliases
-- it to `ns.db.global.history` so every push persists across /reload and
-- characters. Shared across characters because REPL one-liners are
-- usually generic Lua scratchwork, not character-specific.
local HISTORY_CAP  = 500
local _replHistory = {}
local _replHistPos = nil

-- Guards against re-firing the dropdown Changed event when we
-- programmatically reset it after the user cancels a switch.
local _suppressDropdownChange = false


-- ----- Output helpers ------------------------------------------------------

local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

function UI.AppendOutput(lines, color)
    if not _outputText then return end
    for _, line in ipairs(lines or {}) do
        local esc = escapeBars(line)
        if color then
            _outputLines[#_outputLines + 1] = "|c" .. color .. esc .. "|r"
        else
            _outputLines[#_outputLines + 1] = esc
        end
    end
    -- One-shot slice when we cross the cap (vs while+table.remove which is
    -- O(N^2) on big bursts). Shift the surviving suffix left, then nil the
    -- trailing slots so #_outputLines reflects the new length.
    local overflow = #_outputLines - OUTPUT_CAP
    if overflow > 0 then
        for i = 1, OUTPUT_CAP do
            _outputLines[i] = _outputLines[i + overflow]
        end
        for i = OUTPUT_CAP + 1, #_outputLines do
            _outputLines[i] = nil
        end
    end
    _outputText:SetText(table.concat(_outputLines, "\n"))
    if UI._reflowOutput then UI._reflowOutput() end
    if _outputScroll and _outputScroll.Cairn and _outputScroll.Cairn.ScrollToBottom then
        _outputScroll.Cairn:ScrollToBottom()
    end
end

function UI.ClearOutput()
    if ns.Eval and ns.Eval.EndSession then
        ns.Eval.EndSession()
    end
    for i = #_outputLines, 1, -1 do _outputLines[i] = nil end
    if _outputText then
        _outputText:SetText("")
        if UI._reflowOutput then UI._reflowOutput() end
    end
end


-- ----- Error transcript ---------------------------------------------------
-- AppendError tees: it appends the error lines to the visible output pane
-- in red (existing behavior) AND records them with timestamps in
-- _errorLines for later export. _errorLines survives ClearOutput so an
-- accidental Clear doesn't lose the only record of what blew up.
--
-- `source` is a free-form label (snippet name or "repl") so the export
-- can be skimmed without remembering what tab generated which error.

function UI.AppendError(lines, source)
    if type(lines) ~= "table" then return end
    UI.AppendOutput(lines, "ffff4040")
    local ts  = date and date("%H:%M:%S") or ""
    local src = source or "?"
    for _, line in ipairs(lines) do
        _errorLines[#_errorLines + 1] = string.format("[%s] [%s] %s", ts, src, tostring(line))
    end
    -- One-shot slice trim (same shape as the output cap).
    local overflow = #_errorLines - ERROR_CAP
    if overflow > 0 then
        for i = 1, ERROR_CAP do
            _errorLines[i] = _errorLines[i + overflow]
        end
        for i = ERROR_CAP + 1, #_errorLines do
            _errorLines[i] = nil
        end
    end
end

function UI.ClearErrors()
    for i = #_errorLines, 1, -1 do _errorLines[i] = nil end
end

-- Build a plain-text transcript ready to paste into a bug report.
function UI.GetErrorTranscript()
    if #_errorLines == 0 then return "(no errors recorded)" end
    return table.concat(_errorLines, "\n")
end


-- ----- Editor helpers ------------------------------------------------------

function UI.GetEditor()
    if not _editorEdit then return "" end
    return _editorEdit:GetText() or ""
end

function UI.SetEditor(text)
    if not _editorEdit then return end
    _editorEdit:SetText(text or "")
    _editorEdit:SetCursorPosition(0)
    if _editorScroll and _editorScroll.Cairn and _editorScroll.Cairn.ScrollToTop then
        _editorScroll.Cairn:ScrollToTop()
    end
    -- Programmatic SetText doesn't reliably fire OnTextChanged on raw
    -- EditBoxes in modern retail, so explicitly refresh gutter + reflow.
    if _gutter and ns.LineNumbers then
        ns.LineNumbers.Update(_gutter)
    end
    if UI._reflowEditor then UI._reflowEditor() end
end

-- Live editor text vs the saved code of the current snippet. Used by the
-- modified indicator and the switch-confirm prompt.
function UI.IsModified()
    if not _editorEdit then return false end
    local cur = ns.GetCurrentSnippet()
    if not cur then return false end
    local saved = ns.LoadSnippet(cur) or ""
    return (_editorEdit:GetText() or "") ~= saved
end

-- Flush live editor text into the current snippet.
function UI.SaveCurrent()
    if not _editorEdit then return end
    local cur = ns.GetCurrentSnippet()
    if not cur then return end
    ns.SaveSnippet(cur, _editorEdit:GetText() or "")
    UI.RefreshModifiedIndicator()
end

-- Load the current snippet's code into the editor.
function UI.LoadCurrent()
    if not _editorEdit then return end
    local cur = ns.GetCurrentSnippet()
    local code = cur and ns.LoadSnippet(cur) or ""
    UI.SetEditor(code)
    UI.RefreshModifiedIndicator()
    UI.RefreshLockButton()
    UI.RefreshAutoRun()
end


-- ----- Run -----------------------------------------------------------------

-- Move cursor to the first character of `lineNum` (1-based). Used after
-- a runtime/syntax error to put the user right where they need to fix.
function UI.JumpToLine(lineNum)
    if not (_editorEdit and lineNum and lineNum > 0) then return end
    local text = _editorEdit:GetText() or ""
    local pos, cur = 1, 1
    while cur < lineNum do
        local s, e = text:find("\n", pos, true)
        if not e then break end
        pos = e + 1
        cur = cur + 1
    end
    _editorEdit:SetFocus()
    _editorEdit:SetCursorPosition(pos - 1)
end

function UI.RunEditor()
    local code = UI.GetEditor()
    if code:match("^%s*$") then return end
    local cur = ns.GetCurrentSnippet() or "?"

    -- Clear any prior error highlight from the gutter before running.
    if _gutter and ns.LineNumbers then
        ns.LineNumbers.ClearHighlight(_gutter)
    end

    UI.AppendOutput({ "> run " .. cur }, "ffd87f3a")

    local ok, lines, errLine = ns.Eval.Run(code, {
        idleSec  = 5,
        onAppend = function(line)
            UI.AppendOutput({ line }, "ff7fbfff")
        end,
    })
    if ok then
        UI.AppendOutput(lines, "ffaaaaaa")
    else
        UI.AppendError(lines, cur)
    end

    -- On error, light up the gutter line + jump cursor to that line.
    if (not ok) and errLine and _gutter and ns.LineNumbers then
        ns.LineNumbers.SetHighlight(_gutter, errLine)
        UI.JumpToLine(errLine)
    end
end


-- ----- Dropdown refresh ---------------------------------------------------

-- Build the options array from the current snippet list. Each entry's
-- label is the snippet name, with a "[L] " prefix when the snippet is
-- locked. The modified asterisk lives in a separate Label next to the
-- dropdown so we don't have to rebuild the options on every keystroke.
local function buildDropdownOptions()
    local opts = {}
    for _, name in ipairs(ns.ListSnippets()) do
        local label = name
        if ns.IsLocked and ns.IsLocked(name) then
            label = "|cffd87f3a[L]|r " .. name
        end
        opts[#opts + 1] = { value = name, label = label }
    end
    return opts
end

function UI.RefreshDropdown()
    if not _dropdown then return end
    _suppressDropdownChange = true
    _dropdown.Cairn:SetOptions(buildDropdownOptions())
    _dropdown.Cairn:SetSelected(ns.GetCurrentSnippet() or ns.SCRATCH)
    _suppressDropdownChange = false
    UI.RefreshLockButton()
    UI.RefreshAutoRun()
end

function UI.RefreshModifiedIndicator()
    if not _modLabel then return end
    if UI.IsModified() then
        _modLabel.Cairn:SetText("|cffd87f3a*|r")
    else
        _modLabel.Cairn:SetText("")
    end
end

-- Sync the autorun checkbox to the current snippet's per-character flag.
function UI.RefreshAutoRun()
    if not _autoCb then return end
    local cur = ns.GetCurrentSnippet()
    local on  = cur and ns.IsAutoRun and ns.IsAutoRun(cur) or false
    -- Guard against the Toggled event re-firing into SetAutoRun. We
    -- short-circuit in the Toggled handler when the value already matches.
    _autoCb.Cairn:SetChecked(on)
end

-- Reflect lock state on the toolbar button label.
function UI.RefreshLockButton()
    if not _lockBtn then return end
    local cur = ns.GetCurrentSnippet()
    local locked = cur and ns.IsLocked and ns.IsLocked(cur)
    if locked then
        _lockBtn.Cairn:SetText("|cffd87f3aL|r")
    else
        _lockBtn.Cairn:SetText("L")
    end
    -- Scratch can't be locked; disable the button when scratch is current.
    if _lockBtn.Cairn.SetEnabled then
        _lockBtn.Cairn:SetEnabled(cur ~= ns.SCRATCH)
    end
end


-- ----- Switch logic --------------------------------------------------------
-- Switching when the editor is unmodified is immediate. When modified, we
-- prompt Save / Discard / Cancel; on Cancel we revert the dropdown.

local function reallySwitchTo(name)
    if not ns.SetCurrentSnippet(name) then return end
    UI.LoadCurrent()
    UI.RefreshDropdown()
end

local function showSwitchConfirm(fromName, toName)
    if not _switchPopup then
        UI._buildSwitchPopup()
    end
    _switchPopup._body.Cairn:SetText(string.format(
        "Snippet |cffffd200%s|r has unsaved changes.\nSave before switching to |cffffd200%s|r?",
        fromName, toName))
    _switchPopup._fromName = fromName
    _switchPopup._toName   = toName
    _switchPopup:Show()
end

function UI.SwitchTo(name)
    if not name then return end
    local cur = ns.GetCurrentSnippet()
    if name == cur then return end
    if not UI.IsModified() then
        reallySwitchTo(name)
        return
    end
    -- Modified: prompt. If the user cancels, we revert the dropdown to
    -- the current snippet inside the cancel handler.
    showSwitchConfirm(cur, name)
end


-- ----- Popups -------------------------------------------------------------

-- Build the Add-snippet Window (Window widget at DIALOG strata, lazily
-- created on first use and shown/hidden thereafter).
function UI._buildAddPopup()
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local win = Gui:Acquire("Window", UIParent, {
        title    = "New Snippet",
        width    = 360,
        height   = 130,
        strata   = "DIALOG",
        closable = true,
        movable  = true,
    })
    win:Hide()
    win:ClearAllPoints()
    win:SetPoint("CENTER")

    local content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 8, padding = 10 })

    Gui:Acquire("Label", content, { text = "Name:", variant = "muted" })

    local eb = Gui:Acquire("EditBox", content, {
        width       = 320,
        height      = 24,
        placeholder = "snippet name",
    })

    -- Button row anchored to the bottom of the window.
    local btnRow = Gui:Acquire("Container", content, { height = 24 })

    local createBtn = Gui:Acquire("Button", btnRow, {
        text = "Create", variant = "primary", width = 80, height = 22,
    })
    createBtn:ClearAllPoints()
    createBtn:SetPoint("RIGHT", btnRow, "RIGHT", 0, 0)

    local cancelBtn = Gui:Acquire("Button", btnRow, {
        text = "Cancel", variant = "ghost", width = 80, height = 22,
    })
    cancelBtn:ClearAllPoints()
    cancelBtn:SetPoint("RIGHT", createBtn, "LEFT", -6, 0)

    local function attempt()
        local name = (eb.Cairn:GetText() or ""):match("^%s*(.-)%s*$") or ""
        if name == "" then return end
        if ns.GetSnippet(name) then
            UI.AppendOutput({ "snippet '" .. name .. "' already exists." }, "ffff4040")
            return
        end
        ns.SaveSnippet(name, "")
        ns.SetCurrentSnippet(name)
        UI.LoadCurrent()
        UI.RefreshDropdown()
        win:Hide()
    end
    createBtn.Cairn:On("Click", attempt)
    cancelBtn.Cairn:On("Click", function() win:Hide() end)
    eb.Cairn:On("EnterPressed", attempt)
    eb.Cairn:On("EscapePressed", function() win:Hide() end)

    win.Cairn:On("Close", function() win:Hide() end)

    win._eb = eb
    _addPopup = win
end

function UI._showAddPopup()
    if not _addPopup then UI._buildAddPopup() end
    if not _addPopup then return end
    _addPopup._eb.Cairn:SetText("")
    _addPopup:Show()
    _addPopup._eb.Cairn:Focus()
end

-- Build the Delete-snippet confirm Window.
function UI._buildDelPopup()
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local win = Gui:Acquire("Window", UIParent, {
        title    = "Delete Snippet",
        width    = 380,
        height   = 130,
        strata   = "DIALOG",
        closable = true,
        movable  = true,
    })
    win:Hide()
    win:ClearAllPoints()
    win:SetPoint("CENTER")

    local content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 8, padding = 10 })

    local body = Gui:Acquire("Label", content, { text = "" })

    local btnRow = Gui:Acquire("Container", content, { height = 24 })

    local delBtn = Gui:Acquire("Button", btnRow, {
        text = "Delete", variant = "primary", width = 80, height = 22,
    })
    delBtn:ClearAllPoints()
    delBtn:SetPoint("RIGHT", btnRow, "RIGHT", 0, 0)

    local cancelBtn = Gui:Acquire("Button", btnRow, {
        text = "Cancel", variant = "ghost", width = 80, height = 22,
    })
    cancelBtn:ClearAllPoints()
    cancelBtn:SetPoint("RIGHT", delBtn, "LEFT", -6, 0)

    delBtn.Cairn:On("Click", function()
        local name = win._targetName
        if not name then win:Hide(); return end
        ns.DeleteSnippet(name)
        UI.LoadCurrent()
        UI.RefreshDropdown()
        win:Hide()
    end)
    cancelBtn.Cairn:On("Click", function() win:Hide() end)
    win.Cairn:On("Close", function() win:Hide() end)

    win._body = body
    _delPopup = win
end

-- Show the delete-confirm popup targeting `name`. Falls back to the
-- currently-selected snippet if `name` is nil (the toolbar trash button
-- path). Right-click-on-row passes the row's snippet explicitly.
function UI._showDelPopupFor(name)
    if not name then return end
    if name == ns.SCRATCH then
        UI.AppendOutput({ "scratch can't be deleted." }, "ffd87f3a")
        return
    end
    if not _delPopup then UI._buildDelPopup() end
    if not _delPopup then return end
    _delPopup._body.Cairn:SetText(string.format(
        "Delete snippet |cffffd200%s|r?\nThis cannot be undone.", name))
    _delPopup._targetName = name
    _delPopup:Show()
end

function UI._showDelPopup()
    UI._showDelPopupFor(ns.GetCurrentSnippet())
end

-- Build the Switch-Confirm Window (Save / Discard / Cancel).
function UI._buildSwitchPopup()
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local win = Gui:Acquire("Window", UIParent, {
        title    = "Unsaved changes",
        width    = 420,
        height   = 140,
        strata   = "DIALOG",
        closable = true,
        movable  = true,
    })
    win:Hide()
    win:ClearAllPoints()
    win:SetPoint("CENTER")

    local content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 8, padding = 10 })

    local body = Gui:Acquire("Label", content, { text = "" })

    local btnRow = Gui:Acquire("Container", content, { height = 24 })

    local saveBtn = Gui:Acquire("Button", btnRow, {
        text = "Save", variant = "primary", width = 80, height = 22,
    })
    saveBtn:ClearAllPoints()
    saveBtn:SetPoint("RIGHT", btnRow, "RIGHT", 0, 0)

    local discardBtn = Gui:Acquire("Button", btnRow, {
        text = "Discard", variant = "ghost", width = 80, height = 22,
    })
    discardBtn:ClearAllPoints()
    discardBtn:SetPoint("RIGHT", saveBtn, "LEFT", -6, 0)

    local cancelBtn = Gui:Acquire("Button", btnRow, {
        text = "Cancel", variant = "ghost", width = 80, height = 22,
    })
    cancelBtn:ClearAllPoints()
    cancelBtn:SetPoint("RIGHT", discardBtn, "LEFT", -6, 0)

    saveBtn.Cairn:On("Click", function()
        -- Save current editor text to old snippet, then switch.
        local from = win._fromName
        local to   = win._toName
        if from then
            ns.SaveSnippet(from, _editorEdit and _editorEdit:GetText() or "")
        end
        win:Hide()
        if to then reallySwitchTo(to) end
    end)
    discardBtn.Cairn:On("Click", function()
        local to = win._toName
        win:Hide()
        if to then reallySwitchTo(to) end
    end)
    cancelBtn.Cairn:On("Click", function()
        win:Hide()
        -- Revert the dropdown to the snippet we were editing.
        UI.RefreshDropdown()
    end)
    win.Cairn:On("Close", function()
        win:Hide()
        UI.RefreshDropdown()
    end)

    win._body = body
    _switchPopup = win
end


-- ----- Copy / Export popups ----------------------------------------------
-- Both popups are read-only-style: a wide multi-line EditBox the user can
-- Ctrl+A, Ctrl+C from. WoW has no clipboard API, so the user-driven
-- keyboard copy is the only way. Window is at DIALOG strata so it
-- floats above Forge's HIGH-strata main window.

local function buildCopyExportPopup(title, hint)
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return nil end

    local win = Gui:Acquire("Window", UIParent, {
        title    = title,
        width    = 560,
        height   = 360,
        strata   = "DIALOG",
        closable = true,
        movable  = true,
    })
    win:Hide()
    win:ClearAllPoints()
    win:SetPoint("CENTER")

    local content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 8 })

    Gui:Acquire("Label", content, { text = hint, variant = "muted" })

    -- The EditBox holds the payload. Multi-line; the user selects with
    -- Ctrl+A and copies with Ctrl+C. We set it as read-only-ish by
    -- restoring the original text on every OnTextChanged, but allow
    -- selection and copy first by giving keyboard focus.
    local eb = Gui:Acquire("EditBox", content, {
        width     = 540,
        height    = 270,
        multiline = true,
        text      = "",
    })

    -- Button row: Copy + Close side by side. WoW has no clipboard API
    -- so the Copy button can't actually push to the OS clipboard; it
    -- re-selects all text and refocuses the EditBox so the user only
    -- has to press Ctrl-C. This handles the case where the user clicked
    -- into the textbox after open and lost the auto-selection.
    local btnRow = Gui:Acquire("Container", content, { height = 22 })
    btnRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    local copyBtn = Gui:Acquire("Button", btnRow, {
        text = "Copy", variant = "primary", width = 80, height = 22,
    })
    copyBtn.Cairn:On("Click", function()
        if eb and eb.Cairn then
            if eb.Cairn.HighlightText then eb.Cairn:HighlightText() end
            if eb.Cairn.Focus         then eb.Cairn:Focus()         end
        end
    end)

    local closeBtn = Gui:Acquire("Button", btnRow, {
        text = "Close", variant = "ghost", width = 80, height = 22,
    })
    closeBtn.Cairn:On("Click", function() win:Hide() end)
    win.Cairn:On("Close", function() win:Hide() end)

    win._eb = eb
    return win
end

function UI._buildCopyPopup()
    _copyPopup = buildCopyExportPopup(
        "Copy output",
        "Click Copy to re-select all (or Ctrl-A), then press Ctrl-C. "
        .. "Color codes are stripped.")
end

function UI._buildExportPopup()
    _exportPopup = buildCopyExportPopup(
        "Export snippets",
        "Ctrl-A to select all, Ctrl-C to copy. Paste into a Lua source file or a /script line.")
end

function UI._buildErrorsPopup()
    _errorsPopup = buildCopyExportPopup(
        "Error transcript",
        "Errors captured since the last /forge consoleerrclear. Ctrl-A to select, Ctrl-C to copy.")
end


-- ----- Snippet right-click context menu ----------------------------------
-- Small floating Window with two actions for a single snippet (Lock toggle
-- + Delete). Anchored below the row that fired RowRightClick. Reuses the
-- existing _delPopup for the destructive-confirm step so the deletion UX
-- matches the toolbar trash button.

function UI._buildCtxMenu()
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local win = Gui:Acquire("Window", UIParent, {
        title    = "Snippet",
        width    = 200,
        height   = 116,
        strata   = "DIALOG",
        closable = true,
        movable  = false,
    })
    win:Hide()

    local content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 8 })

    local nameLbl = Gui:Acquire("Label", content, { text = "" })

    local lockBtn = Gui:Acquire("Button", content, {
        text = "Lock", variant = "default", width = 184, height = 22,
    })
    lockBtn.Cairn:On("Click", function()
        local n = win._target
        win:Hide()
        if not n then return end
        ns.ToggleLocked(n)
        UI.RefreshLockButton()
        UI.RefreshDropdown()
    end)

    local delBtn = Gui:Acquire("Button", content, {
        text = "Delete...", variant = "danger", width = 184, height = 22,
    })
    delBtn.Cairn:On("Click", function()
        local n = win._target
        win:Hide()
        if not n then return end
        UI._showDelPopupFor(n)
    end)

    win.Cairn:On("Close", function() win:Hide() end)

    win._nameLbl = nameLbl
    win._lockBtn = lockBtn
    _ctxMenu = win
end

function UI._showCtxMenuFor(name, anchorFrame)
    if not name then return end
    if name == ns.SCRATCH then
        UI.AppendOutput({ "scratch cannot be locked or deleted." }, "ffd87f3a")
        return
    end
    if not _ctxMenu then UI._buildCtxMenu() end
    if not _ctxMenu then return end
    _ctxMenu._target = name
    _ctxMenu._nameLbl.Cairn:SetText("|cffffd200" .. name .. "|r")
    _ctxMenu._lockBtn.Cairn:SetText(ns.IsLocked(name) and "Unlock" or "Lock")
    _ctxMenu:ClearAllPoints()
    if anchorFrame and anchorFrame.GetBottom then
        _ctxMenu:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -2)
    else
        _ctxMenu:SetPoint("CENTER")
    end
    _ctxMenu:Show()
end

function UI.ShowCopyPopup()
    if not _copyPopup then UI._buildCopyPopup() end
    if not _copyPopup then return end
    local raw = (_outputText and _outputText:GetText()) or ""
    -- Strip color escape codes (|cAARRGGBB ... |r) so the copy is plain.
    local clean = raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if clean == "" then clean = "(output is empty)" end
    _copyPopup._eb.Cairn:SetText(clean)
    _copyPopup:Show()
    _copyPopup._eb.Cairn:HighlightText()
    _copyPopup._eb.Cairn:Focus()
end


-- Show the copy popup with an arbitrary string instead of reading from
-- the output pane. Useful for diagnostic snippets that want their full
-- report in the popup directly, bypassing the output-buffer timing
-- (Eval batches snippet print() output and only flushes to the pane
-- after the snippet body returns).
function UI.ShowCopyPopupWithText(text)
    if not _copyPopup then UI._buildCopyPopup() end
    if not _copyPopup then return end
    local clean = tostring(text or "")
    -- Strip color escape codes the same way ShowCopyPopup does so the
    -- caller can pass colorized strings if they want.
    clean = clean:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if clean == "" then clean = "(empty)" end
    _copyPopup._eb.Cairn:SetText(clean)
    _copyPopup:Show()
    _copyPopup._eb.Cairn:HighlightText()
    _copyPopup._eb.Cairn:Focus()
end

function UI.ShowExportPopup()
    if not _exportPopup then UI._buildExportPopup() end
    if not _exportPopup then return end
    local text = (ns.BuildExportString and ns.BuildExportString()) or "-- empty"
    _exportPopup._eb.Cairn:SetText(text)
    _exportPopup:Show()
    _exportPopup._eb.Cairn:HighlightText()
    _exportPopup._eb.Cairn:Focus()
end

function UI.ShowErrorsPopup()
    if not _errorsPopup then UI._buildErrorsPopup() end
    if not _errorsPopup then return end
    _errorsPopup._eb.Cairn:SetText(UI.GetErrorTranscript())
    _errorsPopup:Show()
    _errorsPopup._eb.Cairn:HighlightText()
    _errorsPopup._eb.Cairn:Focus()
end


-- ----- Relayout -----------------------------------------------------------

local function relayout()
    if not (_pane and _editorScroll and _outputScroll) then return end
    local paneH = _pane:GetHeight() or 0
    if paneH < (HEADER_RESERVED + EDITOR_MIN_H + OUTPUT_MIN_H + REPL_H) then return end

    -- Reserve REPL_H at the bottom plus GAP above it. Remaining vertical
    -- space is split between editor (upper) and output (lower) by
    -- OUTPUT_PORTION.
    local available = paneH - HEADER_RESERVED - BOTTOM_PAD - REPL_H - GAP * 2
    local outputH   = math.max(OUTPUT_MIN_H, math.floor(available * OUTPUT_PORTION))
    local editorH   = available - outputH

    _editorScroll:ClearAllPoints()
    _editorScroll:SetPoint("TOPLEFT",  _pane, "TOPLEFT",   SIDE_PAD, -HEADER_RESERVED)
    _editorScroll:SetPoint("TOPRIGHT", _pane, "TOPRIGHT", -SIDE_PAD, -HEADER_RESERVED)
    _editorScroll:SetHeight(editorH)

    _outputScroll:ClearAllPoints()
    _outputScroll:SetPoint("TOPLEFT",  _editorScroll, "BOTTOMLEFT",  0, -GAP)
    _outputScroll:SetPoint("TOPRIGHT", _editorScroll, "BOTTOMRIGHT", 0, -GAP)
    _outputScroll:SetHeight(outputH)

    if _replBg then
        _replBg:ClearAllPoints()
        _replBg:SetPoint("BOTTOMLEFT",  _pane, "BOTTOMLEFT",   SIDE_PAD,  BOTTOM_PAD)
        _replBg:SetPoint("BOTTOMRIGHT", _pane, "BOTTOMRIGHT", -SIDE_PAD,  BOTTOM_PAD)
        _replBg:SetHeight(REPL_H)
    end

    if UI._reflowEditor then UI._reflowEditor() end
    if UI._reflowOutput then UI._reflowOutput() end
end


-- ----- Build --------------------------------------------------------------

function UI.Build(pane, mod)
    _pane = pane
    _mod  = mod

    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    -- Alias the in-memory REPL history + error transcript to the
    -- SavedVariables lists so every write persists automatically. Done
    -- BEFORE the REPL strip below so the input/arrow-key closures capture
    -- the SV-backed table. Trim once on hydration in case a hand-edited
    -- SV exceeded the cap.
    local g = ns.db and ns.db.global
    if g then
        if type(g.history) ~= "table" then g.history = {} end
        _replHistory = g.history
        while #_replHistory > HISTORY_CAP do
            table.remove(_replHistory, 1)
        end

        if type(g.errors) ~= "table" then g.errors = {} end
        _errorLines = g.errors
        while #_errorLines > ERROR_CAP do
            table.remove(_errorLines, 1)
        end
    end
    _replHistPos = nil

    pane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 10 })

    -- ===== Header =========================================================
    Gui:Acquire("Label", pane, { text = "Console", variant = "heading" })

    Gui:Acquire("Label", pane, {
        text    = "|cff888888Pick a snippet, edit, Run. Switching snippets prompts if there are unsaved changes. Use bare expressions or `return expr` to print values.|r",
        variant = "muted",
    })

    -- ===== Toolbar ========================================================
    local toolbar = Gui:Acquire("Container", pane, { height = 26 })

    _dropdown = Gui:Acquire("Dropdown", toolbar, {
        width          = DROPDOWN_W,
        height         = 24,
        options        = buildDropdownOptions(),
        selected       = ns.GetCurrentSnippet() or ns.SCRATCH,
        placeholder    = "(no snippet)",
        maxVisibleRows = 10,
    })
    _dropdown:ClearAllPoints()
    _dropdown:SetPoint("LEFT", toolbar, "LEFT", 0, 0)
    _dropdown.Cairn:On("Changed", function(_, value)
        if _suppressDropdownChange then return end
        if not value then return end
        UI.SwitchTo(value)
    end)

    -- Right-click on a dropdown row opens the per-snippet context menu
    -- (Lock/Unlock + Delete). The dropdown popup stays open after a
    -- right-click (Cairn-Gui Standard MINOR=16); close it explicitly
    -- so the menu lands above an empty area instead of overlapping the
    -- option list. Anchor the menu to the row that fired the event so
    -- the user keeps spatial context with what they clicked on.
    _dropdown.Cairn:On("RowRightClick", function(_, value, _label, rowFrame)
        if _dropdown.Cairn.Close then _dropdown.Cairn:Close() end
        UI._showCtxMenuFor(value, rowFrame)
    end)

    _modLabel = Gui:Acquire("Label", toolbar, { text = "" })
    _modLabel:ClearAllPoints()
    _modLabel:SetPoint("LEFT", _dropdown, "RIGHT", 6, 0)
    _modLabel:SetWidth(14)

    local addBtn = Gui:Acquire("Button", toolbar, {
        text = "+", variant = "ghost", width = SMALL_BTN, height = SMALL_BTN,
    })
    addBtn:ClearAllPoints()
    addBtn:SetPoint("LEFT", _modLabel, "RIGHT", 4, 0)
    addBtn.Cairn:On("Click", UI._showAddPopup)

    local delBtn = Gui:Acquire("Button", toolbar, {
        text = "-", variant = "ghost", width = SMALL_BTN, height = SMALL_BTN,
    })
    delBtn:ClearAllPoints()
    delBtn:SetPoint("LEFT", addBtn, "RIGHT", 2, 0)
    delBtn.Cairn:On("Click", UI._showDelPopup)

    -- Lock toggle. The L button's color shifts amber when the current
    -- snippet is locked. Scratch can't be locked, so the button is
    -- disabled when scratch is current (RefreshLockButton manages this).
    _lockBtn = Gui:Acquire("Button", toolbar, {
        text = "L", variant = "ghost", width = SMALL_BTN, height = SMALL_BTN,
    })
    _lockBtn:ClearAllPoints()
    _lockBtn:SetPoint("LEFT", delBtn, "RIGHT", 4, 0)
    _lockBtn.Cairn:On("Click", function()
        local cur = ns.GetCurrentSnippet()
        if not cur then return end
        local ok, err = ns.ToggleLocked(cur)
        if not ok then
            UI.AppendOutput({ "lock toggle failed: " .. tostring(err) }, "ffd87f3a")
            return
        end
        -- Clear the one-time warning when re-locking; user might lock
        -- and unlock and expect a fresh warning next time.
        _lockWarnedThisSession[cur] = nil
        UI.RefreshDropdown()      -- redraws option labels with [L] prefix
        UI.RefreshModifiedIndicator()
    end)

    -- Autorun-on-login checkbox. Per-character flag. The checkbox is on
    -- the current snippet (changes target when the user switches).
    _autoCb = Gui:Acquire("Checkbox", toolbar, {
        text    = "Auto-run on login",
        checked = false,
        width   = 160, height = 22,
    })
    _autoCb:ClearAllPoints()
    _autoCb:SetPoint("LEFT", _lockBtn, "RIGHT", 8, 0)
    _autoCb.Cairn:On("Toggled", function(_, newValue)
        local cur = ns.GetCurrentSnippet()
        if not cur or not ns.SetAutoRun then return end
        ns.SetAutoRun(cur, newValue)
    end)

    _runBtn = Gui:Acquire("Button", toolbar, {
        text = "Run", variant = "primary", width = 70, height = 22,
    })
    _runBtn:ClearAllPoints()
    _runBtn:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    _runBtn.Cairn:On("Click", function() UI.RunEditor() end)

    _clearBtn = Gui:Acquire("Button", toolbar, {
        text = "Clear", variant = "ghost", width = 70, height = 22,
    })
    _clearBtn:ClearAllPoints()
    _clearBtn:SetPoint("RIGHT", _runBtn, "LEFT", -6, 0)
    _clearBtn.Cairn:On("Click", function() UI.ClearOutput() end)

    -- Permanent Copy button. Always visible in the toolbar; on click,
    -- opens the copy popup with the current output pane contents
    -- pre-selected and focused, so the user just presses Ctrl-C.
    -- Replaces the previous workflow of typing /forge consolecopy.
    _copyBtn = Gui:Acquire("Button", toolbar, {
        text = "Copy", variant = "ghost", width = 70, height = 22,
    })
    _copyBtn:ClearAllPoints()
    _copyBtn:SetPoint("RIGHT", _clearBtn, "LEFT", -6, 0)
    _copyBtn.Cairn:On("Click", function() UI.ShowCopyPopup() end)

    -- ===== Editor =========================================================
    _editorScroll = Gui:Acquire("ScrollFrame", pane, {
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
    })
    _editorScroll.Cairn:SetLayoutManual(true)

    local editorContent = _editorScroll.Cairn:GetContent()

    _editorEdit = CreateFrame("EditBox", nil, editorContent)
    _editorEdit:SetMultiLine(true)
    _editorEdit:SetAutoFocus(false)
    _editorEdit:SetFontObject("ChatFontNormal")
    _editorEdit:SetTextInsets(6, 6, 4, 4)
    _editorEdit:SetMaxLetters(0)
    _editorEdit:SetMaxBytes(0)
    _editorEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    _editorEdit:SetScript("OnTextChanged", function(self)
        -- Persist to the current snippet on every keystroke, but skip the
        -- write if the text matches what's already saved (e.g. right after
        -- a programmatic SetText during snippet load) or if the snippet
        -- is locked. Locked snippets keep accepting typing in the editor
        -- (the user is mid-edit), but the changes don't persist; the
        -- modified asterisk lights up to show that.
        local cur = ns.GetCurrentSnippet()
        if cur then
            local newText = self:GetText() or ""
            local saved   = ns.LoadSnippet(cur) or ""
            if newText ~= saved then
                local locked = ns.IsLocked and ns.IsLocked(cur)
                if locked then
                    -- One-time warning per session per locked snippet.
                    if not _lockWarnedThisSession[cur] then
                        _lockWarnedThisSession[cur] = true
                        UI.AppendOutput({
                            ("[lock] '%s' is locked; edits won't save. Click L to unlock."):format(cur),
                        }, "ffd87f3a")
                    end
                else
                    ns.SaveSnippet(cur, newText)
                end
            end
        end
        UI.RefreshModifiedIndicator()
        if _gutter and ns.LineNumbers then
            ns.LineNumbers.Update(_gutter)
        end
        if UI._reflowEditor then UI._reflowEditor() end
    end)

    -- ----- Line-number gutter ---------------------------------------------
    -- Build the gutter BEFORE setting editor anchors so we know its width.
    -- The gutter is a FontString inside editorContent at TOPLEFT; the
    -- EditBox starts at gutter_width + a small gap from the left edge.
    if ns.LineNumbers then
        _gutter = ns.LineNumbers.Build(editorContent, _editorEdit)
        if _gutter then
            -- Re-anchor the editor whenever the gutter grows or shrinks
            -- (decade-boundary crossings on add/remove of lines).
            _gutter._onWidthChanged = function(newW)
                if not _editorEdit then return end
                _editorEdit:ClearAllPoints()
                _editorEdit:SetPoint("TOPLEFT",  editorContent, "TOPLEFT",  newW + 4, 0)
                _editorEdit:SetPoint("TOPRIGHT", editorContent, "TOPRIGHT", 0, 0)
            end
        end
    end

    local function reflowEditor()
        if not (_editorScroll and _editorEdit) then return end
        local sw = _editorScroll:GetWidth() or 0
        local gw = (_gutter and ns.LineNumbers and ns.LineNumbers.GetWidth(_gutter)) or 0
        local w  = sw - 16 - gw - 4   -- scrollbar reserve + gutter + gap
        if w < 1 then w = 1 end
        _editorEdit:SetWidth(w)
        local th = (_editorEdit:GetHeight() or 0)
        if th < 40 then th = 40 end
        editorContent:SetSize(sw - 16, th + 8)
        if _editorScroll.Cairn and _editorScroll.Cairn.SetContentHeight then
            _editorScroll.Cairn:SetContentHeight(th + 8)
        end
    end
    UI._reflowEditor = reflowEditor
    UI._editorContent = editorContent
    _editorContent = editorContent

    -- Initial editor anchors (gutter width is known after Build).
    local gw0 = (_gutter and ns.LineNumbers and ns.LineNumbers.GetWidth(_gutter)) or 0
    _editorEdit:ClearAllPoints()
    _editorEdit:SetPoint("TOPLEFT",  editorContent, "TOPLEFT",  gw0 + 4, 0)
    _editorEdit:SetPoint("TOPRIGHT", editorContent, "TOPRIGHT", 0, 0)

    -- ----- FAIAP syntax highlight + smart indent --------------------------
    -- Enable AFTER my OnTextChanged is installed so FAIAP's hookHandler
    -- chains my handler instead of replacing it. FAIAP swaps GetText /
    -- SetText to encode/decode color escapes transparently; all my
    -- consumer code keeps working as if the text is plain.
    if ns.indent and ns.indent.enable then
        ns.indent.enable(_editorEdit, ns.indent.defaultColorTable, 4)
    end

    -- Populate the gutter once with "1\n2\n..." for whatever's already
    -- in the editor (initial snippet load happens at the end of Build).
    if _gutter and ns.LineNumbers then
        ns.LineNumbers.Update(_gutter)
    end

    -- ===== Output =========================================================
    _outputScroll = Gui:Acquire("ScrollFrame", pane, {
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
    })
    _outputScroll.Cairn:SetLayoutManual(true)

    _outputContent = _outputScroll.Cairn:GetContent()

    _outputText = _outputContent:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    _outputText:SetJustifyH("LEFT")
    _outputText:SetJustifyV("TOP")
    _outputText:SetPoint("TOPLEFT", _outputContent, "TOPLEFT", 6, -4)
    _outputText:SetWordWrap(true)
    _outputText:SetText("")

    local function reflowOutput()
        if not (_outputScroll and _outputText) then return end
        local sw = _outputScroll:GetWidth() or 0
        local w  = sw - 18
        if w < 1 then w = 1 end
        _outputText:SetWidth(w)
        local th = (_outputText:GetStringHeight() or 0) + 12
        _outputContent:SetSize(w, math.max(th, 40))
        if _outputScroll.Cairn and _outputScroll.Cairn.SetContentHeight then
            _outputScroll.Cairn:SetContentHeight(math.max(th, 40))
        end
    end
    UI._reflowOutput = reflowOutput

    -- ===== REPL strip =====================================================
    -- A thin bar at the bottom: prompt ("> " or ">> ") plus a single-line
    -- input. Enter compiles + runs (or accumulates if the block isn't
    -- closed). Up/Down cycles native EditBox history. Esc cancels a
    -- continuation buffer if one is in flight, otherwise clears focus.
    _replBg = Gui:Acquire("Container", pane, {
        bg          = "color.bg.surface",
        border      = "color.border.default",
        borderWidth = 1,
        height      = REPL_H,
    })
    -- relayout() anchors the strip to the bottom of the pane manually,
    -- so the pane's Stack must skip it. SetLayoutManual marks it skipped.
    _replBg.Cairn:SetLayoutManual(true)

    _replPrompt = _replBg:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    _replPrompt:SetPoint("LEFT", _replBg, "LEFT", 8, 0)
    _replPrompt:SetText("|cffd87f3a> |r")
    _replPrompt:SetWordWrap(false)

    _replInput = CreateFrame("EditBox", nil, _replBg)
    _replInput:SetPoint("LEFT",  _replPrompt, "RIGHT", 2, 0)
    _replInput:SetPoint("RIGHT", _replBg,     "RIGHT", -8, 0)
    _replInput:SetHeight(REPL_H - 8)
    _replInput:SetAutoFocus(false)
    _replInput:SetMultiLine(false)
    _replInput:SetFontObject("ChatFontNormal")
    _replInput:SetTextInsets(2, 2, 0, 0)
    _replInput:SetMaxLetters(0)
    _replInput:SetMaxBytes(0)

    local function refreshPrompt()
        if not ns.REPL then return end
        if ns.REPL.IsContinuing() then
            _replPrompt:SetText("|cffd87f3a>> |r")
        else
            _replPrompt:SetText("|cffd87f3a> |r")
        end
    end

    -- Push a line onto the recall list. Dedupes consecutive duplicates so
    -- mashing Enter on the same statement doesn't fill the history. The
    -- table is aliased to ns.db.global.history at the top of Build, so
    -- every mutation here persists across /reload and characters.
    local function pushHistory(line)
        if type(line) ~= "string" or not line:match("%S") then return end
        if _replHistory[#_replHistory] == line then return end
        _replHistory[#_replHistory + 1] = line
        -- Cap so long sessions / long-running SVs don't accrete forever.
        while #_replHistory > HISTORY_CAP do table.remove(_replHistory, 1) end
        _replHistPos = nil
    end

    _replInput:SetScript("OnEnterPressed", function(self)
        local line = self:GetText() or ""
        self:SetText("")
        if not ns.REPL then return end

        local promptStr = ns.REPL.Prompt()
        UI.AppendOutput({ promptStr .. line }, "ffd87f3a")

        pushHistory(line)

        local action, ok, lines = ns.REPL.Submit(line)
        if action == "ran" then
            if ok then
                UI.AppendOutput(lines or {}, "ffaaaaaa")
            else
                UI.AppendError(lines or {}, "repl")
            end
        end
        refreshPrompt()
    end)

    _replInput:SetScript("OnEscapePressed", function(self)
        if ns.REPL and ns.REPL.CancelBuffer() then
            UI.AppendOutput({ "(cancelled)" }, "ffaaaaaa")
            refreshPrompt()
        else
            self:SetText("")
            self:ClearFocus()
        end
    end)

    -- Up / Down arrow history walking. OnArrowPressed fires for UP DOWN
    -- LEFT RIGHT; we only react to UP and DOWN. LEFT/RIGHT fall through
    -- to native cursor movement.
    _replInput:SetScript("OnArrowPressed", function(self, key)
        if key ~= "UP" and key ~= "DOWN" then return end
        if #_replHistory == 0 then return end

        if key == "UP" then
            if _replHistPos == nil then
                _replHistPos = #_replHistory
            elseif _replHistPos > 1 then
                _replHistPos = _replHistPos - 1
            else
                return  -- already at oldest
            end
        else  -- DOWN
            if _replHistPos == nil then return end
            if _replHistPos < #_replHistory then
                _replHistPos = _replHistPos + 1
            else
                _replHistPos = nil
                self:SetText("")
                return
            end
        end

        local text = _replHistory[_replHistPos] or ""
        self:SetText(text)
        self:SetCursorPosition(#text)  -- park cursor at end
    end)

    -- Click anywhere on the strip background to focus the input.
    _replBg:EnableMouse(true)
    _replBg:SetScript("OnMouseDown", function() _replInput:SetFocus() end)

    -- ===== Wiring =========================================================
    pane:HookScript("OnSizeChanged", relayout)
    relayout()

    UI.AppendOutput({
        "Forge Console - Phase 5 (lock / autorun / slash / copy / export).",
        "L locks the current snippet (no save). Checkbox marks autorun-on-login per character.",
        "Slash: /forge consolesave/load/list/rm/autorun/copy/export. /forge help shows them all.",
    }, "ff7fbfff")

    UI.LoadCurrent()
    UI.RefreshDropdown()
end


-- Called by descriptor's OnTabShow whenever the tab becomes visible.
function UI.OnTabShow(pane, mod)
    _pane = pane
    _mod  = mod
    relayout()
    -- Refresh dropdown + lock + autorun in case state changed via slash
    -- commands or another tab path between hide and show.
    UI.RefreshDropdown()
    UI.RefreshModifiedIndicator()
end

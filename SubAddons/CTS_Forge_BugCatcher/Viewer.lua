-- Forge_BugCatcher.Viewer: error list + detail UI.
--
-- v1 layout (vertical Stack inside the tab pane):
--   1. Header row: "Bug Catcher" heading + counter label
--   2. Toolbar:    Clear button, Copy All button
--   3. List:       ScrollFrame of clickable error-row Containers
--   4. Detail:     multi-line EditBox (read-ish) with the selected error's
--                  full message + stack + locals — copyable
--
-- Refresh path:
--   * Viewer.Build runs once per tab open (gated by pane.Cairn._builtOnce).
--   * Viewer.Refresh re-renders the list + counter when called.
--   * Capture.OnChange subscribes on Build so error additions auto-refresh
--     even when the tab is currently visible.

local ADDON, ns = ...

local Viewer = {}
ns.Viewer = Viewer


-- ---------------------------------------------------------------------------
-- Module-scope refs to the live widgets — set on Build, read on Refresh.
-- ---------------------------------------------------------------------------
-- Keeping these at module scope rather than on `mod` is intentional: the
-- Viewer is a single-instance tab and the Container pool returns the same
-- pane frame each time the tab is opened, so the widgets persist across
-- OnTabShow/OnTabHide cycles. Re-Build is gated by pane.Cairn._builtOnce.

local _pane              -- the tab pane Container
local _counterLabel
local _listContent       -- Stack-laid Container inside the ScrollFrame
local _listScroll
local _rows = {}         -- list of { container, msgLabel, kindLabel, countLabel } — recycled across refreshes
local _detail            -- multi-line EditBox
local _selectedIndex     -- index into Capture.GetAll(); detail mirrors this


-- ---------------------------------------------------------------------------
-- Formatting helpers
-- ---------------------------------------------------------------------------

local KIND_COLOR = {
    error   = "|cffff5050",
    warning = "|cffffd060",
    taint   = "|cffd060ff",
    block   = "|cff8888ff",
}


local function fmtTime(ts)
    if not ts or ts == 0 then return "--:--" end
    return date and date("%H:%M:%S", ts) or tostring(ts)
end


local function summaryOf(entry)
    local msg = tostring(entry.message or "")
    -- One line, capped. The detail pane shows the full thing.
    msg = msg:gsub("\n.*", "")
    local prefix = ""
    if entry.addon and entry.addon ~= "" then
        prefix = "|cff88aaff[" .. entry.addon .. "]|r "
    end
    if entry.location and entry.location ~= "" then
        prefix = prefix .. "|cff888888" .. entry.location .. "|r  "
    end
    msg = prefix .. msg
    if #msg > 150 then msg = msg:sub(1, 147) .. "..." end
    return msg
end


local function detailTextOf(entry)
    if not entry then return "(no entry selected)" end
    local parts = {
        ("Kind:       %s"):format(tostring(entry.kind or "error")),
        ("Addon:      %s"):format(tostring(entry.addon or "(unknown)")),
        ("Location:   %s"):format(tostring(entry.location or "(unknown)")),
        ("First seen: %s"):format(fmtTime(entry.ts)),
        ("Last seen:  %s"):format(fmtTime(entry.lastTs or entry.ts)),
        ("Count:      %d"):format(entry.count or 1),
        "",
        "Message:",
        tostring(entry.message or ""),
    }
    if entry.stack then
        parts[#parts + 1] = ""
        parts[#parts + 1] = "Stack:"
        parts[#parts + 1] = entry.stack
    end
    if entry.locals then
        parts[#parts + 1] = ""
        parts[#parts + 1] = "Locals:"
        parts[#parts + 1] = entry.locals
    end
    return table.concat(parts, "\n")
end


-- ---------------------------------------------------------------------------
-- Row rendering
-- ---------------------------------------------------------------------------
-- Rows are pooled in `_rows`: a Refresh that needs N rows ensures N rows
-- exist (Acquiring more if needed) and hides the rest. This avoids
-- per-refresh Acquire/Release churn when the user clears or new entries
-- arrive in bursts.

local function acquireRow(Gui, index)
    local existing = _rows[index]
    if existing and existing.container then
        existing.container:Show()
        return existing
    end

    -- Row width: the Stack layout in _listContent stretches children to
    -- the content width minus padding, but we still need a concrete width
    -- so the right-anchored countLabel positions correctly.
    local rowW = (_listContent:GetWidth() or 600) - 12

    local row = {}
    row.container = Gui:Acquire("Container", _listContent, {
        bg          = "color.bg.surface",
        border      = "color.border.default",
        borderWidth = 1,
        width       = rowW,
        height      = 26,
    })
    -- IMPORTANT: do NOT call SetLayoutManual on the row itself — that
    -- would opt the row out of _listContent's Stack layout and every row
    -- would render at (0,0) on top of each other. Instead, mark each
    -- LABEL as SetLayoutManual so the row's own (unset) layout skips them
    -- and our explicit SetPoint anchors are what wins.

    row.kindLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.kindLabel.Cairn:SetLayoutManual(true)
    row.kindLabel:ClearAllPoints()
    row.kindLabel:SetPoint("LEFT", row.container, "LEFT", 6, 0)
    row.kindLabel:SetWidth(70)

    row.msgLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.msgLabel.Cairn:SetLayoutManual(true)
    row.msgLabel:ClearAllPoints()
    row.msgLabel:SetPoint("LEFT",  row.container, "LEFT",  80, 0)
    row.msgLabel:SetPoint("RIGHT", row.container, "RIGHT", -90, 0)

    row.countLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.countLabel.Cairn:SetLayoutManual(true)
    row.countLabel:ClearAllPoints()
    row.countLabel:SetPoint("RIGHT", row.container, "RIGHT", -6, 0)
    row.countLabel:SetWidth(80)

    -- Row click: select this entry. The Container widget is plain — wire
    -- the click via the underlying frame's OnMouseUp + EnableMouse.
    row.container:EnableMouse(true)
    row.container:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        _selectedIndex = row._index
        if _detail and _detail.Cairn and _detail.Cairn.SetText then
            local entries = ns.Capture and ns.Capture.GetAll() or {}
            _detail.Cairn:SetText(detailTextOf(entries[_selectedIndex]))
        end
    end)

    _rows[index] = row
    return row
end


local function hideExtraRows(fromIndex)
    for i = fromIndex, #_rows do
        if _rows[i] and _rows[i].container then
            _rows[i].container:Hide()
        end
    end
end


-- ---------------------------------------------------------------------------
-- Public: Refresh
-- ---------------------------------------------------------------------------

function Viewer.Refresh()
    if not _listContent then return end
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local entries = ns.Capture and ns.Capture.GetAll() or {}

    if _counterLabel and _counterLabel.Cairn and _counterLabel.Cairn.SetText then
        local active = ns.Capture and ns.Capture.IsActive() and "ON" or "OFF"
        _counterLabel.Cairn:SetText(
            ("%d entries  |  capture: %s"):format(#entries, active))
    end

    -- Iterate newest-first so the most recent error is at the top.
    local n = #entries
    for displayIdx = 1, n do
        local entry = entries[n - displayIdx + 1]
        local row = acquireRow(Gui, displayIdx)
        row._index = n - displayIdx + 1  -- index into Capture.GetAll()

        local color = KIND_COLOR[entry.kind or "error"] or "|cffffffff"
        row.kindLabel.Cairn:SetText(
            color .. tostring(entry.kind or "error") .. "|r")
        row.msgLabel.Cairn:SetText(summaryOf(entry))
        local countStr
        if (entry.count or 1) > 1 then
            countStr = ("|cff888888x%d|r %s"):format(entry.count,
                fmtTime(entry.lastTs))
        else
            countStr = fmtTime(entry.lastTs or entry.ts)
        end
        row.countLabel.Cairn:SetText(countStr)
    end
    hideExtraRows(n + 1)

    -- Grow the content height so the ScrollFrame can scroll all rows.
    -- Each row is 26 tall + 4 gap from Stack = 30 effective.
    if _listScroll and _listScroll.Cairn and _listScroll.Cairn.SetContentHeight then
        _listScroll.Cairn:SetContentHeight(math.max(60, n * 30))
    end

    -- Refresh the detail pane in case the selection still points at an
    -- entry that just changed (dedup bumped its count, etc.). If the
    -- selection is now out of range, clear it.
    if _selectedIndex and entries[_selectedIndex] then
        if _detail and _detail.Cairn then
            _detail.Cairn:SetText(detailTextOf(entries[_selectedIndex]))
        end
    elseif _detail and _detail.Cairn then
        _detail.Cairn:SetText(detailTextOf(nil))
        _selectedIndex = nil
    end
end


-- ---------------------------------------------------------------------------
-- Public: Build
-- ---------------------------------------------------------------------------
-- Called from Core.lua's OnTabShow when the pane hasn't been built yet.
-- Sets up the entire UI hierarchy and registers a Capture.OnChange so
-- new errors re-render the list automatically.

function Viewer.Build(pane, mod)
    _pane = pane
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    pane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 10 })

    -- Header row.
    Gui:Acquire("Label", pane, {
        text    = "Bug Catcher",
        variant = "heading",
    })
    _counterLabel = Gui:Acquire("Label", pane, {
        text    = "0 entries  |  capture: OFF",
        variant = "muted",
    })

    -- Toolbar (horizontal Stack).
    local toolbar = Gui:Acquire("Container", pane, { height = 28 })
    toolbar.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    -- IMPORTANT: Button widget ignores `onClick` in opts. Bind via
    -- `btn.Cairn:On("Click", fn)` post-Acquire (this bit Forge_BugCatcher
    -- v1 silently — buttons rendered but did nothing).

    local clearBtn = Gui:Acquire("Button", toolbar, {
        text = "Clear", variant = "ghost", width = 80,
    })
    clearBtn.Cairn:On("Click", function()
        if ns.Capture and ns.Capture.Clear then
            ns.Capture.Clear()
            _selectedIndex = nil
        end
    end)

    local copyAllBtn = Gui:Acquire("Button", toolbar, {
        text = "Copy All", variant = "ghost", width = 90,
    })
    copyAllBtn.Cairn:On("Click", function()
        -- Copy-all populates the detail editbox with every entry
        -- concatenated, then highlights it for Ctrl+C. WoW has no
        -- programmatic clipboard write, so the editbox detour is the
        -- standard idiom.
        local entries = ns.Capture and ns.Capture.GetAll() or {}
        local parts = {}
        for i = 1, #entries do
            parts[#parts + 1] = "----- entry " .. i .. " -----"
            parts[#parts + 1] = detailTextOf(entries[i])
            parts[#parts + 1] = ""
        end
        if _detail and _detail.Cairn then
            _detail.Cairn:SetText(table.concat(parts, "\n"))
            if _detail.Cairn.Focus         then _detail.Cairn:Focus()         end
            if _detail.Cairn.HighlightText then _detail.Cairn:HighlightText() end
        end
    end)

    local copyOneBtn = Gui:Acquire("Button", toolbar, {
        text = "Copy", variant = "ghost", width = 60,
    })
    copyOneBtn.Cairn:On("Click", function()
        -- Single-entry copy: dump the selected error's full detail into
        -- the editbox and highlight for Ctrl+C. No-op when no row is
        -- selected.
        local entries = ns.Capture and ns.Capture.GetAll() or {}
        local entry   = _selectedIndex and entries[_selectedIndex]
        if not entry then return end
        if _detail and _detail.Cairn then
            _detail.Cairn:SetText(detailTextOf(entry))
            if _detail.Cairn.Focus         then _detail.Cairn:Focus()         end
            if _detail.Cairn.HighlightText then _detail.Cairn:HighlightText() end
        end
    end)

    local refreshBtn = Gui:Acquire("Button", toolbar, {
        text = "Refresh", variant = "ghost", width = 80,
    })
    refreshBtn.Cairn:On("Click", function() Viewer.Refresh() end)

    -- "Ignore Selected" — adds the selected entry's normalized message to
    -- the ignore list. Plain-substring match: anything that contains the
    -- exact normalized text will be skipped at capture time. Future entries
    -- matching this pattern won't appear; existing entries stay until the
    -- user clicks Clear.
    local ignoreBtn = Gui:Acquire("Button", toolbar, {
        text = "Ignore Selected", variant = "ghost", width = 130,
    })
    ignoreBtn.Cairn:On("Click", function()
        local entries = ns.Capture and ns.Capture.GetAll() or {}
        local entry   = _selectedIndex and entries[_selectedIndex]
        if not entry then return end
        local pat = entry.normalized or entry.message
        if pat and pat ~= "" then
            ns.Capture.Ignore(pat)
        end
    end)

    -- Auto-popup toggle. Reads / writes Capture.GetOptions/SetOption so
    -- the value persists across sessions in db.profile.options.autoPopup.
    local autoPopupBox = Gui:Acquire("Checkbox", toolbar, {
        text    = "Auto-popup",
        checked = (ns.Capture.GetOptions().autoPopup == true),
        width   = 110,
    })
    autoPopupBox.Cairn:On("Toggled", function(_, checked)
        ns.Capture.SetOption("autoPopup", checked and true or false)
    end)
    -- Keep the checkbox sane when the option is mutated elsewhere (e.g.
    -- via slash command later). Subscribed once at build time.
    if ns.Capture and ns.Capture.OnChange then
        ns.Capture.OnChange(function()
            if not (autoPopupBox and autoPopupBox.Cairn and autoPopupBox.Cairn.SetChecked) then return end
            autoPopupBox.Cairn:SetChecked(ns.Capture.GetOptions().autoPopup == true)
        end)
    end

    -- List ScrollFrame. Height is a chunk of the tab pane; Stack lets the
    -- subsequent detail editbox fill the rest. The internal content area
    -- gets a vertical Stack so rows just append.
    local paneW = (pane:GetWidth() or 700) - 20
    local listH = math.floor(((pane:GetHeight() or 500) - 140) * 0.55)

    _listScroll = Gui:Acquire("ScrollFrame", pane, {
        width         = paneW,
        height        = math.max(listH, 100),
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
    })

    _listContent = _listScroll.Cairn:GetContent()
    _listContent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 6 })

    -- Detail editbox (multi-line, read-mostly — WoW EditBox doesn't have a
    -- true read-only mode, but pairing it with no autofocus and treating
    -- writes as accidental gets us close enough for v1).
    local detailH = math.max(((pane:GetHeight() or 500) - 140) - math.max(listH, 100) - 30, 100)

    _detail = Gui:Acquire("EditBox", pane, {
        width       = paneW,
        height      = detailH,
        multiline   = true,
        text        = "(select an entry above)",
        bg          = "color.bg.surface",
        border      = "color.border.default",
        borderWidth = 1,
    })

    -- Subscribe to Capture changes so we live-refresh without waiting
    -- on the user to click Refresh.
    if ns.Capture and ns.Capture.OnChange then
        ns.Capture.OnChange(function() Viewer.Refresh() end)
    end

    Viewer.Refresh()
end

-- Forge_Registry.UI: two-pane registry browser.
--
-- Layout:
--   +-----------+--------------------------------------+
--   | Sources   | [Search] [Refresh]            N items|
--   |  Addons   +--------------------------------------+
--   |  Hooks    | key1                                 |
--   |  Timers   | summary1                             |
--   |  ...      |   ...                                |
--   |           | (click a row -> copy-dialog detail)  |
--   +-----------+--------------------------------------+
--
-- Built with raw frames intentionally: this is a brand-new view, and we
-- want to keep the surface simple while the Cairn-Gui kit is still
-- shaking out gotchas (empty-label Button, kit reload behaviors). Easy
-- to migrate once stable.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H = 28
local SOURCES_W = 130
local ROW_H     = 34   -- two-line rows: key + summary
local PAD       = 6
local DETAIL_H  = 180  -- bottom detail pane height (in right column)

local _activeMod

local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

-- ----- Toolbar ----------------------------------------------------------
local function buildToolbar(parent, mod)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetPoint("TOPLEFT",  parent, "TOPLEFT",  4, -4)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -4)
    bar:SetHeight(TOOLBAR_H)

    -- Search box.
    local searchBg = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    searchBg:SetSize(220, 22)
    searchBg:SetPoint("LEFT", bar, "LEFT", 4, 0)
    searchBg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    searchBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    searchBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    local search = CreateFrame("EditBox", nil, searchBg)
    search:SetMultiLine(false); search:SetAutoFocus(false)
    search:SetFontObject("ChatFontNormal")
    search:SetPoint("LEFT", 6, 0); search:SetPoint("RIGHT", -6, 0); search:SetHeight(18)
    search:SetText(ns.GetSearchText() or "")
    search:SetScript("OnTextChanged", function(self)
        ns.SetSearchText(self:GetText() or "")
        UI.Refresh()
    end)
    search:SetScript("OnEscapePressed", function(self)
        self:ClearFocus(); self:SetText("")
        ns.SetSearchText("")
        UI.Refresh()
    end)
    local hint = searchBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 8, 0); hint:SetText("Filter (substring on key + summary)...")
    if (ns.GetSearchText() or "") ~= "" then hint:Hide() end
    search:SetScript("OnEditFocusGained", function() hint:Hide() end)
    search:SetScript("OnEditFocusLost",  function(self)
        if (self:GetText() or "") == "" then hint:Show() end
    end)

    -- Refresh button: re-runs the active source's list().
    local refreshBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    refreshBtn:SetSize(80, 22)
    refreshBtn:SetPoint("LEFT", searchBg, "RIGHT", 6, 0)
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", function() UI.Refresh() end)

    -- Count label on right edge.
    local countFs = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countFs:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    countFs:SetTextColor(0.85, 0.7, 0.4, 1)
    mod._countFs = countFs

    return bar
end

-- ----- Left pane: source list -------------------------------------------
local function buildSourceRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(20)

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

local function buildSourcesPane(parent, mod, toolbar)
    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bg:SetPoint("TOPLEFT",    toolbar, "BOTTOMLEFT", 0, -PAD)
    bg:SetPoint("BOTTOMLEFT", parent,  "BOTTOMLEFT", 4, 4)
    bg:SetWidth(SOURCES_W)
    bg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    mod._sourceRows = {}
    local y = 6
    for i, provider in ipairs(ns.Sources.providers) do
        local row = buildSourceRow(bg)
        row._provider = provider
        row._fs:SetText(provider.name)
        row:SetPoint("TOPLEFT",  bg, "TOPLEFT",   6, -y)
        row:SetPoint("TOPRIGHT", bg, "TOPRIGHT", -6, -y)
        row:SetScript("OnClick", function(self)
            ns.SetSelectedSource(self._provider.name)
            UI.Refresh()
        end)
        mod._sourceRows[i] = row
        y = y + 22
    end
    return bg
end

-- ----- Right pane: entry list -------------------------------------------
local function buildEntryRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)

    local sel = row:CreateTexture(nil, "BACKGROUND", nil, -2)
    sel:SetColorTexture(0.85, 0.50, 0.20, 0.20); sel:SetAllPoints(); sel:Hide()
    row._sel = sel
    local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    hov:SetColorTexture(0.45, 0.32, 0.15, 0.30); hov:SetAllPoints(); hov:Hide()
    row._hov = hov

    local key = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    key:SetPoint("TOPLEFT",  row, "TOPLEFT",   6, -2)
    key:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -2)
    key:SetJustifyH("LEFT"); key:SetWordWrap(false); key:SetMaxLines(1)
    key:SetTextColor(0.9, 0.7, 0.4, 1)
    row._key = key

    local summary = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("BOTTOMLEFT",  row, "BOTTOMLEFT",   6, 2)
    summary:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 2)
    summary:SetJustifyH("LEFT"); summary:SetWordWrap(false); summary:SetMaxLines(1)
    summary:SetTextColor(0.7, 0.7, 0.7, 1)
    row._summary = summary

    row:SetScript("OnEnter", function(self) self._hov:Show() end)
    row:SetScript("OnLeave", function(self) self._hov:Hide() end)
    return row
end

local function buildEntriesPane(parent, mod, toolbar, sourcesPane)
    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    -- Two-corner anchor: TOPLEFT chained off sourcesPane.RIGHT; BOTTOMRIGHT
    -- offset up from parent.BOTTOMRIGHT by DETAIL_H + PAD + 4 so the bottom
    -- edge sits exactly above where the detail pane will go.
    bg:SetPoint("TOPLEFT",     sourcesPane, "TOPRIGHT",  PAD, 0)
    bg:SetPoint("BOTTOMRIGHT", parent,      "BOTTOMRIGHT", -4, DETAIL_H + PAD + 4)
    bg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    local sf = CreateFrame("ScrollFrame", nil, bg, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -28, 6)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(1, 1)
    sf:SetScrollChild(content)
    mod._entriesScroll  = sf
    mod._entriesContent = content
    mod._entryRows      = {}
    return bg
end

-- ----- Detail pane (bottom of right column) -----------------------------
-- Shows the `detail` field of the currently-selected entry. Click any
-- entry row to populate. Copy button kept for paste workflows.
--
-- Anchored directly off the entries pane's BOTTOMLEFT/BOTTOMRIGHT so we
-- don't need to recompute parent-relative offsets if the entries pane
-- moves. SetHeight(DETAIL_H) sets the actual pane height; the anchor
-- offsets handle the gap above.
local function buildDetailPane(parent, mod, entriesPane)
    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bg:SetPoint("TOPLEFT",  entriesPane, "BOTTOMLEFT",  0, -PAD)
    bg:SetPoint("TOPRIGHT", entriesPane, "BOTTOMRIGHT", 0, -PAD)
    bg:SetHeight(DETAIL_H)
    bg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.04, 0.04, 0.04, 0.55)
    bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    -- Title row: shows "<source> / <key>" or "(no entry selected)".
    local title = bg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", bg, "TOPLEFT", 8, -6)
    title:SetPoint("TOPRIGHT", bg, "TOPRIGHT", -90, -6)
    title:SetJustifyH("LEFT"); title:SetWordWrap(false); title:SetMaxLines(1)
    title:SetTextColor(0.85, 0.7, 0.4, 1)
    title:SetText("|cffaaaaaa(no entry selected)|r")
    mod._detailTitle = title

    -- Copy button on the top-right corner of the detail pane. Falls back
    -- to a no-op if Forge.ShowCopyDialog isn't available.
    local copyBtn = CreateFrame("Button", nil, bg, "UIPanelButtonTemplate")
    copyBtn:SetSize(76, 20)
    copyBtn:SetPoint("TOPRIGHT", bg, "TOPRIGHT", -6, -4)
    copyBtn:SetText("Copy")
    copyBtn:SetScript("OnClick", function()
        local e = mod._selectedEntry
        if not e then return end
        if Forge and Forge.ShowCopyDialog then
            local title_str = string.format("%s / %s",
                ns.GetSelectedSource() or "?", e.key or "?")
            Forge.ShowCopyDialog(title_str, e.detail or e.summary or "(no detail)",
                "Ctrl-A to select all, Ctrl-C to copy.")
        end
    end)

    -- Scrollable detail body.
    local sf = CreateFrame("ScrollFrame", nil, bg, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",    bg, "TOPLEFT",    6, -28)
    sf:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -28, 6)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(1, 1)
    sf:SetScrollChild(content)

    local fs = content:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -4)
    fs:SetWordWrap(true)
    fs:SetText("|cffaaaaaaClick an entry to see details.|r")

    mod._detailScroll  = sf
    mod._detailContent = content
    mod._detailFs      = fs

    -- Reflow on width change so SetText recomputes the wrap height.
    local function reflow()
        local w = (sf:GetWidth() or 1) - 8
        if w < 1 then w = 1 end
        fs:SetWidth(w)
        local h = (fs:GetStringHeight() or 0) + 8
        content:SetSize(w, math.max(h, sf:GetHeight() or 0))
        sf:UpdateScrollChildRect()
    end
    sf:SetScript("OnSizeChanged", reflow)
    mod._detailReflow = reflow
    return bg
end

-- ----- Public API -------------------------------------------------------
function UI.Build(parent, mod)
    _activeMod = mod
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    local toolbar     = buildToolbar(frame, mod)
    local sourcesPane = buildSourcesPane(frame, mod, toolbar)
    local entriesPane = buildEntriesPane(frame, mod, toolbar, sourcesPane)
    local detailPane  = buildDetailPane(frame, mod, entriesPane)
    UI.Refresh()
end

-- Populate the detail pane and highlight the selected entry row. Called
-- when the user clicks any entry row.
function UI.SelectEntry(idx)
    local mod = _activeMod
    if not mod then return end
    local entry = mod._entryRows[idx] and mod._entryRows[idx]._entry
    mod._selectedEntry = entry
    -- Highlight the selected row, dim the rest.
    for i, row in ipairs(mod._entryRows or {}) do
        if row._sel then
            if i == idx then row._sel:Show() else row._sel:Hide() end
        end
    end
    -- Populate the detail pane.
    if entry and mod._detailTitle and mod._detailFs then
        mod._detailTitle:SetText(string.format(
            "|cffd87f3a%s|r  /  %s",
            ns.GetSelectedSource() or "?",
            tostring(entry.key or "?")))
        mod._detailFs:SetText(entry.detail or entry.summary or "(no detail)")
        if mod._detailReflow then mod._detailReflow() end
        if mod._detailScroll then mod._detailScroll:SetVerticalScroll(0) end
    end
end

-- Clear selection (used when the user changes source or filters and the
-- previously-selected entry might not be on the visible list anymore).
local function clearSelection(mod)
    mod._selectedEntry = nil
    if mod._detailTitle then
        mod._detailTitle:SetText("|cffaaaaaa(no entry selected)|r")
    end
    if mod._detailFs then
        mod._detailFs:SetText("|cffaaaaaaClick an entry to see details.|r")
        if mod._detailReflow then mod._detailReflow() end
    end
    for _, row in ipairs(mod._entryRows or {}) do
        if row._sel then row._sel:Hide() end
    end
end

local function applyFilter(entries, filter)
    if not filter or filter == "" then return entries end
    local lf = filter:lower()
    local out = {}
    for _, e in ipairs(entries) do
        if (e.key and e.key:lower():find(lf, 1, true))
           or (e.summary and e.summary:lower():find(lf, 1, true)) then
            out[#out + 1] = e
        end
    end
    return out
end

function UI.Refresh()
    local mod = _activeMod
    if not mod or not mod._sourceRows then return end

    local selected = ns.GetSelectedSource() or "Addons"
    -- Highlight selected row in the left pane.
    for _, row in ipairs(mod._sourceRows) do
        if row._provider and row._provider.name == selected then
            row._sel:Show()
        else
            row._sel:Hide()
        end
    end

    local provider = ns.Sources and ns.Sources.Get(selected)
    local entries  = (provider and provider.list and provider.list()) or {}
    entries = applyFilter(entries, ns.GetSearchText())

    if mod._countFs then
        mod._countFs:SetText(string.format("%d items", #entries))
    end

    -- Layout entry rows. Reuse a row pool, hide unused. Refresh always
    -- clears selection because the index of a previously-selected entry
    -- may no longer match a row (filter / source change).
    clearSelection(mod)
    for _, row in ipairs(mod._entryRows) do row:Hide() end

    local y = 0
    for i, entry in ipairs(entries) do
        local row = mod._entryRows[i]
        if not row then
            row = buildEntryRow(mod._entriesContent)
            mod._entryRows[i] = row
        end
        row._entry = entry
        row._idx   = i
        row._key:SetText(entry.key or "?")
        row._summary:SetText(entry.summary or "")
        row:ClearAllPoints()
        row:SetWidth((mod._entriesScroll:GetWidth() or 1) - 8)
        row:SetPoint("TOPLEFT", mod._entriesContent, "TOPLEFT", 0, -y)
        row:SetScript("OnClick", function(self) UI.SelectEntry(self._idx) end)
        row:Show()
        y = y + ROW_H
    end
    if y < 1 then y = 1 end
    mod._entriesContent:SetSize(
        (mod._entriesScroll:GetWidth() or 1) - 8,
        math.max(y, mod._entriesScroll:GetHeight() or 0))
    mod._entriesScroll:UpdateScrollChildRect()
end

function UI.OnTabShow(mod)
    _activeMod = mod
    UI.Refresh()
end

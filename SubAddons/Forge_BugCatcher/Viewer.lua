-- Forge_BugCatcher.Viewer: Bug Catcher tab inside the Forge window.
--
-- Layout:
--   Toolbar (top):  Show All | Clear | [x] Auto-popup on new error | "N session / M total"
--   List pane (left):  scrollable list of error rows (clickable, highlighted)
--   Detail pane (right):  selected error message + Ignore button

local ADDON, ns = ...

local Viewer = {}
ns.Viewer = Viewer

local LIST_WIDTH = 300
local TOOLBAR_H  = 28
local ROW_HEIGHT = 22
local PAD        = 6

local function nowTs()
    if time then return time() end
    return os.time()
end

local function fmtTime(ts)
    if not ts then return "?" end
    if date then return date("%H:%M:%S", ts) end
    return tostring(ts)
end

local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

-- Pull the addon name out of the message - either the AddOns\<Name>\ prefix
-- or, failing that, the leading filename. Used for the per-error source tag
-- and color coding.
local function detectSource(entry)
    local m = entry.message or ""
    return m:match("AddOns[\\/]([^\\/]+)")
        or m:match("^([^/\\:%.]+)%.lua")
        or "?"
end

-- Deterministic source -> color mapping so the same addon always gets the
-- same row color across sessions. Hash is cheap (sum of byte * position
-- mod a prime); palette is small and tuned to stay readable on the dark
-- backdrop.
local PALETTE = {
    "ff7fdfff", "ff80ff80", "ffffd87f", "ffd87f3a", "ffaaaaff",
    "ffff80c0", "ffaaffaa", "ffffaaaa", "ff7fffd0", "ffd8a8ff",
    "ffd8d87f", "ffaaffd8", "ff80c0ff", "ffffff80", "ffffaa66",
}
local _sourceColor = {}
local function colorForSource(name)
    if not name or name == "" or name == "?" then return "ffaaaaaa" end
    if _sourceColor[name] then return _sourceColor[name] end
    local h = 0
    for i = 1, #name do h = (h + name:byte(i) * i) % 9973 end
    local color = PALETTE[(h % #PALETTE) + 1]
    _sourceColor[name] = color
    return color
end

local function rowText(entry)
    local count = (entry.count and entry.count > 1)
        and (" |cffff8080(x" .. entry.count .. ")|r") or ""
    local source = detectSource(entry)
    local color  = colorForSource(source)
    local short  = (entry.message or ""):gsub("Interface\\AddOns\\", ""):gsub("\n.*$", "")
    if #short > 80 then short = short:sub(1, 80) .. "..." end
    return string.format("|cff888888[%s]|r |cff%s%s|r  %s%s",
        fmtTime(entry.lastTs or entry.ts), color, source, escapeBars(short), count)
end

local function reflowDetail(mod)
    -- ds may be the Cairn-Gui widget OR a raw Blizzard ScrollFrame; both
    -- pass GetWidth/GetHeight through ObjectBase. Low-level
    -- UpdateScrollChildRect only exists on the inner Blizzard frame, kept
    -- on `_detailScrollFrame` in both backends.
    local ds  = mod._detailScroll
    local dsf = mod._detailScrollFrame or ds
    local dc  = mod._detailContent
    local dt  = mod._detailText
    if not (ds and dc and dt) then return end
    local w = (ds:GetWidth() or 0) - 8
    if w < 1 then w = 1 end
    dt:SetWidth(w)
    local h = (dt:GetStringHeight() or 0) + 12
    if h < (ds:GetHeight() or 0) then h = ds:GetHeight() or 0 end
    dc:SetSize(w, h)
    if dsf.UpdateScrollChildRect then dsf:UpdateScrollChildRect() end
end

local function buildToolbar(frame, mod)
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    bar:SetHeight(TOOLBAR_H)

    -- Cairn-Gui Button helper. Returns (widget-or-frame, frame) so chain
    -- anchors via the underlying Frame regardless of backend. Same pattern
    -- as Forge_Logs/UI.lua. Memory: Cairn-Gui Button needs a non-empty
    -- initial label or it doesn't render.
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local function makeButton(label, w, h)
        local b = Gui and Gui:Create("Button")
        if b then
            b:SetParent(bar)
            b:ClearAllPoints()
            b:SetWidth(w); b:SetHeight(h)
            b:SetText(label)
            return b, b.frame
        end
        local raw = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
        raw:SetSize(w, h)
        raw:SetText(label)
        return raw, raw
    end
    local function onClick(btn, fn)
        if btn.SetEventListener then
            btn:SetEventListener("OnClick", function() fn() end)
        else
            btn:SetScript("OnClick", function() fn() end)
        end
    end

    local showAll, showAllFrame = makeButton("Show All", 80, 22)
    showAll:SetPoint("LEFT", bar, "LEFT", 4, 0)
    onClick(showAll, function() Viewer.ShowAll(mod) end)

    local clear, clearFrame = makeButton("Clear", 56, 22)
    clear:SetPoint("LEFT", showAllFrame, "RIGHT", 4, 0)
    onClick(clear, function()
        ns.Capture.Clear()
        Viewer.SelectIndex(mod, nil)
    end)

    -- Auto-popup checkbox: Cairn-Gui CheckBox (widget VERSION 2 -- includes
    -- the PlaySound pcall fix). Default size in the widget is tiny (12x12);
    -- we set 22x22 to match the prior UICheckButton footprint. The widget's
    -- OnValueChanged event provides the new checked state directly.
    local autoCb, autoCbFrame
    do
        local cb = Gui and Gui:Create("CheckBox")
        if cb then
            cb:SetParent(bar); cb:ClearAllPoints()
            cb:SetWidth(22); cb:SetHeight(22)
            cb:SetPoint("LEFT", clearFrame, "RIGHT", 12, 0)
            -- Defensive: re-parenting can sometimes clear mouse / click
            -- registration on Button-derived frames. Force them on so
            -- the OnClick handler is reachable.
            cb.frame:EnableMouse(true)
            if cb.frame.RegisterForClicks then
                cb.frame:RegisterForClicks("AnyUp")
            end
            cb:SetChecked(ns.Capture.GetOptions().autoPopup or false)
            cb:SetEventListener("OnValueChanged", function(_, _, checked)
                ns.Capture.SetOption("autoPopup", checked and true or false)
            end)
            autoCb, autoCbFrame = cb, cb.frame
        else
            local raw = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
            raw:SetSize(22, 22)
            raw:SetPoint("LEFT", clearFrame, "RIGHT", 12, 0)
            raw:SetChecked(ns.Capture.GetOptions().autoPopup or false)
            raw:SetScript("OnClick", function(self)
                ns.Capture.SetOption("autoPopup", self:GetChecked() and true or false)
            end)
            autoCb, autoCbFrame = raw, raw
        end
    end

    local autoLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoLabel:SetPoint("LEFT", autoCbFrame, "RIGHT", 2, 0)
    autoLabel:SetText("Auto-popup on new error")

    -- Filter input: substring match against entry.message (case-insensitive).
    -- Migrated to Cairn-Gui-Core Input. Same gotcha as Forge_Logs: the
    -- widget fires OnEnterPressed/OnEscapePressed/OnEditFocus*, but NOT
    -- OnTextChanged. Hook the inner editBox directly for live filter.
    -- Defensive fallback path if the kit didn't load.
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local filter = Gui and Gui:Create("Input")
    if filter then
        filter:SetParent(bar)
        filter:ClearAllPoints()
        filter:SetPoint("LEFT", autoLabel, "RIGHT", 12, 0)
        filter:SetWidth(160)
        filter:SetHeight(22)

        filter.editBox:HookScript("OnTextChanged", function(self)
            mod._filter = self:GetText() or ""
            Viewer.Refresh(mod)
        end)
        filter:SetEventListener("OnEscapePressed", function()
            filter:SetText("")
            mod._filter = ""
            Viewer.Refresh(mod)
        end)

        -- Hint FontString sits on bar (widget doesn't expose placeholder).
        local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("LEFT", filter.frame, "LEFT", 8, 0)
        hint:SetText("Filter...")
        filter:SetEventListener("OnEditFocusGained", function() hint:Hide() end)
        filter:SetEventListener("OnEditFocusLost",  function()
            if (filter:GetText() or "") == "" then hint:Show() end
        end)
    else
        local filterBg = CreateFrame("Frame", nil, bar, "BackdropTemplate")
        filterBg:SetSize(160, 22)
        filterBg:SetPoint("LEFT", autoLabel, "RIGHT", 12, 0)
        filterBg:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        filterBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
        filterBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
        local filterEdit = CreateFrame("EditBox", nil, filterBg)
        filterEdit:SetMultiLine(false); filterEdit:SetAutoFocus(false)
        filterEdit:SetFontObject("ChatFontNormal")
        filterEdit:SetPoint("LEFT", 6, 0); filterEdit:SetPoint("RIGHT", -6, 0); filterEdit:SetHeight(18)
        filterEdit:SetScript("OnTextChanged", function(self)
            mod._filter = self:GetText() or ""
            Viewer.Refresh(mod)
        end)
        filterEdit:SetScript("OnEscapePressed", function(self)
            self:ClearFocus(); self:SetText(""); mod._filter = ""; Viewer.Refresh(mod)
        end)
        local hint = filterBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("LEFT", 8, 0); hint:SetText("Filter...")
        filterEdit:SetScript("OnEditFocusGained", function() hint:Hide() end)
        filterEdit:SetScript("OnEditFocusLost",  function(self)
            if (self:GetText() or "") == "" then hint:Show() end
        end)
    end

    local count = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("RIGHT", bar, "RIGHT", -8, 0)
    count:SetTextColor(0.85, 0.7, 0.4, 1)
    mod._countText = count

    return bar
end

local function buildListPane(frame, mod, toolbar)
    local pane = CreateFrame("Frame", nil, frame)
    pane:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -PAD)
    pane:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    pane:SetWidth(LIST_WIDTH)

    -- Cairn-Gui ScrollFrame migration. Two handles stored on `mod`:
    --   _listScroll       -- the high-level widget (or raw frame in fallback)
    --   _listScrollFrame  -- the inner Blizzard ScrollFrame in BOTH paths;
    --                        used for UpdateScrollChildRect / GetWidth /
    --                        GetHeight which the widget doesn't expose at
    --                        the top level.
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local listGui = Gui and Gui:Create("ScrollFrame")
    if listGui then
        listGui:SetParent(pane)
        listGui:ClearAllPoints()
        listGui:SetPoint("TOPLEFT",     pane, "TOPLEFT",     0, 0)
        listGui:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
        mod._listScroll      = listGui
        mod._listScrollFrame = listGui.scrollFrame
        mod._listContent     = listGui.content
    else
        local scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
        scroll:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -22, 0)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(1, 1)
        scroll:SetScrollChild(content)
        mod._listScroll      = scroll
        mod._listScrollFrame = scroll
        mod._listContent     = content
    end

    mod._listPane = pane
    mod._listRows = {}
    return pane
end

local function buildDetailPane(frame, mod, toolbar)
    local pane = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    pane:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", LIST_WIDTH + PAD, -PAD)
    pane:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    pane:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    pane:SetBackdropColor(0.05, 0.05, 0.05, 0.40)
    pane:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    -- Ignore button: Cairn-Gui Button when available, raw Blizzard fallback
    -- otherwise. detailScroll's BOTTOMRIGHT anchors to the button's frame,
    -- so we keep `ignoreFrame` regardless of backend for that anchor.
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local ignoreBtn, ignoreFrame
    do
        local b = Gui and Gui:Create("Button")
        if b then
            b:SetParent(pane); b:ClearAllPoints()
            b:SetWidth(80); b:SetHeight(22)
            b:SetText("Ignore")
            b:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -6, 6)
            b:SetEventListener("OnClick", function() Viewer.IgnoreSelected(mod) end)
            ignoreBtn, ignoreFrame = b, b.frame
        else
            local raw = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
            raw:SetSize(80, 22)
            raw:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -6, 6)
            raw:SetText("Ignore")
            raw:SetScript("OnClick", function() Viewer.IgnoreSelected(mod) end)
            ignoreBtn, ignoreFrame = raw, raw
        end
    end

    -- Cairn-Gui ScrollFrame migration. Same handle split as the list pane:
    --   _detailScroll       -- widget or raw frame
    --   _detailScrollFrame  -- inner Blizzard frame for SetVerticalScroll /
    --                          UpdateScrollChildRect / GetWidth / GetHeight
    local detailGui = Gui and Gui:Create("ScrollFrame")
    local detailScroll, detailContent
    if detailGui then
        detailGui:SetParent(pane)
        detailGui:ClearAllPoints()
        detailGui:SetPoint("TOPLEFT",     pane, "TOPLEFT",     6, -6)
        detailGui:SetPoint("BOTTOMRIGHT", ignoreFrame, "TOPRIGHT", 0, 6)
        detailScroll  = detailGui
        detailContent = detailGui.content
        mod._detailScrollFrame = detailGui.scrollFrame
    else
        local sf = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", pane, "TOPLEFT", 6, -6)
        sf:SetPoint("BOTTOMRIGHT", ignoreFrame, "TOPRIGHT", 0, 6)
        local content = CreateFrame("Frame", nil, sf)
        content:SetSize(1, 1)
        sf:SetScrollChild(content)
        detailScroll = sf
        detailContent = content
        mod._detailScrollFrame = sf
    end

    local detailText = detailContent:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    detailText:SetJustifyH("LEFT")
    detailText:SetJustifyV("TOP")
    detailText:SetPoint("TOPLEFT", detailContent, "TOPLEFT", 4, -4)
    detailText:SetWordWrap(true)
    detailText:SetText("|cffaaaaaa(no error selected)|r")

    pane:SetScript("OnSizeChanged", function() reflowDetail(mod) end)

    mod._detailPane    = pane
    mod._detailScroll  = detailScroll
    mod._detailContent = detailContent
    mod._detailText    = detailText

    return pane
end

function Viewer.SelectIndex(mod, idx)
    local entries = ns.Capture.GetAll()
    local entry = idx and entries[idx] or nil
    mod._selected = entry

    if not entry then
        if mod._detailText then mod._detailText:SetText("|cffaaaaaa(no error selected)|r") end
        for _, row in ipairs(mod._listRows or {}) do
            if row._selBg then row._selBg:Hide() end
        end
        reflowDetail(mod)
        return
    end

    -- Build detail body. Header (timestamps + count) + message + optional
    -- stack + optional locals. Stack/locals are present when the seh path
    -- captured them via debugstack/debuglocals at error time, OR when an
    -- external tracker (BugGrabber) provided them in the errorObject.
    local parts = {
        string.format(
            "|cffd87f3aFirst seen:|r %s\n|cffd87f3aLast seen: |r %s\n|cffd87f3aCount:     |r %d\n\n%s",
            fmtTime(entry.ts), fmtTime(entry.lastTs), entry.count or 1, escapeBars(entry.message or "")
        ),
    }
    if entry.stack and entry.stack ~= "" then
        parts[#parts + 1] = "\n\n|cffd87f3aStack|r\n" .. escapeBars(entry.stack)
    end
    if entry.locals and entry.locals ~= "" then
        parts[#parts + 1] = "\n\n|cffd87f3aLocals|r\n" .. escapeBars(entry.locals)
    end
    mod._detailText:SetText(table.concat(parts))
    reflowDetail(mod)
    -- SetVerticalScroll is a Blizzard ScrollFrame method; widget doesn't
    -- expose it. Use the inner frame handle which works for both backends.
    local dsf = mod._detailScrollFrame
    if dsf and dsf.SetVerticalScroll then dsf:SetVerticalScroll(0) end

    for i, row in ipairs(mod._listRows or {}) do
        if row._selBg then
            if i == idx then row._selBg:Show() else row._selBg:Hide() end
        end
    end
end

function Viewer.IgnoreSelected(mod)
    local e = mod._selected
    if not e then return end
    local prefix = (e.message or ""):match("^([^:]+:%d+:)") or e.normalized or e.message
    if prefix and prefix ~= "" then
        ns.Capture.Ignore(prefix)
    end
end

function Viewer.Refresh(mod)
    if not mod or not mod._listContent then return end
    local entries = ns.Capture.GetAll()
    local filter  = (mod._filter or ""):lower()

    -- Filter pass: only entries whose message contains the filter substring.
    -- Skip entirely if no filter so we keep the cheap path.
    local visible = entries
    if filter ~= "" then
        visible = {}
        for _, e in ipairs(entries) do
            if e.message and e.message:lower():find(filter, 1, true) then
                visible[#visible + 1] = e
            end
        end
    end

    for _, row in ipairs(mod._listRows) do row:Hide() end

    local y = 0
    for i, entry in ipairs(visible) do
        local row = mod._listRows[i]
        if not row then
            row = CreateFrame("Button", nil, mod._listContent)
            row:SetSize(LIST_WIDTH - 24, ROW_HEIGHT)

            -- Selected background (hidden by default; shown when SelectIndex picks this row).
            local sel = row:CreateTexture(nil, "BACKGROUND", nil, -2)
            sel:SetColorTexture(0.85, 0.50, 0.20, 0.35)
            sel:SetAllPoints()
            sel:Hide()
            row._selBg = sel

            -- Hover background.
            local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
            hov:SetColorTexture(0.45, 0.32, 0.15, 0.30)
            hov:SetAllPoints()
            hov:Hide()
            row._hovBg = hov

            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetPoint("LEFT",  row, "LEFT",  6, 0)
            fs:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            fs:SetMaxLines(1)
            row._text = fs

            row:SetScript("OnEnter", function(self) self._hovBg:Show() end)
            row:SetScript("OnLeave", function(self) self._hovBg:Hide() end)
            row:SetScript("OnClick", function(self) Viewer.SelectIndex(mod, self._index) end)
            mod._listRows[i] = row
        end
        row._index = i
        row._text:SetText(rowText(entry))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", mod._listContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + ROW_HEIGHT
    end

    if y < 1 then y = 1 end
    mod._listContent:SetHeight(y)
    -- UpdateScrollChildRect is Blizzard-only; widget doesn't expose it.
    -- _listScrollFrame is the inner Blizzard frame in both backends.
    local lsf = mod._listScrollFrame
    if lsf and lsf.UpdateScrollChildRect then lsf:UpdateScrollChildRect() end

    if mod._countText then
        local session = ns.Capture.SessionCount()
        local total = 0
        for _, e in ipairs(entries) do total = total + (e.count or 1) end
        if filter ~= "" then
            mod._countText:SetText(string.format(
                "%d shown   |cffaaaaaa%d session / %d total|r", #visible, session, total))
        else
            mod._countText:SetText(string.format("Errors: %d session / %d total", session, total))
        end
    end
end

function Viewer.ShowAll(mod)
    local entries = ns.Capture.GetAll()
    if #entries == 0 then return end

    -- Per-error block: header line + message + optional stack + optional
    -- locals, separated by blank lines so paste-into-issue stays readable.
    local lines = { "Forge Bug Catcher - error dump", "Generated: " .. fmtTime(nowTs()), "" }
    for _, e in ipairs(entries) do
        lines[#lines + 1] = string.format(
            "[%s] x%d: %s", fmtTime(e.lastTs or e.ts), e.count or 1, e.message or "(no message)")
        if e.stack and e.stack ~= "" then
            lines[#lines + 1] = "Stack:"
            lines[#lines + 1] = e.stack
        end
        if e.locals and e.locals ~= "" then
            lines[#lines + 1] = "Locals:"
            lines[#lines + 1] = e.locals
        end
        lines[#lines + 1] = ""  -- blank separator between entries
    end
    local text = table.concat(lines, "\n")

    if Forge and Forge.ShowCopyDialog then
        Forge.ShowCopyDialog("Bug Catcher - all errors", text,
            "Ctrl-A to select all, Ctrl-C to copy. Paste into Discord or a GitHub issue.")
    end
end

function Viewer.Build(parent, mod)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    local toolbar = buildToolbar(frame, mod)
    buildListPane(frame, mod, toolbar)
    buildDetailPane(frame, mod, toolbar)

    if not mod._unsubChange then
        mod._unsubChange = ns.Capture.OnChange(function() Viewer.Refresh(mod) end)
    end
end

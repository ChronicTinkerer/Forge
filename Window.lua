-- Forge.Window: the main /forge window.
--
-- A single reusable frame with a tab strip on top (one tab per registered
-- sub-module) and a content area below. Sub-modules build their UI lazily
-- inside the content area via the OnTabShow descriptor callback.
--
-- When the user installs more sub-addons, more tabs appear automatically;
-- when they install fewer, the corresponding tabs simply don't show up.

local ADDON, ns = ...

local Window = {}
ns.Window = Window

local FRAME_NAME = "ForgeMainWindow"
local TAB_HEIGHT = 26
local TAB_PAD    = 4

local frame
local tabButtons = {}
local activeTab
local contentArea

-- --------------------------------------------------------------------------
-- Persistence helpers.
-- --------------------------------------------------------------------------
local function persistGeometry()
    local db = ns.db
    if not (frame and db) then return end
    local p = db.profile.window
    p.x = frame:GetLeft() or 0
    p.y = frame:GetTop()  or 0
    p.w = frame:GetWidth()  or 880
    p.h = frame:GetHeight() or 560
end

-- --------------------------------------------------------------------------
-- Frame creation (lazy: built on first Show).
-- --------------------------------------------------------------------------
local function buildFrame()
    if frame then return frame end

    local f = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
    frame = f

    local p = ns.db.profile.window
    f:SetSize(p.w or 880, p.h or 560)
    if p.x and p.y and (p.x ~= 0 or p.y ~= 0) then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    f:SetMovable(true)
    f:SetResizable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing(); persistGeometry() end)

    -- Reflow tabs as the window resizes so the strip stays in bounds.
    f:SetScript("OnSizeChanged", function() Window.RefreshTabs() end)

    if f.SetResizeBounds then
        f:SetResizeBounds(560, 320, 1600, 1000)
    elseif f.SetMinResize then
        f:SetMinResize(560, 320)
    end

    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.05, 0.72)
    f:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    f:SetFrameStrata("MEDIUM")
    f:Hide()

    -- Watermark logo (sits behind tabs and content). Subtle, not loud.
    local logo = f:CreateTexture(nil, "ARTWORK", nil, -7)
    logo:SetTexture("Interface\\AddOns\\Forge\\ForgeLogo.png")
    logo:SetPoint("CENTER", f, "CENTER", 0, 0)
    logo:SetSize(540, 540)
    logo:SetAlpha(0.32)
    f._logo = logo

    -- Title.
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -10)
    title:SetText("|cffd87f3aForge|r")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("LEFT", title, "RIGHT", 8, -1)
    subtitle:SetText("dev tools for Cairn / LibCodex")

    -- Close button (top right).
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() Window.Hide() end)

    -- Resize grip.
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp",   function() f:StopMovingOrSizing(); persistGeometry() end)

    -- Tab strip container.
    local tabStrip = CreateFrame("Frame", nil, f)
    tabStrip:SetPoint("TOPLEFT",  f, "TOPLEFT",  10, -36)
    tabStrip:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -36)
    tabStrip:SetHeight(TAB_HEIGHT)
    f._tabStrip = tabStrip

    -- Thin divider beneath tabs.
    local divider = f:CreateTexture(nil, "OVERLAY")
    divider:SetColorTexture(0.4, 0.3, 0.15, 0.6)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT",  tabStrip, "BOTTOMLEFT",  0, -2)
    divider:SetPoint("TOPRIGHT", tabStrip, "BOTTOMRIGHT", 0, -2)

    -- Content area.
    contentArea = CreateFrame("Frame", nil, f)
    contentArea:SetPoint("TOPLEFT", tabStrip, "BOTTOMLEFT", 0, -6)
    contentArea:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 18)
    f._contentArea = contentArea

    -- Empty-state message.
    local empty = contentArea:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    empty:SetPoint("CENTER", contentArea, "CENTER", 0, 0)
    empty:SetText("No Forge sub-modules loaded.\n\nInstall any of:  Forge_BugCatcher, Forge_Macros,\nForge_Console, Forge_Inspector, Forge_Logs,\nForge_Profiles, Forge_Setup, Forge_AddonManager, Forge_Codex")
    empty:SetJustifyH("CENTER")
    f._emptyText = empty

    return f
end

-- --------------------------------------------------------------------------
-- Tab strip rendering.
-- --------------------------------------------------------------------------
local function buildTabButton(parent, name, descriptor)
    local btn = tabButtons[name]
    if btn then return btn end

    btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(120, TAB_HEIGHT)
    btn:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", btn, "CENTER", 0, 0)
    text:SetText(descriptor.title or name)
    btn._text = text

    -- Active / inactive paint.
    btn._setActive = function(self, active)
        self._isActive = active and true or false
        if active then
            self:SetBackdropColor(0.30, 0.20, 0.10, 1)        -- selected: warm
            self:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)  -- forge orange
            self._text:SetTextColor(1.00, 0.85, 0.50, 1)
        else
            self:SetBackdropColor(0.08, 0.06, 0.04, 1)
            self:SetBackdropBorderColor(0.30, 0.22, 0.12, 1)
            self._text:SetTextColor(0.65, 0.55, 0.40, 1)
        end
    end
    btn:_setActive(false)

    btn:SetScript("OnEnter", function(self)
        if self._isActive then return end
        self:SetBackdropColor(0.16, 0.12, 0.07, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        if self._isActive then return end
        self:SetBackdropColor(0.08, 0.06, 0.04, 1)
    end)
    btn:SetScript("OnClick", function() Window.OpenTab(name) end)

    tabButtons[name] = btn
    return btn
end

function Window.RefreshTabs()
    if not frame then return end
    local strip = frame._tabStrip
    if not strip then return end

    for _, btn in pairs(tabButtons) do btn:Hide() end

    if not ns.Registry then return end
    local order = ns.Registry.List()

    if frame._emptyText then
        if #order == 0 then frame._emptyText:Show() else frame._emptyText:Hide() end
    end

    -- Compute natural widths (text width + padding) for each tab, then scale
    -- uniformly to fit the strip if the total exceeds available width. Floor
    -- at 56px so labels don't disappear; cap at 120px so wide windows don't
    -- stretch tabs absurdly.
    local TAB_MIN, TAB_MAX = 56, 120
    local stripW    = strip:GetWidth() or 800
    local naturalW  = {}
    local naturalSum = 0
    for _, name in ipairs(order) do
        local descriptor = ns.Registry.Get(name)
        if descriptor then
            local btn = buildTabButton(strip, name, descriptor)
            btn._text:SetText(descriptor.title or name)
            local w = (btn._text:GetStringWidth() or 60) + 18  -- L/R padding
            w = math.min(TAB_MAX, math.max(TAB_MIN, w))
            naturalW[name] = w
            naturalSum = naturalSum + w
        end
    end
    local gapTotal = math.max(0, (#order - 1)) * TAB_PAD
    local need     = naturalSum + gapTotal
    local scale    = 1
    if need > stripW and naturalSum > 0 then
        scale = (stripW - gapTotal) / naturalSum
    end

    local x = 0
    for _, name in ipairs(order) do
        local descriptor = ns.Registry.Get(name)
        if descriptor then
            local btn = buildTabButton(strip, name, descriptor)
            local w = math.max(TAB_MIN * 0.7, math.floor((naturalW[name] or TAB_MIN) * scale))
            btn:SetWidth(w)
            btn:ClearAllPoints()
            btn:SetPoint("LEFT", strip, "LEFT", x, 0)
            btn:Show()
            x = x + w + TAB_PAD
        end
    end

    if not activeTab and order[1] then
        Window.OpenTab(order[1])
    end
end

-- --------------------------------------------------------------------------
-- Tab open / close.
-- --------------------------------------------------------------------------
function Window.OpenTab(name)
    buildFrame()
    if not (ns.Registry and ns.Registry.Get(name)) then
        if ns.out then ns.out("no such tab: " .. tostring(name)) end
        return
    end

    -- Defensive: hide every registered tab's frame before activating the new
    -- one. Cures a class of bugs where a tab's OnTabHide fails silently or
    -- where a sub-addon stashes its panel at a non-_frame field (still
    -- rendering as a child of contentArea). After this loop the only frames
    -- visible inside contentArea are the new tab's.
    for _, otherName in ipairs(ns.Registry.List() or {}) do
        if otherName ~= name then
            local d = ns.Registry.Get(otherName)
            if d then
                if type(d.OnTabHide) == "function" then
                    local ok, err = pcall(d.OnTabHide, contentArea, d)
                    if not ok and geterrorhandler then geterrorhandler()(err) end
                end
                -- Hard-hide every plausible frame field the descriptor or its
                -- UI module may have stashed.
                if d._frame           then d._frame:Hide()           end
                if d._macrosPanel     then d._macrosPanel:Hide()     end
                if d._sequencesPanel  then d._sequencesPanel:Hide()  end
            end
        end
    end

    for tabName, btn in pairs(tabButtons) do
        if btn._setActive then
            btn:_setActive(tabName == name)
        end
    end

    activeTab = name
    if ns.db and ns.db.profile and ns.db.profile.window then
        ns.db.profile.window.activeTab = name
    end

    local descriptor = ns.Registry.Get(name)
    if descriptor and type(descriptor.OnTabShow) == "function" then
        local ok, err = pcall(descriptor.OnTabShow, contentArea, descriptor)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end

    if not frame:IsShown() then
        frame:Show()
        if ns.db and ns.db.profile and ns.db.profile.window then
            ns.db.profile.window.shown = true
        end
    end
end

-- --------------------------------------------------------------------------
-- Show / hide / toggle.
-- --------------------------------------------------------------------------
function Window.Show()
    buildFrame()
    Window.RefreshTabs()
    if not activeTab then
        local list = ns.Registry and ns.Registry.List() or {}
        if list[1] then
            Window.OpenTab(list[1])
            return  -- OpenTab will Show() the frame itself
        end
    end
    frame:Show()
    if ns.db and ns.db.profile and ns.db.profile.window then
        ns.db.profile.window.shown = true
    end
end

function Window.Hide()
    if frame then frame:Hide() end
    if ns.db and ns.db.profile and ns.db.profile.window then
        ns.db.profile.window.shown = false
    end
end

function Window.Toggle()
    if frame and frame:IsShown() then Window.Hide() else Window.Show() end
end

function Window.IsShown()
    return (frame and frame:IsShown()) or false
end

-- ===========================================================================
-- Shared utilities exposed to every sub-addon: a copy-dialog popup and a Lua
-- table serializer. Sub-addons hit `Forge.ShowCopyDialog(title, text, hint)`
-- to surface text the user wants to copy out (errors, snippets, addon state),
-- and `Forge.SerializeTable(t)` to produce loadable Lua for the dialog body.
-- ===========================================================================

local _copyDialog
local function buildCopyDialog()
    local f = CreateFrame("Frame", "ForgeCopyDialog", UIParent, "BackdropTemplate")
    f:SetSize(720, 520)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.95)
    f:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    f:Hide()

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    f._title = title

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", title, "RIGHT", 8, 0)
    f._hint = hint

    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     12, -36)
    sf:SetPoint("BOTTOMRIGHT", -32, 12)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject("ChatFontNormal")
    eb:SetWidth(660)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    sf:SetScrollChild(eb)
    f._eb = eb
    return f
end

function Window.ShowCopyDialog(title, text, hint)
    if not _copyDialog then _copyDialog = buildCopyDialog() end
    local f = _copyDialog
    f._title:SetText("|cffd87f3a" .. tostring(title or "Copy") .. "|r")
    f._hint:SetText(hint or "Ctrl-A to select all, Ctrl-C to copy")
    f._eb:SetText(text or "")
    f._eb:SetCursorPosition(0)
    f._eb:HighlightText()
    f:Show()
    f._eb:SetFocus()
    return f
end

-- ===========================================================================
-- SerializeTable: produces loadable Lua for a value. Round-trippable for
-- strings/numbers/booleans/nested tables. Cycles render as `nil --[[cycle]]`.
-- ===========================================================================
local function _serialize(v, indent, seen)
    indent = indent or ""
    seen = seen or {}
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
    if t ~= "table" then return "nil --[[" .. t .. "]]" end
    if seen[v] then return "nil --[[cycle]]" end
    seen[v] = true

    if next(v) == nil then return "{}" end
    local pad = indent .. "    "
    local lines = { "{" }

    local seqLen = #v
    for i = 1, seqLen do
        lines[#lines + 1] = pad .. _serialize(v[i], pad, seen) .. ","
    end

    local hashKeys = {}
    for k in pairs(v) do
        if not (type(k) == "number" and k >= 1 and k <= seqLen and k == math.floor(k)) then
            hashKeys[#hashKeys + 1] = k
        end
    end
    table.sort(hashKeys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(hashKeys) do
        local keyStr
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
            keyStr = k
        elseif type(k) == "string" then
            keyStr = string.format("[%q]", k)
        else
            keyStr = "[" .. tostring(k) .. "]"
        end
        lines[#lines + 1] = pad .. keyStr .. " = " .. _serialize(v[k], pad, seen) .. ","
    end

    lines[#lines + 1] = indent .. "}"
    return table.concat(lines, "\n")
end

function Window.SerializeTable(t)
    return _serialize(t, "", {})
end

-- Top-level convenience aliases on the Forge namespace.
ns.ShowCopyDialog = Window.ShowCopyDialog
ns.SerializeTable = Window.SerializeTable

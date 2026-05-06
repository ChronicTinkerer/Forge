-- Forge_Inspector.UI: split-pane _G tree browser + watch panel.
--
-- Layout:
--   [Search ............]        [Refresh] [Collapse all]
--   +------------------------+--+----------------------------+
--   | Tree (left ~60%)       |  | Watch (right ~40%)         |
--   |  > _G                  |  |  path     | type | value   |
--   |    > MyAddon  (table)  |  |  ...                        |
--   |        version : "1.0" |  |                             |
--   +------------------------+--+----------------------------+
--
-- Tree behavior:
--   - Root is _G.
--   - Click a row's [+] / [-] to expand/collapse a table.
--   - Each row shows `key : type` and an inline value for primitives.
--   - Right-click a row to pin its path to the Watch panel.
--   - Search box filters keys at the CURRENT visible level (case-insensitive).
--   - 0.5s auto-poll refreshes visible rows' values.
--
-- Watch behavior:
--   - Pinned paths persist in db.profile.watch (per character).
--   - Each row shows path, current value type, and value (truncated).
--   - X button removes from watch.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H   = 56  -- two rows of 22-px controls
local ROW_H       = 18
local PAD         = 6
local SPLIT_RATIO = 0.6   -- tree pane width fraction

-- The expensive part of expanding `_G` was creating ~10k UI Frames in one
-- tick, not iterating Lua tables. We use a small pool of row buttons
-- (VISIBLE_ROW_BUFFER) and recycle them as the user scrolls. With
-- virtualization there is no need to cap children.
--
-- Paranoia cap only - if some addon installs an absurdly large table this
-- still bounds the closure-creation work.
local VISIBLE_ROW_BUFFER = 40   -- ~1.5x a typical viewport's row count

local _activeMod
local _filterText = ""
local _ticker

-- ----- Type colors (ARGB) ------------------------------------------------
local TYPE_COLOR = {
    ["string"]   = "ff80ff80",
    ["number"]   = "ff7fdfff",
    ["boolean"]  = "ffffd87f",
    ["function"] = "ffaaaaaa",
    ["table"]    = "ffd87f3a",
    ["nil"]      = "ffff5050",
    ["userdata"] = "ffaaaaff",
    ["thread"]   = "ffaaaaff",
}

local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

-- ----- Taint-safe helpers ------------------------------------------------
-- Some Blizzard tables are "secret" — calling pairs() on them propagates
-- taint to our addon's execution and blocks secure operations until the
-- next /reload. The Blizzard API exposes detection functions; we check
-- BEFORE iterating, so we never pair() a forbidden table at all.
local function isSecret(v)
    if type(v) ~= "table" then
        if issecretvalue and issecretvalue(v) then return true end
        return false
    end
    if issecrettable and issecrettable(v) then return true end
    if issecretvalue and issecretvalue(v) then return true end
    return false
end

-- Some frame-like tables expose IsForbidden(); skip those too.
local function isForbidden(v)
    if type(v) ~= "table" then return false end
    local fn = rawget(v, "IsForbidden") or (getmetatable(v) and v.IsForbidden)
    if type(fn) ~= "function" then return false end
    local ok, forbidden = pcall(fn, v)
    return ok and forbidden and true or false
end

local function isUntouchable(v)
    return isSecret(v) or isForbidden(v)
end

-- Format a value for inline display. Tables / functions show summary only;
-- strings get truncated.
local function fmtValue(v)
    local t = type(v)
    local color = TYPE_COLOR[t] or "ffffffff"
    if t == "string" then
        local s = v
        if #s > 60 then s = s:sub(1, 57) .. "..." end
        return "|c" .. color .. string.format("%q", s) .. "|r"
    elseif t == "number" or t == "boolean" or t == "nil" then
        return "|c" .. color .. tostring(v) .. "|r"
    elseif t == "function" then
        return "|c" .. color .. "function|r"
    elseif t == "table" then
        if isUntouchable(v) then
            return "|c" .. color .. "table  |cffff8080<protected>|r|r"
        end
        local n = 0
        for _ in pairs(v) do n = n + 1; if n > 10 then break end end
        return "|c" .. color .. "table  |cffaaaaaa(" .. n .. (n >= 10 and "+" or "") .. " keys)|r|r"
    end
    return "|c" .. color .. tostring(v) .. "|r"
end

local function shortType(v)
    return type(v)
end

-- ----- Tree node model ---------------------------------------------------
-- node = {
--   key       = "SomeKey",        -- last path segment (string)
--   keyType   = "string",         -- type of the key
--   getter    = function() return value end,   -- pull current value
--   parent    = parent_node,      -- nil for the root
--   depth     = number,           -- 0 for root
--   expanded  = bool,
--   children  = nil or { node, ... },  -- lazy-built
--   path      = "_G.A.B",         -- display path
-- }

local function buildChildren(node)
    local v = node.getter()
    if type(v) ~= "table" then node.children = {}; return end

    -- CRITICAL: never call pairs() on a secret/forbidden table. Doing so
    -- propagates taint to our addon's execution even if pcall catches the
    -- thrown error - taint is set BEFORE the error fires. Detect first.
    if isUntouchable(v) then
        node.children    = {}
        node._isProtected = true
        return
    end

    -- Pass 1: collect bare keys ONLY. No closures, no nested tables.
    -- This is the cheapest possible iteration of `v`.
    local rawKeys = {}
    local ok, err = pcall(function()
        for k in pairs(v) do
            rawKeys[#rawKeys + 1] = k
        end
    end)
    if not ok then
        node._iterError = tostring(err)
    end

    -- Pass 2: sort the bare keys. String comparator only - no per-element
    -- table allocation in the comparator.
    table.sort(rawKeys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == tb then
            if ta == "string" then return a < b end
            if ta == "number" then return a < b end
        end
        return tostring(a) < tostring(b)
    end)

    -- Pass 3: build child nodes. With virtualized rendering only ~40 row
    -- frames ever exist regardless of children count - no data-layer cap.
    local total = #rawKeys
    local cap = total
    local kids = {}
    for i = 1, cap do
        local k = rawKeys[i]
        local keyType = type(k)
        local function child_getter()
            local parentVal = node.getter()
            if type(parentVal) ~= "table" then return nil end
            return parentVal[k]
        end
        local keyStr
        if keyType == "string" then
            keyStr = k
        else
            keyStr = "[" .. tostring(k) .. "]"
        end
        kids[i] = {
            key       = keyStr,
            rawKey    = k,
            keyType   = keyType,
            getter    = child_getter,
            parent    = node,
            depth     = node.depth + 1,
            expanded  = false,
            children  = nil,
            path      = node.path .. "." .. keyStr,
        }
    end

    -- Append $metatable / $metatable.__index entries when expanding a real
    -- table so you can drill into Mixin chains (frames, addon objects, etc).
    local mt
    pcall(function() mt = getmetatable(v) end)
    if type(mt) == "table" and not isUntouchable(mt) then
        local mtCount = 0
        for _ in pairs(mt) do mtCount = mtCount + 1 end
        -- If the metatable is just { __index = T }, hop straight to T.
        if mtCount == 1 and type(mt.__index) == "table" then
            local idx = mt.__index
            kids[#kids + 1] = {
                key       = "$metatable.__index",
                rawKey    = "$metatable.__index",
                keyType   = "string",
                getter    = function() return idx end,
                parent    = node,
                depth     = node.depth + 1,
                expanded  = false,
                children  = nil,
                path      = node.path .. ".$metatable.__index",
                _isMeta   = true,
            }
        elseif mtCount > 0 then
            kids[#kids + 1] = {
                key       = "$metatable",
                rawKey    = "$metatable",
                keyType   = "string",
                getter    = function() return mt end,
                parent    = node,
                depth     = node.depth + 1,
                expanded  = false,
                children  = nil,
                path      = node.path .. ".$metatable",
                _isMeta   = true,
            }
        end
    end

    node.children       = kids
    node._totalChildren = total
end

-- ----- Root nodes --------------------------------------------------------
-- A "root" is just a top-level node in the tree. Multiple roots are stacked
-- in the visible list. The first root is always _G; users can pin more via
-- mouseover, /forge inspect <path>, or find/startswith results.
--
-- Spec shape:
--   { kind = "path",     path = "_G.X.Y" }                 -- persistent
--   { kind = "snapshot", name = "find:foo", value = tbl }  -- session-only

local function makeRootFromSpec(spec)
    local name, getter, path
    if spec.kind == "path" then
        path = spec.path or "_G"
        name = path
        if path == "_G" then
            getter = function() return _G end
        else
            -- Walk _G.X.Y at lookup time so the value tracks live updates.
            local segments = {}
            for seg in path:gsub("^_G%.?", ""):gmatch("[^%.]+") do
                segments[#segments + 1] = seg
            end
            getter = function()
                local cur = _G
                for _, seg in ipairs(segments) do
                    if type(cur) ~= "table" then return nil end
                    cur = cur[seg]
                end
                return cur
            end
        end
    elseif spec.kind == "snapshot" then
        name   = spec.name or "snapshot"
        path   = "$" .. name
        local v = spec.value
        getter = function() return v end
    elseif spec.kind == "live_mouseover" then
        name   = "@mouseover"
        path   = "@mouseover"
        getter = function()
            if GetMouseFoci then
                local list = GetMouseFoci() or {}
                return list[1]
            elseif GetMouseFocus then
                return GetMouseFocus()
            end
            return nil
        end
    else
        return nil
    end
    return {
        key      = name,
        keyType  = "string",
        getter   = getter,
        parent   = nil,
        depth    = 0,
        expanded = false,
        path     = path,
        _spec    = spec,  -- so we can identify / remove later
    }
end

local function defaultRoots()
    return { makeRootFromSpec({ kind = "path", path = "_G" }) }
end

-- Enumerate currently-loaded addons and produce path-kind specs pointing at
-- whatever passes for each addon's "namespace". Two sources, in priority:
--
--   1) `_G[AddOnName]` if it's a table (most public addons expose one).
--   2) `Cairn.Addon.registry[AddOnName]` (Cairn-managed addons that don't
--      publish a global, e.g. Forge_Console).
--
-- Specs are session-only (not persisted) and recomputed on each Build so the
-- list tracks enable/disable across /reload without leaving stale pins.
local function loadedAddonSpecs()
    local specs = {}
    if not (C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetAddOnInfo) then
        return specs
    end
    local seen = {}  -- by path; prevents dupes if a name appears twice
    local count = C_AddOns.GetNumAddOns() or 0
    for i = 1, count do
        local isLoaded = C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(i)
        if isLoaded then
            local name = C_AddOns.GetAddOnInfo(i)
            if type(name) == "string" and name ~= "" then
                local path
                local globalVal = rawget(_G, name)
                if type(globalVal) == "table" then
                    path = "_G." .. name
                elseif Cairn and Cairn.Addon and Cairn.Addon.registry
                    and Cairn.Addon.registry[name] then
                    path = "Cairn.Addon.registry." .. name
                end
                if path and not seen[path] then
                    seen[path] = true
                    specs[#specs + 1] = { kind = "path", path = path }
                end
            end
        end
    end
    table.sort(specs, function(a, b) return a.path < b.path end)
    return specs
end

-- Walk all roots top-down, returning a flat list of currently-visible nodes.
local function flatten(roots, filterText)
    local out = {}
    local function visit(node)
        out[#out + 1] = node
        if node.expanded then
            if not node.children then buildChildren(node) end
            for _, child in ipairs(node.children or {}) do
                if filterText == "" or node.depth ~= 0
                    or tostring(child.key):lower():find(filterText:lower(), 1, true) then
                    visit(child)
                end
            end
        end
    end
    for _, root in ipairs(roots or {}) do visit(root) end
    return out
end

-- ----- Watch list --------------------------------------------------------
local function resolvePath(pathStr)
    -- Walk from _G via dot-separated keys. No support for keys containing
    -- dots (rare in practice). Brackets like [1] resolve to the numeric key 1.
    if pathStr == "_G" then return _G end
    local cur = _G
    -- Drop the leading "_G." prefix.
    local p = pathStr:gsub("^_G%.", "")
    for seg in p:gmatch("[^%.]+") do
        if type(cur) ~= "table" then return nil end
        if isUntouchable(cur) then return "<protected>" end
        if seg:match("^%[(.-)%]$") then
            local inner = seg:match("^%[(.-)%]$")
            local n = tonumber(inner)
            if n then
                cur = cur[n]
            else
                cur = cur[inner:gsub('^"', ""):gsub('"$', "")]
            end
        else
            cur = cur[seg]
        end
    end
    return cur
end

-- ----- UI builder --------------------------------------------------------
function UI.Build(parent, mod)
    _activeMod = mod
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- Acquire Cairn-Gui-Core once. Each migration site below has a vanilla
    -- fallback for safety if the kit failed to load.
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    -- ----- Migration helpers -------------------------------------------------
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
    local function makeInput(parentFrame, w, h, hintText)
        local s = Gui and Gui:Create("Input")
        if s then
            s:SetParent(parentFrame); s:ClearAllPoints()
            s:SetWidth(w); s:SetHeight(h)
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
            return s, s.frame, hint, s.editBox
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
            raw:SetTextInsets(0, 0, 0, 0)
            local hint
            if hintText then
                hint = bg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                hint:SetPoint("LEFT", 8, 0); hint:SetText(hintText)
                raw:SetScript("OnEditFocusGained", function() hint:Hide() end)
                raw:SetScript("OnEditFocusLost",  function(self)
                    if (self:GetText() or "") == "" then hint:Show() end
                end)
            end
            raw.frame = bg
            return raw, bg, hint, raw
        end
    end
    local function makeCheck(parentFrame, initialChecked, onChange, tipLines)
        local widget = Gui and Gui:Create("CheckBox")
        if widget then
            widget:SetParent(parentFrame); widget:ClearAllPoints()
            widget:SetWidth(20); widget:SetHeight(20)
            widget.frame:EnableMouse(true)
            if widget.frame.RegisterForClicks then widget.frame:RegisterForClicks("AnyUp") end
            widget:SetChecked(initialChecked and true or false)
            widget:SetEventListener("OnValueChanged", function(_, _, checked)
                onChange(checked and true or false)
            end)
            if tipLines then
                widget.frame:HookScript("OnEnter", function(self)
                    if not GameTooltip then return end
                    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
                    for _, line in ipairs(tipLines) do
                        if line.title then GameTooltip:AddLine("|cffd87f3a" .. line.text .. "|r")
                        else GameTooltip:AddLine(line.text, 1, 1, 1, true) end
                    end
                    GameTooltip:Show()
                end)
                widget.frame:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
            end
            return widget, widget.frame
        else
            local raw = CreateFrame("CheckButton", nil, parentFrame, "UICheckButtonTemplate")
            raw:SetSize(20, 20)
            raw:SetChecked(initialChecked and true or false)
            raw:SetScript("OnClick", function(self) onChange(self:GetChecked() and true or false) end)
            if tipLines then
                raw:SetScript("OnEnter", function(self)
                    if not GameTooltip then return end
                    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
                    for _, line in ipairs(tipLines) do
                        if line.title then GameTooltip:AddLine("|cffd87f3a" .. line.text .. "|r")
                        else GameTooltip:AddLine(line.text, 1, 1, 1, true) end
                    end
                    GameTooltip:Show()
                end)
                raw:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
            end
            return raw, raw
        end
    end
    local function makeScroll(parentFrame, anchorTL, anchorBR)
        local s = Gui and Gui:Create("ScrollFrame")
        if s then
            s:SetParent(parentFrame); s:ClearAllPoints()
            s:SetPoint("TOPLEFT",     parentFrame, "TOPLEFT",     anchorTL[1], anchorTL[2])
            s:SetPoint("BOTTOMRIGHT", parentFrame, "BOTTOMRIGHT", anchorBR[1], anchorBR[2])
            -- Expose .scrollFrame so callers using HookScript /
            -- GetVerticalScroll / UpdateScrollChildRect work uniformly.
            return s, s.content, s.scrollFrame or s
        else
            local raw = CreateFrame("ScrollFrame", nil, parentFrame, "UIPanelScrollFrameTemplate")
            raw:SetPoint("TOPLEFT",     anchorTL[1], anchorTL[2])
            raw:SetPoint("BOTTOMRIGHT", anchorBR[1] - 22, anchorBR[2])
            local content = CreateFrame("Frame", nil, raw); content:SetSize(1,1); raw:SetScrollChild(content)
            return raw, content, raw
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

    -- ===== Toolbar =======================================================
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  4, -4)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    bar:SetHeight(TOOLBAR_H)

    -- ---------- Toolbar row 1: filter + view controls ------------------
    local search, searchFrame, _searchHint, searchEb = makeInput(bar, 200, 22, "Filter top-level keys...")
    search:ClearAllPoints()
    search:SetPoint("TOPLEFT", bar, "TOPLEFT", 4, -2)
    searchEb:SetScript("OnTextChanged", function(self) _filterText = self:GetText() or ""; UI.RebuildTree() end)
    searchEb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText(""); _filterText = ""; UI.RebuildTree() end)

    local refreshBtn, refreshBtnFrame = makeBtn(bar, "Refresh", 70, 22, function() UI.RebuildTree() end)
    refreshBtn:ClearAllPoints()
    refreshBtn:SetPoint("LEFT", searchFrame, "RIGHT", 6, 0)

    -- Live (0.5s auto-poll) toggle.
    local liveCb, liveCbFrame = makeCheck(bar, (ns.IsLive and ns.IsLive()) or false,
        function(v) if ns.SetLive then ns.SetLive(v) end end,
        {
            { title = true, text = "Live (0.5s auto-poll)" },
            { text = "Re-renders visible tree rows + the watch list every 0.5s." },
        })
    liveCb:ClearAllPoints()
    liveCb:SetPoint("LEFT", refreshBtnFrame, "RIGHT", 6, 0)
    local liveLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    liveLabel:SetPoint("LEFT", liveCbFrame, "RIGHT", 2, 0)
    liveLabel:SetText("Live")
    liveLabel:SetTextColor(0.85, 0.7, 0.4, 1)

    -- Mouseover (live) toggle.
    local mouseCb, mouseCbFrame = makeCheck(bar, false,
        function(v) UI.SetMouseoverEnabled(v) end,
        {
            { title = true, text = "Mouseover (live)" },
            { text = "Adds an |cffd87f3a@mouseover|r root that tracks the frame currently" },
            { text = "under your cursor. Updates 5x/sec; expand to drill in." },
        })
    mouseCb:ClearAllPoints()
    mouseCb:SetPoint("LEFT", liveLabel, "RIGHT", 8, 0)
    local mouseLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mouseLabel:SetPoint("LEFT", mouseCbFrame, "RIGHT", 2, 0)
    mouseLabel:SetText("Mouseover")
    mouseLabel:SetTextColor(0.85, 0.7, 0.4, 1)

    local collapseBtn = makeBtn(bar, "Collapse all", 90, 22, function()
        for _, root in ipairs(mod._roots or {}) do
            root.expanded = false
            root.children = nil
        end
        UI.RebuildTree()
    end)
    collapseBtn:ClearAllPoints()
    collapseBtn:SetPoint("LEFT", mouseLabel, "RIGHT", 8, 0)

    -- ---------- Toolbar row 2: search + tools ---------------------------
    local findEdit, findFrame, _findHint, findEditEb = makeInput(bar, 180, 22, "Search _G for...")
    findEdit:ClearAllPoints()
    findEdit:SetPoint("TOPLEFT", bar, "TOPLEFT", 4, -28)
    findEditEb:SetScript("OnEnterPressed", function(self)
        UI.RunFind(self:GetText(), "contains")
        self:ClearFocus()
    end)
    findEditEb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText("") end)
    mod._findEdit = findEditEb  -- preserve old API: callers GetText on this

    local function attachTip(frameRef, lines)
        frameRef:HookScript("OnEnter", function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
            for _, l in ipairs(lines) do GameTooltip:AddLine(l, 1, 1, 1, true) end
            GameTooltip:Show()
        end)
        frameRef:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end

    local findBtn, findBtnFrame = makeBtn(bar, "Find", 50, 22,
        function() UI.RunFind(findEditEb:GetText(), "contains") end)
    findBtn:ClearAllPoints()
    findBtn:SetPoint("LEFT", findFrame, "RIGHT", 4, 0)
    attachTip(findBtnFrame, { "Find: pin a snapshot of _G keys that |cffd87f3acontain|r the term." })

    local startBtn, startBtnFrame = makeBtn(bar, "Starts", 60, 22,
        function() UI.RunFind(findEditEb:GetText(), "prefix") end)
    startBtn:ClearAllPoints()
    startBtn:SetPoint("LEFT", findBtnFrame, "RIGHT", 4, 0)
    attachTip(startBtnFrame, { "Starts: pin a snapshot of _G keys that |cffd87f3astart with|r the term." })

    local fstackBtn, fstackBtnFrame = makeBtn(bar, "FStack", 70, 22, function() UI.OpenFStack() end)
    fstackBtn:ClearAllPoints()
    fstackBtn:SetPoint("LEFT", startBtnFrame, "RIGHT", 12, 0)
    attachTip(fstackBtnFrame, {
        "Toggle Blizzard's Frame Stack tooltip.",
        "Same thing as |cffd87f3a/framestack|r.",
    })

    local etraceBtn, etraceBtnFrame = makeBtn(bar, "ETrace", 70, 22, function() UI.OpenETrace() end)
    etraceBtn:ClearAllPoints()
    etraceBtn:SetPoint("LEFT", fstackBtnFrame, "RIGHT", 4, 0)
    attachTip(etraceBtnFrame, {
        "Toggle Blizzard's Event Trace.",
        "Same thing as |cffd87f3a/eventtrace|r.",
    })

    -- ===== Tree pane (left) ==============================================
    -- Taint warning banner just below the toolbar.
    local warn = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warn:SetPoint("TOPLEFT",  bar, "BOTTOMLEFT",  4, -2)
    warn:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", -4, -2)
    warn:SetJustifyH("LEFT")
    warn:SetText("|cffffaa00Note:|r protected Blizzard tables show as |cffff8080<protected>|r and can't be expanded (skipping them prevents taint). Click |cffd87f3a>|r to expand any safe table.")

    local treeBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    treeBg:SetPoint("TOPLEFT", warn, "BOTTOMLEFT", 0, -2)
    treeBg:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 4)
    treeBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    treeBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    treeBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    -- Width set on parent resize.
    local function reposTree()
        local fw = frame:GetWidth() or 0
        local treeW = math.floor((fw - 12) * SPLIT_RATIO)
        treeBg:SetWidth(treeW)
    end
    frame:SetScript("OnSizeChanged", function() reposTree() end)
    reposTree()

    local treeScroll, treeContent, treeScrollFrame = makeScroll(treeBg, { 6, -6 }, { -2, 6 })
    mod._treeScroll      = treeScroll
    mod._treeContent     = treeContent
    mod._treeScrollFrame = treeScrollFrame
    mod._treeRows = {}

    -- Virtualized rendering: re-render the visible window on every scroll
    -- tick. HookScripts go on the inner Blizzard scrollFrame so the kit's
    -- own SetScript handlers stay intact.
    treeScrollFrame:HookScript("OnVerticalScroll", function() UI.RenderVisibleWindow() end)
    treeScrollFrame:HookScript("OnSizeChanged",    function() UI.RenderVisibleWindow() end)

    -- ===== Right pane (tabbed: Watch | Events) ==========================
    local rightBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    rightBg:SetPoint("TOPLEFT", treeBg, "TOPRIGHT", PAD, 0)
    rightBg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    rightBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    rightBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    rightBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    mod._rightBg = rightBg

    -- Tab strip at the top of the right pane. Returns (widget, frame) so
    -- subsequent tabs anchor to the previous one's actual frame.
    local function makeTabBtn(label, anchorFrame, dx)
        local widget, frameRef = makeBtn(rightBg, label, 70, 22, nil)
        widget:ClearAllPoints()
        if anchorFrame then
            widget:SetPoint("LEFT", anchorFrame, "RIGHT", dx or 4, 0)
        else
            widget:SetPoint("TOPLEFT", rightBg, "TOPLEFT", 6, -4)
        end
        return widget, frameRef
    end
    local watchTabBtn,  watchTabFrame  = makeTabBtn("Watch",  nil, 0)
    local eventsTabBtn, eventsTabFrame = makeTabBtn("Events", watchTabFrame, 4)
    local fnlogTabBtn,  fnlogTabFrame  = makeTabBtn("FnLog",  eventsTabFrame, 4)
    mod._watchTabBtn  = watchTabBtn
    mod._eventsTabBtn = eventsTabBtn
    mod._fnlogTabBtn  = fnlogTabBtn

    -- ----- Watch panel (existing watch list, now in a sub-frame) ------
    local watchPanel = CreateFrame("Frame", nil, rightBg)
    watchPanel:SetPoint("TOPLEFT",     watchTabFrame, "BOTTOMLEFT", -2, -4)
    watchPanel:SetPoint("BOTTOMRIGHT", rightBg,       "BOTTOMRIGHT", -6, 6)
    mod._watchPanel = watchPanel

    local watchTitle = watchPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    watchTitle:SetPoint("TOPLEFT", 6, -2)
    watchTitle:SetText("|cffd87f3aWatch list|r  |cffaaaaaaright-click a tree row to pin|r")
    mod._watchTitle = watchTitle

    local watchScroll, watchContent, watchScrollFrame = makeScroll(watchPanel, { 6, -18 }, { -2, 6 })
    mod._watchScroll       = watchScroll
    mod._watchContent      = watchContent
    mod._watchScrollFrame  = watchScrollFrame
    mod._watchRows = {}

    -- ----- Events panel ------------------------------------------------
    local eventsPanel = CreateFrame("Frame", nil, rightBg)
    eventsPanel:SetPoint("TOPLEFT",     watchTabFrame, "BOTTOMLEFT", -2, -4)
    eventsPanel:SetPoint("BOTTOMRIGHT", rightBg,       "BOTTOMRIGHT", -6, 6)
    eventsPanel:Hide()
    mod._eventsPanel = eventsPanel

    -- Top: input + Add button
    local evtInput, evtInputFrame, _evtHint, evtInputEb = makeInput(eventsPanel, 180, 22, "PLAYER_LOGIN, BAG_UPDATE, ...")
    evtInput:ClearAllPoints()
    evtInput:SetPoint("TOPLEFT", eventsPanel, "TOPLEFT", 6, -2)
    evtInputEb:SetScript("OnEnterPressed", function(self)
        UI.AddEventWatchFromInput(self:GetText()); self:SetText(""); self:ClearFocus()
    end)
    evtInputEb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText("") end)
    mod._evtInput = evtInputEb

    local addEvtBtn, addEvtBtnFrame = makeBtn(eventsPanel, "Add", 50, 22, function()
        UI.AddEventWatchFromInput(evtInputEb:GetText() or ""); evtInputEb:SetText("")
    end)
    addEvtBtn:ClearAllPoints()
    addEvtBtn:SetPoint("LEFT", evtInputFrame, "RIGHT", 4, 0)

    local clearLogBtn, clearLogBtnFrame = makeBtn(eventsPanel, "Clear", 60, 22, function()
        if ns.ClearEventLog then ns.ClearEventLog() end
        UI.RefreshEventsPane()
    end)
    clearLogBtn:ClearAllPoints()
    clearLogBtn:SetPoint("LEFT", addEvtBtnFrame, "RIGHT", 4, 0)

    -- Watched-events list (small)
    local watchListLabel = eventsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    watchListLabel:SetPoint("TOPLEFT", evtInputFrame, "BOTTOMLEFT", 0, -8)
    watchListLabel:SetText("|cffd87f3aWatching:|r")

    -- Watch list ScrollFrame: anchored TOPLEFT below the label, BOTTOMRIGHT
    -- right-margin only (height is fixed via SetHeight). Use a custom build
    -- since makeScroll's anchor pattern is bottom-anchored; here we're using
    -- explicit SetPoint pairs.
    local watchListScroll, watchListContent
    local watchListScrollFrame
    do
        local s = Gui and Gui:Create("ScrollFrame")
        if s then
            s:SetParent(eventsPanel); s:ClearAllPoints()
            s:SetPoint("TOPLEFT", watchListLabel, "BOTTOMLEFT", 0, -2)
            s:SetPoint("RIGHT",   eventsPanel,    "RIGHT",      -2, 0)
            s:SetHeight(90)
            watchListScroll       = s
            watchListContent      = s.content
            watchListScrollFrame  = s.scrollFrame or s
        else
            local raw = CreateFrame("ScrollFrame", nil, eventsPanel, "UIPanelScrollFrameTemplate")
            raw:SetPoint("TOPLEFT", watchListLabel, "BOTTOMLEFT", 0, -2)
            raw:SetPoint("RIGHT", eventsPanel, "RIGHT", -28, 0)
            raw:SetHeight(90)
            local content = CreateFrame("Frame", nil, raw); content:SetSize(1,1); raw:SetScrollChild(content)
            watchListScroll       = raw
            watchListContent      = content
            watchListScrollFrame  = raw
        end
    end
    mod._evtListScroll       = watchListScroll
    mod._evtListContent      = watchListContent
    mod._evtListScrollFrame  = watchListScrollFrame
    mod._evtListRows         = {}

    -- Recent fires log
    local logLabel = eventsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Anchor to the inner Blizzard scrollFrame, not the kit widget table.
    -- In the kit path watchListScroll is a Lua table (the widget); SetPoint
    -- on a FontString expects a Frame as relativeTo and throws
    -- "FontString:SetPoint(): Wrong object type for function" when it gets
    -- a non-Frame.
    logLabel:SetPoint("TOPLEFT", watchListScrollFrame, "BOTTOMLEFT", 0, -8)
    logLabel:SetText("|cffd87f3aRecent fires|r  |cffaaaaaa(newest at bottom)|r")
    mod._evtLogLabel = logLabel

    local logScroll, logContent, logScrollFrame
    do
        local s = Gui and Gui:Create("ScrollFrame")
        if s then
            s:SetParent(eventsPanel); s:ClearAllPoints()
            s:SetPoint("TOPLEFT",     logLabel,    "BOTTOMLEFT",  0, -2)
            s:SetPoint("BOTTOMRIGHT", eventsPanel, "BOTTOMRIGHT", -2, 6)
            logScroll       = s
            logContent      = s.content
            logScrollFrame  = s.scrollFrame or s
        else
            local raw = CreateFrame("ScrollFrame", nil, eventsPanel, "UIPanelScrollFrameTemplate")
            raw:SetPoint("TOPLEFT",     logLabel,    "BOTTOMLEFT", 0, -2)
            raw:SetPoint("BOTTOMRIGHT", eventsPanel, "BOTTOMRIGHT", -28, 6)
            local content = CreateFrame("Frame", nil, raw); content:SetSize(1,1); raw:SetScrollChild(content)
            logScroll       = raw
            logContent      = content
            logScrollFrame  = raw
        end
    end
    mod._evtLogScroll       = logScroll
    mod._evtLogContent      = logContent
    mod._evtLogScrollFrame  = logScrollFrame
    mod._evtLogText = logContent:CreateFontString(nil, "ARTWORK", "ChatFontSmall")
    mod._evtLogText:SetPoint("TOPLEFT", 4, -2)
    mod._evtLogText:SetJustifyH("LEFT"); mod._evtLogText:SetJustifyV("TOP")
    mod._evtLogText:SetWordWrap(true)

    -- ----- FnLog panel -------------------------------------------------
    local fnPanel = CreateFrame("Frame", nil, rightBg)
    fnPanel:SetPoint("TOPLEFT",     watchTabFrame, "BOTTOMLEFT", -2, -4)
    fnPanel:SetPoint("BOTTOMRIGHT", rightBg,       "BOTTOMRIGHT", -6, 6)
    fnPanel:Hide()
    mod._fnPanel = fnPanel

    local fnInput, fnInputFrame, _fnHint, fnInputEb = makeInput(fnPanel, 180, 22, "_G.UIParent.Show ...")
    fnInput:ClearAllPoints()
    fnInput:SetPoint("TOPLEFT", fnPanel, "TOPLEFT", 6, -2)
    fnInputEb:SetScript("OnEnterPressed", function(self)
        UI.AddFnLogFromInput(self:GetText()); self:SetText(""); self:ClearFocus()
    end)
    fnInputEb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText("") end)
    mod._fnInput = fnInputEb

    local addFnBtn, addFnBtnFrame = makeBtn(fnPanel, "Add", 50, 22, function()
        UI.AddFnLogFromInput(fnInputEb:GetText() or ""); fnInputEb:SetText("")
    end)
    addFnBtn:ClearAllPoints()
    addFnBtn:SetPoint("LEFT", fnInputFrame, "RIGHT", 4, 0)

    local clearFnBtn, clearFnBtnFrame = makeBtn(fnPanel, "Clear", 60, 22, function()
        if ns.ClearFnCallLog then ns.ClearFnCallLog() end
        UI.RefreshFnLogPane()
    end)
    clearFnBtn:ClearAllPoints()
    clearFnBtn:SetPoint("LEFT", addFnBtnFrame, "RIGHT", 4, 0)

    local fnListLabel = fnPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fnListLabel:SetPoint("TOPLEFT", fnInputFrame, "BOTTOMLEFT", 0, -8)
    fnListLabel:SetText("|cffd87f3aWatching:|r")

    local fnListScroll, fnListContent, fnListScrollFrame
    do
        local s = Gui and Gui:Create("ScrollFrame")
        if s then
            s:SetParent(fnPanel); s:ClearAllPoints()
            s:SetPoint("TOPLEFT", fnListLabel, "BOTTOMLEFT", 0, -2)
            s:SetPoint("RIGHT",   fnPanel,     "RIGHT",     -2, 0)
            s:SetHeight(90)
            fnListScroll       = s
            fnListContent      = s.content
            fnListScrollFrame  = s.scrollFrame or s
        else
            local raw = CreateFrame("ScrollFrame", nil, fnPanel, "UIPanelScrollFrameTemplate")
            raw:SetPoint("TOPLEFT", fnListLabel, "BOTTOMLEFT", 0, -2)
            raw:SetPoint("RIGHT",   fnPanel,     "RIGHT", -28, 0)
            raw:SetHeight(90)
            local content = CreateFrame("Frame", nil, raw); content:SetSize(1,1); raw:SetScrollChild(content)
            fnListScroll       = raw
            fnListContent      = content
            fnListScrollFrame  = raw
        end
    end
    mod._fnListScroll       = fnListScroll
    mod._fnListContent      = fnListContent
    mod._fnListScrollFrame  = fnListScrollFrame
    mod._fnListRows         = {}

    local fnLogLabel = fnPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Anchor to inner scrollFrame (see watch panel above for the same fix).
    fnLogLabel:SetPoint("TOPLEFT", fnListScrollFrame, "BOTTOMLEFT", 0, -8)
    fnLogLabel:SetText("|cffd87f3aRecent calls|r")
    mod._fnLogLabel = fnLogLabel

    local fnLogScroll, fnLogContent, fnLogScrollFrame
    do
        local s = Gui and Gui:Create("ScrollFrame")
        if s then
            s:SetParent(fnPanel); s:ClearAllPoints()
            s:SetPoint("TOPLEFT",     fnLogLabel, "BOTTOMLEFT", 0, -2)
            s:SetPoint("BOTTOMRIGHT", fnPanel,    "BOTTOMRIGHT", -2, 6)
            fnLogScroll       = s
            fnLogContent      = s.content
            fnLogScrollFrame  = s.scrollFrame or s
        else
            local raw = CreateFrame("ScrollFrame", nil, fnPanel, "UIPanelScrollFrameTemplate")
            raw:SetPoint("TOPLEFT",     fnLogLabel, "BOTTOMLEFT", 0, -2)
            raw:SetPoint("BOTTOMRIGHT", fnPanel,    "BOTTOMRIGHT", -28, 6)
            local content = CreateFrame("Frame", nil, raw); content:SetSize(1,1); raw:SetScrollChild(content)
            fnLogScroll       = raw
            fnLogContent      = content
            fnLogScrollFrame  = raw
        end
    end
    mod._fnLogScroll       = fnLogScroll
    mod._fnLogContent      = fnLogContent
    mod._fnLogScrollFrame  = fnLogScrollFrame
    mod._fnLogText = fnLogContent:CreateFontString(nil, "ARTWORK", "ChatFontSmall")
    mod._fnLogText:SetPoint("TOPLEFT", 4, -2)
    mod._fnLogText:SetJustifyH("LEFT"); mod._fnLogText:SetJustifyV("TOP")
    mod._fnLogText:SetWordWrap(true)

    -- Tab handlers. Use SetEventListener on the widget when present so the
    -- kit's PlaySound / FireEvent path runs; fall back to SetScript on the
    -- raw frame.
    local function bindTab(btnW, frameRef, tabKey)
        if btnW.SetEventListener then
            btnW:SetEventListener("OnClick", function() UI.SelectRightTab(tabKey) end)
        else
            frameRef:SetScript("OnClick", function() UI.SelectRightTab(tabKey) end)
        end
    end
    bindTab(watchTabBtn,  watchTabFrame,  "watch")
    bindTab(eventsTabBtn, eventsTabFrame, "events")
    bindTab(fnlogTabBtn,  fnlogTabFrame,  "fnlog")

    -- Subscribe to event log changes so the panel auto-refreshes.
    if ns.SubscribeEventLog then
        mod._evtUnsub = ns.SubscribeEventLog(function()
            if mod._activeRightTab == "events" then UI.RefreshEventsPane() end
        end)
    end
    -- Same for fnLog.
    if ns.SubscribeFnLog then
        mod._fnUnsub = ns.SubscribeFnLog(function()
            if mod._activeRightTab == "fnlog" then UI.RefreshFnLogPane() end
        end)
    end

    mod._activeRightTab = "watch"

    -- ===== Init root + first build =====================================
    mod._roots = defaultRoots()
    UI.AddLoadedAddonRoots()  -- session-only: one root per loaded addon
    UI.RestorePinnedRoots()   -- pull persisted user roots from db
    UI.RebuildTree()

    -- 0.5s auto-poll: opt-in via the Live checkbox. Default OFF because
    -- iterating _G and visible nodes propagates taint to anything we touch,
    -- and a persistent ticker that taints once-per-second will eventually
    -- get blamed for blocked secure-code operations downstream. The user
    -- can flip Live on for short bursts, or just hit Refresh on demand.
    if not _ticker and C_Timer and C_Timer.NewTicker then
        _ticker = C_Timer.NewTicker(0.5, function()
            if ns.IsLive and ns.IsLive() then UI.RefreshLive() end
        end)
    end
end

-- Build a tree row.
local function buildTreeRow(parent, mod)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)

    local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    hov:SetColorTexture(0.45, 0.32, 0.15, 0.30); hov:SetAllPoints(); hov:Hide()
    row._hov = hov

    local toggle = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toggle:SetPoint("LEFT", row, "LEFT", 4, 0)
    toggle:SetWidth(14); toggle:SetJustifyH("CENTER")
    toggle:SetTextColor(0.85, 0.7, 0.4, 1)
    row._toggle = toggle

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", toggle, "RIGHT", 2, 0)
    text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    text:SetJustifyH("LEFT"); text:SetWordWrap(false); text:SetMaxLines(1)
    row._text = text

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnEnter", function(self)
        self._hov:Show()
        if self._node then UI.ShowRowTooltip(self) end
    end)
    row:SetScript("OnLeave", function(self)
        self._hov:Hide()
        if GameTooltip then GameTooltip:Hide() end
    end)
    row:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and self._node then
            local n = self._node
            local v = n.getter()
            -- Skip expand on protected tables — iterating them taints us.
            if type(v) == "table" and not isUntouchable(v) then
                n.expanded = not n.expanded
                UI.RebuildTree()
            end
        elseif button == "RightButton" and self._node then
            UI.PinPath(self._node.path)
        end
    end)
    return row
end

local function rowText(node)
    local v = node.getter()
    local prefix = string.rep("  ", node.depth - 1)  -- depth 0 = root, depth 1 = no indent
    if node.depth == 0 then prefix = "" end
    local keyStr = "|cffffe6a8" .. escapeBars(node.key) .. "|r"
    local sep = "  : "
    return prefix .. keyStr .. sep .. fmtValue(v)
end

local function rowToggleSymbol(node)
    local v = node.getter()
    if type(v) ~= "table" then return " " end
    if isUntouchable(v) then return "X" end  -- protected; can't expand
    return node.expanded and "v" or ">"
end

-- Recompute the flat visible list. Called when tree structure changes
-- (expand/collapse/filter/refresh) - not on every scroll.
function UI.RecomputeVisible()
    local mod = _activeMod
    if not mod then return end
    mod._visible = flatten(mod._roots, _filterText or "")
end

-- Render only the rows currently inside the scroll viewport. Re-uses the
-- row buttons in mod._treeRows; creates lazily up to VISIBLE_ROW_BUFFER.
function UI.RenderVisibleWindow()
    local mod = _activeMod
    if not (mod and mod._treeContent and mod._visible) then return end

    local total = #mod._visible
    -- Set virtual content height so the scrollbar reflects the full size.
    mod._treeContent:SetHeight(math.max(1, total * ROW_H))

    -- The widget's GetWidth pass-through works for sizing rows, but
    -- GetVerticalScroll / GetHeight live only on the inner Blizzard
    -- scrollFrame. _treeScrollFrame points at it on both backends.
    local sf        = mod._treeScrollFrame or mod._treeScroll
    local scrollY   = sf:GetVerticalScroll() or 0
    local viewportH = sf:GetHeight() or 0
    local firstIdx  = math.max(1, math.floor(scrollY / ROW_H) + 1)
    local rowsToShow = math.min(
        VISIBLE_ROW_BUFFER,
        math.ceil(viewportH / ROW_H) + 2,   -- +2 for partial top/bottom rows
        total - firstIdx + 1
    )

    -- Hide every pooled row first; we'll re-show only the ones we need.
    for _, row in ipairs(mod._treeRows) do row:Hide() end

    for i = 1, math.max(0, rowsToShow) do
        local nodeIdx = firstIdx + i - 1
        local node = mod._visible[nodeIdx]
        if not node then break end

        local row = mod._treeRows[i]
        if not row then
            row = buildTreeRow(mod._treeContent, mod)
            mod._treeRows[i] = row
        end
        row._node = node
        row._toggle:SetText(rowToggleSymbol(node))
        row._text:SetText(rowText(node))
        row:ClearAllPoints()
        row:SetWidth((mod._treeScroll:GetWidth() or 400) - 8)
        -- Position in absolute treeContent coordinates so scrolling the
        -- ScrollFrame moves the row naturally with the content.
        row:SetPoint("TOPLEFT", mod._treeContent, "TOPLEFT", 0, -((nodeIdx - 1) * ROW_H))
        row:Show()
    end

    sf:UpdateScrollChildRect()
end

function UI.RebuildTree()
    UI.RecomputeVisible()
    UI.RenderVisibleWindow()
    UI.RefreshWatch()
end

-- Lighter pass: only update text on visible rows, no rebuild.
function UI.RefreshLive()
    local mod = _activeMod
    if not (mod and mod._treeRows) then return end
    for _, row in ipairs(mod._treeRows) do
        if row:IsShown() and row._node then
            row._toggle:SetText(rowToggleSymbol(row._node))
            row._text:SetText(rowText(row._node))
        end
    end
    UI.RefreshWatchValues()
end

-- ----- Watch list operations --------------------------------------------
function UI.PinPath(path)
    if not path or path == "" then return end
    if path == "_G" then
        if ns.out then ns.out("can't pin _G itself; pin a child key.") end
        return
    end
    if not ns.AddWatch then return end
    if ns.AddWatch(path) then
        if ns.out then ns.out("pinned to watch: " .. path) end
        UI.RefreshWatch()
    end
end

function UI.RefreshWatch()
    local mod = _activeMod
    if not mod or not mod._watchContent then return end
    local watch = (ns.GetWatch and ns.GetWatch()) or {}

    for _, row in ipairs(mod._watchRows) do row:Hide() end
    local y = 0
    for i, path in ipairs(watch) do
        local row = mod._watchRows[i]
        if not row then
            row = CreateFrame("Frame", nil, mod._watchContent)
            row:SetHeight(ROW_H)
            local rmBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            rmBtn:SetSize(18, 18); rmBtn:SetPoint("LEFT", row, "LEFT", 0, 0); rmBtn:SetText("x")
            rmBtn:SetScript("OnClick", function() if ns.RemoveWatch then ns.RemoveWatch(row._path); UI.RefreshWatch() end end)
            local pathFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            pathFs:SetPoint("LEFT", rmBtn, "RIGHT", 4, 0)
            pathFs:SetWidth(180); pathFs:SetJustifyH("LEFT"); pathFs:SetWordWrap(false); pathFs:SetMaxLines(1)
            pathFs:SetTextColor(0.85, 0.7, 0.4, 1)
            row._pathFs = pathFs
            local valFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            valFs:SetPoint("LEFT", pathFs, "RIGHT", 6, 0)
            valFs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            valFs:SetJustifyH("LEFT"); valFs:SetWordWrap(false); valFs:SetMaxLines(1)
            row._valFs = valFs
            mod._watchRows[i] = row
        end
        row._path = path
        row._pathFs:SetText(escapeBars(path))
        row._valFs:SetText(fmtValue(resolvePath(path)))
        row:ClearAllPoints()
        row:SetWidth((mod._watchScroll:GetWidth() or 300) - 8)
        row:SetPoint("TOPLEFT", mod._watchContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + ROW_H
    end
    if y < 1 then y = 1 end
    mod._watchContent:SetHeight(y)
    if mod._safeUpdateScrollRect then mod._safeUpdateScrollRect(mod._watchScroll) end
end

-- Live-only refresh: just the value text, not the layout.
function UI.RefreshWatchValues()
    local mod = _activeMod
    if not mod or not mod._watchRows then return end
    for _, row in ipairs(mod._watchRows) do
        if row:IsShown() and row._path then
            row._valFs:SetText(fmtValue(resolvePath(row._path)))
        end
    end
end

function UI.OnTabShow(mod)
    _activeMod = mod
    if not mod._roots then
        mod._roots = defaultRoots()
        UI.RestorePinnedRoots()
    end
    UI.RebuildTree()
    if UI.RefreshEventsPane then UI.RefreshEventsPane() end
end

-- ----- Right-pane tabs (Watch | Events | FnLog) -------------------------
function UI.SelectRightTab(name)
    local mod = _activeMod
    if not mod then return end
    mod._activeRightTab = name
    if mod._watchPanel  then mod._watchPanel:Hide()  end
    if mod._eventsPanel then mod._eventsPanel:Hide() end
    if mod._fnPanel     then mod._fnPanel:Hide()     end
    if name == "events" then
        if mod._eventsPanel then mod._eventsPanel:Show() end
        UI.RefreshEventsPane()
    elseif name == "fnlog" then
        if mod._fnPanel then mod._fnPanel:Show() end
        UI.RefreshFnLogPane()
    else
        if mod._watchPanel then mod._watchPanel:Show() end
    end
end

-- ----- Events pane ------------------------------------------------------
function UI.AddEventWatchFromInput(text)
    text = text and text:match("^%s*(.-)%s*$") or ""
    if text == "" then return end
    -- Uppercase WoW event names by convention.
    local eventName = text:upper()
    if not ns.AddEventWatch then return end
    if ns.AddEventWatch(eventName) then
        if ns.out then ns.out("watching event: " .. eventName) end
        UI.RefreshEventsPane()
    else
        if ns.out then ns.out("already watching: " .. eventName) end
    end
end

local function fmtEventTime(ts)
    if not ts then return "?" end
    if date then return date("%H:%M:%S", ts) end
    return tostring(ts)
end

local function buildEventListRow(parent, mod)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(20)

    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(18, 18)
    cb:SetPoint("LEFT", row, "LEFT", 0, 0)
    row._cb = cb

    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetMaxLines(1)
    row._fs = fs

    local rm = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    rm:SetSize(18, 18)
    rm:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    rm:SetText("x")
    row._rm = rm

    return row
end

function UI.RefreshEventsPane()
    local mod = _activeMod
    if not (mod and mod._evtListContent) then return end

    -- ---- Watched events list ----
    local watches = ns.GetEventWatches and ns.GetEventWatches() or {}
    local names = {}
    for k in pairs(watches) do names[#names + 1] = k end
    table.sort(names)

    for _, row in ipairs(mod._evtListRows) do row:Hide() end

    local y = 0
    for i, name in ipairs(names) do
        local w = watches[name]
        local row = mod._evtListRows[i]
        if not row then
            row = buildEventListRow(mod._evtListContent, mod)
            mod._evtListRows[i] = row
        end
        row._evtName = name
        row._cb:SetChecked(w.active and true or false)
        row._cb:SetScript("OnClick", function(self)
            if ns.SetEventWatchActive then ns.SetEventWatchActive(name, self:GetChecked() and true or false) end
        end)
        local label = name
        if (w.fireCount or 0) > 0 then
            label = string.format("%s  |cffaaaaaa(%dx)|r", name, w.fireCount)
        end
        if not w.active then
            label = label .. "  |cffff8080(off)|r"
        end
        row._fs:SetText(label)
        row._rm:SetScript("OnClick", function()
            if ns.RemoveEventWatch then ns.RemoveEventWatch(name) end
            UI.RefreshEventsPane()
        end)
        row:ClearAllPoints()
        row:SetWidth((mod._evtListScroll:GetWidth() or 300) - 8)
        row:SetPoint("TOPLEFT", mod._evtListContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + 20
    end
    if y < 1 then y = 1 end
    mod._evtListContent:SetHeight(y)
    if mod._safeUpdateScrollRect then mod._safeUpdateScrollRect(mod._evtListScroll) end

    -- ---- Recent fires log ----
    local log = ns.GetEventLog and ns.GetEventLog() or {}
    local lines = {}
    for _, e in ipairs(log) do
        lines[#lines + 1] = string.format(
            "|cffaaaaaa[%s]|r |cffd87f3a%s|r %s",
            fmtEventTime(e.ts), e.event, e.args or "")
    end
    if mod._evtLogText then
        local sw = (mod._evtLogScroll:GetWidth() or 300) - 8
        mod._evtLogText:SetText(table.concat(lines, "\n"))
        mod._evtLogText:SetWidth(sw)
        local h = mod._evtLogText:GetStringHeight() + 8
        mod._evtLogContent:SetSize(sw, math.max(1, h))
        if mod._safeUpdateScrollRect then mod._safeUpdateScrollRect(mod._evtLogScroll) end
        -- Auto-scroll to bottom (newest line). Inner Blizzard scrollFrame
        -- only.
        local sf = mod._evtLogScrollFrame or mod._evtLogScroll
        if sf.SetVerticalScroll then
            sf:SetVerticalScroll(math.max(0, h - (sf:GetHeight() or 0)))
        end
    end

    if mod._evtLogLabel then
        mod._evtLogLabel:SetText(string.format(
            "|cffd87f3aRecent fires|r  |cffaaaaaa(%d entries, newest at bottom)|r", #log))
    end
end

-- ----- FnLog pane -------------------------------------------------------
function UI.AddFnLogFromInput(text)
    text = text and text:match("^%s*(.-)%s*$") or ""
    if text == "" then return end
    -- Split on the LAST dot: parent.fn -> "parent", "fn".
    local parentPath, fnName = text:match("^(.-)%.([^%.]+)$")
    if not parentPath or parentPath == "" or not fnName or fnName == "" then
        if ns.out then ns.out("usage: <parent>.<fn> -  e.g. _G.UIParent.Show") end
        return
    end
    if not parentPath:match("^_G") then parentPath = "_G." .. parentPath end
    if not ns.AddFnLog then return end
    if ns.AddFnLog(parentPath, fnName) then
        if ns.out then ns.out("logging calls to " .. parentPath .. "." .. fnName) end
        UI.RefreshFnLogPane()
    else
        if ns.out then ns.out("already logging or fn not found: " .. parentPath .. "." .. fnName) end
    end
end

local function buildFnListRow(parent, mod)
    -- Same shape as the event watch row: checkbox + label + remove.
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(20)

    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(18, 18)
    cb:SetPoint("LEFT", row, "LEFT", 0, 0)
    row._cb = cb

    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetMaxLines(1)
    row._fs = fs

    local rm = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    rm:SetSize(18, 18)
    rm:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    rm:SetText("x")
    row._rm = rm

    return row
end

function UI.RefreshFnLogPane()
    local mod = _activeMod
    if not (mod and mod._fnListContent) then return end

    -- Watching list
    local logs = ns.GetFnLogs and ns.GetFnLogs() or {}
    local keys = {}
    for k in pairs(logs) do keys[#keys + 1] = k end
    table.sort(keys)

    for _, row in ipairs(mod._fnListRows) do row:Hide() end

    local y = 0
    for i, key in ipairs(keys) do
        local w = logs[key]
        local row = mod._fnListRows[i]
        if not row then
            row = buildFnListRow(mod._fnListContent, mod)
            mod._fnListRows[i] = row
        end
        row._cb:SetChecked(w.active and true or false)
        row._cb:SetScript("OnClick", function(self)
            if ns.SetFnLogActive then ns.SetFnLogActive(w.parentPath, w.fnName, self:GetChecked() and true or false) end
        end)
        local label = w.parentPath .. "." .. w.fnName
        if (w.callCount or 0) > 0 then
            label = string.format("%s  |cffaaaaaa(%dx)|r", label, w.callCount)
        end
        if not w.active then label = label .. "  |cffff8080(off)|r" end
        row._fs:SetText(label)
        row._rm:SetScript("OnClick", function()
            if ns.RemoveFnLog then ns.RemoveFnLog(w.parentPath, w.fnName) end
            UI.RefreshFnLogPane()
        end)
        row:ClearAllPoints()
        row:SetWidth((mod._fnListScroll:GetWidth() or 300) - 8)
        row:SetPoint("TOPLEFT", mod._fnListContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + 20
    end
    if y < 1 then y = 1 end
    mod._fnListContent:SetHeight(y)
    if mod._safeUpdateScrollRect then mod._safeUpdateScrollRect(mod._fnListScroll) end

    -- Recent calls log
    local function fmtTime(ts)
        if not ts then return "?" end
        if date then return date("%H:%M:%S", ts) end
        return tostring(ts)
    end
    local log = ns.GetFnCallLog and ns.GetFnCallLog() or {}
    local lines = {}
    for _, e in ipairs(log) do
        lines[#lines + 1] = string.format(
            "|cffaaaaaa[%s]|r |cffd87f3a%s.%s|r(%s)  |cffaaaaaa->|r %s",
            fmtTime(e.ts), e.parentPath, e.fnName, e.args or "", e.returns or "")
    end
    if mod._fnLogText then
        local sw = (mod._fnLogScroll:GetWidth() or 300) - 8
        mod._fnLogText:SetText(table.concat(lines, "\n"))
        mod._fnLogText:SetWidth(sw)
        local h = mod._fnLogText:GetStringHeight() + 8
        mod._fnLogContent:SetSize(sw, math.max(1, h))
        if mod._safeUpdateScrollRect then mod._safeUpdateScrollRect(mod._fnLogScroll) end
        local sf = mod._fnLogScrollFrame or mod._fnLogScroll
        if sf.SetVerticalScroll then
            sf:SetVerticalScroll(math.max(0, h - (sf:GetHeight() or 0)))
        end
    end
    if mod._fnLogLabel then
        mod._fnLogLabel:SetText(string.format(
            "|cffd87f3aRecent calls|r  |cffaaaaaa(%d entries)|r", #log))
    end
end

-- ----- Multi-root API ---------------------------------------------------
-- Public helpers used by slash commands (mouseover / find / pin path).
-- All operations rebuild the tree.

local function specMatches(a, b)
    if a.kind ~= b.kind then return false end
    if a.kind == "path" then return a.path == b.path end
    if a.kind == "snapshot" then return a.name == b.name end
    return false
end

function UI.HasRoot(spec)
    local mod = _activeMod
    if not mod or not mod._roots then return false end
    for _, root in ipairs(mod._roots) do
        if root._spec and specMatches(root._spec, spec) then return true end
    end
    return false
end

-- Push a new root. `persist` controls whether to save it to db.profile.
-- Path-kind roots default to persistent; snapshots are session-only.
function UI.AddRoot(spec, persist)
    local mod = _activeMod
    if not mod then
        if ns.out then ns.out("Inspector not built yet; open the tab first.") end
        return false
    end
    mod._roots = mod._roots or defaultRoots()
    if UI.HasRoot(spec) then
        if ns.out then ns.out("already pinned: " .. (spec.path or spec.name or "?")) end
        return false
    end
    local root = makeRootFromSpec(spec)
    if not root then return false end
    mod._roots[#mod._roots + 1] = root
    if persist == nil then persist = (spec.kind == "path") end
    if persist and ns.AddPinnedRoot then ns.AddPinnedRoot(spec) end
    UI.RebuildTree()
    return true
end

-- Remove a root by spec match. The first root (_G) is permanent.
function UI.RemoveRoot(spec)
    local mod = _activeMod
    if not mod or not mod._roots then return false end
    for i = #mod._roots, 2, -1 do  -- never remove index 1 (_G)
        local root = mod._roots[i]
        if root._spec and specMatches(root._spec, spec) then
            table.remove(mod._roots, i)
            if ns.RemovePinnedRoot then ns.RemovePinnedRoot(spec) end
            UI.RebuildTree()
            return true
        end
    end
    return false
end

-- Inject one session-only root per loaded addon (their _G global, or their
-- Cairn.Addon.registry entry as fallback). NOT persisted: recomputed each
-- time the Inspector tab is built, so disabled addons disappear cleanly.
function UI.AddLoadedAddonRoots()
    if not _activeMod then return end
    _activeMod._roots = _activeMod._roots or defaultRoots()
    local specs = loadedAddonSpecs()
    for _, spec in ipairs(specs) do
        if not UI.HasRoot(spec) then
            local root = makeRootFromSpec(spec)
            if root then
                _activeMod._roots[#_activeMod._roots + 1] = root
            end
        end
    end
end

-- Called once at first build to load persisted roots from db.
function UI.RestorePinnedRoots()
    if not (ns.GetPinnedRoots and _activeMod) then return end
    local saved = ns.GetPinnedRoots()
    for _, spec in ipairs(saved) do
        if not UI.HasRoot(spec) then
            local root = makeRootFromSpec(spec)
            if root then _activeMod._roots[#_activeMod._roots + 1] = root end
        end
    end
end

-- ----- Live mouseover ----------------------------------------------------
local _mouseoverTicker
local _mouseoverEnabled = false

function UI.IsMouseoverEnabled() return _mouseoverEnabled end

function UI.SetMouseoverEnabled(on)
    _mouseoverEnabled = on and true or false
    local mod = _activeMod
    local spec = { kind = "live_mouseover" }

    if _mouseoverEnabled then
        if mod and not UI.HasRoot(spec) then
            UI.AddRoot(spec, false)  -- session-only root
        end
        if not _mouseoverTicker and C_Timer and C_Timer.NewTicker then
            _mouseoverTicker = C_Timer.NewTicker(0.2, function()
                if not _mouseoverEnabled then return end
                -- Cheap refresh of visible row text only - the @mouseover
                -- root's getter resolves to the current focus on every read.
                if UI.RefreshLive then UI.RefreshLive() end
            end)
        end
    else
        UI.RemoveRoot(spec)
        if _mouseoverTicker then
            _mouseoverTicker:Cancel()
            _mouseoverTicker = nil
        end
    end
end

-- ----- Find / Starts entry point (used by toolbar buttons) --------------
function UI.RunFind(pattern, mode)
    pattern = pattern and pattern:match("^%s*(.-)%s*$") or ""
    if pattern == "" then
        if ns.out then ns.out("type a search term in the box first.") end
        return
    end
    local results, count = UI.FindInTable(_G, pattern, mode or "contains")
    if not results or count == 0 then
        if ns.out then ns.out("no matches for '" .. pattern .. "' in _G") end
        return
    end
    local label = string.format("%s '%s' in _G (%d)",
        mode == "prefix" and "starts" or "find", pattern, count)
    UI.AddSnapshotRoot(label, results)
    if ns.out then ns.out("pinned: " .. label) end
end

-- ----- FStack / ETrace pass-throughs ------------------------------------
function UI.OpenFStack()
    if SlashCmdList and SlashCmdList.FRAMESTACK then
        SlashCmdList.FRAMESTACK("")
        return
    end
    if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_DebugTools") end
    if FrameStackTooltip and FrameStackTooltip.Toggle then
        FrameStackTooltip:Toggle()
    elseif ns.out then
        ns.out("frame stack tool unavailable on this client.")
    end
end

function UI.OpenETrace()
    for _, key in ipairs({ "EVENTTRACE", "ETRACE" }) do
        if SlashCmdList and SlashCmdList[key] then
            SlashCmdList[key]("")
            return
        end
    end
    if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_EventTrace") end
    if EventTrace and EventTrace.Show then
        if EventTrace:IsShown() then EventTrace:Hide() else EventTrace:Show() end
    elseif ns.out then
        ns.out("event trace tool unavailable on this client.")
    end
end

function UI.ListRoots()
    local mod = _activeMod
    if not mod or not mod._roots then return {} end
    local out = {}
    for i, root in ipairs(mod._roots) do
        out[i] = { name = root.key, kind = root._spec and root._spec.kind or "?", path = root.path }
    end
    return out
end

-- ----- Snapshot root helper ---------------------------------------------
-- Used by find / startswith / mouseover to pin a synthetic table as a
-- top-level root. Snapshot roots are session-only (not persisted).
function UI.AddSnapshotRoot(name, value)
    if not name or name == "" then return false end
    if type(value) ~= "table" then return false end
    return UI.AddRoot({ kind = "snapshot", name = name, value = value }, false)
end

-- ----- Search helpers ---------------------------------------------------
-- Iterate `parent` and return a synthetic table containing matching keys.
-- `mode` is "contains" (substring) or "prefix" (starts-with). Case-insensitive.
function UI.FindInTable(parent, pattern, mode)
    if type(parent) ~= "table" or isUntouchable(parent) then return nil, 0 end
    if type(pattern) ~= "string" or pattern == "" then return nil, 0 end
    local lpat = pattern:lower()
    local out = {}
    local count = 0
    pcall(function()
        for k, v in pairs(parent) do
            if type(k) == "string" then
                local lk = k:lower()
                local hit
                if mode == "prefix" then
                    hit = lk:sub(1, #lpat) == lpat
                else
                    hit = lk:find(lpat, 1, true) ~= nil
                end
                if hit then
                    out[k] = v
                    count = count + 1
                end
            end
        end
    end)
    return out, count
end

-- ----- Row tooltip ------------------------------------------------------
-- Show a tooltip with frame metadata when hovering a row whose value is a
-- frame-like object. Cheap when the value is a primitive (no tooltip).
function UI.ShowRowTooltip(row)
    local node = row._node
    if not (node and GameTooltip) then return end
    local v
    pcall(function() v = node.getter() end)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(node.path or node.key)
    GameTooltip:AddLine("type: " .. type(v), 0.7, 0.7, 0.7, false)

    if type(v) == "table" and not isUntouchable(v) then
        -- Frame metadata: GetObjectType / GetName / GetText / GetTexture.
        local function tryMethod(name)
            local fn = v[name]
            if type(fn) ~= "function" then return nil end
            local ok, result = pcall(fn, v)
            if ok then return result end
            return nil
        end
        local objType = tryMethod("GetObjectType")
        local frameName = tryMethod("GetName")
        local text     = tryMethod("GetText")
        local texture  = tryMethod("GetTexture")
        if objType    then GameTooltip:AddLine("|cffd87f3aobject:|r  " .. tostring(objType), 1, 1, 1) end
        if frameName  then GameTooltip:AddLine("|cffd87f3aname:|r    " .. tostring(frameName), 1, 1, 1) end
        if text       then GameTooltip:AddLine("|cffd87f3atext:|r    " .. tostring(text), 1, 1, 1, true) end
        if texture    then GameTooltip:AddLine("|cffd87f3atexture:|r " .. tostring(texture), 1, 1, 1, true) end
        if node._totalChildren then
            GameTooltip:AddLine("|cffaaaaaa" .. node._totalChildren .. " keys|r")
        end
    elseif type(v) == "string" and #v > 60 then
        GameTooltip:AddLine(v, 0.85, 0.85, 0.85, true)
    end
    GameTooltip:Show()
end

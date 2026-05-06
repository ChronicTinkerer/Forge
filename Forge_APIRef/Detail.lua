-- Forge_APIRef.Detail: detail-pane renderer.
--
-- Public API:
--   ns.Detail.Build(parent)       -- build the pane as a child of `parent`
--   ns.Detail.Render(entry)       -- repaint pane contents from a Lookup entry
--   ns.Detail.Clear()             -- empty the pane (no entry selected)
--   ns.Detail.GetFrame()          -- container ScrollFrame for layout
--
-- Renders the entry schema as a vertically-stacked block of FontStrings.
-- Long content scrolls. Single shared content frame is rebuilt on each
-- Render to keep the impl simple; entries are small (a few hundred chars
-- of text) so the rebuild cost is trivial.

local ADDON, ns = ...

local Detail = {}
ns.Detail = Detail

-- Layout constants.
local PAD       = 8
local LINE_GAP  = 4
local SECTION_GAP = 10

-- Internal handles.
local _scrollWidget  -- Cairn-Gui ScrollFrame widget
local _scrollFrame   -- underlying Blizzard ScrollFrame
local _content       -- content Frame inside the scroll
local _strings       -- table of FontStrings reused across Render calls

-- --------------------------------------------------------------------------
-- Build (idempotent).
-- --------------------------------------------------------------------------
function Detail.Build(parent)
    if _scrollFrame then return _scrollFrame end
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    local sw = Gui and Gui:Create("ScrollFrame")
    if sw then
        sw:SetParent(parent); sw:ClearAllPoints()
        sw:SetPoint("TOPLEFT",     parent, "TOPLEFT",     0, 0)
        sw:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
        _scrollWidget = sw
        _scrollFrame  = sw.scrollFrame
        _content      = sw.content
    else
        local raw = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
        raw:SetPoint("TOPLEFT",     parent, "TOPLEFT",     0, 0)
        raw:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 0)
        local content = CreateFrame("Frame", nil, raw)
        content:SetSize(raw:GetWidth(), 1)
        raw:SetScrollChild(content)
        _scrollFrame = raw
        _content     = content
    end

    _strings = {}
    return _scrollFrame
end

-- --------------------------------------------------------------------------
-- Internal: stack of FontStrings, claimed sequentially per Render and
-- hidden afterwards if not used.
-- --------------------------------------------------------------------------
local function claimString(idx, fontObject)
    local s = _strings[idx]
    if not s then
        s = _content:CreateFontString(nil, "OVERLAY", fontObject or "GameFontNormal")
        s:SetJustifyH("LEFT")
        s:SetJustifyV("TOP")
        s:SetWordWrap(true)
        _strings[idx] = s
    else
        s:SetFontObject(fontObject or "GameFontNormal")
    end
    s:Show()
    return s
end

local function hideTrailing(fromIdx)
    for i = fromIdx, #_strings do
        if _strings[i] then _strings[i]:Hide() end
    end
end

-- --------------------------------------------------------------------------
-- Helpers to format individual sections.
-- --------------------------------------------------------------------------
local function formatParam(p)
    local nilable = p.nilable and "?" or ""
    local def     = (p.default ~= nil) and (" = " .. tostring(p.default)) or ""
    return string.format("|cffd87f3a%s|r : |cffecbc2a%s%s|r%s",
        tostring(p.name or "?"), tostring(p.type or "?"), nilable, def)
end

local function formatField(f)
    return formatParam(f)  -- structures use the same shape
end

local function flagLine(entry)
    local parts = {}
    if entry.secretArguments then
        parts[#parts + 1] = "|cff5588ff" .. tostring(entry.secretArguments) .. "|r"
    end
    if entry.hasRestrictions then
        parts[#parts + 1] = "|cffff5555HasRestrictions|r"
    end
    if entry.mayReturnNothing then
        parts[#parts + 1] = "|cffaaaaaaMayReturnNothing|r"
    end
    if entry.deprecated then
        parts[#parts + 1] = "|cffff8c00Deprecated " .. tostring(entry.deprecated) .. "|r"
    end
    if entry.removed then
        parts[#parts + 1] = "|cffff5555Removed " .. tostring(entry.removed) .. "|r"
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "  ")
end

-- --------------------------------------------------------------------------
-- Render: build a stack of FontStrings from the entry. Each section gets a
-- header line ("Arguments", "Returns", ...) plus body lines.
-- --------------------------------------------------------------------------
function Detail.Render(entry)
    if not _content then return end
    if not entry then Detail.Clear(); return end

    local cw = _scrollFrame and _scrollFrame:GetWidth() or 400
    local strW = math.max(100, cw - 2 * PAD - 4)

    local idx = 0
    local y = -PAD

    local function addLine(text, fontObject, gap)
        idx = idx + 1
        local s = claimString(idx, fontObject)
        s:SetText(text)
        s:SetWidth(strW)
        s:ClearAllPoints()
        s:SetPoint("TOPLEFT", _content, "TOPLEFT", PAD, y)
        local h = s:GetStringHeight() or 14
        y = y - h - (gap or LINE_GAP)
    end

    local function addSectionHeader(text)
        addLine("|cffd87f3a" .. text .. "|r", "GameFontNormalLarge", LINE_GAP)
    end

    -- Title.
    local fullName = entry.namespace
        and (entry.namespace .. "." .. (entry.name or ""))
        or  (entry.name or "(unknown)")
    addLine("|cffffffff" .. fullName .. "|r", "GameFontHighlightLarge", LINE_GAP)

    -- Type tag + flags.
    local typeTag = "|cffaaaaaa" .. tostring(entry.type or "?") .. "|r"
    local flags = flagLine(entry)
    addLine(flags and (typeTag .. "    " .. flags) or typeTag, "GameFontDisableSmall", SECTION_GAP)

    -- Signature (functions only).
    if entry.signature then
        addLine("|cff88ddffSignature|r", "GameFontNormal", LINE_GAP)
        addLine(entry.signature, "GameFontHighlight", SECTION_GAP)
    end

    -- Description.
    if entry.desc and entry.desc ~= "" then
        addSectionHeader("Description")
        addLine(entry.desc, "GameFontHighlight", SECTION_GAP)
    end

    -- Arguments / Params.
    if entry.params and #entry.params > 0 then
        addSectionHeader("Arguments")
        for _, p in ipairs(entry.params) do
            addLine("  " .. formatParam(p), "GameFontHighlight", LINE_GAP)
        end
        y = y - (SECTION_GAP - LINE_GAP)
    end

    -- Returns.
    if entry.returns and #entry.returns > 0 then
        addSectionHeader("Returns")
        for _, r in ipairs(entry.returns) do
            addLine("  " .. formatParam(r), "GameFontHighlight", LINE_GAP)
        end
        y = y - (SECTION_GAP - LINE_GAP)
    end

    -- Event payload.
    if entry.type == "event" then
        addSectionHeader("Payload")
        if entry.payload and #entry.payload > 0 then
            for _, p in ipairs(entry.payload) do
                addLine("  " .. formatParam(p), "GameFontHighlight", LINE_GAP)
            end
        else
            addLine("  |cff666666(none)|r", "GameFontDisableSmall", LINE_GAP)
        end
        if entry.literalName then
            addLine("Register: |cffd87f3aframe:RegisterEvent(\"" .. entry.literalName .. "\")|r",
                "GameFontDisableSmall", LINE_GAP)
        end
        y = y - (SECTION_GAP - LINE_GAP)
    end

    -- Structure fields.
    if entry.type == "structure" and entry.fields then
        addSectionHeader("Fields")
        for _, f in ipairs(entry.fields) do
            addLine("  " .. formatField(f), "GameFontHighlight", LINE_GAP)
        end
        y = y - (SECTION_GAP - LINE_GAP)
    end

    -- Version info.
    if entry.added or entry.removed or entry.deprecated then
        addSectionHeader("Version")
        if entry.added      then addLine("  Added in: |cffd87f3a" .. tostring(entry.added) .. "|r", "GameFontHighlight", LINE_GAP) end
        if entry.deprecated then addLine("  Deprecated in: |cffff8c00" .. tostring(entry.deprecated) .. "|r", "GameFontHighlight", LINE_GAP) end
        if entry.removed    then addLine("  Removed in: |cffff5555" .. tostring(entry.removed) .. "|r", "GameFontHighlight", LINE_GAP) end
        y = y - (SECTION_GAP - LINE_GAP)
    end

    -- Examples.
    if entry.examples and #entry.examples > 0 then
        addSectionHeader("Examples")
        for _, ex in ipairs(entry.examples) do
            addLine(ex, "GameFontNormalSmall", LINE_GAP)
        end
        y = y - (SECTION_GAP - LINE_GAP)
    end

    -- See also.
    if entry.seeAlso and #entry.seeAlso > 0 then
        addSectionHeader("See also")
        for _, ref in ipairs(entry.seeAlso) do
            addLine("  " .. ref, "GameFontHighlight", LINE_GAP)
        end
        y = y - (SECTION_GAP - LINE_GAP)
    end

    -- Related events.
    if entry.relatedEvents and #entry.relatedEvents > 0 then
        addSectionHeader("Related events")
        for _, ev in ipairs(entry.relatedEvents) do
            addLine("  " .. ev, "GameFontHighlight", LINE_GAP)
        end
        y = y - (SECTION_GAP - LINE_GAP)
    end

    -- Hide any leftover strings from a previous longer entry.
    hideTrailing(idx + 1)

    -- Size content frame for the scrollbar to compute thumb size.
    local totalH = math.max(1, -y + PAD)
    if _scrollWidget and _scrollWidget.SetContentHeight then
        _scrollWidget:SetContentHeight(totalH)
    elseif _content then
        _content:SetSize(cw, totalH)
    end
end

-- --------------------------------------------------------------------------
-- Clear: empty the pane.
-- --------------------------------------------------------------------------
function Detail.Clear()
    if not _strings then return end
    for _, s in ipairs(_strings) do s:Hide() end
    if _scrollWidget and _scrollWidget.SetContentHeight then
        _scrollWidget:SetContentHeight(1)
    elseif _content then
        _content:SetHeight(1)
    end
end

function Detail.GetFrame()
    return _scrollFrame
end

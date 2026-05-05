-- Forge_Console.LineNumbers: gutter that mirrors the editor's line count.
--
-- Builds a narrow read-only EditBox to the LEFT of the editor that displays
-- "1 / 2 / 3 / ..." stacked vertically and grows wider as line count crosses
-- the next decade boundary. Supports flashing one line red after a runtime
-- error.
--
-- Why a separate EditBox (not a FontString)? FontStrings refuse SetScript so
-- we can't sync scrolling cleanly, and they don't share the editbox font
-- metrics exactly. An EditBox lets us mirror the editor's font and use the
-- same scrollFrame plumbing (we anchor the gutter content to the editor's
-- vertical scroll position via OnVerticalScroll).
--
-- Memory hits to remember:
--   * `wow_setfont_flags_required` - SetFont needs a flags arg on 120005.
--   * `cairn_gui_widget_as_anchor` - widgets are tables, not Frames; use
--     widget.scrollFrame as the anchor target.

local ADDON, ns = ...

local LN = {}
ns.LineNumbers = LN

local DEFAULT_FONT_HEIGHT = 14
local PAD_X = 4   -- horizontal padding inside the gutter
local CHAR_W = 8  -- approximate digit width at default font

-- ----- Build ---------------------------------------------------------------
-- Creates the gutter widgets attached to `parent` (the editor backdrop) and
-- anchored to the editor scrollFrame's vertical scroll. Returns a table of
-- handles the caller can keep on the module.
function LN.Build(parent, editorScrollFrame, editor)
    local g = {}

    -- Container frame to the left of the editor. The editor itself will be
    -- re-anchored by the caller to leave room for this gutter.
    g.frame = CreateFrame("Frame", nil, parent)
    g.frame:SetPoint("TOPLEFT",    parent, "TOPLEFT",    6, -6)
    g.frame:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 6,  6)
    g.frame:SetWidth(PAD_X * 2 + CHAR_W * 2)  -- room for "99" by default

    -- A scrollFrame so the gutter scrolls with the editor.
    local sf = CreateFrame("ScrollFrame", nil, g.frame)
    sf:SetAllPoints(g.frame)
    g.scroll = sf

    -- Inner content frame holds the FontString. We use a FontString (not an
    -- EditBox) for simplicity: the gutter is non-interactive and we just
    -- need text to render. If we want per-line color escape control we can
    -- swap to an EditBox later.
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(1, 1)
    sf:SetScrollChild(content)
    g.content = content

    local fs = content:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    -- The editor's editBox uses SetTextInsets(2, 2, 2, 2). Match the top
    -- inset so line "1" in the gutter aligns with line 1 of the code.
    fs:SetPoint("TOPLEFT",  content, "TOPLEFT",  PAD_X, -2)
    fs:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD_X, -2)
    fs:SetJustifyH("RIGHT")
    fs:SetJustifyV("TOP")
    g.text = fs

    -- Mirror editor scroll position. Hook the editor's scrollFrame so when
    -- the user scrolls the code, the gutter follows pixel-for-pixel.
    if editorScrollFrame and editorScrollFrame.HookScript then
        editorScrollFrame:HookScript("OnVerticalScroll", function(self, offset)
            sf:SetVerticalScroll(offset or 0)
        end)
    end

    g._editor = editor
    g._highlightLine = nil

    return g
end

-- ----- Update --------------------------------------------------------------
-- Recompute the gutter contents from the editor's current text. Cheap enough
-- to call on every OnTextChanged.
--
-- Wrap-aware? No, not yet: in the rare case a single source line wraps in
-- the visible editor, the gutter line count for that visual run won't pad
-- with blanks. WowLua's UpdateLineNums had wrap detection via a separate
-- "linetest" FontString; if the misalignment becomes annoying, port it. For
-- typical Lua snippets where lines stay under ~80 chars, this is fine.
function LN.Update(g)
    if not (g and g.text and g._editor) then return end

    -- FAIAP replaces editor:GetText() to return decoded (uncolored) text by
    -- default. That's what we want here since we're counting source lines.
    local text = g._editor:GetText() or ""

    -- Count newlines. Total lines = newlines + 1, except a trailing newline
    -- means we have an empty "line N+1" the user can type into; show it.
    local _, nl = text:gsub("\n", "\n")
    local total = nl + 1

    local hl = g._highlightLine
    local parts = {}
    for i = 1, total do
        if i == hl then
            parts[i] = "|cffff5050" .. i .. "|r"
        else
            parts[i] = tostring(i)
        end
    end
    g.text:SetText(table.concat(parts, "\n"))

    -- Grow the gutter wider if line count crossed a decade boundary.
    local digits = math.max(2, #tostring(total))
    local desired = PAD_X * 2 + CHAR_W * digits
    if g.frame:GetWidth() ~= desired then
        g.frame:SetWidth(desired)
        if g._onWidthChanged then g._onWidthChanged(desired) end
    end

    -- Make sure the content frame is tall enough to scroll.
    local h = (g.text:GetStringHeight() or 0) + 4
    g.content:SetSize(g.frame:GetWidth(), math.max(h, g.frame:GetHeight() or 0))
end

-- ----- Highlight a specific line (for runtime errors) ---------------------
function LN.SetHighlight(g, lineNum)
    if not g then return end
    g._highlightLine = tonumber(lineNum) or nil
    LN.Update(g)
end

function LN.ClearHighlight(g)
    if not g then return end
    if g._highlightLine then
        g._highlightLine = nil
        LN.Update(g)
    end
end

-- ----- Match the editor's font (size / family) ----------------------------
-- Memory `wow_setfont_flags_required`: on 120005 the flags arg is mandatory.
function LN.SetFont(g, file, height, flags)
    if not (g and g.text) then return end
    g.text:SetFont(file or "Fonts\\ARIALN.TTF", height or DEFAULT_FONT_HEIGHT, flags or "")
end

-- Forge_Console.LineNumbers: gutter that mirrors the editor's line count.
--
-- Simpler than OLD: the gutter lives INSIDE the editor's scroll content
-- area (not in its own scrollFrame), so it scrolls naturally with the
-- editor without a separate HookScript sync. The gutter is just a
-- FontString anchored to the content's left edge; the EditBox is
-- anchored at gutter_width offset from the same content.
--
-- Public API:
--   ns.LineNumbers.Build(content, editor) -> gutter handle
--   ns.LineNumbers.Update(g)              -- recompute line count + width
--   ns.LineNumbers.SetHighlight(g, line)  -- mark a line red (error)
--   ns.LineNumbers.ClearHighlight(g)
--   ns.LineNumbers.GetWidth(g)            -- current gutter width in px
--
-- Memory notes:
--   * wow_setfont_flags_required - SetFont needs a flags arg on 120005.
--   * wow_lua_ascii_only        - keep this file ASCII.

local ADDON, ns = ...

local LN = {}
ns.LineNumbers = LN

local DEFAULT_FONT_HEIGHT = 14
local PAD_X    = 4   -- horizontal padding inside the gutter
local CHAR_W   = 7   -- approximate digit width at default font (ARIALN 14)
local TOP_PAD  = 4   -- matches the EditBox's top text inset so "1" aligns


-- ----- Build ---------------------------------------------------------------
-- Creates a FontString anchored TOPLEFT of `content` with a fixed width.
-- The width grows on decade boundaries via LN.Update. Returns a handle
-- the caller passes to LN.Update / LN.SetHighlight.
function LN.Build(content, editor)
    if not (content and editor) then return nil end

    local g = {}
    g._content       = content
    g._editor        = editor
    g._highlightLine = nil
    g._width         = PAD_X * 2 + CHAR_W * 2  -- room for "99" initially

    -- FontString rendered into the content area. ARTWORK layer + small
    -- right-justified format means "  1", " 12", "123" all align at the
    -- right edge of the gutter column.
    local fs = content:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", PAD_X, -TOP_PAD)
    fs:SetWidth(g._width - PAD_X * 2)
    fs:SetJustifyH("RIGHT")
    fs:SetJustifyV("TOP")
    fs:SetText("")
    g.text = fs

    return g
end


-- ----- Update --------------------------------------------------------------
-- Recompute the gutter text + width from the editor's current text. Called
-- on every OnTextChanged. Returns the current gutter width in pixels so
-- the caller can re-anchor the editor if width crossed a decade boundary.
function LN.Update(g)
    if not (g and g.text and g._editor) then return g and g._width end

    -- FAIAP swaps editor:GetText to return decoded (plain) text. Count
    -- newlines on that to get the source line count.
    local text = g._editor:GetText() or ""
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

    -- Grow on decade boundary. Cap at 5 digits because if anyone ever
    -- pastes 100k lines into the Console, the gutter width is the
    -- least of their problems.
    local digits = math.max(2, math.min(5, #tostring(total)))
    local desired = PAD_X * 2 + CHAR_W * digits
    if g._width ~= desired then
        g._width = desired
        g.text:SetWidth(desired - PAD_X * 2)
        if g._onWidthChanged then g._onWidthChanged(desired) end
    end

    return g._width
end


-- ----- Highlight a specific line (runtime error) --------------------------

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


-- ----- Accessors ----------------------------------------------------------

function LN.GetWidth(g)
    if not g then return 0 end
    return g._width or 0
end


-- ----- Font (optional override, matches editor font on 120005) -------------
-- SetFont's third arg is mandatory on 120005 -- pass "" if no flags.
function LN.SetFont(g, file, height, flags)
    if not (g and g.text) then return end
    g.text:SetFont(file or "Fonts\\ARIALN.TTF", height or DEFAULT_FONT_HEIGHT, flags or "")
end

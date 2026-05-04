-- Forge.About: registers the About tab with the Forge.Registry.
-- Shows the logo + a curated summary of what Forge is and what each
-- sub-addon does. Update this text when sub-addons change shape.

local ADDON, ns = ...

local About = {}
ns.About = About

-- Curated summary shown on the About tab. Markdown-light: `# H1`, `## H2`
-- become colored headers via decorate() below.
local SUMMARY_TEXT = [[
# Forge

A developer toolset for World of Warcraft addons.

Forge is a collection of in-game tools for addon authors. Each tool is
its own optional sub-addon that plugs into this shared window. Install
only the ones you want; each adds a tab here on load.

## What's included

Bug Catcher
   Quiet Lua error capture. Browsable viewer with copy-as-block,
   ignore list, optional auto-popup, and a minimap counter. Replaces
   WoW's default error popup; chains to any external error-tracking
   addon so they keep working.

Console
   In-game Lua REPL with snippet manager, auto-run on login, history,
   and a scrollable output pane. Workspace flow with named snippets.

Macros
   Macro editor for Account + Character macros, plus a sequence
   builder that compiles a stack of /cast lines into a /castsequence
   macro you can drag to your bar.

Inspector
   Real-time _G tree browser with virtualized scrolling. Pin any path
   as a root, snapshot the frame under your cursor, search by prefix
   or substring, drill into metatables, hover for frame metadata.
   Plus an Events tab (live event monitor with payload capture) and
   FnLog tab (wrap any function to log its calls and return values).

Addons
   Addon enable/disable with named sets (Raid / Solo / PvP), sortable
   columns, status filter, dependency tooltips, recursive enable,
   protected addons, auto-disable-new-on-login with a popup prompt.

Logs
   Per-source log viewer over Cairn.Log's ring buffer. Level filter,
   search, copy-as-block, CSV export. Replaces Cairn.Dashboard.

## Quick start

   /forge            Toggle this window
   /forge help       List every subcommand from every sub-module
   /forge status     Cairn / LibCodex / profile / sub-modules info
   /forge modules    Every loaded sub-addon

Each sub-addon adds its own subcommand on load (/forge bug,
/forge console, /forge inspect, /forge addon, /forge logs, ...).

## Built on Cairn

Forge depends on the Cairn library stack:

   Cairn.DB        SavedVariables with profiles
   Cairn.Addon     Lifecycle (OnInit / OnLogin / OnLogout)
   Cairn.Slash     /forge router, sub-module slashes auto-wired
   Cairn.Events    Event subscription (used by Inspector's Events tab)
   Cairn.Log       Leveled per-source logger (used by Logs tab)

Forge never duplicates work that lives in Cairn. The Cairn libraries
are MIT-licensed and can be reused independently.

## Naming family

   Cairn    stones / foundation        composable Lua libraries
   Codex    book / data                game data catalog
   Vellum   page / rendered guide      in-game quest guide addon
   Forge    workshop / dev tools       this addon

## Author and license

   Author:  ChronicTinkerer
   License: All Rights Reserved
   Project: github.com/ChronicTinkerer

The library dependencies (Cairn, LibCodex) are MIT-licensed.
This addon and its sub-addons are proprietary; install via the
official channels (CurseForge / Wago / WoWInterface / GitHub
releases) and use within World of Warcraft.
]]

-- Strip leading/trailing whitespace.
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Quick markdown -> plain text scrub for in-game display:
--   * Drop image lines (<p align>...<img...></p>) entirely.
--   * Replace `# Header`, `## Header` etc. with bracketed forms.
--   * Code fences (``` ) become a divider line.
--   * Leave tables alone; they're readable enough.
local function decorate(text)
    local out = {}
    local in_html = false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local s = line
        if s:match("^<p%s") or s:match("^</p>") or s:match("^%s*<img") then
            -- skip html image-block lines
        elseif s:match("^```") then
            out[#out + 1] = "|cff666666---|r"
        else
            -- Headings.
            local h, body = s:match("^(#+)%s+(.*)$")
            if h then
                local color = (#h == 1) and "ffd87f3a"  -- forge orange
                          or  (#h == 2) and "ffffe6a8"  -- pale gold
                          or                "ffaaaaaa"  -- dim
                out[#out + 1] = "|c" .. color .. body .. "|r"
            else
                out[#out + 1] = s
            end
        end
    end
    return table.concat(out, "\n")
end

About.Text = decorate(trim(SUMMARY_TEXT))

-- Build and register the descriptor.
local function buildAbout(parent, mod)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- Logo (centered, top).
    local logo = frame:CreateTexture(nil, "ARTWORK")
    logo:SetTexture("Interface\\AddOns\\Forge\\ForgeLogo.png")
    logo:SetSize(220, 220)
    logo:SetPoint("TOP", frame, "TOP", 0, -8)
    mod._logo = logo

    -- Tagline beneath logo.
    local tagline = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tagline:SetPoint("TOP", logo, "BOTTOM", 0, -8)
    tagline:SetText("|cffd87f3aForge|r  |cffaaaaaadeveloper toolset for WoW addons|r")

    -- Scrollable README text below.
    local bg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    bg:SetPoint("TOPLEFT",     tagline, "BOTTOMLEFT",  -200, -16)
    bg:SetPoint("TOPRIGHT",    tagline, "BOTTOMRIGHT",  200, -16)
    bg:SetPoint("BOTTOMLEFT",  frame,   "BOTTOMLEFT",   8, 8)
    bg:SetPoint("BOTTOMRIGHT", frame,   "BOTTOMRIGHT", -8, 8)
    bg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    local sf = CreateFrame("ScrollFrame", nil, bg, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     6, -6)
    sf:SetPoint("BOTTOMRIGHT", -28, 6)

    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(1, 1)
    sf:SetScrollChild(content)

    local fs = content:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -4)
    fs:SetWordWrap(true)
    fs:SetText(About.Text)

    local function reflow()
        local w = (sf:GetWidth() or 0) - 8
        if w < 1 then w = 1 end
        fs:SetWidth(w)
        local h = (fs:GetStringHeight() or 0) + 12
        content:SetSize(w, math.max(h, sf:GetHeight() or 0))
        sf:UpdateScrollChildRect()
    end
    sf:SetScript("OnSizeChanged", reflow)
    reflow()
end

About.descriptor = {
    name        = "About",
    title       = "About",
    order       = 999,  -- always last
    description = "Forge logo + README.",
    SlashSub    = { name = "about", help = "open the About tab" },
    OnTabShow   = function(parent, mod)
        if not mod._built then
            buildAbout(parent, mod)
            mod._built = true
        end
        if mod._frame then mod._frame:Show() end
    end,
    OnTabHide   = function(parent, mod)
        if mod._frame then mod._frame:Hide() end
    end,
}

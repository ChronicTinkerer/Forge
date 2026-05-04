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

-- Build a "Loaded builds" block listing every Forge_* sub-addon and Cairn /
-- LibCodex with their .toc Version. Computed at tab-show time so it reflects
-- whatever's actually loaded in the session.
local function buildBuildsBlock()
    local readBuild = ns.readBuild or function() return "?" end
    local lines = {
        "",
        "|cffd87f3aLoaded builds|r",
    }
    -- Forge parent first.
    lines[#lines + 1] = string.format("  %-22s %s", "Forge", readBuild("Forge"))
    -- Every loaded Forge_* folder. Walks the WoW addon list directly so
    -- folder/tab-key mismatches (Addons -> Forge_AddonManager) don't hide rows.
    if ns.listForgeAddonFolders then
        for _, n in ipairs(ns.listForgeAddonFolders()) do
            lines[#lines + 1] = string.format("  %-22s %s", n, readBuild(n))
        end
    end
    -- Libraries.
    lines[#lines + 1] = string.format("  %-22s %s", "Cairn",       readBuild("Cairn"))
    local lcVer = readBuild("LibCodex-1.0")
    if lcVer ~= "?" then
        lines[#lines + 1] = string.format("  %-22s %s", "LibCodex-1.0", lcVer)
    end
    return table.concat(lines, "\n")
end

-- Build and register the descriptor.
--
-- Migration note (2026-05-04): the scrolling README panel was rebuilt on top
-- of Cairn-Gui-Core's `ScrollFrame` widget (the Diesal-derived family) instead
-- of `UIPanelScrollFrameTemplate`. First Forge tab to dogfood the new widget
-- kit; logo and tagline stay as raw FontString/Texture (decorative, not
-- interactive). The outer parchment-look BackdropTemplate frame is kept as
-- visual chrome around the widget.
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

    -- Parchment-look chrome around the scroll widget. Kept as raw
    -- BackdropTemplate because Cairn-Gui-Core doesn't yet ship a "bordered
    -- panel" widget; the widget kit only owns the scroll machinery.
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
    mod._bg = bg

    -- Scrollable README via Cairn-Gui-Core widget. The widget exposes
    --   sw.frame   -- outer frame; we anchor this inside `bg`
    --   sw.content -- the scroll child; FontString lives here
    --   sw:SetContentHeight(h) -- drives scrollbar visibility/grip size
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local sw  = Gui and Gui:Create("ScrollFrame")
    if not sw then
        -- Defensive fallback: if Cairn-Gui-Core isn't loaded for any reason,
        -- fall back to a plain FontString without scroll. The About tab still
        -- renders something useful instead of erroring out.
        local fs = bg:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetPoint("TOPLEFT",     bg, "TOPLEFT",     8, -8)
        fs:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -8, 8)
        fs:SetWordWrap(true)
        fs:SetText(About.Text .. "\n" .. buildBuildsBlock())
        mod._aboutFs = fs
        return
    end

    sw:SetParent(bg)
    sw:ClearAllPoints()
    sw:SetPoint("TOPLEFT",     bg, "TOPLEFT",      6, -6)
    sw:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -2,  6)
    mod._scrollWidget = sw

    -- FontString lives on the widget's scroll child.
    local fs = sw.content:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetPoint("TOPLEFT", sw.content, "TOPLEFT", 4, -4)
    fs:SetWordWrap(true)
    -- Append the live "Loaded builds" block. Computed each build call so a
    -- /reload after bumping a sub-addon shows the new stamps without
    -- requiring About.Text to be regenerated.
    fs:SetText(About.Text .. "\n" .. buildBuildsBlock())
    mod._aboutFs = fs

    -- Recompute content height for the current FontString text. Called
    -- whenever the text changes (e.g. on tab show after the builds block
    -- gets refreshed) and whenever the scroll child's width changes.
    local function reflow()
        local w = sw.content:GetWidth() or 0
        if w >= 1 then fs:SetWidth(math.max(w - 8, 1)) end
        local h = (fs:GetStringHeight() or 0) + 12
        sw:SetContentHeight(math.max(h, sw.frame:GetHeight() or 0))
    end
    mod._reflow = reflow

    -- Reflow when the scroll child's width changes (driven by the widget's
    -- internal scrollFrame:OnSizeChanged -> content:SetWidth). We gate on
    -- width so SetContentHeight (which sets content's height) doesn't loop.
    local lastWidth
    sw.content:SetScript("OnSizeChanged", function(_, w)
        if w == lastWidth or not w or w < 1 then return end
        lastWidth = w
        reflow()
    end)
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
        -- Refresh the builds list each show so it reflects whatever's loaded
        -- right now (useful when iterating sub-addons mid-session).
        if mod._aboutFs then
            mod._aboutFs:SetText(About.Text .. "\n" .. buildBuildsBlock())
        end
        -- Recompute scroll content height for the new text (Cairn-Gui path).
        if mod._reflow then mod._reflow() end
    end,
    OnTabHide   = function(parent, mod)
        if mod._frame then mod._frame:Hide() end
    end,
}

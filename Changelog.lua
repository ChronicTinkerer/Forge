-- Forge.Changelog: registers the Changelog tab with Forge.Registry.
-- Shows the rolling release notes for Forge + every shipped sub-addon.
--
-- The text below is the in-game source of truth. The repo-root CHANGELOG.md
-- carries the same content for GitHub readers. When you bump a sub-addon and
-- write a CHANGELOG.md entry there, mirror the headline + bullets here so
-- users see it without leaving the game.

local ADDON, ns = ...

local Changelog = {}
ns.Changelog = Changelog

-- Markdown-light: `# Header` and `## Header` colorize via decorate(). Same
-- pattern as About.lua so the look is consistent across tabs.
local CHANGELOG_TEXT = [[
# Changelog

Release notes across the Forge family. Newest releases on top.

## v12 - 2026-05-06

### Fixed
- Forge_APIRef bake.py: manifest-update functions can no longer silently
  truncate Forge/.pkgmeta and Forge/.dev/release.ps1. Both writes now go
  through a defensive helper that refuses sub-50% shrinkage, verifies
  byte-equality after a temp-file write, and atomic-renames into place.
- Removed corrupted self-overwriting trailer on bake.py itself (an orphan
  call line followed by a duplicated copy of main()'s tail). Cosmetic;
  was unreachable at runtime.
- Removed stub artifact from the bottom of Forge/.pkgmeta (a half-pasted
  duplicate of the @project-version comment header).

### Added
- Pure-Python regression test at
  Forge/SubAddons/Forge_APIRef/.dev/tests/test_bake_manifest_preservation.py.
  16/16 PASS. Covers helper presence, pkgmeta + release.ps1 trailer
  preservation across substitutions, namespace add/remove, the helper's
  refusal of sub-50% shrinkage, .tmp cleanup, and idempotency.

## v10 - 2026-05-06

### Added
- LoadOnDemand sub-addon support. Forge parent now scans installed
  Forge_* addons at PLAYER_LOGIN and creates "stub" tab descriptors for
  any that declare `## LoadOnDemand: 1` plus `## X-Forge-Tool-Name: <Title>`.
  The sub-addon stays unloaded until the user clicks its tab; on first
  click the stub does C_AddOns.LoadAddOn and delegates to the real
  descriptor that the sub-addon's OnInit just registered.
- Forge.Registry stub-protection: a real descriptor never gets
  overwritten by a late stub registration.
- Forge_CVars sub-addon (LoadOnDemand): in-game CVar browser and editor
  with named profiles. First user of the new LoD-stub pattern.

### Notes for sub-addon authors
- LoD sub-addons MUST register their Forge.Registry descriptor in
  `OnInit`, not `OnLogin`. Cairn.Events doesn't retro-fire PLAYER_LOGIN,
  so a sub-addon LoD-loaded post-login never sees OnLogin.

## v6 - 2026-05-05

### Added
- Forge.Changelog: this tab. Pulls release notes into an in-game view so
  users can see what changed without leaving the game.
- Cairn.Locale dev override: `/forge locale <code>` overrides
  `GetLocale()` for every Cairn.Locale instance, persists across
  reloads. `/forge locale clear` removes the override. Useful for
  testing translations without restarting the client.
- Forge_AddonManager localized via Cairn-Locale-1.0. enUS is
  authoritative; nine other locale tables wait for translations.
- Forge_AddonManager: CPU profiler columns (Recent / Peak / Spikes)
  next to Memory. Tooltip on a row shows the full breakdown
  (encounter avg, last frame, spike counts at every threshold).
  Backed by `C_AddOnProfiler` (Mainline 11.0.5+); silent on Classic.

### Changed
- Forge.About: trimmed long-form description. The Changelog tab now
  carries the rolling notes; About is a one-screen overview.

## v5 - 2026-05-05

### Fixed
- `release.ps1` and `refresh.ps1` anchor at the repo root from the new
  `.dev/` location (three `dirname()` calls up, not two).

## v4 - 2026-05-05

### Changed
- All dev-local artifacts consolidated under `.dev/` at the repo root.
  Tools, release scripts, intermediate import dumps, caches, and
  per-tool configs now live in one folder; `.gitignore` and `.pkgmeta`
  each carry one entry that covers everything.

## v3 - 2026-05-05

### Added
- Sequential build numbering (replaces YYMMDDHHMM stamps). Each release
  reads the current TOC version and increments by 1. Strictly
  monotonic; immune to timezone drift between dev machines.

## Older (pre-v3, YYMMDDHHMM-stamped era)

Per-sub-addon changelogs were consolidated into the root
CHANGELOG.md on 2026-05-05. Pre-v3 entries are preserved there
verbatim under "Older". Summary:

### Forge_Console

[2605051821] Fixed Indent.lua nil-load error.

[2605051145] Added REPL command line, history persistence,
multi-line continuation, Esc-to-cancel.

[2605051138] Added FAIAP syntax highlighting, line-number gutter,
runtime-error cursor-jump.
]]

-- Strip leading/trailing whitespace.
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Reuse About.lua's decoration approach: header lines with `#` get tinted.
local function decorate(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local s = line
        if s:match("^```") then
            out[#out + 1] = "|cff666666---|r"
        else
            local h, body = s:match("^(#+)%s+(.*)$")
            if h then
                local color = (#h == 1) and "ffd87f3a"  -- forge orange
                          or  (#h == 2) and "ffffe6a8"  -- pale gold (release version)
                          or  (#h == 3) and "ffaaccff"  -- light blue (Added/Changed/Fixed)
                          or                "ffaaaaaa"
                out[#out + 1] = "|c" .. color .. body .. "|r"
            else
                out[#out + 1] = s
            end
        end
    end
    return table.concat(out, "\n")
end

Changelog.Text = decorate(trim(CHANGELOG_TEXT))

-- Tab build mirrors About.lua's scrolling-FontString pattern, minus the
-- logo + tagline (the changelog is dense; we want every pixel for content).
local function buildChangelog(parent, mod)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- Section header at the top.
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -10)
    title:SetText("|cffd87f3aChangelog|r")

    -- Parchment chrome around the scroll widget.
    local bg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    bg:SetPoint("TOPLEFT",     frame, "TOPLEFT",      8,  -36)
    bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8,    8)
    bg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    bg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    mod._bg = bg

    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local sw  = Gui and Gui:Create("ScrollFrame")
    if not sw then
        -- Fallback: plain non-scrolling FontString. Still readable, just
        -- truncated when the text overflows the frame.
        local fs = bg:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetPoint("TOPLEFT",     bg, "TOPLEFT",      8, -8)
        fs:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -8,  8)
        fs:SetWordWrap(true)
        fs:SetText(Changelog.Text)
        mod._fs = fs
        return
    end

    sw:SetParent(bg)
    sw:ClearAllPoints()
    sw:SetPoint("TOPLEFT",     bg, "TOPLEFT",      6, -6)
    sw:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -2,  6)
    mod._scrollWidget = sw

    local fs = sw.content:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetPoint("TOPLEFT", sw.content, "TOPLEFT", 4, -4)
    fs:SetWordWrap(true)
    fs:SetText(Changelog.Text)
    mod._fs = fs

    local function reflow()
        local w = sw.content:GetWidth() or 0
        if w >= 1 then fs:SetWidth(math.max(w - 8, 1)) end
        local h = (fs:GetStringHeight() or 0) + 12
        sw:SetContentHeight(math.max(h, sw.frame:GetHeight() or 0))
    end
    mod._reflow = reflow

    local lastWidth
    sw.content:SetScript("OnSizeChanged", function(_, w)
        if w == lastWidth or not w or w < 1 then return end
        lastWidth = w
        reflow()
    end)
end

Changelog.descriptor = {
    name        = "Changelog",
    title       = "Changelog",
    -- About is order=999 (last). 998 places Changelog immediately before it.
    order       = 998,
    description = "Forge release notes.",
    SlashSub    = { name = "changelog", help = "open the Changelog tab" },
    OnTabShow   = function(parent, mod)
        if not mod._built then
            buildChangelog(parent, mod)
            mod._built = true
        end
        if mod._frame then mod._frame:Show() end
        if mod._reflow then mod._reflow() end
    end,
    OnTabHide   = function(parent, mod)
        if mod._frame then mod._frame:Hide() end
    end,
}

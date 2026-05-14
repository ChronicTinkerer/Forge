-- Forge_Stats: live system + character info tab.
--
-- Sections (top-down inside the tab pane):
--   1. Character — name, level/class/race/faction/spec/guild
--   2. Location  — realm, region, zone, subzone, world coords
--   3. Network   — latencyHome / latencyWorld (ms), bandwidthIn/Out (KB/s)
--   4. System    — FPS, addon memory, total Lua memory, /played-style runtime
--   5. Build     — WoW client version + build number
--
-- Refresh strategy:
--   * Static-ish values (name, class, realm, region) — set once on first
--     OnTabShow.
--   * Live values (zone, coords, latency, FPS, memory) — re-read every
--     REFRESH_INTERVAL seconds while the tab is visible.
--   * Ticker is cancelled in OnTabHide so the tab uses zero CPU when not
--     visible.

local ADDON, ns = ...

_G.Forge_Stats = ns


Cairn.Register("CTS_Forge_Stats", ns, {
    dbName = "Forge_StatsDB",
    Log    = true,
    Events = true,
    Timer  = true,
    dbDefaults = { profile = {}, global = {} },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Stats"]
local db        = _entry and _entry.db
ns.db           = db

local addon = _entry and _entry.cairnAddon
ns.addon    = addon


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local REFRESH_INTERVAL = 0.5   -- seconds between live-value refreshes


-- ---------------------------------------------------------------------------
-- Module-scope refs to live widgets
-- ---------------------------------------------------------------------------

local _ticker            -- C_Timer ticker; nil when tab is hidden
local _labels = {}       -- map: key -> Cairn-Gui Label
local _bootTime          -- GetTime() at OnLogin; used for session runtime


-- ---------------------------------------------------------------------------
-- Data readers
-- ---------------------------------------------------------------------------
-- Defensive: every reader returns a STRING (possibly "?") so the Label
-- update path doesn't have to type-check at runtime.

local CLASS_COLORS = RAID_CLASS_COLORS  -- Blizzard global; nil-safe via or


local function colorClass(class)
    local key = class and class:upper():gsub(" ", "")
    local c   = CLASS_COLORS and key and CLASS_COLORS[key]
    if not c then return tostring(class or "?") end
    return ("|cff%02x%02x%02x%s|r"):format(c.r * 255, c.g * 255, c.b * 255, class)
end


local function colorFaction(faction)
    if faction == "Alliance" then return "|cff0080ffAlliance|r" end
    if faction == "Horde"    then return "|cffff2020Horde|r"    end
    return tostring(faction or "Neutral")
end


local function readCharacter()
    local name  = UnitName and UnitName("player") or "?"
    local level = UnitLevel and UnitLevel("player") or 0
    local class = (UnitClass and select(1, UnitClass("player"))) or "?"
    local race  = (UnitRace  and select(1, UnitRace("player")))  or "?"
    local faction = (UnitFactionGroup and UnitFactionGroup("player")) or "?"

    local specName = ""
    if GetSpecialization and GetSpecializationInfo then
        local specIndex = GetSpecialization()
        if specIndex then
            local _, n = GetSpecializationInfo(specIndex)
            specName = n or ""
        end
    end

    local guild
    if GetGuildInfo then guild = GetGuildInfo("player") end

    return {
        line1 = ("%s — level %d %s %s"):format(name, level, race, colorClass(class)),
        line2 = ("%s%s%s"):format(
            colorFaction(faction),
            (specName ~= "" and ("  •  " .. specName)) or "",
            (guild and guild ~= "" and ("  •  <" .. guild .. ">")) or ""),
    }
end


local function readLocation()
    local realm  = GetRealmName and GetRealmName() or "?"
    local region = "?"
    if GetCurrentRegionName then
        region = GetCurrentRegionName() or region
    elseif GetCurrentRegion then
        local regions = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }
        region = regions[GetCurrentRegion()] or region
    end

    local zone    = GetZoneText        and GetZoneText()        or "?"
    local subzone = GetSubZoneText     and GetSubZoneText()     or ""
    local realZone= GetRealZoneText    and GetRealZoneText()    or zone

    -- World map coords: only available when the player has a known map.
    local coordStr = "(no map)"
    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID then
            local pos = C_Map.GetPlayerMapPosition(mapID, "player")
            if pos then
                local x, y = pos:GetXY()
                coordStr = ("%.1f, %.1f  (map %d)"):format(x * 100, y * 100, mapID)
            end
        end
    end

    return {
        realm    = ("%s — %s"):format(realm, region),
        zone     = realZone .. (subzone ~= "" and ("  •  " .. subzone) or ""),
        coords   = coordStr,
    }
end


local function readNetwork()
    if not GetNetStats then
        return { latency = "n/a", bandwidth = "n/a" }
    end
    local bin, bout, lhome, lworld = GetNetStats()
    -- GetNetStats refreshes every ~30s on the client. The values are
    -- already smoothed by Blizzard — we just display them.
    return {
        latency   = ("home %d ms   world %d ms"):format(lhome or 0, lworld or 0),
        bandwidth = ("in %.1f KB/s   out %.1f KB/s"):format(bin or 0, bout or 0),
    }
end


-- Force a one-time addon-memory recalc, then read totals. UpdateAddOnMemoryUsage
-- is the snapshot trigger — without it GetAddOnMemoryUsage returns stale data.
-- This is the same pattern Forge_AddonManager uses for its memory column.
local function readSystem()
    local fps = GetFramerate and GetFramerate() or 0
    local totalMem
    if UpdateAddOnMemoryUsage and collectgarbage then
        UpdateAddOnMemoryUsage()
        totalMem = collectgarbage("count")  -- KB across all Lua addons
    end

    local runtime = ""
    if _bootTime and GetTime then
        local secs = math.floor(GetTime() - _bootTime)
        local h = math.floor(secs / 3600)
        local m = math.floor((secs % 3600) / 60)
        local s = secs % 60
        if h > 0 then runtime = ("%dh %02dm %02ds"):format(h, m, s)
        elseif m > 0 then runtime = ("%dm %02ds"):format(m, s)
        else            runtime = ("%ds"):format(s) end
    end

    return {
        fps       = ("%.1f"):format(fps),
        memory    = totalMem and ("%.1f MB"):format(totalMem / 1024) or "n/a",
        runtime   = runtime,
    }
end


local function readBuild()
    if not GetBuildInfo then return { version = "?" } end
    local version, build, dateStr, tocVersion = GetBuildInfo()
    return {
        version = ("%s (build %s)  •  TOC %s"):format(
            version or "?", build or "?", tostring(tocVersion or "?")),
        builtOn = dateStr or "",
    }
end


-- ---------------------------------------------------------------------------
-- Refresh: read all live values and stamp into the existing Labels
-- ---------------------------------------------------------------------------

local function refresh()
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end
    local function set(key, text)
        local lbl = _labels[key]
        if lbl and lbl.Cairn and lbl.Cairn.SetText then
            lbl.Cairn:SetText(text)
        end
    end

    local c = readCharacter()
    set("char.l1", c.line1)
    set("char.l2", c.line2)

    local l = readLocation()
    set("loc.realm",  l.realm)
    set("loc.zone",   l.zone)
    set("loc.coords", l.coords)

    local n = readNetwork()
    set("net.latency",   n.latency)
    set("net.bandwidth", n.bandwidth)

    local s = readSystem()
    set("sys.fps",     "FPS: " .. s.fps)
    set("sys.memory",  "Lua memory: " .. s.memory)
    set("sys.runtime", "Session: " .. s.runtime)

    local b = readBuild()
    set("build.version", b.version)
    if b.builtOn ~= "" then set("build.date", "Released " .. b.builtOn) end
end


-- ---------------------------------------------------------------------------
-- Build: create the section layout (once per pane)
-- ---------------------------------------------------------------------------

local function build(pane)
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    pane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 10, padding = 14 })

    local function heading(text)
        Gui:Acquire("Label", pane, { text = text, variant = "heading" })
    end

    local function row(key, initial)
        local lbl = Gui:Acquire("Label", pane, { text = initial or "" })
        _labels[key] = lbl
    end

    local function muted(key, initial)
        local lbl = Gui:Acquire("Label", pane, {
            text = initial or "", variant = "muted",
        })
        _labels[key] = lbl
    end

    -- Character
    heading("Character")
    row("char.l1", "")
    muted("char.l2", "")

    -- Location
    heading("Location")
    row("loc.realm", "")
    row("loc.zone", "")
    muted("loc.coords", "")

    -- Network
    heading("Network")
    row("net.latency",   "")
    muted("net.bandwidth", "")

    -- System
    heading("System")
    row("sys.fps", "")
    row("sys.memory", "")
    muted("sys.runtime", "")

    -- Build
    heading("WoW client")
    row("build.version", "")
    muted("build.date", "")
end


-- ---------------------------------------------------------------------------
-- Tab descriptor
-- ---------------------------------------------------------------------------

ns.descriptor = {
    name        = "Stats",
    title       = "Stats",
    order       = 20,
    description = "Live character / location / network / system stats.",

    OnTabShow = function(pane, mod)
        if not pane.Cairn._builtOnce then
            pane.Cairn._builtOnce = true
            build(pane)
        end
        refresh()
        -- Start the live-update ticker. Cancelled in OnTabHide so the
        -- tab uses zero CPU when the user isn't looking at it.
        if C_Timer and C_Timer.NewTicker and not _ticker then
            _ticker = C_Timer.NewTicker(REFRESH_INTERVAL, refresh)
        end
    end,

    OnTabHide = function(pane, mod)
        if _ticker and _ticker.Cancel then
            _ticker:Cancel()
            _ticker = nil
        end
    end,
}


-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function addon:OnInit()
    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
end


function addon:OnLogin()
    _bootTime = GetTime and GetTime() or 0
end

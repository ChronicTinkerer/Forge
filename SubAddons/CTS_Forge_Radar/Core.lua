-- Forge_Radar: live list of nearby entities (group, nameplates, vignettes,
-- area POIs) with distance and bearing relative to the player's facing.
--
-- v1 scope (this file):
--   * Four data sources, each pcall-wrapped so a broken API can't poison
--     the whole panel:
--       - Group: party1..4, raid1..40, arena1..5, "player", "pet", and
--         pet of every party/raid member that has one.
--       - Nameplates: C_NamePlate.GetNamePlates() iteration.
--       - Vignettes: C_VignetteInfo.GetVignettes() + GetVignetteInfo +
--         GetVignettePosition for the current map.
--       - Area POIs: C_AreaPoiInfo.GetAreaPOIForMap on the current map +
--         GetAreaPOIInfo for label/description/coords.
--   * Distance + bearing math via UnitPosition (units) or
--     C_Map.GetWorldPosFromMapPos (map-coord sources). Bearing is
--     relative to GetPlayerFacing(); we render an 8-segment ASCII compass
--     label (Fwd / F-R / R / B-R / Bk / B-L / L / F-L). ASCII only per
--     project rule (Unicode arrows + em-dash break the WoW parser
--     sometimes; see memory wow_lua_ascii_only.md).
--   * Toolbar filters: source, reaction, max-distance, sort, pause toggle.
--     All filter state persisted to db.profile so /reload preserves view.
--   * Pooled rows in a ScrollFrame. Click a row to target the unit (if
--     the token still resolves) or super-track the coords (vignette/POI).
--   * Live tick via C_Timer.NewTicker started in OnTabShow / cancelled in
--     OnTabHide so the tab uses zero CPU when not visible. Same pattern
--     as Forge_Stats and Forge_AddonManager.
--
-- Out of scope for v1 (queued for v2):
--   * Graphical radar circle (concentric rings + dots). User picked
--     list-only for v1; data layer needs to settle first.
--   * Rotated arrow texture instead of ASCII labels (needs a Cairn-Media
--     arrow asset; Vellum compass arrow is a candidate).
--   * Mouseover-history bucket (capture every GameObject the player
--     mouses over and remember it for the session).
--   * Combat-log derived bucket (capture every NPC GUID that participates
--     in combat, even if no nameplate is active right now).
--   * CSV export of the visible list.
--
-- Failure modes handled:
--   * UnitPosition returns nil in BG/arena/instance for non-group units.
--     Affected rows still render with "?" distance + "?" bearing rather
--     than disappearing; group rows still work because UnitPosition does
--     return values for grouped units there.
--   * Nameplate token can become invalid mid-frame. Every API call is
--     pcall-wrapped; failed reads drop that row from the current tick.
--   * Vignette + POI APIs return nil / empty in instances; collectors
--     no-op cleanly.

local ADDON, ns = ...
_G.Forge_Radar = ns


Cairn.Register("CTS_Forge_Radar", ns, {
    dbName = "Forge_RadarDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = {
        profile = {
            sourceFilter   = "All",     -- All / Group / Players / NPCs / Objects
            reactionFilter = "All",     -- All / Friend / Enemy / Neutral
            sortMode       = "distance", -- distance / name / reaction
            maxDistance    = 0,         -- yards; 0 = no limit
            paused         = false,
        },
        global = {},
    },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Radar"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local REFRESH_INTERVAL = 0.2    -- seconds between live-update ticks (5 Hz)

local ROW_HEIGHT       = 16
local HEADER_HEIGHT    = ROW_HEIGHT  -- column header bar (fixed, non-scrolling)
local MAX_VISIBLE_ROWS = 200    -- safety cap

-- TOP_RESERVED = heading + description + toolbar + nameplate hint +
-- column header + Stack gaps. Hint label is a fixed-height row even
-- when empty so the layout doesn't jump when the hint shows/hides.
local HINT_HEIGHT      = 14
local TOP_RESERVED     = 110 + HEADER_HEIGHT + 6 + HINT_HEIGHT + 6
local BOTTOM_PAD       = 10
local SIDE_PAD         = 10


-- 8-segment compass labels, indexed 1..8 going clockwise from forward.
-- Forward = where the player is looking; Bk = directly behind.
-- ASCII-only per wow_lua_ascii_only.md.
local ARROW_LABELS = {
    "Fwd", "F-R", "R", "B-R", "Bk", "B-L", "L", "F-L",
}


-- Reaction color codes. Built from class/reaction palette so they read
-- the same as Blizzard's nameplates / unit frames.
local REACTION_COLORS = {
    enemy   = "|cffff5555",   -- hostile = red
    neutral = "|cffffcc33",   -- neutral = yellow
    friend  = "|cff55ff55",   -- friendly = green
    object  = "|cff80c0ff",   -- vignette / POI = blue-ish
    unknown = "|cffaaaaaa",
}


-- Kind tags shown in the row chip. Short on purpose so they don't
-- crowd the name column.
local KIND_LABELS = {
    group     = "Group",
    nameplate = "NPlate",
    sticky    = "Stick",   -- target / focus / mouseover (always-on)
    history   = "Mem",     -- mouseover-history bucket (session memory)
    vignette  = "Vign",
    poi       = "POI",
}


-- Mouseover-history bucket: capture every NPC/Player you mouse over and
-- remember it for the session, even after the nameplate drops. Cap is
-- LRU-evicted so the table stays bounded.
local MO_HISTORY_CAP        = 100   -- max remembered entities

-- Nameplate-empty hint: WoW's GetNamePlates() returns an empty array
-- when nameplates are toggled off. After this many consecutive empty
-- ticks we show a hint label nudging the user to press V.
local EMPTY_PLATE_HINT_AFTER = 5    -- ticks (5 * REFRESH_INTERVAL = 1s)


-- ---------------------------------------------------------------------------
-- Module-scope state
-- ---------------------------------------------------------------------------

local _rows           = {}      -- last assembled row list (display order)
local _ticker                   -- C_Timer ticker; nil when tab is hidden

local _emptyPlateTicks = 0      -- consecutive ticks with no nameplates

local _moHistory       = {}     -- guid -> entry (see captureMouseover)
local _moHistoryN      = 0      -- size hint for LRU eviction
local _moEventFrame             -- registers UPDATE_MOUSEOVER_UNIT once

local _pane
local _sourceDropdown
local _reactionDropdown
local _sortDropdown
local _maxDistBox
local _pauseBtn
local _statusLabel
local _hintLabel                -- below toolbar; visible only when needed
local _scroll
local _scrollContent
local _rowPool        = {}

-- Detail popup (Forge_Logs-style copy/inspect window).
local _detailPopup
local _detailEditBox
local _detailRow                -- row record currently shown in popup


-- Forward declarations for any local function called from above its
-- definition (Lua upvalue gotcha; see lua_forward_declare_locals memory).
local refresh
local relayout
local showDetailPopup    -- defined further down; click handler captures it


-- ---------------------------------------------------------------------------
-- Math helpers
-- ---------------------------------------------------------------------------

local pi    = math.pi
local atan2 = math.atan2
local sqrt  = math.sqrt
local floor = math.floor


-- World distance between two points (player & target). UnitPosition
-- returns posY, posX in yards already, so straight Euclidean distance
-- on the (Y, X) pair gives yards.
local function distYards(py, px, ty, tx)
    if not (py and px and ty and tx) then return nil end
    local dy, dx = ty - py, tx - px
    return sqrt(dy * dy + dx * dx)
end


-- Bearing from player to target relative to player's facing.
-- Returns angle in radians, [-pi, pi]. Positive = left of facing (CCW),
-- negative = right of facing (CW). 0 = directly ahead.
--
-- Coord convention: WoW's UnitPosition returns posY (north positive),
-- posX (west positive). GetPlayerFacing returns radians where 0 = north,
-- CCW positive (so pi/2 = facing west).
--
-- World direction from player to target measured CCW from north =
-- atan2(dx, dy) where dx = +west component, dy = +north component.
-- Subtract player facing to get bearing relative to facing.
local function bearingTo(py, px, ty, tx, facing)
    if not (py and px and ty and tx and facing) then return nil end
    local angle = atan2(tx - px, ty - py) - facing
    while angle >  pi do angle = angle - 2 * pi end
    while angle < -pi do angle = angle + 2 * pi end
    return angle
end


-- Convert relative bearing in [-pi, pi] to a compass label index.
-- 0 = forward (idx 1), going clockwise (right of facing) increments idx.
local function arrowLabel(angle)
    if not angle then return "?" end
    -- Flip sign so positive = clockwise (right of facing).
    local cw = -angle
    while cw <    0   do cw = cw + 2 * pi end
    while cw >= 2 * pi do cw = cw - 2 * pi end
    -- Snap to nearest pi/4, +pi/8 rounding offset.
    local idx = floor((cw + pi / 8) / (pi / 4)) % 8 + 1
    return ARROW_LABELS[idx] or "?"
end


-- ---------------------------------------------------------------------------
-- Reaction classification
-- ---------------------------------------------------------------------------

local function unitReactionKind(unit)
    if not (unit and UnitExists and UnitExists(unit)) then return "unknown" end
    if UnitIsUnit and UnitIsUnit(unit, "player") then return "friend" end
    if UnitIsEnemy and UnitIsEnemy("player", unit) then return "enemy" end
    if UnitIsFriend and UnitIsFriend("player", unit) then return "friend" end
    -- UnitReaction: 1=hated..4=neutral..5..8=friendly
    if UnitReaction then
        local r = UnitReaction("player", unit)
        if r then
            if r >= 5 then return "friend"
            elseif r == 4 then return "neutral"
            else return "enemy" end
        end
    end
    return "unknown"
end


-- ---------------------------------------------------------------------------
-- Row record builder
-- ---------------------------------------------------------------------------
-- Every collector emits records of the same shape so the renderer is
-- collector-agnostic:
--   { kind    = "group"|"nameplate"|"vignette"|"poi",
--     name    = string,
--     unit    = unit token (units only; nil for vignettes/POIs),
--     guid    = GUID (units only),
--     npcID   = number (NPCs only; parsed from GUID),
--     reaction= "friend"|"enemy"|"neutral"|"object"|"unknown",
--     dist    = number yards or nil,
--     bearing = radians [-pi, pi] or nil,
--     mapY    = world Y for click-to-supertrack (objects only),
--     mapX    = world X (objects only),
--     mapID   = uiMapID (objects only),
--     subtype = string for display chip (e.g. "Player"/"NPC"/"Pet"),
--   }


-- ---------------------------------------------------------------------------
-- Player position cache (refreshed once per tick)
-- ---------------------------------------------------------------------------

local _ppY, _ppX, _ppInst, _pFacing


local function refreshPlayerPos()
    _ppY, _ppX, _ppInst = nil, nil, nil
    _pFacing = nil
    if UnitPosition then
        local ok, y, x, _, inst = pcall(UnitPosition, "player")
        if ok then _ppY, _ppX, _ppInst = y, x, inst end
    end
    if GetPlayerFacing then
        local ok, f = pcall(GetPlayerFacing)
        if ok then _pFacing = f end
    end
end


-- ---------------------------------------------------------------------------
-- Helper: build a unit row record
-- ---------------------------------------------------------------------------

local function unitRow(unit, kind, subtype)
    if not (UnitExists and UnitExists(unit)) then return nil end

    local name = UnitName and UnitName(unit) or "?"
    local guid = UnitGUID and UnitGUID(unit) or nil
    local reaction = unitReactionKind(unit)

    -- NPC ID lives in the GUID: Creature-0-...-NPCID-Spawn
    local npcID
    if guid then
        local kindTag, _, _, _, _, npcStr = strsplit("-", guid)
        if kindTag == "Creature" or kindTag == "Vehicle" or kindTag == "Pet"
           or kindTag == "GameObject" then
            npcID = tonumber(npcStr)
        end
    end

    local dist, bearing
    if UnitPosition and _ppY then
        local ok, y, x, _, inst = pcall(UnitPosition, unit)
        if ok and y and x and inst == _ppInst then
            dist    = distYards(_ppY, _ppX, y, x)
            bearing = bearingTo(_ppY, _ppX, y, x, _pFacing)
        end
    end

    local isPlayer = (UnitIsPlayer and UnitIsPlayer(unit)) or false

    return {
        kind     = kind,
        subtype  = subtype,
        name     = name,
        unit     = unit,
        guid     = guid,
        npcID    = npcID,
        isPlayer = isPlayer,
        reaction = reaction,
        dist     = dist,
        bearing  = bearing,
    }
end


-- ---------------------------------------------------------------------------
-- Collectors
-- ---------------------------------------------------------------------------

local function collectGroup(out)
    -- Player + pet always.
    local r = unitRow("player", "group", "Self")
    if r then out[#out + 1] = r end

    if UnitExists and UnitExists("pet") then
        local pr = unitRow("pet", "group", "Pet")
        if pr then out[#out + 1] = pr end
    end

    -- Party (1..4) or Raid (1..40), whichever the player is in.
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do
            local u = "raid" .. i
            local r2 = unitRow(u, "group", "Raid")
            if r2 then out[#out + 1] = r2 end
            local pu = "raidpet" .. i
            local rp = unitRow(pu, "group", "RaidPet")
            if rp then out[#out + 1] = rp end
        end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do
            local u = "party" .. i
            local r2 = unitRow(u, "group", "Party")
            if r2 then out[#out + 1] = r2 end
            local pu = "partypet" .. i
            local rp = unitRow(pu, "group", "PartyPet")
            if rp then out[#out + 1] = rp end
        end
    end

    -- Arena opponents (rated and skirmish PvP).
    for i = 1, 5 do
        local u = "arena" .. i
        local r3 = unitRow(u, "group", "Arena")
        if r3 then out[#out + 1] = r3 end
    end
end


-- Returns the count of nameplate units seen this call.
--
-- We use TWO paths to find nameplates because C_NamePlate.GetNamePlates()
-- has occasionally returned empty even when rendered nameplates clearly
-- existed (the field namePlateUnitToken seems to lag NAME_PLATE_UNIT_ADDED
-- in some patches, and a few special plates such as personal-resource
-- display can lack the field entirely):
--
--   1. C_NamePlate.GetNamePlates() iteration (fast, the canonical path)
--   2. UnitExists("nameplate"..i) walk for i = 1..NAMEPLATE_TOKEN_MAX
--      (covers anything the API missed; tokens are populated by the
--      NAME_PLATE_UNIT_ADDED event so they're authoritative)
--
-- Dedup by GUID across both paths.
local NAMEPLATE_TOKEN_MAX = 40

local function addNameplateUnit(unit, out, seenGUID)
    local guid = UnitGUID and UnitGUID(unit) or nil
    if guid and seenGUID[guid] then return false end
    local subtype = "NPC"
    if UnitIsPlayer and UnitIsPlayer(unit) then
        subtype = "Player"
    end
    local r = unitRow(unit, "nameplate", subtype)
    if r then
        if guid then seenGUID[guid] = true end
        out[#out + 1] = r
        return true
    end
    return false
end


local function collectNameplates(out, seenGUID)
    local n = 0

    -- Path 1: C_NamePlate.GetNamePlates().
    if C_NamePlate and C_NamePlate.GetNamePlates then
        local plates = C_NamePlate.GetNamePlates()
        if plates then
            for _, plate in ipairs(plates) do
                local unit = plate and plate.namePlateUnitToken
                if unit and UnitExists and UnitExists(unit) then
                    n = n + 1
                    addNameplateUnit(unit, out, seenGUID)
                end
            end
        end
    end

    -- Path 2: nameplate1..N token walk. Cheap (40 UnitExists calls) and
    -- covers any nameplate the API didn't surface.
    for i = 1, NAMEPLATE_TOKEN_MAX do
        local unit = "nameplate" .. i
        if UnitExists and UnitExists(unit) then
            -- Only count if path-1 didn't already count it. We can't
            -- cheaply detect overlap, so we accept some double-counting
            -- in the n value; it's used only for the hint threshold.
            n = n + 1
            addNameplateUnit(unit, out, seenGUID)
        end
    end

    return n
end


-- Sticky units: target / focus / mouseover. Always read these even
-- when no nameplate is active. Cheap and useful: lets the user see
-- "what I'm pointing at" with full distance + bearing math, even
-- inside an instance where nameplates may be limited.
local function collectStickyUnits(out, seenGUID)
    local stickyTokens = {
        { unit = "target",    sub = "Target" },
        { unit = "focus",     sub = "Focus" },
        { unit = "mouseover", sub = "Mouseover" },
    }
    for _, info in ipairs(stickyTokens) do
        if UnitExists and UnitExists(info.unit) then
            local guid = UnitGUID and UnitGUID(info.unit) or nil
            if not (guid and seenGUID[guid]) then
                local r = unitRow(info.unit, "sticky", info.sub)
                if r then
                    if guid then seenGUID[guid] = true end
                    out[#out + 1] = r
                end
            end
        end
    end
end


-- Mouseover-history capture: fires on UPDATE_MOUSEOVER_UNIT, snapshots
-- the GUID/name/world position so the entity stays in the radar even
-- after the user looks away. Stored position goes stale fast (the mob
-- may have moved), so the row's distance/bearing reflects the LAST
-- known location, not current. The "Xs ago" subtype tells the user.
local function captureMouseover()
    if not (UnitExists and UnitExists("mouseover")) then return end
    local guid = UnitGUID and UnitGUID("mouseover") or nil
    if not guid then return end

    local name = UnitName and UnitName("mouseover") or "?"
    local reaction = unitReactionKind("mouseover")
    local isPlayer = (UnitIsPlayer and UnitIsPlayer("mouseover")) or false

    local y, x, inst
    if UnitPosition then
        local ok, py, px, _, pinst = pcall(UnitPosition, "mouseover")
        if ok then y, x, inst = py, px, pinst end
    end

    local existing = _moHistory[guid]
    if not existing then _moHistoryN = _moHistoryN + 1 end

    _moHistory[guid] = {
        name     = name,
        y        = y,
        x        = x,
        inst     = inst,
        reaction = reaction,
        isPlayer = isPlayer,
        lastSeen = (GetTime and GetTime()) or 0,
    }

    -- LRU evict if over cap. O(N) per evict but N is bounded at
    -- MO_HISTORY_CAP+1, so worst case 100 iterations once per insert.
    while _moHistoryN > MO_HISTORY_CAP do
        local oldestGUID, oldestTime = nil, math.huge
        for g, e in pairs(_moHistory) do
            if (e.lastSeen or 0) < oldestTime then
                oldestGUID, oldestTime = g, e.lastSeen or 0
            end
        end
        if oldestGUID then
            _moHistory[oldestGUID] = nil
            _moHistoryN = _moHistoryN - 1
        else
            break
        end
    end
end


-- Frame is created once on OnInit and persists for the session, so
-- mouseover history accumulates even when the Radar tab is hidden.
local function ensureMouseoverFrame()
    if _moEventFrame then return end
    if not CreateFrame then return end
    _moEventFrame = CreateFrame("Frame")
    _moEventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    _moEventFrame:SetScript("OnEvent", captureMouseover)
end


local function collectMouseoverHistory(out, seenGUID)
    local now = (GetTime and GetTime()) or 0
    for guid, e in pairs(_moHistory) do
        if not seenGUID[guid] then
            local dist, bearing
            if e.y and e.x and _ppY and e.inst == _ppInst then
                dist    = distYards(_ppY, _ppX, e.y, e.x)
                bearing = bearingTo(_ppY, _ppX, e.y, e.x, _pFacing)
            end
            local age    = now - (e.lastSeen or now)
            local ageStr = ("%ds ago"):format(math.floor(age))
            out[#out + 1] = {
                kind     = "history",
                subtype  = ageStr,
                name     = e.name,
                guid     = guid,
                isPlayer = e.isPlayer or false,
                reaction = e.reaction or "unknown",
                dist     = dist,
                bearing  = bearing,
            }
        end
    end
end


-- Convert a (mapID, normalized x, normalized y) into world (Y, X) for
-- distance + bearing math via C_Map.GetWorldPosFromMapPos.
local function mapToWorld(mapID, nx, ny)
    if not (mapID and nx and ny and C_Map and C_Map.GetWorldPosFromMapPos) then
        return nil, nil, nil
    end
    -- C_Map.GetWorldPosFromMapPos returns (instanceID, vec2D) where
    -- vec2D.x = world Y (north positive) and vec2D.y = world X (west
    -- positive). HBD-2.0 verifies this convention. Note pcall return
    -- order is (ok, instance, world), NOT (ok, world, instance).
    local ok, inst, world = pcall(
        C_Map.GetWorldPosFromMapPos, mapID,
        CreateVector2D and CreateVector2D(nx, ny) or { x = nx, y = ny })
    if not (ok and world) then return nil, nil, nil end
    return world.x, world.y, inst
end


local function collectVignettes(out)
    if not (C_VignetteInfo and C_VignetteInfo.GetVignettes) then return end
    local ids = C_VignetteInfo.GetVignettes()
    if not ids then return end

    local mapID = C_Map and C_Map.GetBestMapForUnit
        and C_Map.GetBestMapForUnit("player") or nil

    for _, id in ipairs(ids) do
        local ok, info = pcall(C_VignetteInfo.GetVignetteInfo, id)
        if ok and info and info.name then
            local pos
            if C_VignetteInfo.GetVignettePosition and mapID then
                local ok2, p = pcall(
                    C_VignetteInfo.GetVignettePosition, id, mapID)
                if ok2 then pos = p end
            end

            local dist, bearing
            if pos and mapID and _ppY then
                local wy, wx, inst = mapToWorld(mapID, pos.x, pos.y)
                if wy and wx and inst == _ppInst then
                    dist    = distYards(_ppY, _ppX, wy, wx)
                    bearing = bearingTo(_ppY, _ppX, wy, wx, _pFacing)
                end
            end

            out[#out + 1] = {
                kind        = "vignette",
                subtype     = info.atlasName or "Vign",
                name        = info.name,
                reaction    = "object",
                dist        = dist,
                bearing     = bearing,
                mapID       = mapID,
                mapX        = pos and pos.x or nil,
                mapY        = pos and pos.y or nil,
                -- info.vignetteID is the numeric vignette type ID
                -- (shared across all instances of the same rare/treasure).
                -- info.objectGUID is the per-instance unique GUID.
                extraID     = info.vignetteID,
                objGUID     = info.objectGUID,
                atlas       = info.atlasName,
                vignetteRaw = info,   -- full table for the detail popup
            }
        end
    end
end


local function collectPOIs(out)
    if not (C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap) then return end
    local mapID = C_Map and C_Map.GetBestMapForUnit
        and C_Map.GetBestMapForUnit("player") or nil
    if not mapID then return end

    local ok, ids = pcall(C_AreaPoiInfo.GetAreaPOIForMap, mapID)
    if not (ok and ids) then return end

    for _, id in ipairs(ids) do
        local ok2, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, id)
        if ok2 and info and info.name then
            local pos = info.position  -- Vector2D normalized
            local dist, bearing
            if pos and _ppY then
                local wy, wx, inst = mapToWorld(mapID, pos.x, pos.y)
                if wy and wx and inst == _ppInst then
                    dist    = distYards(_ppY, _ppX, wy, wx)
                    bearing = bearingTo(_ppY, _ppX, wy, wx, _pFacing)
                end
            end

            out[#out + 1] = {
                kind        = "poi",
                subtype     = info.atlasName or "POI",
                name        = info.name,
                reaction    = "object",
                dist        = dist,
                bearing     = bearing,
                mapID       = mapID,
                mapX        = pos and pos.x or nil,
                mapY        = pos and pos.y or nil,
                -- areaPoiID is the numeric ID; loop variable.
                extraID     = id,
                atlas       = info.atlasName,
                description = info.description,
                poiRaw      = info,   -- full table for the detail popup
            }
        end
    end
end


-- ---------------------------------------------------------------------------
-- Filter + sort
-- ---------------------------------------------------------------------------

-- Pets count as NPCs, not Players, so we need to exclude them when the
-- user filters by Players. Group pets carry these subtype tags.
local function isGroupPet(r)
    return r.kind == "group" and (r.subtype == "Pet"
        or r.subtype == "PartyPet" or r.subtype == "RaidPet")
end


local function rowMatchesSource(r, filter)
    if filter == "All"     then return true end
    if filter == "Group"   then return r.kind == "group" end
    if filter == "Memory"  then return r.kind == "history" end
    if filter == "Objects" then
        return r.kind == "vignette" or r.kind == "poi"
    end
    if filter == "Players" then
        if r.kind == "vignette" or r.kind == "poi" then return false end
        return r.isPlayer == true
    end
    if filter == "NPCs" then
        if r.kind == "vignette" or r.kind == "poi" then return false end
        if r.isPlayer then return false end
        return not isGroupPet(r)  -- pets are NPCs by classification but
                                  -- you usually want them in Group view
                                  -- only; flip this if surprising
    end
    return true
end


local function rowMatchesReaction(r, filter)
    if filter == "All" then return true end
    if filter == "Friend"  then return r.reaction == "friend" end
    if filter == "Enemy"   then return r.reaction == "enemy" end
    if filter == "Neutral" then return r.reaction == "neutral" end
    return true
end


local function applyFilters(rows)
    local sf = db and db.profile.sourceFilter   or "All"
    local rf = db and db.profile.reactionFilter or "All"
    local md = (db and db.profile.maxDistance) or 0
    local out = {}
    for _, r in ipairs(rows) do
        if rowMatchesSource(r, sf) and rowMatchesReaction(r, rf) then
            if md <= 0 or (r.dist and r.dist <= md) then
                out[#out + 1] = r
            end
        end
    end
    return out
end


local function sortRows(rows)
    local mode = db and db.profile.sortMode or "distance"
    if mode == "distance" then
        table.sort(rows, function(a, b)
            local da, dbv = a.dist or 1e9, b.dist or 1e9
            if da ~= dbv then return da < dbv end
            return (a.name or "") < (b.name or "")
        end)
    elseif mode == "name" then
        table.sort(rows, function(a, b)
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)
    elseif mode == "reaction" then
        local rank = { friend = 1, neutral = 2, enemy = 3,
                       object = 4, unknown = 5 }
        table.sort(rows, function(a, b)
            local ra = rank[a.reaction] or 9
            local rb = rank[b.reaction] or 9
            if ra ~= rb then return ra < rb end
            return (a.dist or 1e9) < (b.dist or 1e9)
        end)
    end
end


-- ---------------------------------------------------------------------------
-- Master collect
-- ---------------------------------------------------------------------------

local function collectAll()
    refreshPlayerPos()

    local rows, seenGUID = {}, {}

    -- Order matters for the seenGUID dedup chain:
    --   1. Group  -> own player/pet/party get the canonical row
    --   2. Sticky -> target/focus/mouseover only added if new GUID
    --   3. Nameplate -> visible-range units only added if new GUID
    --   4. History  -> remembered mouseovers only added if not currently
    --                  represented by any of the above
    --   5. Vignette / POI -> not unit-keyed, no GUID dedup needed
    local ok = pcall(collectGroup, rows)
    if not ok then end

    for _, r in ipairs(rows) do
        if r.guid then seenGUID[r.guid] = true end
    end

    pcall(collectStickyUnits, rows, seenGUID)

    -- Nameplate count is returned so we can drive the "press V" hint.
    local npOk, plateCount = pcall(collectNameplates, rows, seenGUID)
    if npOk then
        if (plateCount or 0) == 0 then
            _emptyPlateTicks = _emptyPlateTicks + 1
        else
            _emptyPlateTicks = 0
        end
    end

    pcall(collectMouseoverHistory, rows, seenGUID)
    pcall(collectVignettes, rows)
    pcall(collectPOIs, rows)

    rows = applyFilters(rows)
    sortRows(rows)

    if #rows > MAX_VISIBLE_ROWS then
        for i = MAX_VISIBLE_ROWS + 1, #rows do rows[i] = nil end
    end

    return rows
end


-- ---------------------------------------------------------------------------
-- Row pool + render
-- ---------------------------------------------------------------------------

local function fmtDist(d)
    if not d then return "?" end
    if d < 10 then return ("%.1fy"):format(d) end
    return ("%dy"):format(d + 0.5)
end


local function rowReactionColor(r)
    if r.kind == "vignette" or r.kind == "poi" then
        return REACTION_COLORS.object
    end
    return REACTION_COLORS[r.reaction] or REACTION_COLORS.unknown
end


local function acquireRow(Gui, idx)
    local existing = _rowPool[idx]
    if existing and existing.container then
        existing.container:Show()
        return existing
    end

    local row = {}
    row.container = Gui:Acquire("Container", _scrollContent,
        { height = ROW_HEIGHT })
    row.container:EnableMouse(true)

    row.distLabel = Gui:Acquire("Label", row.container,
        { text = "", variant = "muted" })
    row.distLabel.Cairn:SetLayoutManual(true)
    row.distLabel:ClearAllPoints()
    row.distLabel:SetPoint("LEFT", row.container, "LEFT", 4, 0)
    row.distLabel:SetWidth(50)

    row.bearLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.bearLabel.Cairn:SetLayoutManual(true)
    row.bearLabel:ClearAllPoints()
    row.bearLabel:SetPoint("LEFT", row.container, "LEFT", 56, 0)
    row.bearLabel:SetWidth(40)

    row.kindLabel = Gui:Acquire("Label", row.container,
        { text = "", variant = "muted" })
    row.kindLabel.Cairn:SetLayoutManual(true)
    row.kindLabel:ClearAllPoints()
    row.kindLabel:SetPoint("LEFT", row.container, "LEFT", 100, 0)
    row.kindLabel:SetWidth(50)

    -- ID column: NPC ID for creatures, vignetteID for vignettes,
    -- areaPoiID for POIs. Empty for player rows (Players have GUIDs
    -- but no useful short numeric ID; full GUID lives in detail popup).
    row.idLabel = Gui:Acquire("Label", row.container,
        { text = "", variant = "muted" })
    row.idLabel.Cairn:SetLayoutManual(true)
    row.idLabel:ClearAllPoints()
    row.idLabel:SetPoint("LEFT", row.container, "LEFT", 154, 0)
    row.idLabel:SetWidth(70)

    row.nameLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.nameLabel.Cairn:SetLayoutManual(true)
    row.nameLabel:ClearAllPoints()
    row.nameLabel:SetPoint("LEFT",  row.container, "LEFT",  228, 0)
    row.nameLabel:SetPoint("RIGHT", row.container, "RIGHT", -22,  0)

    row.container:SetScript("OnMouseUp", function(_, button)
        local r = row._row
        if not r then return end

        -- Left-click: open detail popup with full record + live unit
        -- data. showDetailPopup is forward-declared at file top.
        if button == "LeftButton" then
            _detailRow = r
            showDetailPopup()
            return
        end

        -- Right-click: original target / super-track action.
        if button == "RightButton" then
            if r.unit and UnitExists and UnitExists(r.unit) then
                -- /target by name. RunMacroText is non-secure-safe and
                -- avoids tainting the secure environment with TargetUnit
                -- on a nameplate (taint propagates to CompactUnitFrame).
                if r.name and r.name ~= "" and RunMacroText then
                    RunMacroText("/target " .. r.name)
                end
            elseif r.mapID and r.mapX and r.mapY then
                -- Object: super-track a waypoint at the coords.
                -- UiMapPoint is a Mixin table with a CreateFromCoordinates
                -- method; there is no underscore-suffixed global.
                if C_Map and C_Map.SetUserWaypoint
                   and UiMapPoint and UiMapPoint.CreateFromCoordinates then
                    local ok, p = pcall(UiMapPoint.CreateFromCoordinates,
                        r.mapID, r.mapX, r.mapY)
                    if ok and p then
                        pcall(C_Map.SetUserWaypoint, p)
                        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
                        end
                    end
                end
            end
        end
    end)

    _rowPool[idx] = row
    return row
end


local function hideExtraRows(fromIndex)
    for i = fromIndex, #_rowPool do
        if _rowPool[i] and _rowPool[i].container then
            _rowPool[i].container:Hide()
        end
    end
end


-- ---------------------------------------------------------------------------
-- Detail popup (left-click a row)
-- ---------------------------------------------------------------------------
-- Mirrors the Forge_Logs copy/inspect popup pattern: a Window-DIALOG
-- strata window with a multi-line EditBox the user can Ctrl-A / Ctrl-C
-- out of. Built lazily on first open so we don't pay the cost if the
-- user never inspects a row.

local function fmtBearingDetail(angle)
    if not angle then return "?" end
    local glyph = arrowLabel(angle)
    -- Convert to degrees clockwise from forward (intuitive compass).
    local cw = -angle
    while cw <    0   do cw = cw + 2 * pi end
    while cw >= 2 * pi do cw = cw - 2 * pi end
    local deg = floor(cw * 180 / pi + 0.5)
    return ("%s (%d deg, %.3f rad)"):format(glyph, deg, angle)
end


-- Append live UnitX(unit) reads to the lines table. We re-query at
-- popup-open time rather than caching at row-collect time so the user
-- sees current health / combat state, not a stale snapshot.
local function dumpLiveUnit(unit, lines)
    if not (unit and UnitExists and UnitExists(unit)) then
        lines[#lines + 1] = "  (unit no longer exists)"
        return
    end
    local function add(k, v)
        if v == nil or v == "" then return end
        lines[#lines + 1] = ("  %-15s %s"):format(k, tostring(v))
    end
    if UnitLevel          then add("level",         UnitLevel(unit)) end
    if UnitClassification then add("classification", UnitClassification(unit)) end
    if UnitCreatureType   then add("creature type", UnitCreatureType(unit)) end
    if UnitClass and UnitIsPlayer and UnitIsPlayer(unit) then
        local cls, _, classID = UnitClass(unit)
        if cls then add("class", cls .. " (id " .. tostring(classID) .. ")") end
    end
    if UnitRace and UnitIsPlayer and UnitIsPlayer(unit) then
        local race, _, raceID = UnitRace(unit)
        if race then add("race", race .. " (id " .. tostring(raceID) .. ")") end
    end
    if UnitFactionGroup then
        local fac = UnitFactionGroup(unit)
        if fac then add("faction", fac) end
    end
    if UnitHealth and UnitHealthMax then
        local h, m = UnitHealth(unit), UnitHealthMax(unit)
        if h and m and m > 0 then
            add("health", ("%d / %d (%d%%)"):format(
                h, m, floor(h * 100 / m)))
        end
    end
    if UnitIsDead          and UnitIsDead(unit)          then add("dead",       "yes") end
    if UnitIsGhost         and UnitIsGhost(unit)         then add("ghost",      "yes") end
    if UnitAffectingCombat and UnitAffectingCombat(unit) then add("in combat",  "yes") end
    if UnitInVehicle       and UnitInVehicle(unit)       then add("in vehicle", "yes") end
end


local function buildDetail(r)
    if not r then return "(no row selected)" end
    local lines = {}
    local function L(s) lines[#lines + 1] = s end

    L(("== %s =="):format(r.name or "?"))
    L(("kind:           %s"):format(KIND_LABELS[r.kind] or r.kind or "?"))
    if r.subtype and r.subtype ~= "" then
        L(("subtype:        %s"):format(r.subtype))
    end
    if r.npcID    then L(("npcID:          %s"):format(r.npcID)) end
    if r.extraID  then L(("extraID:        %s"):format(tostring(r.extraID))) end
    if r.guid     then L(("guid:           %s"):format(r.guid)) end
    if r.objGUID  then L(("objectGUID:     %s"):format(tostring(r.objGUID))) end
    L(("isPlayer:       %s"):format(tostring(r.isPlayer or false)))
    L(("reaction:       %s"):format(r.reaction or "?"))
    L(("distance:       %s"):format(fmtDist(r.dist)))
    L(("bearing:        %s"):format(fmtBearingDetail(r.bearing)))

    if r.mapID or r.mapX or r.mapY then
        L("")
        L("map:")
        if r.mapID then L(("  mapID:          %s"):format(r.mapID)) end
        if r.mapX  then L(("  mapX:           %.4f"):format(r.mapX)) end
        if r.mapY  then L(("  mapY:           %.4f"):format(r.mapY)) end
    end

    if r.atlas then
        L("")
        L(("atlas:          %s"):format(r.atlas))
    end
    if r.description and r.description ~= "" then
        L(("description:    %s"):format(r.description))
    end

    if r.unit then
        L("")
        L("live unit data:")
        dumpLiveUnit(r.unit, lines)
    end

    if r.kind == "history" then
        L("")
        L("(history snapshot; distance/bearing are computed from the "
          .. "last-known position, NOT current. Mob may have moved.)")
    end

    return table.concat(lines, "\n")
end


local function buildDetailPopup()
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local win = Gui:Acquire("Window", UIParent, {
        title    = "Radar entity detail",
        width    = 560,
        height   = 360,
        strata   = "DIALOG",
        closable = true,
        movable  = true,
    })
    win:Hide()
    win:ClearAllPoints()
    win:SetPoint("CENTER")

    local content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 8 })

    Gui:Acquire("Label", content, {
        text    = "Ctrl-A to select, Ctrl-C to copy. Right-click a row "
                  .. "in the radar to target / waypoint without opening "
                  .. "this dialog.",
        variant = "muted",
    })

    local eb = Gui:Acquire("EditBox", content, {
        width     = 540,
        height    = 270,
        multiline = true,
        text      = "",
    })

    local closeBtn = Gui:Acquire("Button", content, {
        text = "Close", variant = "ghost", width = 80, height = 22,
    })
    closeBtn.Cairn:On("Click", function() win:Hide() end)
    win.Cairn:On("Close", function() win:Hide() end)

    _detailPopup   = win
    _detailEditBox = eb
end


-- Assigned (not `local function`) so the forward-declared upvalue at
-- file top resolves correctly inside acquireRow's earlier OnMouseUp.
showDetailPopup = function()
    if not _detailPopup then buildDetailPopup() end
    if not _detailPopup then return end
    if _detailEditBox and _detailEditBox.Cairn then
        _detailEditBox.Cairn:SetText(buildDetail(_detailRow))
    end
    _detailPopup:Show()
    _detailPopup:Raise()
end


-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

refresh = function()
    if not _scrollContent then return end
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    if db and db.profile.paused then
        if _statusLabel and _statusLabel.Cairn then
            _statusLabel.Cairn:SetText("|cffffaa00paused|r")
        end
        return
    end

    _rows = collectAll()

    if _statusLabel and _statusLabel.Cairn then
        _statusLabel.Cairn:SetText(("|cff888888%d entities|r"):format(#_rows))
    end

    -- Drive the nameplate hint. Show after EMPTY_PLATE_HINT_AFTER ticks
    -- of zero nameplates so a single mid-frame blip doesn't flicker the
    -- label on/off. Neutral wording: the hint says "0 returned" rather
    -- than blaming the user, because in practice an empty result can
    -- mean (a) no units in nameplate range, (b) nameplates toggled off,
    -- or (c) the API momentarily returned empty. Use /forge radardump
    -- to see the raw API state.
    if _hintLabel and _hintLabel.Cairn then
        if _emptyPlateTicks >= EMPTY_PLATE_HINT_AFTER then
            _hintLabel.Cairn:SetText(
                "|cffffaa000 nameplates returned by API. If units are "
                .. "visible nearby, run /forge radardump to inspect.|r")
        else
            _hintLabel.Cairn:SetText("")
        end
    end

    for i, r in ipairs(_rows) do
        local row = acquireRow(Gui, i)
        row._row = r

        row.distLabel.Cairn:SetText(
            "|cff888888" .. fmtDist(r.dist) .. "|r")

        row.bearLabel.Cairn:SetText(
            "|cffaaaaaa" .. arrowLabel(r.bearing) .. "|r")

        local kindTxt = KIND_LABELS[r.kind] or r.kind or "?"
        row.kindLabel.Cairn:SetText(
            "|cff707070[" .. kindTxt .. "]|r")

        -- ID column. Prefer npcID (creatures) over extraID (vignette /
        -- POI). Players get "-" since their GUID is opaque and not a
        -- short ID; full GUID is in the detail popup.
        local idText = ""
        if r.npcID then
            idText = tostring(r.npcID)
        elseif r.extraID then
            idText = tostring(r.extraID)
        elseif r.isPlayer then
            idText = "-"
        end
        row.idLabel.Cairn:SetText("|cff909090" .. idText .. "|r")

        local color = rowReactionColor(r)
        local sub   = r.subtype and (" |cff707070(" .. r.subtype .. ")|r")
                       or ""
        row.nameLabel.Cairn:SetText(
            color .. (r.name or "?") .. "|r" .. sub)
    end
    hideExtraRows(#_rows + 1)

    if _scroll and _scroll.Cairn and _scroll.Cairn.SetContentHeight then
        _scroll.Cairn:SetContentHeight(
            math.max(40, #_rows * (ROW_HEIGHT + 2) + 4))
    end
end


-- ---------------------------------------------------------------------------
-- Relayout
-- ---------------------------------------------------------------------------

relayout = function()
    if not (_pane and _scroll) then return end
    _scroll:ClearAllPoints()
    _scroll:SetPoint("TOPLEFT",     _pane, "TOPLEFT",      SIDE_PAD, -TOP_RESERVED)
    _scroll:SetPoint("BOTTOMRIGHT", _pane, "BOTTOMRIGHT", -SIDE_PAD,  BOTTOM_PAD)
end


-- ---------------------------------------------------------------------------
-- Dropdown helpers
-- ---------------------------------------------------------------------------

local function makeChoices(arr)
    local out = {}
    for _, v in ipairs(arr) do
        out[#out + 1] = { value = v, label = v }
    end
    return out
end


-- ---------------------------------------------------------------------------
-- Build (UI)
-- ---------------------------------------------------------------------------

local function setPauseLabel()
    if not (_pauseBtn and _pauseBtn.Cairn) then return end
    local p = db and db.profile.paused
    _pauseBtn.Cairn:SetText(p and "Resume" or "Pause")
end


local function build(pane)
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end
    _pane = pane

    pane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 10 })

    Gui:Acquire("Label", pane, { text = "Radar", variant = "heading" })

    Gui:Acquire("Label", pane, {
        text    = "|cff888888Live list of nearby group, nameplates, "
                  .. "vignettes, POIs. Distance + bearing relative to "
                  .. "facing. Left-click row for full detail; "
                  .. "right-click to target unit / set waypoint.|r",
        variant = "muted",
    })

    -- Toolbar.
    local toolbar = Gui:Acquire("Container", pane, { height = 28 })
    toolbar.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    _sourceDropdown = Gui:Acquire("Dropdown", toolbar, {
        width    = 110,
        height   = 22,
        options  = makeChoices({ "All", "Group", "Players", "NPCs",
                                 "Objects", "Memory" }),
        selected = db.profile.sourceFilter,
    })
    _sourceDropdown.Cairn:On("Changed", function(_, val)
        db.profile.sourceFilter = val
        refresh()
    end)

    _reactionDropdown = Gui:Acquire("Dropdown", toolbar, {
        width    = 100,
        height   = 22,
        options  = makeChoices({ "All", "Friend", "Enemy", "Neutral" }),
        selected = db.profile.reactionFilter,
    })
    _reactionDropdown.Cairn:On("Changed", function(_, val)
        db.profile.reactionFilter = val
        refresh()
    end)

    _sortDropdown = Gui:Acquire("Dropdown", toolbar, {
        width    = 100,
        height   = 22,
        options  = makeChoices({ "distance", "name", "reaction" }),
        selected = db.profile.sortMode,
    })
    _sortDropdown.Cairn:On("Changed", function(_, val)
        db.profile.sortMode = val
        refresh()
    end)

    _maxDistBox = Gui:Acquire("EditBox", toolbar, {
        width       = 80,
        height      = 22,
        text        = (db.profile.maxDistance and db.profile.maxDistance > 0)
                       and tostring(db.profile.maxDistance) or "",
        placeholder = "Max yds",
    })
    _maxDistBox.Cairn:On("TextChanged", function(_, text)
        local n = tonumber(text or "") or 0
        if n < 0 then n = 0 end
        db.profile.maxDistance = n
        refresh()
    end)

    _pauseBtn = Gui:Acquire("Button", toolbar, {
        text = "Pause", variant = "ghost", width = 80, height = 22,
    })
    _pauseBtn.Cairn:On("Click", function()
        db.profile.paused = not db.profile.paused
        setPauseLabel()
        refresh()
    end)

    _statusLabel = Gui:Acquire("Label", toolbar, {
        text = "|cff888888loading...|r", variant = "muted",
    })

    setPauseLabel()

    -- Nameplate-empty hint. Lives in Stack flow above the column header.
    -- We always reserve its height so the layout doesn't jump when the
    -- hint appears/disappears; refresh() sets the text to "" when
    -- nameplates are healthy and to a yellow nudge when they're not.
    _hintLabel = Gui:Acquire("Label", pane, {
        text    = "",
        variant = "muted",
        height  = HINT_HEIGHT,
    })

    -- Column header bar. Sits above the ScrollFrame in Stack flow so it
    -- does NOT scroll with the rows. Each label uses the same LEFT
    -- offset + width as the corresponding data-row label so columns
    -- visually line up. If you re-anchor a data column, mirror it here.
    local header = Gui:Acquire("Container", pane, { height = HEADER_HEIGHT })

    local function headerLabel(text, leftOff, width)
        local lbl = Gui:Acquire("Label", header, {
            text    = "|cffd0d0d0" .. text .. "|r",
            variant = "muted",
        })
        lbl.Cairn:SetLayoutManual(true)
        lbl:ClearAllPoints()
        lbl:SetPoint("LEFT", header, "LEFT", leftOff, 0)
        if width then lbl:SetWidth(width) end
        return lbl
    end

    headerLabel("Dist", 4,   50)
    headerLabel("Dir",  56,  40)
    headerLabel("Kind", 100, 50)
    headerLabel("ID",   154, 70)
    headerLabel("Name", 228, nil)

    -- ScrollFrame holds rows. Manual-anchored to fill remaining space.
    _scroll = Gui:Acquire("ScrollFrame", pane, {
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
    })
    _scroll.Cairn:SetLayoutManual(true)

    _scrollContent = _scroll.Cairn:GetContent()
    _scrollContent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 2, padding = 4 })

    pane:HookScript("OnSizeChanged", relayout)
    relayout()

    refresh()
end


-- ---------------------------------------------------------------------------
-- Tab descriptor + ticker lifecycle
-- ---------------------------------------------------------------------------

ns.descriptor = {
    name        = "Radar",
    title       = "Radar",
    order       = 95,
    description = "Live list of nearby entities with distance + bearing.",

    OnTabShow = function(pane, mod)
        if not pane.Cairn._builtOnce then
            pane.Cairn._builtOnce = true
            build(pane)
        end
        relayout()
        refresh()

        -- Start the live-update ticker. Cancelled in OnTabHide so the
        -- tab uses zero CPU when not visible.
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


-- Expose for external callers.
ns.UI = {
    Refresh = function() refresh() end,
}


-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function addon:OnInit()
    -- Start mouseover capture immediately. The frame persists for the
    -- session so history accumulates whether or not the Radar tab is
    -- visible; cost is one event subscription that fires only when the
    -- player actually mouses over a unit.
    ensureMouseoverFrame()

    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
    if Forge and Forge.Slash and Forge.Slash.Sub then
        Forge.Slash:Sub("radarpause", function()
            db.profile.paused = not db.profile.paused
            setPauseLabel()
            refresh()
        end, "toggle Forge_Radar pause")

        Forge.Slash:Sub("radarrange", function(arg)
            local n = tonumber(arg or "") or 0
            if n < 0 then n = 0 end
            db.profile.maxDistance = n
            if _maxDistBox and _maxDistBox.Cairn then
                _maxDistBox.Cairn:SetText(n > 0 and tostring(n) or "")
            end
            refresh()
        end, "set Forge_Radar max distance in yards (0 = no limit)")

        Forge.Slash:Sub("radarforget", function()
            _moHistory  = {}
            _moHistoryN = 0
            refresh()
        end, "wipe Forge_Radar mouseover-history bucket")

        -- Diagnostic: dumps what the nameplate API actually reports so
        -- we can tell whether GetNamePlates() is returning empty for a
        -- real reason or a phantom nothing-in-range. Use this when the
        -- "0 nameplates returned" hint appears but units are visible.
        Forge.Slash:Sub("radardump", function()
            local function p(s) print("|cff80c0ff[Forge_Radar]|r " .. s) end

            p("--- nameplate API state ---")

            local pathACount = 0
            if C_NamePlate and C_NamePlate.GetNamePlates then
                local plates = C_NamePlate.GetNamePlates()
                if plates then
                    pathACount = #plates
                    for i, plate in ipairs(plates) do
                        if i > 5 then break end
                        local unit  = plate and plate.namePlateUnitToken
                        local name  = (unit and UnitName) and UnitName(unit)
                        local exists = unit and UnitExists and UnitExists(unit)
                        p(("  GetNamePlates[%d] token=%s name=%s exists=%s"):
                            format(i, tostring(unit), tostring(name),
                                   tostring(exists)))
                    end
                end
                p(("  GetNamePlates() returned %d plates"):format(pathACount))
            else
                p("  C_NamePlate.GetNamePlates is nil (API missing)")
            end

            local pathBCount = 0
            for i = 1, NAMEPLATE_TOKEN_MAX do
                local unit = "nameplate" .. i
                if UnitExists and UnitExists(unit) then
                    pathBCount = pathBCount + 1
                    if pathBCount <= 5 then
                        local name = UnitName and UnitName(unit) or "?"
                        local guid = UnitGUID and UnitGUID(unit) or "?"
                        p(("  token-walk %s name=%s guid=%s"):
                            format(unit, name, tostring(guid)))
                    end
                end
            end
            p(("  nameplate1..%d walk found %d units"):
                format(NAMEPLATE_TOKEN_MAX, pathBCount))

            -- Sticky tokens for context.
            p("--- sticky tokens ---")
            for _, u in ipairs({ "target", "focus", "mouseover" }) do
                local exists = UnitExists and UnitExists(u)
                local name   = exists and UnitName and UnitName(u)
                p(("  %s: exists=%s name=%s"):
                    format(u, tostring(exists), tostring(name)))
            end

            -- Player position for context.
            if UnitPosition then
                local ok, py, px, _, pinst = pcall(UnitPosition, "player")
                if ok then
                    p(("--- player pos: y=%s x=%s inst=%s"):
                        format(tostring(py), tostring(px), tostring(pinst)))
                end
            end
        end, "dump Forge_Radar nameplate / sticky / position API state")
    end
end

-- Forge_BugCatcher.Capture: error grabber with dedup, ignore list, throttle.
--
-- Install path picks ONE of four at boot, in priority order:
--   1. "bg"      — BugGrabber present; register its CallbackHandler-style
--                  hook (probe 4 known API shapes). Capture.Add receives
--                  every error BG sees. BG owns the seterrorhandler slot.
--   2. "bs"      — BugSack present (without BG); same callback probe.
--   3. "bs_poll" — BugSack present but no callback API; poll BS:GetErrors()
--                  on a 1s ticker for net-new entries.
--   4. "seh"     — no external grabber; own the seterrorhandler slot
--                  ourselves. Watchdog re-installs if anyone stomps it.
--
-- Either way we also neuter Blizzard's ScriptErrorsFrame and subscribe to
-- ADDON_ACTION_BLOCKED / _FORBIDDEN, MACRO_ACTION_BLOCKED / _FORBIDDEN,
-- and LUA_WARNING. Entries push into db.profile.errors with normalize /
-- dedup / throttle protections.
--
-- Third-party displays can register by adding `## X-Forge-BugDisplay:
-- <GlobalName>` to their TOC and exposing `<GlobalName>:FormatError(entry)`.
-- Every captured NEW entry is dispatched to all registered displays.
--
-- Throttle: token-bucket capped at THROTTLE_BUCKET_MAX, refilled at
-- THROTTLE_PER_SEC. A runaway addon firing thousands of errors per second
-- from an OnUpdate gets capped instead of freezing the client.

local ADDON, ns = ...

local Capture = {}
ns.Capture = Capture


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local MAX_ENTRIES            = 500  -- cap SV size
local STACK_MAX              = 4000 -- characters; truncate beyond
local LOCALS_MAX             = 4000

local THROTTLE_PER_SEC       = 10   -- token refill rate
local THROTTLE_BUCKET_MAX    = 10   -- burst cap
local THROTTLE_WARN_COOLDOWN = 60   -- seconds between "throttled" chat warnings


-- ---------------------------------------------------------------------------
-- Module-scope state
-- ---------------------------------------------------------------------------
-- Module-level so that re-Install on /reload can read the prior install
-- state and restore the previous error handler. _db is intentionally
-- captured at Install time and not re-fetched — the DB instance is stable
-- across reloads.

local _db
local _onChange      = {}
local _installMethod = "off"      -- "bg" / "bs" / "seh" once installed; "off" otherwise
local _origHandler                 -- the seterrorhandler we displaced; restored on uninstall (future)
local _selfHandler                 -- our installed handler; we compare to detect external overrides (future watchdog hook)
local _eventsFrame                 -- ADDON_ACTION_FORBIDDEN + LUA_WARNING listener
local _eventsActive  = false
local _seenAction    = {}          -- addon-name x event dedup (saves Capture.Add a walk)

-- BugGrabber / BugSack coexistence state.
local _bgAttempted   = false
local _bsAttempted   = false
local _bgRegistered  = false
local _bsRegistered  = false
local _bgError                     -- diagnostic string when probe failed
local _bsError

-- BugSack-polling fallback. Used when BS is installed but exposes no
-- callback API we can probe. Polls BS:GetErrors() once per second and
-- forwards anything past _bsPollLastSeen into Capture.Add.
local _bsPoller
local _bsPollActive    = false
local _bsPollLastSeen  = 0
local _bsPollTotalRead = 0

-- Pluggable bug displays (X-Forge-BugDisplay TOC field). Third-party
-- addons that advertise this field name a global with :FormatError.
-- We dispatch every captured entry to all registered displays.
local _bugDisplays = {}

-- Dedup map: dedupKey -> entry table reference. Populated on every Add
-- and rebuilt from db.profile.errors on Install (so SV-persisted entries
-- still dedup against new captures across /reload).
--
-- Composite key strategy (DevForge pattern): first line of message +
-- first line of stack. Same-text errors thrown from different call sites
-- stay as separate entries; identical errors from the same site collapse
-- into one entry with .count++.
local _dedupMap = {}

-- Forward declaration so Capture.Install (defined earlier in source) can
-- reference rebuildDedupMap which is assigned further down. Lua locals
-- are scoped textually — without this forward declaration, the call site
-- inside Install would resolve to a nil global.
local rebuildDedupMap

-- Watchdog state. Active only when install method is "seh"; BG/BS paths
-- intentionally hand the seterrorhandler slot to the external grabber.
local _watchdog                    -- C_Timer ticker
local _watchdogActive    = false
local _watchdogChecks    = 0
local _watchdogReinstalls = 0
local WATCHDOG_INTERVAL  = 2       -- seconds between checks

-- Throttle state.
local _tokens             = THROTTLE_BUCKET_MAX
local _lastTokenRefill    = nil
local _throttleLastWarn   = 0
local _throttleSkippedRun = 0

-- issecretvalue: Mainline 11.x guard. Reading a Blizzard secret-table value
-- taints execution; if a secret leaks into an error message we drop it
-- silently. Classic clients don't ship the global — fall back to "never
-- secret" so all messages pass through.
local _issecretvalue = _G.issecretvalue or function() return false end


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function nowTs()
    if time then return time() end
    return 0
end


local function fireChange()
    for i = 1, #_onChange do
        pcall(_onChange[i])
    end
end


local function capStr(s, max)
    if type(s) ~= "string" then return nil end
    if #s <= max then return s end
    return s:sub(1, max) .. "\n... (truncated " .. (#s - max) .. " bytes)"
end


-- First line of a possibly-multiline string. Cheap: one find. Used to
-- build the composite dedup key without paying the cost of holding the
-- entire stack in the key.
local function firstLine(s)
    if type(s) ~= "string" then return "" end
    local nl = s:find("\n", 1, true)
    if nl then return s:sub(1, nl - 1) end
    return s
end


local function buildDedupKey(normalizedMessage, stack)
    return firstLine(normalizedMessage) .. "|" .. firstLine(stack or "")
end


-- Token-bucket throttle. Cheap: one GetTime + a few floats per error. The
-- chat warning is rate-limited to once per THROTTLE_WARN_COOLDOWN seconds
-- so an error storm doesn't become a chat-spam storm.
local function consumeToken()
    local now = (GetTime and GetTime()) or 0
    if not _lastTokenRefill then _lastTokenRefill = now end
    _tokens = math.min(THROTTLE_BUCKET_MAX,
        _tokens + (now - _lastTokenRefill) * THROTTLE_PER_SEC)
    _lastTokenRefill = now
    if _tokens < 1 then
        _throttleSkippedRun = _throttleSkippedRun + 1
        if (now - _throttleLastWarn) > THROTTLE_WARN_COOLDOWN then
            _throttleLastWarn = now
            print(("|cffff8800Forge_BugCatcher|r: error capture throttled "
                .. "(%d errors dropped, > %d/sec); a runaway addon may be misbehaving."):format(
                _throttleSkippedRun, THROTTLE_PER_SEC))
            _throttleSkippedRun = 0
        end
        return false
    end
    _tokens = _tokens - 1
    return true
end


-- ---------------------------------------------------------------------------
-- Public: subscriptions
-- ---------------------------------------------------------------------------

function Capture.OnChange(fn)
    if type(fn) ~= "function" then return function() end end
    _onChange[#_onChange + 1] = fn
    return function()
        for i, f in ipairs(_onChange) do
            if f == fn then table.remove(_onChange, i); return end
        end
    end
end


-- ---------------------------------------------------------------------------
-- Public: ignore list
-- ---------------------------------------------------------------------------
-- Patterns are plain substrings (not Lua patterns) so users can paste an
-- error message fragment without escaping magic characters. Match is
-- case-sensitive.

function Capture.Normalize(message)
    return tostring(message or "")
end


-- ParseAddonName: extract the offending addon name from an error message's
-- file path. Looks for "Interface[/\\]AddOns[/\\]<Name>[/\\]" anywhere in the
-- string. Returns the addon name (without folder prefix) or nil.
--
-- Falls back to "FrameXML" / "GlueXML" for Blizzard built-in code paths
-- so those errors group together separately from real addon errors.
function Capture.ParseAddonName(message)
    if type(message) ~= "string" then return nil end
    local m = message:match("Interface[\\/]AddOns[\\/]([^\\/]+)[\\/]")
    if m then return m end
    if message:find("Interface[\\/]FrameXML", 1, false) then return "FrameXML" end
    if message:find("Interface[\\/]GlueXML",  1, false) then return "GlueXML"  end
    return nil
end


-- ExtractLocation: pull the first "<File.lua>:<line>" pair out of a stack
-- or message string. Returns it as a single "File.lua:Line" token, or nil
-- when the input doesn't contain a Lua path. Used to stamp entries with
-- a concise location field surfaced in the Viewer row.
function Capture.ExtractLocation(s)
    if type(s) ~= "string" then return nil end
    local file, line = s:match("([^\\/:%s]+%.lua):(%d+)")
    if file and line then return file .. ":" .. line end
    return nil
end


-- ---------------------------------------------------------------------------
-- Pluggable bug displays (X-Forge-BugDisplay TOC field)
-- ---------------------------------------------------------------------------
-- Any installed addon can advertise itself as a Forge bug display by
-- adding `## X-Forge-BugDisplay: <SomeGlobal>` to its TOC. The named
-- global must expose `:FormatError(entry)`. After every capture we
-- dispatch the entry to each registered display so it can render the
-- error in its own UI surface.
--
-- Scanner runs once per Install (and re-runs on `force` to pick up
-- LoD-loaded displays).

local function scanBugDisplays()
    _bugDisplays = {}
    if not (C_AddOns and C_AddOns.GetNumAddOns) then return end
    local n = C_AddOns.GetNumAddOns() or 0
    for i = 1, n do
        local addonName = C_AddOns.GetAddOnInfo and C_AddOns.GetAddOnInfo(i)
        local loaded    = addonName and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(addonName)
        if loaded then
            local globalName = C_AddOns.GetAddOnMetadata
                and C_AddOns.GetAddOnMetadata(addonName, "X-Forge-BugDisplay")
            if globalName and globalName ~= "" then
                local display = _G[globalName]
                if type(display) == "table" and type(display.FormatError) == "function" then
                    _bugDisplays[#_bugDisplays + 1] = display
                end
            end
        end
    end
end


local function dispatchToDisplays(entry)
    if #_bugDisplays == 0 then return end
    for i = 1, #_bugDisplays do
        local display = _bugDisplays[i]
        local ok, err = pcall(display.FormatError, display, entry)
        if not ok then
            -- A misbehaving display shouldn't break capture. Log via
            -- print (we can't use ns:Info inside Capture's tight loop
            -- without risking re-entry).
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cffff8080Forge_BugCatcher:|r display error: " .. tostring(err))
            end
        end
    end
end


-- ---------------------------------------------------------------------------
-- BugSack polling fallback
-- ---------------------------------------------------------------------------
-- Some installs ship BugSack without a callback API. We can still pick
-- up its captures by polling BS:GetErrors() every second and forwarding
-- net-new entries to Capture.Add. Cheap: one function call + a size
-- comparison per tick.

local function bsPullOnce()
    local BS = _G.BugSack
    if not (BS and type(BS.GetErrors) == "function") then return end
    local ok, errors = pcall(BS.GetErrors, BS)
    if not ok or type(errors) ~= "table" then return end
    for i = _bsPollLastSeen + 1, #errors do
        local e = errors[i]
        if type(e) == "table" then
            local msg = e.message or e[1] or tostring(e)
            Capture.Add(msg, e.stack, e.locals, "error")
            _bsPollTotalRead = _bsPollTotalRead + 1
        end
    end
    _bsPollLastSeen = #errors
end


local function tryBsPoll()
    if _bsPollActive then return true end
    local BS = _G.BugSack
    if not (BS and type(BS.GetErrors) == "function") then
        return false, "BugSack:GetErrors not exposed"
    end
    if not (C_Timer and C_Timer.NewTicker) then
        return false, "C_Timer not available"
    end
    bsPullOnce()
    _bsPoller = C_Timer.NewTicker(1, bsPullOnce)
    _bsPollActive = true
    return true
end


function Capture.IsIgnored(message)
    if not _db then return false end
    local list = _db.profile.ignored
    if type(list) ~= "table" then return false end
    local m = tostring(message or "")
    for i = 1, #list do
        local pat = list[i]
        if type(pat) == "string" and pat ~= "" and string.find(m, pat, 1, true) then
            return true
        end
    end
    return false
end


function Capture.Ignore(pattern)
    if not _db or type(pattern) ~= "string" or pattern == "" then return end
    local list = _db.profile.ignored
    list[#list + 1] = pattern
    fireChange()
end


function Capture.GetIgnoreList()
    if not _db then return {} end
    return _db.profile.ignored or {}
end


function Capture.RemoveIgnore(index)
    if not _db then return end
    local list = _db.profile.ignored
    if type(list) ~= "table" then return end
    if type(index) == "number" and list[index] then
        table.remove(list, index)
        fireChange()
    end
end


-- ---------------------------------------------------------------------------
-- Public: options
-- ---------------------------------------------------------------------------

function Capture.GetOptions()
    if not _db then return { autoPopup = false } end
    return _db.profile.options or { autoPopup = false }
end


function Capture.SetOption(key, value)
    if not _db then return end
    _db.profile.options = _db.profile.options or {}
    _db.profile.options[key] = value
    fireChange()
end


-- ---------------------------------------------------------------------------
-- Public: capture
-- ---------------------------------------------------------------------------
-- Capture.Add(message, stack, locals, kind)
--
-- Stack and locals are optional. seh-path callers capture both via
-- debugstack/debuglocals at the throwing frame; event-path callers
-- (ADDON_ACTION_FORBIDDEN, LUA_WARNING) typically have no stack.
--
-- Both are stored on the entry, capped to STACK_MAX / LOCALS_MAX chars so
-- a deep recursion or bloated locals dump doesn't balloon SavedVariables.

function Capture.Add(message, stack, locals, kind)
    if not _db then return end
    -- Secret-value guard: skip silently so we don't taint execution by
    -- reading the value.
    if _issecretvalue(message) then return end
    if not consumeToken() then return end

    pcall(function()
        local norm = Capture.Normalize(message)
        if Capture.IsIgnored(norm) then return end

        local entries  = _db.profile.errors
        local now      = nowTs()
        local dedupKey = buildDedupKey(norm, stack)

        -- Hash lookup across ALL entries. Same-key hit → bump the existing
        -- entry's count. Different key (or first-seen) → new entry.
        local existing = _dedupMap[dedupKey]
        if existing then
            existing.count  = (existing.count or 1) + 1
            existing.lastTs = now
            if stack  then existing.stack  = capStr(stack,  STACK_MAX)  end
            if locals then existing.locals = capStr(locals, LOCALS_MAX) end
            return
        end

        -- Stamp the offending addon at capture time. Most useful path
        -- is the stack (which has the actual throwing file); fall back
        -- to the message if the stack doesn't expose a path.
        local addonName = Capture.ParseAddonName(stack)
                      or Capture.ParseAddonName(message)
        -- Stamp a concise File.lua:Line location for the Viewer row
        -- summary. Same precedence as addon detection: prefer the
        -- stack since it points at the throwing frame.
        local location = Capture.ExtractLocation(stack)
                     or Capture.ExtractLocation(message)
        local entry = {
            ts         = now,
            lastTs     = now,
            message    = tostring(message),
            normalized = norm,
            count      = 1,
            stack      = capStr(stack,  STACK_MAX),
            locals     = capStr(locals, LOCALS_MAX),
            kind       = kind or "error",  -- "error" / "warning" / "taint" / "block"
            addon      = addonName,        -- nil when path isn't in the message/stack
            location   = location,         -- "File.lua:Line" or nil
            _dedupKey  = dedupKey,         -- back-ref for eviction cleanup
        }
        entries[#entries + 1] = entry
        _dedupMap[dedupKey]   = entry

        -- Evict oldest entries if cap exceeded. Only nil the map entry
        -- when it still points at the evicted entry (guard against
        -- duplicate keys that map to a later entry, though our new
        -- dedup logic shouldn't produce those).
        while #entries > MAX_ENTRIES do
            local oldest = entries[1]
            table.remove(entries, 1)
            if oldest._dedupKey and _dedupMap[oldest._dedupKey] == oldest then
                _dedupMap[oldest._dedupKey] = nil
            end
        end

        -- Dispatch to any addons that registered as X-Forge-BugDisplay.
        -- New entries only — third-party displays generally want one
        -- notify-per-novel-error.
        dispatchToDisplays(entry)
    end)

    fireChange()
end


-- ---------------------------------------------------------------------------
-- Internal: handler installation
-- ---------------------------------------------------------------------------
-- The handler captures debugstack and debuglocals at the THROWING frame —
-- not at Capture.Add's frame, which would just show our own pipeline.
-- xpcall the body so a bug in our own handler doesn't itself trigger a
-- recursive seterrorhandler call.
--
-- ScriptErrorsFrame neuter: UnregisterAllEvents stops Blizzard's frame from
-- listening for runtime errors (we own the seh now anyway). The OnShow→Hide
-- hook is durable: even if a third party calls :Show() on it later it
-- snaps back closed. Without this, /console scriptErrors 1 or any external
-- call to ScriptErrorsFrame:Show() would un-neuter it.

local function installSelfHandler()
    _selfHandler = function(err, lvl)
        local stack  = debugstack(lvl or 2, 20, 20)
        local locals = (debuglocals and debuglocals(lvl or 2)) or nil
        Capture.Add(err, stack, locals, "error")
        return err
    end
    _origHandler = seterrorhandler(_selfHandler)
    _installMethod = "seh"
end


-- ---------------------------------------------------------------------------
-- Slot-guard / watchdog
-- ---------------------------------------------------------------------------
-- Modern Retail forbids hooksecurefunc on `seterrorhandler` itself, so we
-- can't catch overrides instantly via a Cairn-Hooks Post hook. Instead we
-- poll every WATCHDOG_INTERVAL seconds: if our install method is "seh" and
-- the live handler is no longer _selfHandler, an external addon stomped us
-- (BugGrabber/BugSack loading late, an addon calling seterrorhandler with
-- its own function, etc.). Re-install in that case.
--
-- Only runs while _installMethod == "seh". The "bg" and "bs" paths
-- intentionally cede the slot to the external grabber — re-stealing it
-- would defeat coexistence.

local function watchdogTick()
    _watchdogChecks = _watchdogChecks + 1
    if _installMethod ~= "seh" then return end
    if not geterrorhandler then return end
    local current = geterrorhandler()
    if current == _selfHandler then return end

    -- Slot stolen. Preserve whoever's there now as the chain target so
    -- their handler still gets called when ours forwards (currently we
    -- don't forward in installSelfHandler, but storing the prior handler
    -- gives the future-chained variant a target).
    _origHandler = current
    installSelfHandler()
    _watchdogReinstalls = _watchdogReinstalls + 1
end


function Capture.WireSlotGuard()
    if _watchdogActive then return end
    if not (C_Timer and C_Timer.NewTicker) then return end
    _watchdog = C_Timer.NewTicker(WATCHDOG_INTERVAL, watchdogTick)
    _watchdogActive = true
end


function Capture.StopSlotGuard()
    if _watchdog and _watchdog.Cancel then _watchdog:Cancel() end
    _watchdog       = nil
    _watchdogActive = false
end


-- ---------------------------------------------------------------------------
-- BugGrabber / BugSack callback probes
-- ---------------------------------------------------------------------------
-- Each error tracker (BugGrabber, BugSack, ImprovedErrorFrame forks, etc.)
-- exposes its callback API in a slightly different shape depending on which
-- CallbackHandler revision the author was targeting. We probe four paths in
-- order; the first that succeeds wins. Diagnostic failure strings are
-- collected on _bgError / _bsError for the bugstatus subcommand.
--
-- When the callback registers successfully, OUR Capture.Add receives every
-- error the tracker captures — we coexist with its UI rather than fighting
-- for the seterrorhandler slot.

local function makeBGCallback()
    return function(_, errorObject)
        if not errorObject then return end
        local msg = errorObject.message
            or (errorObject[1] and tostring(errorObject[1]))
            or tostring(errorObject)
        Capture.Add(msg, errorObject.stack, errorObject.locals, "error")
    end
end


local function tryCallback(targetGlobal)
    local T = _G[targetGlobal]
    if not T then return false, "global '" .. targetGlobal .. "' not present" end

    local cb     = makeBGCallback()
    local errors = {}

    -- Path A: T:RegisterCallback(target, event, method) — CallbackHandler on T directly.
    if type(T.RegisterCallback) == "function" then
        local ok, err = pcall(T.RegisterCallback, T, ns, "BugGrabber_BugGrabbed", cb)
        if ok then return true end
        errors[#errors + 1] = "A: " .. tostring(err)
    else
        errors[#errors + 1] = "A: RegisterCallback is " .. type(T.RegisterCallback)
    end

    -- Path B: T.callbacks:RegisterCallback(target, event, method) — CH sub-object, colon.
    if type(T.callbacks) == "table" and type(T.callbacks.RegisterCallback) == "function" then
        local ok, err = pcall(T.callbacks.RegisterCallback, T.callbacks, ns, "BugGrabber_BugGrabbed", cb)
        if ok then return true end
        errors[#errors + 1] = "B: " .. tostring(err)
    end

    -- Path C: T.callbacks.RegisterCallback(target, event, method) — CH sub-object, dot-call style.
    if type(T.callbacks) == "table" and type(T.callbacks.RegisterCallback) == "function" then
        local ok, err = pcall(T.callbacks.RegisterCallback, ns, "BugGrabber_BugGrabbed", cb)
        if ok then return true end
        errors[#errors + 1] = "C: " .. tostring(err)
    end

    -- Path D: T:RegisterMessage — AceEvent-3.0 style.
    if type(T.RegisterMessage) == "function" then
        local ok, err = pcall(T.RegisterMessage, T, ns, "BugGrabber_BugGrabbed", cb)
        if ok then return true end
        errors[#errors + 1] = "D: " .. tostring(err)
    end

    return false, table.concat(errors, "  |  ")
end


local function neuterScriptErrorsFrame()
    if not ScriptErrorsFrame then return end
    ScriptErrorsFrame:UnregisterAllEvents()
    ScriptErrorsFrame:Hide()
    if not ScriptErrorsFrame._forgeNeutered then
        ScriptErrorsFrame:HookScript("OnShow", function(self) self:Hide() end)
        ScriptErrorsFrame._forgeNeutered = true
    end
end


-- ---------------------------------------------------------------------------
-- Internal: ADDON_ACTION + LUA_WARNING events
-- ---------------------------------------------------------------------------
-- ADDON_ACTION_BLOCKED / _FORBIDDEN fire when an addon attempts a
-- protected call (combat-locked or secure-only API).
-- MACRO_ACTION_BLOCKED / _FORBIDDEN fire when a macro tries the same.
-- LUA_WARNING fires for runtime warnings that don't rise to error level.
-- All five are worth capturing for dev-tools — they often hint at the
-- root cause of a downstream error.

-- Lookup table for event → entry kind so onEvent stays a flat dispatch.
local ACTION_KINDS = {
    ADDON_ACTION_FORBIDDEN = "taint",
    ADDON_ACTION_BLOCKED   = "block",
    MACRO_ACTION_FORBIDDEN = "taint",
    MACRO_ACTION_BLOCKED   = "block",
}

local function onEvent(self, event, arg1, arg2)
    local kind = ACTION_KINDS[event]
    if kind then
        -- ADDON_ACTION_*: arg1 = addon name, arg2 = protected function name.
        -- MACRO_ACTION_*: arg1 = macro name, arg2 = protected function name.
        local who      = tostring(arg1 or "?")
        local funcName = tostring(arg2 or "?")
        local key      = event .. "|" .. who .. "|" .. funcName
        if _seenAction[key] then return end
        _seenAction[key] = true
        local prefix = event:match("^MACRO_") and "Macro" or "AddOn"
        Capture.Add(
            ("[%s] %s '%s' tried to call the protected function '%s'."):format(
                event, prefix, who, funcName),
            nil, nil, kind)
    elseif event == "LUA_WARNING" then
        -- arg1 = warning type (number), arg2 = message
        Capture.Add(("LUA_WARNING: %s"):format(tostring(arg2 or arg1 or "?")),
            nil, nil, "warning")
    end
end


function Capture.RegisterEvents()
    if _eventsActive then return end
    if not _eventsFrame then
        _eventsFrame = CreateFrame("Frame")
        _eventsFrame:SetScript("OnEvent", onEvent)
    end
    _eventsFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
    _eventsFrame:RegisterEvent("ADDON_ACTION_BLOCKED")
    _eventsFrame:RegisterEvent("MACRO_ACTION_FORBIDDEN")
    _eventsFrame:RegisterEvent("MACRO_ACTION_BLOCKED")
    _eventsFrame:RegisterEvent("LUA_WARNING")
    _eventsActive = true
end


-- ---------------------------------------------------------------------------
-- Strip Blizzard's default ADDON_ACTION / LUA_WARNING handlers
-- ---------------------------------------------------------------------------
-- Called only when running STANDALONE (no BugGrabber detected). BugGrabber
-- does the same thing when it owns the slot — UnregisterEvent on UIParent +
-- ScriptErrorsFrame so the default red error popup doesn't appear on top of
-- our own UI. With BugGrabber present, BG handles this — we skip to avoid
-- a double-strip causing weird state.
--
-- pcall'd because UnregisterEvent on a frame that didn't register the event
-- is harmless but pcall keeps a future Retail change from breaking Install.

local function stripBlizzardDefaults()
    if UIParent and UIParent.UnregisterEvent then
        pcall(UIParent.UnregisterEvent, UIParent, "ADDON_ACTION_BLOCKED")
        pcall(UIParent.UnregisterEvent, UIParent, "ADDON_ACTION_FORBIDDEN")
        pcall(UIParent.UnregisterEvent, UIParent, "MACRO_ACTION_BLOCKED")
        pcall(UIParent.UnregisterEvent, UIParent, "MACRO_ACTION_FORBIDDEN")
    end
    if _G.ScriptErrorsFrame and _G.ScriptErrorsFrame.UnregisterEvent then
        pcall(_G.ScriptErrorsFrame.UnregisterEvent, _G.ScriptErrorsFrame, "LUA_WARNING")
    end
end


-- ---------------------------------------------------------------------------
-- Public: install / status
-- ---------------------------------------------------------------------------

function Capture.Install(db, force)
    _db = db

    -- Rebuild the dedup map from any SV-persisted entries so a /reload-
    -- survived error still merges with new occurrences rather than
    -- appearing as a duplicate row.
    rebuildDedupMap()

    -- Action/warning events install independently of the seh/bg/bs chain
    -- — they fire outside the Lua-error pipeline anyway.
    Capture.RegisterEvents()

    -- Pick up any X-Forge-BugDisplay registrations from currently-loaded
    -- addons. Re-scanned on `force` so LoD-loaded displays land.
    scanBugDisplays()

    if _installMethod ~= "off" and not force then return end

    -- Probe BugGrabber first. If it's loaded, prefer its callback over the
    -- seh slot — coexistence wins because BG's stack capture happens at the
    -- throwing frame, not at our handler.
    if not _bgAttempted then
        local ok, err = tryCallback("BugGrabber")
        _bgAttempted  = true
        if ok then
            _installMethod = "bg"
            _bgRegistered  = true
            _bgError       = nil
            neuterScriptErrorsFrame()
            return
        end
        _bgError = err
    end

    -- BugSack second. Some installs ship BugSack without BugGrabber (BS
    -- can pull errors from a different source). Same probe pattern.
    if not _bsAttempted then
        local ok, err = tryCallback("BugSack")
        _bsAttempted  = true
        if ok then
            _installMethod = "bs"
            _bsRegistered  = true
            _bsError       = nil
            neuterScriptErrorsFrame()
            return
        end
        _bsError = err
    end

    -- BugSack-polling third. If BS is installed but doesn't expose a
    -- callback API we could probe, fall back to polling its GetErrors()
    -- on a 1s ticker. Common with older / minimal BS forks.
    if _G.BugSack and not _bsPollActive then
        local ok, err = tryBsPoll()
        if ok then
            _installMethod = "bs_poll"
            neuterScriptErrorsFrame()
            return
        end
        -- Stash poll error alongside callback error for diagnostics.
        if err and not _bsError then _bsError = err end
    end

    -- Fallback: own the seh slot ourselves.
    installSelfHandler()
    neuterScriptErrorsFrame()
    -- Standalone path → also strip Blizzard's default UIParent/SEF event
    -- listeners so their red popups don't compete with our viewer. BG path
    -- doesn't do this (BG handles it).
    stripBlizzardDefaults()
end


function Capture.IsActive()
    return _installMethod ~= "off"
end


function Capture.Status()
    local entries = (_db and _db.profile.errors)  or {}
    local ignored = (_db and _db.profile.ignored) or {}
    return {
        method              = _installMethod,
        active              = _installMethod ~= "off",
        entries             = #entries,
        ignored             = #ignored,
        eventsActive        = _eventsActive,
        hasBugGrabber       = _G.BugGrabber ~= nil,
        hasBugSack          = _G.BugSack    ~= nil,
        bgRegistered        = _bgRegistered,
        bsRegistered        = _bsRegistered,
        bgError             = _bgError,
        bsError             = _bsError,
        bsPollActive        = _bsPollActive,
        bsPollLastSeen      = _bsPollLastSeen,
        bsPollTotalRead     = _bsPollTotalRead,
        bugDisplayCount     = #_bugDisplays,
        watchdogActive      = _watchdogActive,
        watchdogChecks      = _watchdogChecks,
        watchdogReinstalls  = _watchdogReinstalls,
    }
end


function Capture.GetAll()
    if not _db then return {} end
    return _db.profile.errors or {}
end


function Capture.Clear()
    if not _db then return end
    local errors = _db.profile.errors
    for k in pairs(errors) do errors[k] = nil end
    -- Wipe the dedup map alongside — next capture starts fresh.
    for k in pairs(_dedupMap) do _dedupMap[k] = nil end
    -- _seenAction is per-session dedup state; keep it as-is so a /forge
    -- bug clear doesn't immediately re-fill with a torrent of the same
    -- forbidden-action error.
    fireChange()
end


-- Rebuild the dedup map from the SV-persisted entries. Called once at
-- Install so /reload-survived entries still merge with newly-captured
-- ones rather than appearing twice. Older entries without a _dedupKey
-- (from before this upgrade) get one computed on the fly.
--
-- Body assigned to the forward-declared local up top (no `local` keyword
-- here — that would shadow it).
function rebuildDedupMap()
    for k in pairs(_dedupMap) do _dedupMap[k] = nil end
    if not (_db and _db.profile.errors) then return end
    for _, entry in ipairs(_db.profile.errors) do
        local key = entry._dedupKey
        if not key then
            key = buildDedupKey(entry.normalized or entry.message or "", entry.stack)
            entry._dedupKey = key
        end
        _dedupMap[key] = entry
    end
end


function Capture.SessionCount()
    return (_db and _db.global and _db.global.totalSessions) or 0
end

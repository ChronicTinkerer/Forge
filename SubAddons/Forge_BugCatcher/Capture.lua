-- Forge_BugCatcher.Capture: error capture, dedup, ignore list, change events.
-- Probes multiple callback API shapes so we can integrate with whichever
-- external error tracker the user has installed (each version exposes
-- RegisterCallback in slightly different layouts).

local ADDON, ns = ...

local Capture = {}
ns.Capture = Capture

local DEDUP_WINDOW = 30
local MAX_ENTRIES  = 500

local _db
local _onChange = {}

local _installMethod
local _origHandler
local _selfHandler
local _bgRegistered
local _bsRegistered
local _bgError
local _bsError
local _hookInstalled
local _hookFireCount = 0
local _watchdog
local _watchdogChecks = 0
local _watchdogReinstalls = 0
local _bgAttempted = false
local _bsAttempted = false
local _sehAnnounced = false
local _bsPollAttempted = false
local _bsPoller
local _bsPollLastSeen = 0
local _bsPollTotalRead = 0
local _sessionMarked = false

local function nowTs()
    if time then return time() end
    return os.time()
end

local function getLog()
    local Cairn = _G.Cairn
    if Cairn and Cairn.Log then return Cairn.Log("Forge_BugCatcher") end
    return nil
end

local function fireChange()
    for i = 1, #_onChange do
        pcall(_onChange[i])
    end
end

function Capture.OnChange(fn)
    if type(fn) ~= "function" then return function() end end
    _onChange[#_onChange + 1] = fn
    return function()
        for i, f in ipairs(_onChange) do
            if f == fn then table.remove(_onChange, i); return end
        end
    end
end

function Capture.Normalize(message) return tostring(message or "") end

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

-- Capture.Add(message, stack, locals)
--
-- Stack and locals are optional. When the error arrives via the seh path
-- (our own seterrorhandler), the caller is in a position to capture both
-- via debugstack/debuglocals; pass them in. Callback-path arrivals (from
-- BugGrabber/BugSack) only get whatever the external tracker already
-- collected -- those callers should pass whatever stack the error object
-- exposed (BugGrabber's errorObject.stack), or nil if absent.
--
-- Both are stored on the entry but capped to reasonable string lengths so
-- a deep recursion or bloated locals dump doesn't balloon SavedVariables.
local STACK_MAX  = 4000
local LOCALS_MAX = 4000
local function capStr(s, max)
    if type(s) ~= "string" then return nil end
    if #s <= max then return s end
    return s:sub(1, max) .. "\n... (truncated " .. (#s - max) .. " bytes)"
end

function Capture.Add(message, stack, locals)
    if not _db then return end
    pcall(function()
        local norm = Capture.Normalize(message)
        if Capture.IsIgnored(norm) then return end
        local entries = _db.profile.errors
        local now = nowTs()
        local last = entries[#entries]
        if last and last.normalized == norm and (now - (last.lastTs or last.ts or 0)) < DEDUP_WINDOW then
            last.count  = (last.count or 1) + 1
            last.lastTs = now
            -- Refresh stack/locals on dedup so the most recent occurrence's
            -- context wins -- they may have shifted if the error fires from
            -- different call sites that normalize to the same string.
            if stack  then last.stack  = capStr(stack,  STACK_MAX)  end
            if locals then last.locals = capStr(locals, LOCALS_MAX) end
        else
            entries[#entries + 1] = {
                ts         = now,
                lastTs     = now,
                message    = tostring(message),
                normalized = norm,
                count      = 1,
                stack      = capStr(stack,  STACK_MAX),
                locals     = capStr(locals, LOCALS_MAX),
            }
            while #entries > MAX_ENTRIES do table.remove(entries, 1) end
        end
    end)
    fireChange()
end

-- Build the callback function used for external-error-tracker callbacks.
-- BugGrabber's error object typically has .message, .stack, .locals, .time,
-- .session, .counter -- forward what's there; debuglocals/debugstack at this
-- point would capture our handler frame, not the throwing frame, so we only
-- use the external tracker's pre-collected values.
local function makeBGCallback()
    return function(_, errorObject)
        if not errorObject then return end
        local msg = errorObject.message
            or (errorObject[1] and tostring(errorObject[1]))
            or tostring(errorObject)
        Capture.Add(msg, errorObject.stack, errorObject.locals)
    end
end

-- Fallback path: poll an external display addon's :GetErrors() method
-- when callback registration isn't available. Each ticker call reads any
-- new entries past _bsPollLastSeen and forwards them.
local function tryExternalPoll()
    local BS = _G.BugSack
    if not BS or type(BS.GetErrors) ~= "function" then
        return false, "external error display .GetErrors not available"
    end
    if not (C_Timer and C_Timer.NewTicker) then
        return false, "C_Timer not available"
    end

    -- Helper that reads the external display's error list and forwards new
    -- entries. Filters by sessionStart so we don't inherit pre-session
    -- history that the external addon persisted across /reload.
    local function pull()
        local ok, errors = pcall(BS.GetErrors, BS)
        if not ok or type(errors) ~= "table" then return end
        local sessionStart = (_db and _db.global.sessionStart) or 0
        for i = _bsPollLastSeen + 1, #errors do
            local e = errors[i]
            if type(e) == "table" then
                local errTime = tonumber(e.time) or 0
                if errTime >= sessionStart then
                    local msg = e.message or e[1] or tostring(e)
                    Capture.Add(msg, errTime)
                    _bsPollTotalRead = _bsPollTotalRead + 1
                end
            end
        end
        _bsPollLastSeen = #errors
    end

    -- Pull whatever is already there.
    pull()

    -- Then poll every 1s. Cheap (one function call + table size check).
    _bsPoller = C_Timer.NewTicker(1, pull)

    return true
end

local function tryCallback(targetGlobal)
    local T = _G[targetGlobal]
    if not T then return false, "global '" .. targetGlobal .. "' not present" end

    local cb = makeBGCallback()
    local errors = {}

    -- Path A: T.RegisterCallback(target, event, method)
    if type(T.RegisterCallback) == "function" then
        local ok, err = pcall(T.RegisterCallback, ns, "BugGrabber_BugGrabbed", cb)
        if ok then return true end
        errors[#errors + 1] = "A: " .. tostring(err)
    else
        errors[#errors + 1] = "A: T.RegisterCallback is " .. type(T.RegisterCallback)
    end

    -- Path B: T.callbacks:RegisterCallback(event, method)  (CH-1.0 sub-object, colon)
    if type(T.callbacks) == "table" and type(T.callbacks.RegisterCallback) == "function" then
        local ok, err = pcall(T.callbacks.RegisterCallback, T.callbacks, ns, "BugGrabber_BugGrabbed", cb)
        if ok then return true end
        errors[#errors + 1] = "B: " .. tostring(err)
    else
        errors[#errors + 1] = "B: T.callbacks." ..
            (type(T.callbacks) == "table" and "RegisterCallback is " .. type(T.callbacks.RegisterCallback)
                                         or "callbacks is " .. type(T.callbacks))
    end

    -- Path C: T.callbacks.RegisterCallback(target, event, method)  (CH-1.0 sub-object, dot)
    if type(T.callbacks) == "table" and type(T.callbacks.RegisterCallback) == "function" then
        local ok, err = pcall(T.callbacks.RegisterCallback, ns, "BugGrabber_BugGrabbed", cb)
        if ok then return true end
        errors[#errors + 1] = "C: " .. tostring(err)
    end

    -- Path D: T.RegisterMessage (AceEvent / AceEvent-3.0)
    if type(T.RegisterMessage) == "function" then
        local ok, err = pcall(T.RegisterMessage, ns, "BugGrabber_BugGrabbed", cb)
        if ok then return true end
        errors[#errors + 1] = "D: " .. tostring(err)
    end

    return false, table.concat(errors, "  |  ")
end

function Capture.Install(db, force)
    _db = db
    if _db and not _sessionMarked then
        _db.global.sessionStart = (time and time()) or os.time()
        _sessionMarked = true
        -- Forge's buffer is intentionally session-only. External error
        -- displays are the long-term store; bs_poll re-fills with this
        -- session's errors only. Without this we would accumulate forever.
        _db.profile.errors = {}
    end
    if _installMethod and not force then return end

    local log = getLog()

    -- bg/bs callback paths are best-effort probes for an installed external
    -- error tracker that exposes a CallbackHandler-style API. On installs
    -- without !BugGrabber (BugSack standalone, or no tracker at all), both
    -- probes legitimately fail and we fall through to bs_poll / seh. Failure
    -- reasons are stashed on _bgError / _bsError for `/forge bugstatus`
    -- diagnostics but NOT logged at warn level — the warn belongs only at
    -- the end if every path failed.
    if not _bgAttempted then
        local okBG, errBG = tryCallback("BugGrabber")
        if okBG then
            _installMethod, _bgRegistered, _bgError = "bg", true, nil
            if log then log:Info("installed via grabber-style callback.") end
            return
        end
        _bgError     = errBG
        _bgAttempted = true
    elseif _bgRegistered then
        return  -- already installed via callback; nothing to do
    end

    if not _bsAttempted then
        local okBS, errBS = tryCallback("BugSack")
        if okBS then
            _installMethod, _bsRegistered, _bsError = "bs", true, nil
            if log then log:Info("installed via display-style callback.") end
            return
        end
        _bsError     = errBS
        _bsAttempted = true
    elseif _bsRegistered then
        return
    end

    -- Fallback: poll the external display's GetErrors() on a timer when
    -- callback registration isn't available (some display addons keep the
    -- seh slot for themselves; we just read their buffer instead).
    if not _bsPollAttempted then
        local okBSP, errBSP = tryExternalPoll()
        _bsPollAttempted = true
        if okBSP then
            _installMethod = "bs_poll"
            if log then log:Info("installed via external display polling.") end
            return
        end
        if log then log:Warn("external display polling not available: %s", tostring(errBSP)) end
    elseif _installMethod == "bs_poll" then
        return  -- already polling; nothing to redo
    end

    -- Fall back to seterrorhandler chain.
    local prev = (geterrorhandler and geterrorhandler()) or nil
    if prev == _selfHandler then prev = _origHandler end
    _origHandler = prev or false

    -- self_handler runs on the same call stack as the throwing function, so
    -- debugstack/debuglocals here capture the throwing frame's context. Skip
    -- our own frame (1) to start at WoW's error caller. This is the
    -- richest-context capture path -- BugGrabber/BugSack chains lose the
    -- live stack by the time their handler fires through CallbackHandler.
    local self_handler
    self_handler = function(msg)
        local stack  = debugstack and debugstack(2, 20, 10)
        local locals = debuglocals and debuglocals(2)
        Capture.Add(msg, stack, locals)
        if _origHandler and _origHandler ~= self_handler then
            pcall(_origHandler, msg)
        end
    end
    _selfHandler = self_handler

    if seterrorhandler then
        seterrorhandler(self_handler)
        _installMethod = "seh"
        if log and not _sehAnnounced then
            log:Info("installed via seterrorhandler (chained = %s).", tostring(prev ~= nil))
            _sehAnnounced = true
        end
    else
        if log and not _sehAnnounced then
            log:Error("no seterrorhandler available; capture disabled.")
            _sehAnnounced = true
        end
    end
end


-- Combined slot-guard:
--   Path A (instant):   Cairn.Hooks.Post("seterrorhandler", ...) catches any
--                       call routed through the global. Doesn't catch addons
--                       that saved a direct reference before hooks landed.
--   Path B (catch-all): a frame OnUpdate ticking at 0.1s. If anyone's bypass
--                       leaves us not-active, we re-install. Cost is one
--                       IsActive() comparison per tick; full re-install only
--                       runs when we actually got bypassed.
function Capture.WireSlotGuard()
    -- Path A. Modern Midnight (Interface 120005) forbids hooksecurefunc on
    -- `seterrorhandler` -- the engine throws "X is forbidden for hooking" at
    -- the call site. Cairn.Hooks now pcalls the hook install, but we still
    -- pcall the Post() entry point itself so any future protection of other
    -- globals doesn't take WireSlotGuard offline. If Path A doesn't install,
    -- Path B (watchdog) is enough on its own to keep the slot ours.
    if not _hookInstalled then
        local Cairn = _G.Cairn
        if Cairn and Cairn.Hooks and Cairn.Hooks.Post then
            local ok = pcall(Cairn.Hooks.Post, "seterrorhandler", function(newHandler)
                _hookFireCount = _hookFireCount + 1
                if not _selfHandler then return end
                if newHandler == _selfHandler then return end
                _origHandler = newHandler
                if seterrorhandler then seterrorhandler(_selfHandler) end
            end)
            _hookInstalled = ok and true or false
        end
    end

    -- Path B.
    if not _watchdog and CreateFrame then
        _watchdog = CreateFrame("Frame")
        local accum = 0
        _watchdog:SetScript("OnUpdate", function(_, elapsed)
            accum = accum + (elapsed or 0)
            if accum < 0.1 then return end
            accum = 0
            _watchdogChecks = _watchdogChecks + 1
            if not Capture.IsActive() and _db then
                _watchdogReinstalls = _watchdogReinstalls + 1
                Capture.Install(_db, true)
            end
        end)
    end

    return _hookInstalled, (_watchdog and true) or false
end

-- Backwards-compat alias (not in active use, kept so older Core.lua copies don't break).
function Capture.StartMaintainer() return Capture.WireSlotGuard() end
function Capture.StopMaintainer()
    if _watchdog and _watchdog.SetScript then _watchdog:SetScript("OnUpdate", nil) end
    _watchdog = nil
end

function Capture.IsActive()
    if _installMethod == "bg" then return _bgRegistered or false end
    if _installMethod == "bs" then return _bsRegistered or false end
    if _installMethod == "bs_poll" then return _bsPoller and true or false end
    if _installMethod == "seh" then
        if not (geterrorhandler and _selfHandler) then return false end
        return geterrorhandler() == _selfHandler
    end
    return false
end

-- Diagnostic: enumerate top-level keys (and types) of a global. Limited count so
-- chat output stays readable.
function Capture.Probe(targetGlobal, max)
    local T = _G[targetGlobal]
    max = max or 25
    if not T then return { absent = true, name = targetGlobal } end
    local out = { name = targetGlobal, kind = type(T), keys = {} }
    if type(T) == "table" then
        local n = 0
        for k, v in pairs(T) do
            n = n + 1
            if n > max then
                out.keys[#out.keys + 1] = "...(" .. tostring(n) .. " more)"
                break
            end
            out.keys[#out.keys + 1] = tostring(k) .. " : " .. type(v)
        end
        out.count = n
    end
    return out
end

function Capture.Status()
    return {
        method        = _installMethod or "none",
        active        = Capture.IsActive(),
        hasBugGrabber = (_G.BugGrabber and true) or false,
        hasBugSack    = (_G.BugSack and true) or false,
        bgRegistered  = _bgRegistered or false,
        bsRegistered  = _bsRegistered or false,
        bgError       = _bgError,
        bsError       = _bsError,
        chained       = (_installMethod == "seh") and (_origHandler and true or false) or false,
        entries       = (_db and #_db.profile.errors) or 0,
        ignored       = (_db and #_db.profile.ignored) or 0,
        sessionStart  = (_db and _db.global.sessionStart) or 0,
        sessionCount         = Capture.SessionCount(),
        hookInstalled        = _hookInstalled and true or false,
        hookFireCount        = _hookFireCount,
        watchdogActive       = (_watchdog and true) or false,
        watchdogChecks       = _watchdogChecks,
        watchdogReinstalls   = _watchdogReinstalls,
        bsPollActive         = _bsPoller and true or false,
        bsPollTotalRead      = _bsPollTotalRead,
        bsPollLastSeen       = _bsPollLastSeen,
    }
end

function Capture.GetAll()
    if not _db then return {} end
    local entries = _db.profile.errors
    local out = {}
    for i = #entries, 1, -1 do out[#out + 1] = entries[i] end
    return out
end

function Capture.SessionCount()
    if not _db then return 0 end
    local since = _db.global.sessionStart or 0
    local n = 0
    for _, e in ipairs(_db.profile.errors) do
        if (e.lastTs or e.ts or 0) >= since then
            n = n + (e.count or 1)
        end
    end
    return n
end

function Capture.Clear()
    if not _db then return end
    _db.profile.errors = {}
    fireChange()
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
    table.remove(_db.profile.ignored, index)
    fireChange()
end

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

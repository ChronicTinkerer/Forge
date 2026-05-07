-- Forge_Console.Eval: run a snippet, capture print output, pretty-print return values.

local ADDON, ns = ...

local Eval = {}
ns.Eval = Eval

local lua_load = loadstring or load

-- ----- Pretty-print --------------------------------------------------------

local MAX_DEPTH         = 4
local INLINE_THRESHOLD  = 4   -- tables with <= N entries render single-line

local pp  -- forward declare for recursion

local function isSeqIndex(k, seqLen)
    return type(k) == "number" and k >= 1 and k <= seqLen and k == math.floor(k)
end

pp = function(v, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local t = type(v)

    if t == "string" then
        return string.format("%q", v)
    elseif t == "nil" or t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "function" then
        local info = (debug and debug.getinfo) and debug.getinfo(v, "S") or nil
        if info and info.short_src and info.linedefined then
            return string.format("function:%s:%d", info.short_src, info.linedefined)
        end
        return tostring(v)
    elseif t ~= "table" then
        return tostring(v)
    end

    if seen[v] then return "<cycle>" end
    if depth >= MAX_DEPTH then return "{...}" end
    seen[v] = true

    if next(v) == nil then return "{}" end

    local seqLen = #v
    local seqParts, hashParts = {}, {}

    for i = 1, seqLen do
        seqParts[i] = pp(v[i], depth + 1, seen)
    end
    for k, val in pairs(v) do
        if not isSeqIndex(k, seqLen) then
            local keyStr
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                keyStr = k
            elseif type(k) == "string" then
                keyStr = string.format("[%q]", k)
            else
                keyStr = "[" .. tostring(k) .. "]"
            end
            hashParts[#hashParts + 1] = keyStr .. " = " .. pp(val, depth + 1, seen)
        end
    end
    table.sort(hashParts)

    local parts = {}
    for _, p in ipairs(seqParts)  do parts[#parts + 1] = p end
    for _, p in ipairs(hashParts) do parts[#parts + 1] = p end

    seen[v] = nil  -- allow re-entry from sibling branches

    if #parts <= INLINE_THRESHOLD then
        return "{ " .. table.concat(parts, ", ") .. " }"
    end

    local pad      = string.rep("  ", depth + 1)
    local closePad = string.rep("  ", depth)
    return "{\n" .. pad .. table.concat(parts, ",\n" .. pad) .. "\n" .. closePad .. "}"
end

ns._pp = pp  -- exposed for tests

-- ----- print capture -------------------------------------------------------

local function tprint(...)
    local n = select("#", ...)
    if n == 0 then return "" end
    local parts = {}
    for i = 1, n do
        parts[i] = tostring(select(i, ...))
    end
    return table.concat(parts, "  ")
end

local function makeWrappedPrint(buffer, origPrint)
    return function(...)
        buffer[#buffer + 1] = tprint(...)
        if origPrint then pcall(origPrint, ...) end
    end
end

local function compile(input)
    local fn, err = lua_load("return " .. input, "=forge_console")
    if fn then return fn end
    fn, err = lua_load(input, "=forge_console")
    return fn, err
end

-- Pull a line number out of either a syntax error or a runtime error message.
-- Lua errors look like:
--   [string "=forge_console"]:5: '=' expected near 'foo'
--   [string "forge_console"]:5: attempt to index a nil value
-- with possible variation in the chunk-name section. The :NN: pattern is
-- what we anchor to. Returns a positive integer or nil.
local function extractErrLine(msg)
    if type(msg) ~= "string" then return nil end
    -- Anchor to ']:' first (the closing bracket of [string "..."]) so we
    -- don't accidentally pick up a colon inside a string literal in user
    -- code, e.g. `print("foo:5:bar")`.
    local n = msg:match("%]:(%d+):")
    if not n then
        -- Fallback: bare `:NN:` near the start of the message.
        n = msg:match("^[^:]*:(%d+):")
    end
    return tonumber(n)
end

-- ----- Streaming session (Option C) -----------------------------------------
-- After Eval.Run's synchronous body returns, we keep _G.print wrapped so
-- prints from deferred callbacks (C_Timer.After, animation completes,
-- network/event handlers, etc.) still land in the snippet's output pane.
-- The wrap auto-disables after `idleSec` seconds of no print activity.
--
-- State is module-scoped so a second Run can force-end any prior session
-- before installing its own. This is what makes the UI feel snappy:
-- starting a new snippet immediately "owns" the print stream.

local session = nil  -- { origPrint, streamFn, onAppend, onEnd, idleSec, gen, ended }

local function endSession(s)
    if not s or s.ended then return end
    s.ended = true
    -- Only restore _G.print if it's still our wrapper. If somebody else
    -- (another addon, a debugger) replaced print mid-session, leave their
    -- replacement alone.
    if _G.print == s.streamFn then
        _G.print = s.origPrint
    end
    if s.onEnd then pcall(s.onEnd) end
    if session == s then session = nil end
end

function Eval.EndSession()
    if session then endSession(session) end
end

local function postponeIdleRestore(s)
    s.gen = s.gen + 1
    local atGen = s.gen
    C_Timer.After(s.idleSec, function()
        -- Only act if we're still the active session and no print has
        -- bumped the gen counter since this timer was scheduled.
        if session == s and not s.ended and s.gen == atGen then
            endSession(s)
        end
    end)
end

local function makeStreamingPrint(s)
    return function(...)
        local line = tprint(...)
        if s.origPrint then pcall(s.origPrint, ...) end
        if s.onAppend then pcall(s.onAppend, line) end
        postponeIdleRestore(s)
    end
end

function Eval.Run(input, opts)
    opts = opts or {}
    if type(input) ~= "string" or input:match("^%s*$") then
        return true, { "(empty)" }
    end
    if not lua_load then
        return false, { "fatal: neither loadstring nor load is available." }
    end

    local out = {}
    local fn, err = compile(input)
    if not fn then
        out[#out + 1] = "syntax error: " .. tostring(err)
        return false, out, extractErrLine(err)
    end

    -- Force-end any prior streaming session so this Run owns the print
    -- stream cleanly. Old session's late deferred prints will now go to
    -- chat via the original print (acceptable: when you run a new
    -- snippet, you've moved on from the old one).
    Eval.EndSession()

    -- Phase 1: synchronous body. Append to the returned `out` array AND
    -- chat (origPrint). Don't fire onAppend yet -- the caller renders the
    -- whole `out` array in one batch after Run returns, and we don't want
    -- to double-render the same lines.
    local origPrint = _G.print
    _G.print = makeWrappedPrint(out, origPrint)

    local results = { pcall(fn) }

    local ok = results[1]
    if not ok then
        out[#out + 1] = "error: " .. tostring(results[2])
        -- Don't install a streaming session on syntax/runtime error: the
        -- snippet aborted, no deferred work was scheduled by the failing
        -- code path that the user cares about.
        _G.print = origPrint
        return false, out, extractErrLine(results[2])
    end

    -- Pretty-print return values.
    local n = #results
    if n > 1 then
        local rv = {}
        for i = 2, n do
            rv[#rv + 1] = pp(results[i])
        end
        out[#out + 1] = "= " .. table.concat(rv, ",  ")
    end

    -- Phase 2: install streaming session if the caller wants it.
    -- Without opts.idleSec, behave like the pre-Option-C path (immediate
    -- restore). With opts.idleSec > 0, stream deferred prints via
    -- onAppend, auto-disable after that many seconds idle.
    if type(opts.idleSec) == "number" and opts.idleSec > 0 then
        local s
        s = {
            origPrint = origPrint,
            onAppend  = opts.onAppend,
            onEnd     = opts.onEnd,
            idleSec   = opts.idleSec,
            gen       = 0,
            ended     = false,
        }
        s.streamFn = makeStreamingPrint(s)
        session   = s
        _G.print  = s.streamFn
        -- Schedule the initial idle timer. If no deferred print arrives
        -- within idleSec, the session ends naturally.
        postponeIdleRestore(s)
    else
        _G.print = origPrint
    end

    return true, out
end

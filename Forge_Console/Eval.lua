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

function Eval.Run(input)
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

    local origPrint = _G.print
    _G.print = makeWrappedPrint(out, origPrint)

    local results = { pcall(fn) }
    _G.print = origPrint

    local ok = results[1]
    if not ok then
        out[#out + 1] = "error: " .. tostring(results[2])
        return false, out, extractErrLine(results[2])
    end

    local n = #results
    if n > 1 then
        local rv = {}
        for i = 2, n do
            rv[#rv + 1] = pp(results[i])
        end
        out[#out + 1] = "= " .. table.concat(rv, ",  ")
    end

    return true, out
end

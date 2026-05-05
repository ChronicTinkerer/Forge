-- Forge_Console.REPL: line-at-a-time evaluator with continuation buffer.
--
-- Behaviors (modeled after WowLua's command bar):
--   * `>` prompt for a fresh statement; `>>` while accumulating an unfinished
--     block (e.g. open `function`, `do`, `if` without `end`).
--   * `= expr` shorthand auto-prints the value (delegated to Eval.Run, which
--     already tries `return ...` first).
--   * Up / Down arrow keys cycle through history (handled in UI.lua via
--     OnArrowPressed since we're using a single-line EditBox).
--   * Esc on a non-empty continuation buffer abandons it without running.
--
-- Why a separate module:
--   The state machine (continuation buffer + history cursor) is small but
--   has enough corner cases that keeping it out of UI.lua is worth it.
--   Eval.Run handles compile + print capture; this layer just decides
--   "is this submission complete enough to run?"

local ADDON, ns = ...

local REPL = {}
ns.REPL = REPL

local lua_load = loadstring or load

-- ----- Module state --------------------------------------------------------
-- buffer is the list of unfinished-block lines accumulated since the last
-- successful submit. historyPos is nil for "live editing" or 1..#history
-- when the user has Up-arrow'd into the past.
local buffer = {}
local historyPos = nil

function REPL.IsContinuing()
    return #buffer > 0
end

function REPL.Reset()
    for i = #buffer, 1, -1 do buffer[i] = nil end
    historyPos = nil
end

-- The prompt the user *currently* sees. Caller uses this to render the
-- left-side label and to echo the typed line into the output transcript.
function REPL.Prompt()
    return REPL.IsContinuing() and ">> " or "> "
end

-- ----- Submit one line -----------------------------------------------------
-- Returns one of:
--   "continue"                              -- buffer holds an unfinished block
--   "ran", ok, outputLines, errLine         -- block executed, emit outputs
--   "empty"                                 -- nothing meaningful, do nothing
local function endsWithEof(err)
    -- Lua 5.1: "...:N: '<eof>' expected" near `<eof>`
    -- Lua 5.4: "...:N: <eof> expected" / "...:N: 'end' expected near <eof>"
    -- Just look for the literal "<eof>" anywhere in the error.
    return type(err) == "string" and err:find("<eof>", 1, true) ~= nil
end

function REPL.Submit(line)
    if type(line) ~= "string" or line:match("^%s*$") then
        -- Pure whitespace: if we're mid-block, treat blank line as "force
        -- run", matching common REPL behavior. Otherwise, no-op.
        if not REPL.IsContinuing() then return "empty" end
    else
        -- Save raw user input to history (deduped + capped by Core.lua).
        if ns.PushHistory then ns.PushHistory(line) end
        historyPos = nil
    end

    -- Append (even empty lines, when continuing, so the user can break
    -- their block visually).
    buffer[#buffer + 1] = line
    local source = table.concat(buffer, "\n")

    -- Detect "block not yet closed". We compile the raw source (no `return`
    -- prefix) and look for a `<eof>` error - that means the parser hit end
    -- of input while expecting more tokens.
    local fn, err = lua_load(source, "=forge_console:repl")
    if not fn and endsWithEof(err) then
        return "continue"
    end

    -- Either the source compiles cleanly OR fails with a real syntax error.
    -- Hand both cases to Eval.Run; it tries the `return ...` shorthand
    -- compile and produces nice error output for the syntax-error case.
    local toRun = source
    REPL.Reset()
    local ok, lines, errLine = ns.Eval.Run(toRun)
    return "ran", ok, lines, errLine
end

-- Esc handler: if there's an in-progress buffer, drop it and tell the caller
-- to update the prompt. Returns true if something was cancelled.
function REPL.CancelBuffer()
    if #buffer > 0 then
        REPL.Reset()
        return true
    end
    return false
end

-- ----- History navigation -------------------------------------------------
-- All three return the text the input box should now display, or nil to
-- mean "leave it alone" (e.g. no history exists).

-- Up arrow: walk backward in history (toward older entries).
function REPL.HistoryPrev()
    local h = ns.GetHistory and ns.GetHistory() or nil
    if not h or #h == 0 then return nil end
    if historyPos == nil then
        historyPos = #h           -- start from most recent
    elseif historyPos > 1 then
        historyPos = historyPos - 1
    end
    return h[historyPos]
end

-- Down arrow: walk forward (toward newer entries; past the end returns "").
function REPL.HistoryNext()
    local h = ns.GetHistory and ns.GetHistory() or nil
    if not h or historyPos == nil then return nil end
    if historyPos < #h then
        historyPos = historyPos + 1
        return h[historyPos]
    end
    historyPos = nil
    return ""   -- "live editing" again, blank input
end

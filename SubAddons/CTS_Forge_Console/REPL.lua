-- Forge_Console.REPL: line-at-a-time evaluator with continuation buffer.
--
-- Behavior (modeled after WowLua's command bar):
--   * `>` prompt for a fresh statement; `>>` while accumulating an
--     unfinished block (open `function`, `do`, `if` without `end`, etc.).
--   * Eval.Run handles compile + print capture; this layer just decides
--     "is this submission complete enough to run?"
--   * Up / Down arrow history is handled in UI.lua via the EditBox's
--     native AddHistoryLine; this module doesn't manage it (yet).
--   * Esc on a non-empty continuation buffer abandons it without running.
--
-- Why a separate module:
--   The state machine (continuation buffer) is small but has enough
--   corner cases that keeping it out of UI.lua is worth it.

local ADDON, ns = ...

local REPL = {}
ns.REPL = REPL

local lua_load = loadstring or load

-- Module state. `buffer` is the list of unfinished-block lines accumulated
-- since the last successful submit.
local buffer = {}


function REPL.IsContinuing()
    return #buffer > 0
end

function REPL.Reset()
    for i = #buffer, 1, -1 do buffer[i] = nil end
end

-- The prompt the user currently sees. Caller renders this on the left of
-- the input strip and echoes it into the transcript when the user submits.
function REPL.Prompt()
    return REPL.IsContinuing() and ">> " or "> "
end


-- ----- "Block not yet closed" detection -----------------------------------
-- Lua 5.1: "...:N: '<eof>' expected"
-- Lua 5.4: "...:N: <eof> expected" / "...:N: 'end' expected near <eof>"
-- Just look for the literal "<eof>" anywhere in the error message.
local function endsWithEof(err)
    return type(err) == "string" and err:find("<eof>", 1, true) ~= nil
end


-- ----- Submit one line -----------------------------------------------------
-- Returns one of:
--   "continue"                              -- buffer holds unfinished block
--   "ran", ok, outputLines, errLine         -- block executed, emit outputs
--   "empty"                                 -- nothing meaningful, no-op
function REPL.Submit(line)
    if type(line) ~= "string" or line:match("^%s*$") then
        -- Pure whitespace: if we're mid-block, treat blank line as "force
        -- run" so the user can break out of a buffer they're stuck in.
        -- Otherwise no-op.
        if not REPL.IsContinuing() then return "empty" end
    end

    -- Append (even empty lines, when continuing, so the user can break
    -- their block visually with blank rows).
    buffer[#buffer + 1] = line
    local source = table.concat(buffer, "\n")

    -- Compile the raw source (no `return` prefix) and look for a `<eof>`
    -- error which means the parser hit end of input while expecting more.
    local fn, err = lua_load(source, "=forge_console:repl")
    if not fn and endsWithEof(err) then
        return "continue"
    end

    -- Source either compiles cleanly OR fails with a real syntax error.
    -- Hand both to Eval.Run; it tries the `return ...` shorthand compile
    -- and produces nice error output for the syntax-error case.
    local toRun = source
    REPL.Reset()
    if not ns.Eval or not ns.Eval.Run then
        return "ran", false, { "Eval module missing" }, nil
    end
    local ok, lines, errLine = ns.Eval.Run(toRun)
    return "ran", ok, lines, errLine
end


-- ----- Cancel ------------------------------------------------------------
-- If there's an in-progress buffer, drop it. Returns true if something
-- was cancelled (caller updates the prompt label to "> ").
function REPL.CancelBuffer()
    if #buffer > 0 then
        REPL.Reset()
        return true
    end
    return false
end

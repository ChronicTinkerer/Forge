-- Forge_Console: in-game Lua REPL.
--
-- Phase 1 (shipped): editor + Run + output + Clear, single persistent buffer.
-- Phase 2 (shipped): snippet picker. Dropdown / Add / Delete / Switch-confirm.
-- Phase 3 (shipped): FAIAP syntax highlight + line-number gutter.
-- Phase 4 (shipped): REPL strip with > / >> prompt + history.
-- Phase 5 (this file): lock state, autorun-on-login (per char), slash
--   subcommands, Copy/Export dialogs, table serializer for export.
--
-- Files:
--   Core.lua        DB + snippet API + descriptor + slash + lifecycle
--   Eval.lua        compile + pcall + pretty-print + streaming print
--   REPL.lua        > / >> prompt state machine
--   Indent.lua      FAIAP syntax highlighter (vendored MIT, ~1275 LOC)
--   LineNumbers.lua gutter inside editor scroll content
--   UI.lua          Cairn-Gui-2.0 widget shell

local ADDON, ns = ...
_G.Forge_Console = ns


-- The reserved scratch snippet. Always present, auto-created on init.
-- Can't be locked, renamed, or deleted; it's the safe default landing pad
-- and the migration target for Phase 1's single buffer.
ns.SCRATCH = "scratch"


Cairn.Register("CTS_Forge_Console", ns, {
    dbName = "Forge_ConsoleDB",
    Log = true,
    dbDefaults = {
        profile = {
            snippets       = {},   -- name -> { code, locked, autorun = {[charKey] = true} }
            currentSnippet = nil,
        },
        global = {
            history = {},          -- REPL recall list, shared across characters
            errors  = {},          -- timestamped error transcript, survives /reload
        },
    },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_Console"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


-- ---------------------------------------------------------------------------
-- Output helper (chat-frame writer for slash command feedback)
-- ---------------------------------------------------------------------------

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge Console:|r " .. tostring(msg))
    end
end
ns.out = out


-- ---------------------------------------------------------------------------
-- Character key (matches Cairn.DB's charKey shape)
-- ---------------------------------------------------------------------------

local function charKey()
    local name  = (GetUnitName and GetUnitName("player", false)) or "Player"
    local realm = (GetRealmName and GetRealmName()) or ""
    return name .. " - " .. realm
end
ns.CharKey = charKey


-- ---------------------------------------------------------------------------
-- Snippet API
-- ---------------------------------------------------------------------------

function ns.ListSnippets()
    local list = {}
    if not (db and db.profile and db.profile.snippets) then return list end
    for name in pairs(db.profile.snippets) do
        list[#list + 1] = name
    end
    table.sort(list, function(a, b)
        if a == ns.SCRATCH then return true end
        if b == ns.SCRATCH then return false end
        return a:lower() < b:lower()
    end)
    return list
end

function ns.GetSnippet(name)
    if not (db and db.profile and db.profile.snippets) then return nil end
    return db.profile.snippets[name]
end

function ns.GetCurrentSnippet()
    if not (db and db.profile) then return nil end
    return db.profile.currentSnippet
end

function ns.SetCurrentSnippet(name)
    if not (db and db.profile and db.profile.snippets) then return false end
    if not db.profile.snippets[name] then return false end
    db.profile.currentSnippet = name
    return true
end

-- Save text into a named snippet. Refuses if the snippet is locked unless
-- `force` is true (Phase 5: the "save anyway" path or scratch). Creates
-- the snippet on first save. Returns true on success, false+reason on refuse.
function ns.SaveSnippet(name, code, force)
    if type(name) ~= "string" or name == "" then return false, "name required" end
    if not (db and db.profile and db.profile.snippets) then return false, "db unavailable" end
    local s = db.profile.snippets[name]
    if s and s.locked and not force then
        return false, "locked"
    end
    if not s then
        s = { code = "", autorun = {} }
        db.profile.snippets[name] = s
    end
    s.code = code or ""
    return true
end

function ns.LoadSnippet(name)
    local s = ns.GetSnippet(name)
    return s and s.code or nil
end

function ns.DeleteSnippet(name)
    if name == ns.SCRATCH then return false, "scratch cannot be deleted" end
    if not (db and db.profile and db.profile.snippets) then return false end
    if not db.profile.snippets[name] then return false, "not found" end
    db.profile.snippets[name] = nil
    if db.profile.currentSnippet == name then
        db.profile.currentSnippet = ns.SCRATCH
        if not db.profile.snippets[ns.SCRATCH] then
            for n in pairs(db.profile.snippets) do
                db.profile.currentSnippet = n
                break
            end
        end
    end
    return true
end

function ns.RenameSnippet(oldName, newName)
    if not (oldName and newName) or oldName == newName then return false end
    if oldName == ns.SCRATCH then return false, "scratch cannot be renamed" end
    if not (db and db.profile and db.profile.snippets) then return false end
    if db.profile.snippets[newName] then return false, "name exists" end
    local s = db.profile.snippets[oldName]
    if not s then return false, "not found" end
    db.profile.snippets[newName] = s
    db.profile.snippets[oldName] = nil
    if db.profile.currentSnippet == oldName then
        db.profile.currentSnippet = newName
    end
    return true
end

function ns.EnsureScratch()
    if not (db and db.profile and db.profile.snippets) then return end
    if not db.profile.snippets[ns.SCRATCH] then
        db.profile.snippets[ns.SCRATCH] = { code = "", autorun = {} }
    end
end


-- ---------------------------------------------------------------------------
-- Lock state
-- ---------------------------------------------------------------------------
-- Locked snippets refuse SaveSnippet unless force=true. Scratch can't be
-- locked: it's the safe default pad and locking it would defeat its purpose.

function ns.IsLocked(name)
    local s = ns.GetSnippet(name)
    return (s and s.locked) and true or false
end

function ns.SetLocked(name, locked)
    if name == ns.SCRATCH then return false, "scratch cannot be locked" end
    local s = ns.GetSnippet(name)
    if not s then return false, "not found" end
    -- Use nil instead of false to save table space when unlocking.
    s.locked = locked and true or nil
    return true
end

function ns.ToggleLocked(name)
    return ns.SetLocked(name, not ns.IsLocked(name))
end


-- ---------------------------------------------------------------------------
-- Autorun state (per character)
-- ---------------------------------------------------------------------------

function ns.IsAutoRun(name)
    local s = ns.GetSnippet(name)
    if not s or not s.autorun then return false end
    return s.autorun[charKey()] and true or false
end

function ns.SetAutoRun(name, on)
    local s = ns.GetSnippet(name)
    if not s then return false, "not found" end
    s.autorun = s.autorun or {}
    s.autorun[charKey()] = on and true or nil
    return true
end


-- ---------------------------------------------------------------------------
-- Simple table serializer (for /forge consoleexport)
-- ---------------------------------------------------------------------------
-- Handles strings, numbers, booleans, nil, and nested tables. Not a full
-- pickler: functions, userdata, threads, and cycles render as "?".
-- Output is valid Lua source you can paste into a `return { ... }` block.

local function isIdentifier(s)
    return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function serialize(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "string" then
        return string.format("%q", value)
    elseif t == "number" or t == "boolean" then
        return tostring(value)
    elseif t == "nil" then
        return "nil"
    elseif t ~= "table" then
        return '"<' .. t .. '>"'
    end

    if next(value) == nil then return "{}" end

    local inner = indent .. "    "
    local parts = {}

    -- Array section first (1..N contiguous integer keys).
    local seqLen = #value
    for i = 1, seqLen do
        parts[#parts + 1] = inner .. serialize(value[i], inner)
    end

    -- Hash section.
    local hashKeys = {}
    for k in pairs(value) do
        if not (type(k) == "number" and k >= 1 and k <= seqLen and k == math.floor(k)) then
            hashKeys[#hashKeys + 1] = k
        end
    end
    table.sort(hashKeys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(hashKeys) do
        local keyStr
        if isIdentifier(k) then
            keyStr = k
        elseif type(k) == "string" then
            keyStr = string.format("[%q]", k)
        else
            keyStr = "[" .. tostring(k) .. "]"
        end
        parts[#parts + 1] = inner .. keyStr .. " = " .. serialize(value[k], inner)
    end

    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end
ns.SerializeTable = serialize

-- Build the canonical export string: a comment header + `return { ... }`.
function ns.BuildExportString()
    local snippets = {}
    for _, name in ipairs(ns.ListSnippets()) do
        snippets[name] = ns.GetSnippet(name)
    end
    return ("-- Forge Console snippets export (%d snippet%s)\n-- Paste into chat with /script or load via SVs.\n\nreturn ")
        :format(#ns.ListSnippets(), #ns.ListSnippets() == 1 and "" or "s")
        .. serialize(snippets) .. "\n"
end


-- ---------------------------------------------------------------------------
-- Migration: Phase 1 (db.profile.code) -> snippets[scratch]
-- ---------------------------------------------------------------------------

local function migratePhase1Buffer()
    if not (db and db.profile) then return end
    local oldCode = db.profile.code
    if type(oldCode) ~= "string" then return end
    ns.EnsureScratch()
    local scratch = db.profile.snippets[ns.SCRATCH]
    if scratch and (scratch.code == nil or scratch.code == "") then
        scratch.code = oldCode
    end
    db.profile.code = nil
end


-- ---------------------------------------------------------------------------
-- Descriptor
-- ---------------------------------------------------------------------------

ns.descriptor = {
    name        = "Console",
    title       = "Console",
    order       = 15,
    description = "In-game Lua REPL with output capture.",

    OnTabShow = function(pane, mod)
        if not pane.Cairn._builtOnce then
            pane.Cairn._builtOnce = true
            if ns.UI and ns.UI.Build then
                ns.UI.Build(pane, mod)
            end
        end
        if ns.UI and ns.UI.OnTabShow then
            ns.UI.OnTabShow(pane, mod)
        end
    end,

    OnTabHide = function(pane, mod)
        if ns.UI and ns.UI.SaveCurrent then
            ns.UI.SaveCurrent(mod)
        end
    end,
}


-- ---------------------------------------------------------------------------
-- Autorun on login (run all flagged snippets for this char)
-- ---------------------------------------------------------------------------

local function runAutoruns()
    if not (db and db.profile and db.profile.snippets) then return end
    local ck = charKey()
    local lua_load = loadstring or load
    for name, s in pairs(db.profile.snippets) do
        if s.autorun and s.autorun[ck] and s.code and s.code ~= "" then
            local ok, err = pcall(function()
                local fn, lerr = lua_load(s.code, "=forge_console:autorun:" .. name)
                if not fn then error(lerr) end
                return fn()
            end)
            if ok then
                out("autorun '" .. name .. "' ok.")
            else
                out("autorun '" .. name .. "' failed: " .. tostring(err))
            end
        end
    end
end


-- ---------------------------------------------------------------------------
-- Slash subcommands
-- ---------------------------------------------------------------------------
-- All register under /forge <name>. Names match the OLD console* prefix so
-- users with muscle memory keep their commands. Help strings show up in
-- /forge help.

local function registerSlash()
    if not (Forge and Forge.Slash and Forge.Slash.Sub) then return end

    Forge.Slash:Sub("consolesave", function(rest)
        local name = (rest or ""):match("^%s*(%S+)") or nil
        if not name then out("usage: /forge consolesave <name>"); return end
        local code = (ns.UI and ns.UI.GetEditor and ns.UI.GetEditor()) or ""
        local ok, err = ns.SaveSnippet(name, code)
        if not ok then out("save failed: " .. tostring(err)); return end
        ns.SetCurrentSnippet(name)
        if ns.UI then
            if ns.UI.RefreshDropdown then ns.UI.RefreshDropdown() end
            if ns.UI.RefreshModifiedIndicator then ns.UI.RefreshModifiedIndicator() end
        end
        out(("saved '%s' (%d chars)."):format(name, #code))
    end, "save the editor content as a named snippet")

    Forge.Slash:Sub("consoleload", function(rest)
        local name = (rest or ""):match("^%s*(%S+)") or nil
        if not name then out("usage: /forge consoleload <name>"); return end
        if not ns.GetSnippet(name) then out("no snippet '" .. name .. "'."); return end
        ns.SetCurrentSnippet(name)
        if ns.UI and ns.UI.LoadCurrent then ns.UI.LoadCurrent() end
        if ns.UI and ns.UI.RefreshDropdown then ns.UI.RefreshDropdown() end
        out("switched to '" .. name .. "'.")
    end, "switch the editor to a named snippet")

    Forge.Slash:Sub("consolelist", function()
        local names = ns.ListSnippets()
        if #names == 0 then out("no snippets saved."); return end
        local cur = ns.GetCurrentSnippet()
        out("snippets:")
        for _, n in ipairs(names) do
            local s = ns.GetSnippet(n)
            local marker  = (n == cur) and " |cffd87f3a*|r" or ""
            local lockTag = ns.IsLocked(n) and " |cffd87f3a[L]|r" or ""
            local autoTag = ns.IsAutoRun(n) and " |cffaaffaaauto|r" or ""
            out(("  %s%s%s   |cffaaaaaa(%d chars)|r%s"):format(
                n, marker, lockTag, s and #(s.code or "") or 0, autoTag))
        end
    end, "list saved snippets")

    Forge.Slash:Sub("consolerm", function(rest)
        local name = (rest or ""):match("^%s*(%S+)") or nil
        if not name then out("usage: /forge consolerm <name>"); return end
        local ok, err = ns.DeleteSnippet(name)
        if not ok then out("delete failed: " .. tostring(err)); return end
        if ns.UI then
            if ns.UI.LoadCurrent then ns.UI.LoadCurrent() end
            if ns.UI.RefreshDropdown then ns.UI.RefreshDropdown() end
        end
        out("deleted '" .. name .. "'.")
    end, "delete a named snippet")

    Forge.Slash:Sub("consoleautorun", function(rest)
        local name = (rest or ""):match("^%s*(%S+)") or ns.GetCurrentSnippet()
        if not name then out("no snippet selected."); return end
        if not ns.GetSnippet(name) then out("no snippet '" .. name .. "'."); return end
        local nowOn = not ns.IsAutoRun(name)
        ns.SetAutoRun(name, nowOn)
        if ns.UI and ns.UI.RefreshAutoRun then ns.UI.RefreshAutoRun() end
        out(("autorun for '%s' on this character: %s"):format(name, nowOn and "ON" or "OFF"))
    end, "toggle autorun-on-login (per character)")

    Forge.Slash:Sub("consolecopy", function()
        if ns.UI and ns.UI.ShowCopyPopup then ns.UI.ShowCopyPopup() end
    end, "open a dialog with the output transcript")

    Forge.Slash:Sub("consoleexport", function()
        if ns.UI and ns.UI.ShowExportPopup then ns.UI.ShowExportPopup() end
    end, "open a dialog with all snippets serialized as Lua")

    Forge.Slash:Sub("consoleerrors", function()
        if ns.UI and ns.UI.ShowErrorsPopup then ns.UI.ShowErrorsPopup() end
    end, "open a dialog with the error transcript")

    Forge.Slash:Sub("consoleerrclear", function()
        if ns.UI and ns.UI.ClearErrors then ns.UI.ClearErrors() end
        out("error transcript cleared.")
    end, "wipe the error transcript")
end


-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function addon:OnInit()
    migratePhase1Buffer()
    ns.EnsureScratch()

    if not ns.GetCurrentSnippet() or not ns.GetSnippet(ns.GetCurrentSnippet()) then
        ns.SetCurrentSnippet(ns.SCRATCH)
    end

    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
end


function addon:OnLogin()
    -- Autorun BEFORE slash registration so slash output doesn't bracket
    -- the autorun output noisily. autorun() writes its own ok/failed lines.
    runAutoruns()
    registerSlash()
end

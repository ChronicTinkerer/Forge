-- Forge_Console: in-game Lua scripting workspace (Cube-inspired).
-- Snippets are first-class: one always-current snippet shown in the editor.
-- Switching snippets via dropdown auto-saves the current one. Add/Delete/Run/
-- Clear/Auto-run live in the top toolbar.

local ADDON, ns = ...

ns.VERSION = "0.2.0-dev"

local db = Cairn.DB.New("ForgeConsoleDB", {
    defaults = {
        profile = {
            history        = {},
            maxHistory     = 100,
            snippets       = {},   -- name -> { code = "...", autorun = {[charKey] = true} }
            currentSnippet = nil,  -- name of selected snippet
        },
    },
    profileType = "default",  -- account-level: Forge is a dev tool, no per-char variation
})
ns.db = db
-- IMPORTANT: do NOT touch db.profile at file scope. WoW loads SavedVariables
-- AFTER addon files execute but BEFORE ADDON_LOADED fires. Reading db.profile
-- here orphans the wrapper. The migration / force-init runs from OnInit below.

local addon = Cairn.Addon.New("Forge_Console")
ns.addon = addon

-- ----- History (kept for /forge consolelist style fallbacks) -------------
function ns.PushHistory(line)
    if type(line) ~= "string" or line == "" then return end
    local h = db.profile.history
    if h[#h] == line then return end
    h[#h + 1] = line
    while #h > (db.profile.maxHistory or 100) do table.remove(h, 1) end
end
function ns.GetHistory() return db.profile.history end
function ns.ClearHistory() db.profile.history = {} end

-- ----- Character key (matches Cairn.DB's charKey format) -----------------
local function charKey()
    if db.GetCurrentProfile then
        local p = db:GetCurrentProfile()
        if p and p ~= "" then return p end
    end
    local name  = (GetUnitName and GetUnitName("player", false)) or "Player"
    local realm = (GetRealmName and GetRealmName()) or ""
    return name .. " - " .. realm
end
ns.CharKey = charKey

-- ----- Snippet API -------------------------------------------------------
function ns.ListSnippets()
    local out = {}
    for name in pairs(db.profile.snippets) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function ns.GetSnippet(name)
    return db.profile.snippets[name]
end

function ns.GetCurrentSnippet()
    return db.profile.currentSnippet
end

function ns.SetCurrentSnippet(name)
    if not db.profile.snippets[name] then return false end
    db.profile.currentSnippet = name
    return true
end

-- The reserved scratch snippet name. Always present; auto-created on init,
-- always re-cleared on the first Console-tab open per game session. Users
-- can't lock or rename scratch; it's the safe default landing pad.
ns.SCRATCH = "scratch"

-- Save text into a named snippet. If the snippet doesn't exist, create it.
-- Returns (true) on success, (false, reason) when refused (e.g., locked).
-- Pass `force=true` to bypass the lock check (used by the explicit "save
-- anyway" path; not used by auto-save).
function ns.SaveSnippet(name, code, force)
    if type(name) ~= "string" or name == "" then return false, "name required" end
    code = code or ""
    local s = db.profile.snippets[name]
    if s and s.locked and not force then
        return false, "locked"
    end
    if not s then
        s = { code = "", autorun = {} }
        db.profile.snippets[name] = s
    end
    s.code = code
    return true
end

-- ----- Lock state --------------------------------------------------------

function ns.IsLocked(name)
    local s = db.profile.snippets[name]
    return (s and s.locked) and true or false
end

-- Toggle or set the locked flag. Scratch can't be locked: it's the safe
-- default pad; locking it would defeat its purpose.
function ns.SetLocked(name, locked)
    if name == ns.SCRATCH then return false, "scratch cannot be locked" end
    local s = db.profile.snippets[name]
    if not s then return false, "not found" end
    s.locked = locked and true or nil  -- nil instead of false saves table space
    return true
end

function ns.ToggleLocked(name)
    return ns.SetLocked(name, not ns.IsLocked(name))
end

-- ----- Scratch / session reset ------------------------------------------

-- Module-scoped flag: true at session start (Lua state initialized fresh
-- on /reload or login), set false after the first Console-tab open in
-- this session. UI.Build / OnTabShow reads this to decide whether to
-- reset scratch.
local _sessionScratchPending = true

function ns.IsScratchResetPending()
    return _sessionScratchPending
end

function ns.MarkScratchResetDone()
    _sessionScratchPending = false
end

-- Ensure the scratch snippet exists. Idempotent.
function ns.EnsureScratch()
    if not db.profile.snippets[ns.SCRATCH] then
        db.profile.snippets[ns.SCRATCH] = { code = "", autorun = {} }
    end
end

-- Wipe scratch's code (preserving its autorun config in the unlikely event
-- the user has scratch flagged for autorun). Force-bypass the lock check
-- since SetLocked refuses to lock scratch in the first place.
function ns.ResetScratch()
    ns.EnsureScratch()
    db.profile.snippets[ns.SCRATCH].code = ""
end

function ns.LoadSnippet(name)
    local s = db.profile.snippets[name]
    return s and s.code or nil
end

function ns.DeleteSnippet(name)
    if not name then return end
    db.profile.snippets[name] = nil
    if db.profile.currentSnippet == name then
        db.profile.currentSnippet = nil
        for n in pairs(db.profile.snippets) do
            db.profile.currentSnippet = n
            break
        end
    end
end

function ns.RenameSnippet(oldName, newName)
    if not (oldName and newName) or oldName == newName then return false end
    if db.profile.snippets[newName] then return false, "name exists" end
    local s = db.profile.snippets[oldName]
    if not s then return false, "not found" end
    db.profile.snippets[newName] = s
    db.profile.snippets[oldName] = nil
    if db.profile.currentSnippet == oldName then db.profile.currentSnippet = newName end
    return true
end

function ns.IsAutoRun(name)
    local s = db.profile.snippets[name]
    if not s or not s.autorun then return false end
    return s.autorun[charKey()] and true or false
end

function ns.SetAutoRun(name, on)
    local s = db.profile.snippets[name]
    if not s then return end
    s.autorun = s.autorun or {}
    s.autorun[charKey()] = on and true or nil
end

-- ----- Forge.Registry descriptor -----------------------------------------
local descriptor = {
    name        = "Console",
    title       = "Console",
    order       = 20,
    description = "In-game Lua scripting workspace.",
    SlashSub    = { name = "console", help = "open the Lua console" },
    OnTabShow   = function(parent, mod)
        -- Session scratch reset: on the first Console-tab open per game
        -- session, switch the active snippet to scratch and clear it. Done
        -- BEFORE UI.Build so the very first editor render lands in a blank
        -- scratch rather than briefly flashing whatever was last selected.
        if ns.IsScratchResetPending() then
            ns.EnsureScratch()
            ns.ResetScratch()
            db.profile.currentSnippet = ns.SCRATCH
            ns.MarkScratchResetDone()
        end

        if not mod._built then
            ns.UI.Build(parent, mod)
            mod._built = true
        end
        if mod._frame then mod._frame:Show() end
        if ns.UI and ns.UI.OnTabShow then ns.UI.OnTabShow(mod) end
    end,
    OnTabHide   = function(parent, mod)
        -- Save on hide so unsaved edits persist if user switches tabs.
        if ns.UI and ns.UI.SaveCurrent then ns.UI.SaveCurrent(mod) end
        if mod._frame then mod._frame:Hide() end
        -- The snippet-picker dropdown is on DIALOG strata (parented to
        -- UIParent, not to mod._frame), so hiding _frame does NOT take it
        -- down. Without this it bleeds through onto whichever Forge tab
        -- the user switches to. Same pattern any tab-floating dropdown
        -- needs to follow.
        if ns._dropdownList and ns._dropdownList:IsShown() then
            ns._dropdownList:Hide()
        end
    end,
}
ns.descriptor = descriptor

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge:|r " .. tostring(msg))
    end
end
ns.out = out

function addon:OnInit()
    -- Force lazy DB init so the migration / defaults below see real tables.
    local _ = db.profile
    -- One-time migration to account-level profile (see Forge_Logs/Core.lua).
    if db.global and not db.global.__acctMigrated then
        if (db:GetCurrentProfile() or "") ~= "Default" then
            db:SetProfile("Default")
        end
        db.global.__acctMigrated = true
    end

    -- Migration + ensure required keys exist (Cairn.DB doesn't retro-merge defaults).
    if db.profile.snippets       == nil then db.profile.snippets       = {} end
    if db.profile.history        == nil then db.profile.history        = {} end
    if db.profile.maxHistory     == nil then db.profile.maxHistory     = 100 end

    -- Convert legacy string-valued snippets to the new {code, autorun} shape.
    for name, val in pairs(db.profile.snippets) do
        if type(val) == "string" then
            db.profile.snippets[name] = { code = val, autorun = {} }
        elseif type(val) == "table" and type(val.code) ~= "string" then
            val.code     = val.code or ""
            val.autorun  = val.autorun or {}
        end
    end

    -- Always ensure the reserved scratch snippet exists. EnsureScratch is
    -- idempotent and creates it lazily; calling unconditionally here
    -- handles both first-ever-run and migration-from-old-snapshots cases.
    ns.EnsureScratch()

    -- Ensure currentSnippet points at something real. Default to scratch
    -- (the safe pad) so a fresh install lands there.
    if not db.profile.currentSnippet or not db.profile.snippets[db.profile.currentSnippet] then
        db.profile.currentSnippet = ns.SCRATCH
    end
end

function addon:OnLogin()
    if Forge and Forge.Registry then
        Forge.Registry.Register(descriptor)
    end

    -- Auto-run: any snippet flagged for this character runs once at login.
    local ck = charKey()
    for name, s in pairs(db.profile.snippets) do
        if s.autorun and s.autorun[ck] and s.code and s.code ~= "" then
            local ok, err = pcall(function()
                local fn = (loadstring or load)(s.code, "=forge_console:autorun:" .. name)
                if fn then return fn() end
            end)
            if ok then out("autorun '" .. name .. "' ok.")
            else        out("autorun '" .. name .. "' failed: " .. tostring(err)) end
        end
    end

    if Forge and Forge.slash then
        Forge.slash:Subcommand("consolesave", function(rest)
            local name = rest:match("^%s*(%S+)")
            if not name then out("usage: /forge consolesave <name>") return end
            local code = (ns.UI and ns.UI.GetEditor and ns.UI.GetEditor()) or ""
            ns.SaveSnippet(name, code)
            ns.SetCurrentSnippet(name)
            if ns.UI and ns.UI.RefreshDropdown then ns.UI.RefreshDropdown() end
            out(string.format("saved snippet '%s' (%d chars).", name, #code))
        end, "save the editor content as a named snippet")

        Forge.slash:Subcommand("consoleload", function(rest)
            local name = rest:match("^%s*(%S+)")
            if not name then out("usage: /forge consoleload <name>") return end
            if not ns.GetSnippet(name) then out("no snippet named '" .. name .. "'.") return end
            if ns.UI and ns.UI.SwitchTo then ns.UI.SwitchTo(name) end
            if Forge.Window and Forge.Window.OpenTab then Forge.Window.OpenTab("Console") end
        end, "switch the editor to a named snippet")

        Forge.slash:Subcommand("consolelist", function()
            local names = ns.ListSnippets()
            if #names == 0 then out("no snippets saved.") return end
            local cur = ns.GetCurrentSnippet()
            out("snippets:")
            for _, n in ipairs(names) do
                local s = ns.GetSnippet(n)
                local marker = (n == cur) and " |cffd87f3a*|r" or ""
                local autorun = ns.IsAutoRun(n) and " |cffaaffaaauto|r" or ""
                out(string.format("  %s%s   |cffaaaaaa(%d chars)|r%s",
                    n, marker, s and #(s.code or "") or 0, autorun))
            end
        end, "list saved Console snippets (* = current, auto = autorun on login)")

        Forge.slash:Subcommand("consolerm", function(rest)
            local name = rest:match("^%s*(%S+)")
            if not name then out("usage: /forge consolerm <name>") return end
            ns.DeleteSnippet(name)
            if ns.UI and ns.UI.RefreshDropdown then ns.UI.RefreshDropdown() end
            if ns.UI and ns.UI.LoadCurrent then ns.UI.LoadCurrent() end
            out("deleted snippet '" .. name .. "' (if it existed).")
        end, "delete a named snippet")

        Forge.slash:Subcommand("consoleautorun", function(rest)
            local name = rest:match("^%s*(%S+)")
            name = name or ns.GetCurrentSnippet()
            if not name then out("no snippet selected.") return end
            local s = ns.GetSnippet(name)
            if not s then out("no snippet named '" .. name .. "'.") return end
            local nowOn = not ns.IsAutoRun(name)
            ns.SetAutoRun(name, nowOn)
            out(string.format("snippet '%s' autorun for this character: %s", name, nowOn and "ON" or "OFF"))
        end, "toggle autorun-on-login for a snippet (defaults to current)")
    end

    local log = self:Log()
    if log then log:Info("Forge_Console v%s registered.", ns.VERSION) end
end

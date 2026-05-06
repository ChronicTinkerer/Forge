-- Forge_Logs: per-source log viewer for Cairn.Log entries.
-- Replaces Cairn.Dashboard's Logs tab as the canonical log UI.

local ADDON, ns = ...

ns.VERSION = "0.1.0-dev"

local db = Cairn.DB.New("ForgeLogsDB", {
    defaults = {
        profile = {
            selectedSource = "All",
            minLevel       = 5,        -- show all levels (5 = TRACE)
            searchText     = "",
            tapEvents      = false,    -- log all WoW events as they fire
            tapChatEvents  = false,    -- log chat messages
        },
    },
    profileType = "default",  -- account-level: Forge is a dev tool, no per-char variation
})
ns.db = db
-- IMPORTANT: do NOT touch db.profile at file scope.

-- Suppress Cairn.Log's INFO+ chat echo immediately at file load. Doing this
-- here (file scope) instead of in OnLogin matters: alphabetical load order
-- puts Forge_Logs after most Forge_* sub-addons, so by the time our OnLogin
-- runs, the other addons have already echoed their INFO lines. File scope
-- runs BEFORE PLAYER_LOGIN, so the echo level is in place before any
-- addon's OnLogin fires. Override with /cairn log echo INFO if wanted.
if Cairn and Cairn.Log and Cairn.Log.SetChatEchoLevel then
    Cairn.Log:SetChatEchoLevel("WARN")
end

local addon = Cairn.Addon.New("Forge_Logs")
ns.addon = addon

local descriptor = {
    name        = "Logs",
    title       = "Logs",
    order       = 25,
    description = "Per-source log viewer.",
    SlashSub    = { name = "logs", help = "open the Logs tab" },
    OnTabShow   = function(parent, mod)
        if not mod._built then
            ns.UI.Build(parent, mod)
            mod._built = true
        end
        if mod._frame then mod._frame:Show() end
        if ns.UI and ns.UI.OnTabShow then ns.UI.OnTabShow(mod) end
    end,
    OnTabHide   = function(parent, mod)
        if mod._frame then mod._frame:Hide() end
    end,
}
ns.descriptor = descriptor

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge:|r " .. tostring(msg))
    end
end
ns.out = out

-- ----- Settings API (used by the UI) ------------------------------------
function ns.GetSelectedSource()  return db.profile.selectedSource or "All" end
function ns.SetSelectedSource(s) db.profile.selectedSource = s or "All" end

function ns.GetMinLevel()        return db.profile.minLevel or 5 end
function ns.SetMinLevel(level)   db.profile.minLevel = level or 5 end

function ns.GetSearchText()      return db.profile.searchText or "" end
function ns.SetSearchText(s)     db.profile.searchText = s or "" end

-- ----- Lifecycle --------------------------------------------------------
function addon:OnInit()
    local _ = db.profile
    -- One-time migration to account-level profile (we used to default to
    -- "char" type; existing chars are still pointed at their char-keyed
    -- profile in sv.profileKeys until we explicitly switch them).
    if db.global and not db.global.__acctMigrated then
        if (db:GetCurrentProfile() or "") ~= "Default" then
            db:SetProfile("Default")
        end
        db.global.__acctMigrated = true
    end
    if db.profile.selectedSource == nil then db.profile.selectedSource = "All" end
    if db.profile.minLevel       == nil then db.profile.minLevel       = 5 end
    if db.profile.searchText     == nil then db.profile.searchText     = "" end
    if db.profile.tapEvents      == nil then db.profile.tapEvents      = false end
    if db.profile.tapChatEvents  == nil then db.profile.tapChatEvents  = false end
end

function addon:OnLogin()
    if Forge and Forge.Registry then
        Forge.Registry.Register(descriptor)
    end

    if Forge and Forge.slash then
        Forge.slash:Subcommand("logsclear", function()
            if Cairn.Log and Cairn.Log.Clear then
                Cairn.Log:Clear()
                out("log buffer cleared.")
                if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
            end
        end, "clear the Cairn.Log ring buffer")

        Forge.slash:Subcommand("logsexport", function()
            if ns.UI and ns.UI.ExportCSV then ns.UI.ExportCSV() end
        end, "open a copyable CSV dump of the current log view")
    end

    local log = self:Log()
    if log then log:Info("Forge_Logs v%s registered.", ns.VERSION) end
end

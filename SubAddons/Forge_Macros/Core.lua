-- Forge_Macros: in-game macro editor + GSE-style sequence builder.

local ADDON, ns = ...

ns.VERSION = "0.1.0-dev"

local db = Cairn.DB.New("ForgeMacrosDB", {
    defaults = {
        profile = {
            sequences = {},  -- name -> { steps = { "/cast X", ... } }
        },
    },
    profileType = "default",  -- account-level: Forge is a dev tool, no per-char variation
})
ns.db = db
-- IMPORTANT: do NOT touch db.profile at file scope. WoW loads SavedVariables
-- AFTER addon files execute but BEFORE ADDON_LOADED fires. Reading db.profile
-- here orphans the wrapper. Force-init lives inside addon:OnInit below.

-- ----- Sequence storage API ----------------------------------------------
function ns.GetSequences()  return db.profile.sequences or {}        end
function ns.GetSequence(n)  return db.profile.sequences and db.profile.sequences[n] end
function ns.SaveSequence(name, seq, silent)
    if type(name) ~= "string" or name == "" then return end
    db.profile.sequences[name] = seq or { steps = {} }
end
function ns.DeleteSequence(name)
    if not name then return end
    db.profile.sequences[name] = nil
end
function ns.RenameSequence(oldName, newName)
    if not (oldName and newName) or newName == "" or oldName == newName then return false end
    if db.profile.sequences[newName] then return false end
    local seq = db.profile.sequences[oldName]
    if not seq then return false end
    db.profile.sequences[newName] = seq
    db.profile.sequences[oldName] = nil
    return true
end

local addon = Cairn.Addon.New("Forge_Macros")
ns.addon = addon

local descriptor = {
    name        = "Macros",
    title       = "Macros",
    order       = 30,
    description = "Macro editor and sequence builder.",
    SlashSub    = { name = "macro", help = "open the Macros tab" },
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

function addon:OnInit()
    local _ = db.profile
    -- One-time migration to account-level profile (see Forge_Logs/Core.lua).
    if db.global and not db.global.__acctMigrated then
        if (db:GetCurrentProfile() or "") ~= "Default" then
            db:SetProfile("Default")
        end
        db.global.__acctMigrated = true
    end
    if db.profile.sequences == nil then db.profile.sequences = {} end
end

function addon:OnLogin()
    if Forge and Forge.Registry then
        Forge.Registry.Register(descriptor)
    end
    local log = self:Log()
    if log then log:Info("Forge_Macros v%s registered.", ns.VERSION) end
end

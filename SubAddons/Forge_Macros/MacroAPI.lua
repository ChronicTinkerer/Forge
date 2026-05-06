-- Forge_Macros.MacroAPI: thin wrappers over WoW's macro globals.
-- Account macros sit at indexes 1..MAX_ACCOUNT_MACROS.
-- Character macros sit at indexes (MAX_ACCOUNT_MACROS+1)..(MAX_ACCOUNT_MACROS+MAX_CHARACTER_MACROS).

local ADDON, ns = ...

local API = {}
ns.MacroAPI = API

local MAX_ACC  = (MAX_ACCOUNT_MACROS or 120)
local MAX_CHAR = (MAX_CHARACTER_MACROS or 18)

local function safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c
end

local function gmi(i)
    -- C_Macro.GetMacroInfo not always present; fall back to global.
    if C_Macro and C_Macro.GetMacroInfo then
        return safe(C_Macro.GetMacroInfo, i)
    end
    return safe(GetMacroInfo, i)
end

local function gmb(i)
    if C_Macro and C_Macro.GetMacroBody then
        return safe(C_Macro.GetMacroBody, i)
    end
    if GetMacroBody then
        return safe(GetMacroBody, i)
    end
    -- Some clients return body via GetMacroInfo's 3rd return.
    local _, _, body = gmi(i)
    return body
end

function API.AccountMacros()
    local out = {}
    for i = 1, MAX_ACC do
        local name, icon, body = gmi(i)
        if name then
            out[#out + 1] = {
                index = i, name = name, icon = icon,
                body = body or gmb(i) or "",
                kind = "account",
            }
        end
    end
    return out
end

function API.CharacterMacros()
    local out = {}
    local lo = MAX_ACC + 1
    local hi = MAX_ACC + MAX_CHAR
    for i = lo, hi do
        local name, icon, body = gmi(i)
        if name then
            out[#out + 1] = {
                index = i, name = name, icon = icon,
                body = body or gmb(i) or "",
                kind = "character",
            }
        end
    end
    return out
end

function API.MaxAccount()   return MAX_ACC  end
function API.MaxCharacter() return MAX_CHAR end

function API.AccountCount()
    local n = 0
    for i = 1, MAX_ACC do if gmi(i) then n = n + 1 end end
    return n
end

function API.CharacterCount()
    local n = 0
    for i = MAX_ACC + 1, MAX_ACC + MAX_CHAR do if gmi(i) then n = n + 1 end end
    return n
end

function API.Edit(index, name, icon, body)
    if EditMacro then return EditMacro(index, name, icon, body) end
end

function API.Create(name, icon, body, perCharacter)
    if CreateMacro then return CreateMacro(name, icon, body, perCharacter and 1 or nil) end
end

function API.Delete(index)
    if DeleteMacro then DeleteMacro(index) end
end

function API.Pickup(index)
    if PickupMacro then PickupMacro(index) end
end

function API.Get(index)
    local name, icon = gmi(index)
    if not name then return nil end
    local body = gmb(index) or ""
    return { index = index, name = name, icon = icon, body = body }
end

-- Forge.Registry: tracks loaded Forge_* sub-addons.
--
-- Each sub-addon (Forge_BugCatcher, Forge_Macros, Forge_Console,
-- Forge_Inspector, Forge_Logs, Forge_Profiles, Forge_Registry,
-- Forge_AddonManager, Forge_Codex) calls Forge.Registry.Register on load
-- to advertise itself. The main /forge window asks the registry which
-- tabs to render and which sub-modules to drive.
--
-- A registration is a small descriptor:
--   {
--     name        = "BugCatcher",          -- short tab/identifier (no "Forge_" prefix)
--     title       = "Bug Catcher",         -- human-readable tab label
--     order       = 10,                    -- tab sort order (lower = leftmost)
--     description = "Errors, captured.",   -- one-line subtitle (optional)
--     icon        = "Interface\\ICONS\\...",-- optional
--     OnTabShow   = function(parentFrame, mod) ... end,  -- builds the tab body
--     OnTabHide   = function(parentFrame, mod) ... end,  -- cleanup (optional)
--     SlashSub    = { name = "bug", help = "open the bug viewer" }, -- optional
--   }
--
-- The descriptor table itself is the "module" object passed back to OnTabShow,
-- so sub-addons can stash state on it. Forge.Registry never mutates it.

local ADDON, ns = ...

local Registry = {}
ns.Registry = Registry

Registry._modules = {}
Registry._order   = {}

local function rebuildOrder()
    Registry._order = {}
    for name in pairs(Registry._modules) do
        Registry._order[#Registry._order + 1] = name
    end
    table.sort(Registry._order, function(a, b)
        local oa = Registry._modules[a].order or 100
        local ob = Registry._modules[b].order or 100
        if oa ~= ob then return oa < ob end
        return a < b
    end)
end

function Registry.Register(descriptor)
    if type(descriptor) ~= "table" then
        error("Forge.Registry.Register: descriptor must be a table", 2)
    end
    local name = descriptor.name
    if type(name) ~= "string" or name == "" then
        error("Forge.Registry.Register: descriptor.name must be a non-empty string", 2)
    end

    Registry._modules[name] = descriptor
    rebuildOrder()

    -- If the module declared a /forge subcommand and the slash router
    -- exists, wire it now.
    if descriptor.SlashSub and ns.slash then
        local sub = descriptor.SlashSub
        if type(sub.name) == "string" and sub.name ~= "" then
            local ok, err = pcall(function()
                ns.slash:Subcommand(sub.name, function()
                    if ns.Window and ns.Window.OpenTab then
                        ns.Window.OpenTab(name)
                    end
                end, sub.help or ("open the " .. name .. " tab"))
            end)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end
    end

    -- Tell the window to refresh its tab strip if it exists.
    if ns.Window and ns.Window.RefreshTabs then
        ns.Window.RefreshTabs()
    end

    return descriptor
end

function Registry.Get(name)
    return Registry._modules[name]
end

function Registry.List()
    local list = {}
    for i, name in ipairs(Registry._order) do list[i] = name end
    return list
end

function Registry.Count()
    local n = 0
    for _ in pairs(Registry._modules) do n = n + 1 end
    return n
end

function Registry.CountString()
    local n = Registry.Count()
    if n == 0 then return "(none)" end
    return tostring(n) .. " (" .. table.concat(Registry._order, ", ") .. ")"
end

function Registry.Iter()
    local i = 0
    return function()
        i = i + 1
        local name = Registry._order[i]
        if name then return name, Registry._modules[name] end
    end
end

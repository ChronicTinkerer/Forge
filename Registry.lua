-- Forge.Registry: descriptor table for loaded Forge_* sub-addons.
--
-- Each sub-addon advertises itself by calling Forge.Registry.Register
-- with a small descriptor table. The main window asks the registry which
-- tabs to render; the slash router auto-wires per-module sub-commands
-- if the descriptor declared one.
--
-- Descriptor shape:
--   {
--     name        = "BugCatcher",          short tab/identifier (no "Forge_" prefix)
--     title       = "Bug Catcher",         human-readable tab label
--     order       = 10,                    tab sort order (lower = leftmost)
--     description = "Errors, captured.",   one-line subtitle (optional)
--     icon        = "Interface\\ICONS\\..", optional tab-strip icon
--     OnTabShow   = function(parent, mod) ... end,  builds the tab body
--     OnTabHide   = function(parent, mod) ... end,  cleanup (optional)
--     SlashSub    = { name = "bug", help = "open the bug viewer" }, optional
--   }
--
-- The descriptor table IS the module object passed back to OnTabShow /
-- OnTabHide, so sub-addons can stash per-instance state on it. The
-- registry never mutates the descriptor.

local ADDON, ns = ...

local Registry = {}
ns.Registry = Registry

Registry._modules = {}
Registry._order   = {}


-- Re-sort the order array. Stable sort by (order, name) so ties resolve
-- alphabetically and tab positions don't shuffle across reloads.
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


-- :Register(descriptor) -> descriptor
--
-- Stub-protection rule: when a real (non-stub) descriptor is already
-- registered under `descriptor.name`, a late stub registration is
-- refused. This guards against the parent's LoD-stub scanner racing
-- with a sub-addon's real OnInit registration: whichever order they
-- run in, the real entry always wins.
function Registry.Register(descriptor)
    if type(descriptor) ~= "table" then
        error("Forge.Registry.Register: descriptor must be a table", 2)
    end
    local name = descriptor.name
    if type(name) ~= "string" or name == "" then
        error("Forge.Registry.Register: descriptor.name must be a non-empty string", 2)
    end

    local existing = Registry._modules[name]
    if existing and not existing._isStub and descriptor._isStub then
        return existing
    end

    Registry._modules[name] = descriptor
    rebuildOrder()

    -- Auto-wire per-module slash sub-command. The descriptor declares
    -- `{ SlashSub = { name = "bug", help = "..." } }` and the registry
    -- adds a /forge sub that opens the corresponding tab. pcall'd so
    -- a malformed SlashSub spec doesn't poison the registration.
    if descriptor.SlashSub and ns.Slash then
        local sub = descriptor.SlashSub
        if type(sub.name) == "string" and sub.name ~= "" then
            local ok, err = pcall(function()
                ns.Slash:Sub(sub.name, function()
                    if ns.Window and ns.Window.OpenTab then
                        ns.Window.OpenTab(name)
                    end
                end, sub.help or ("open the " .. name .. " tab"))
            end)
            if not ok then geterrorhandler()(err) end
        end
    end

    -- Tell the window (if it exists) to refresh its tab strip so a
    -- new tab appears immediately rather than waiting for the next
    -- open/close cycle.
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


-- "5 (BugCatcher, Console, Inspector, Logs, Macros)" — single-line
-- summary used by /forge status and the OnLogin chat banner.
function Registry.CountString()
    local n = Registry.Count()
    if n == 0 then return "(none)" end
    return tostring(n) .. " (" .. table.concat(Registry._order, ", ") .. ")"
end


-- Generic-for iterator: `for name, descriptor in Forge.Registry.Iter() do`.
function Registry.Iter()
    local i = 0
    return function()
        i = i + 1
        local name = Registry._order[i]
        if name then return name, Registry._modules[name] end
    end
end

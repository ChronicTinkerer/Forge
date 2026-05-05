-- Forge_Registry.Sources: declarative enumerators for each Cairn registry.
--
-- Each source has:
--   name       string -- display label, also used as the dict key
--   describe   string -- short subtitle shown above the entries
--   list()     -> array of { key=string, summary=string, detail=string }
--                key      -- short identifier (e.g., addon name, event name)
--                summary  -- one-line description of the entry
--                detail   -- multi-line dump (optional; falls back to summary)
--
-- list() is called every time the user selects this source or the user
-- clicks Refresh in the toolbar -- so it should be cheap. Snapshots the
-- registry at call time; entries don't update live.
--
-- Adding a new source: append to ns.Sources.providers below. UI auto-picks
-- it up. Order = order in this file.

local ADDON, ns = ...

local Sources = {}
ns.Sources = Sources

-- LibStub-resolved handles. Cached on first list() call so lookups don't
-- repeatedly walk LibStub. Falsy if a lib failed to load.
local function lib(name)
    return LibStub and LibStub(name, true) or nil
end

local function safeLen(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function joinKeys(t, max)
    if type(t) ~= "table" then return "" end
    local out, n = {}, 0
    for k in pairs(t) do
        n = n + 1
        if n > max then out[#out + 1] = "..." break end
        out[#out + 1] = tostring(k)
    end
    return table.concat(out, ", ")
end

-- ----- Addons (Cairn.Addon.registry) ------------------------------------
-- Cairn.Addon stores lifecycle timestamps as `initFiredAt` / `loginFiredAt`
-- / `enterFiredAt` / `logoutFiredAt` -- nil until the corresponding hook
-- has fired. We surface them as a y/n flag in the summary and the raw
-- timestamps in the detail block.
local function fmtTs(ts)
    if not ts then return "(never)" end
    if date then return date("%H:%M:%S", ts) .. " (" .. tostring(ts) .. ")" end
    return tostring(ts)
end

local function listAddons()
    local L = lib("Cairn-Addon-1.0")
    if not (L and L.registry) then return {} end
    local out = {}
    for name, a in pairs(L.registry) do
        local initOk  = a.initFiredAt  and "y" or "n"
        local loginOk = a.loginFiredAt and "y" or "n"
        local enterOk = a.enterFiredAt and "y" or "n"
        out[#out + 1] = {
            key     = name,
            summary = string.format("%s  (init=%s login=%s enter=%s)",
                name, initOk, loginOk, enterOk),
            detail  = string.format(
                "name:           %s\ninitFiredAt:    %s\nloginFiredAt:   %s\nenterFiredAt:   %s\nlogoutFiredAt:  %s\nlogger:         %s\nhas OnInit:     %s\nhas OnLogin:    %s\nhas OnEnter:    %s\nhas OnLogout:   %s",
                name,
                fmtTs(a.initFiredAt),
                fmtTs(a.loginFiredAt),
                fmtTs(a.enterFiredAt),
                fmtTs(a.logoutFiredAt),
                a._log and "live" or "(not yet acquired)",
                tostring(type(rawget(a, "OnInit"))   == "function"),
                tostring(type(rawget(a, "OnLogin"))  == "function"),
                tostring(type(rawget(a, "OnEnter"))  == "function"),
                tostring(type(rawget(a, "OnLogout")) == "function")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- Hooks (Cairn.Hooks._registry) ------------------------------------
local function listHooks()
    local L = lib("Cairn-Hooks-1.0")
    if not (L and L._registry) then return {} end
    local out = {}
    for key, entry in pairs(L._registry) do
        local cbCount = entry.callbacks and #entry.callbacks or 0
        out[#out + 1] = {
            key     = key,
            summary = string.format("%s  (callbacks=%d, hookInstalled=%s)",
                key, cbCount, tostring(entry.hookInstalled)),
            detail  = string.format(
                "key:           %s\nname:          %s\ntarget:        %s\ncallbacks:     %d\nhookInstalled: %s",
                key,
                tostring(entry.name),
                tostring(entry.target or "_G"),
                cbCount,
                tostring(entry.hookInstalled)),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- Timers (Cairn.Timer.byOwner / .named) ----------------------------
local function listTimers()
    local L = lib("Cairn-Timer-1.0")
    if not L then return {} end
    local out = {}
    if L.byOwner then
        for owner, handles in pairs(L.byOwner) do
            local n = (type(handles) == "table" and #handles) or 0
            out[#out + 1] = {
                key     = "owner:" .. tostring(owner),
                summary = string.format("owner=%s  (live=%d)", tostring(owner), n),
                detail  = string.format("owner: %s\nlive:  %d", tostring(owner), n),
            }
        end
    end
    if L.named then
        for name, handle in pairs(L.named) do
            out[#out + 1] = {
                key     = "named:" .. tostring(name),
                summary = string.format("named=%s", tostring(name)),
                detail  = string.format("named:  %s\nhandle: %s", tostring(name), tostring(handle)),
            }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- Events (Cairn.Events.handlers) -----------------------------------
local function listEvents()
    local L = lib("Cairn-Events-1.0")
    if not (L and L.handlers) then return {} end
    local out = {}
    for event, entries in pairs(L.handlers) do
        local n = (type(entries) == "table" and #entries) or 0
        local owners = {}
        if type(entries) == "table" then
            for _, e in ipairs(entries) do
                owners[#owners + 1] = tostring(e.owner or e[1] or "?")
            end
        end
        out[#out + 1] = {
            key     = event,
            summary = string.format("%s  (subs=%d)", event, n),
            detail  = string.format("event: %s\nsubs:  %d\nowners:\n  %s",
                event, n, table.concat(owners, "\n  ")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- DB instances (Cairn.DB.instances) --------------------------------
local function listDBs()
    local L = lib("Cairn-DB-1.0")
    if not (L and L.instances) then return {} end
    local out = {}
    for i, inst in ipairs(L.instances) do
        local svName  = inst._svName or inst.svName or "?"
        local profile = (inst.GetProfileKey and inst:GetProfileKey()) or inst._profileKey or "?"
        out[#out + 1] = {
            key     = svName,
            summary = string.format("%s  (profile=%s)", svName, tostring(profile)),
            detail  = string.format(
                "svName:       %s\nprofileKey:   %s\nprofileType:  %s\ninstance idx: %d",
                svName, tostring(profile), tostring(inst._profileType or "?"), i),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- Slash (Cairn.Slash.registry) -------------------------------------
local function listSlash()
    local L = lib("Cairn-Slash-1.0")
    if not (L and L.registry) then return {} end
    local out = {}
    for name, slashObj in pairs(L.registry) do
        local subCount = safeLen(slashObj._subs or slashObj.subs)
        local subList  = joinKeys(slashObj._subs or slashObj.subs, 12)
        out[#out + 1] = {
            key     = name,
            summary = string.format("%s  (subs=%d)", name, subCount),
            detail  = string.format(
                "name:    %s\nsubs:    %d\nsubcommands:\n  %s",
                name, subCount, subList),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- Locales (Cairn.Locale.registry) ----------------------------------
local function listLocales()
    local L = lib("Cairn-Locale-1.0")
    if not (L and L.registry) then return {} end
    local out = {}
    for addonName, locale in pairs(L.registry) do
        out[#out + 1] = {
            key     = addonName,
            summary = string.format("%s  (lang=%s)", addonName, tostring(locale._lang or "?")),
            detail  = string.format("addonName: %s\nlang:      %s", addonName, tostring(locale._lang or "?")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- LibCodex modules (LibCodex.modules) ------------------------------
-- LibCodex itself is the registry: each typed module (Items, Quests, NPCs)
-- registers via RegisterModule. We surface that table here. Each module's
-- collection often exposes Count() or AllArray() -- if available, show the
-- entry count.
local function listCodexModules()
    local LC = _G.LibCodex or (LibStub and LibStub("LibCodex-1.0", true))
    if not (LC and LC.modules) then return {} end
    local out = {}
    for name, mod in pairs(LC.modules) do
        local count = "?"
        if type(mod.Count) == "function" then
            local ok, n = pcall(mod.Count, mod)
            if ok and type(n) == "number" then count = tostring(n) end
        end
        out[#out + 1] = {
            key     = name,
            summary = string.format("%s  (entries=%s)", name, count),
            detail  = string.format(
                "module:  %s\nentries: %s\nhas Get:      %s\nhas AllArray: %s\nhas Search:   %s",
                name, count,
                tostring(type(mod.Get) == "function"),
                tostring(type(mod.AllArray) == "function"),
                tostring(type(mod.Search) == "function")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- LibCodex consumers (TOC dependency scan) -------------------------
-- Walks the loaded addon list and reports any addon that declares
-- "LibCodex-1.0" in its ## Dependencies or ## OptionalDeps. Doesn't catch
-- addons that load it purely at runtime via LibStub without a TOC dep, but
-- those are rare and arguably broken (no enforced load order).
local function listCodexConsumers()
    if not (C_AddOns and C_AddOns.GetNumAddOns) then return {} end
    local out = {}
    local n = C_AddOns.GetNumAddOns()
    for i = 1, n do
        local addonName = C_AddOns.GetAddOnInfo(i)
        if addonName then
            local deps = { C_AddOns.GetAddOnDependencies and C_AddOns.GetAddOnDependencies(i) }
            local opts = {}
            if C_AddOns.GetAddOnOptionalDependencies then
                opts = { C_AddOns.GetAddOnOptionalDependencies(i) }
            end
            local hasDep, viaOpt = false, false
            for _, d in ipairs(deps) do if d == "LibCodex-1.0" then hasDep = true end end
            for _, d in ipairs(opts) do if d == "LibCodex-1.0" then hasDep = true; viaOpt = true end end
            if hasDep then
                local loaded = C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(i)
                out[#out + 1] = {
                    key     = addonName,
                    summary = string.format("%s  (loaded=%s, via=%s)",
                        addonName, tostring(loaded), viaOpt and "OptionalDeps" or "Dependencies"),
                    detail  = string.format(
                        "addon:        %s\nloaded:       %s\ndeclared via: %s\nall deps:     %s\nopt deps:     %s",
                        addonName,
                        tostring(loaded),
                        viaOpt and "OptionalDeps" or "Dependencies",
                        table.concat(deps, ", "),
                        table.concat(opts, ", ")),
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- Comm prefixes (Cairn.Comm.subscribers + .registered) -------------
-- Each prefix shows its subscriber count and whether the prefix was
-- successfully registered with WoW (C_ChatInfo.RegisterAddonMessagePrefix).
local function listCommPrefixes()
    local L = lib("Cairn-Comm-1.0")
    if not L then return {} end
    local out = {}
    local seen = {}
    if L.subscribers then
        for prefix, subs in pairs(L.subscribers) do
            seen[prefix] = true
            local n = (type(subs) == "table" and #subs) or 0
            local owners = {}
            if type(subs) == "table" then
                for _, s in ipairs(subs) do
                    owners[#owners + 1] = tostring(s.owner or "?")
                end
            end
            out[#out + 1] = {
                key     = prefix,
                summary = string.format("%s  (subs=%d, registered=%s)",
                    prefix, n, tostring(L.registered and L.registered[prefix] or false)),
                detail  = string.format(
                    "prefix:     %s\nsubs:       %d\nregistered: %s\nowners:\n  %s",
                    prefix, n,
                    tostring(L.registered and L.registered[prefix] or false),
                    table.concat(owners, "\n  ")),
            }
        end
    end
    -- Surface registered-but-no-subs prefixes too -- might indicate a
    -- subscriber that already unsubscribed but the prefix stayed.
    if L.registered then
        for prefix, ok in pairs(L.registered) do
            if not seen[prefix] then
                out[#out + 1] = {
                    key     = prefix,
                    summary = string.format("%s  (subs=0, registered=%s)", prefix, tostring(ok)),
                    detail  = string.format(
                        "prefix:     %s\nsubs:       0\nregistered: %s",
                        prefix, tostring(ok)),
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- Callback registries (hybrid: Cairn.Callback.instances + LibStub scan)
-- Two-source discovery: primary read from Cairn-Callback.instances (filled
-- by our CallbackHandler shim's :New hook when our shim wins LibStub),
-- then a fallback scan of LibStub.libs for callback registries that
-- weren't tracked. The fallback covers the case where ElvUI's bundled
-- CallbackHandler-1.0 won LibStub (MINOR 8 vs our 7) -- in that scenario
-- our :New never runs, so `instances` stays empty.
--
-- A "callback registry" is duck-typed as: a table with a numeric `recurse`
-- field, a table `events` field, and a function `Fire` field. That's the
-- shape both upstream WoWAce CallbackHandler-1.0 and ElvUI's MINOR=8
-- variant return from :New, regardless of which won LibStub. Common
-- attachment points on libraries: `lib.callbacks`, `lib.events`,
-- `lib.messages`. The label for fallback entries is "{libMAJOR}.{field}"
-- so each row is unambiguous.
local function buildCallbackEntry(reg, label)
    local nEvents, nSubs = 0, 0
    local eventLines = {}
    if reg.events then
        for ev, handlers in pairs(reg.events) do
            nEvents = nEvents + 1
            local n = 0
            for _ in pairs(handlers) do n = n + 1; nSubs = nSubs + 1 end
            eventLines[#eventLines + 1] = string.format("  %s  (subs=%d)", tostring(ev), n)
        end
        table.sort(eventLines)
    end
    local lbl = type(label) == "string" and label or "(unlabeled)"
    local shortLbl = lbl:gsub("^table: ", "table:")
    local eventBlock = #eventLines > 0
        and ("events:\n" .. table.concat(eventLines, "\n"))
        or  "events:\n  (none)"
    return {
        key     = shortLbl,
        summary = string.format("events=%d  subs=%d", nEvents, nSubs),
        detail  = string.format(
            "label:       %s\nevent count: %d\ntotal subs:  %d\nrecurse:     %d\n\n%s",
            lbl, nEvents, nSubs, reg.recurse or 0, eventBlock),
    }
end

local function looksLikeRegistry(t)
    return type(t) == "table"
       and type(t.recurse) == "number"
       and type(t.events)  == "table"
       and type(t.Fire)    == "function"
end

local function listCallbacks()
    local out = {}
    local seen = {}  -- keyed by registry table identity to dedup primary vs fallback

    -- Primary: registries our shim's :New hook tracked.
    local L = lib("Cairn-Callback-1.0")
    if L and L.instances then
        for reg, label in pairs(L.instances) do
            seen[reg] = true
            out[#out + 1] = buildCallbackEntry(reg, label)
        end
    end

    -- Fallback: scan every registered LibStub library for fields that
    -- look like callback registries. Catches the ElvUI-wins case where
    -- our :New never ran (instances empty) AND any lib whose registry was
    -- created before our shim loaded. Skip anything already in `seen`.
    if LibStub and LibStub.libs then
        for libMajor, libTable in pairs(LibStub.libs) do
            if type(libTable) == "table" then
                for fieldName, val in pairs(libTable) do
                    if not seen[val] and looksLikeRegistry(val) then
                        seen[val] = true
                        local label = libMajor .. "." .. tostring(fieldName)
                        out[#out + 1] = buildCallbackEntry(val, label)
                    end
                end
            end
        end
    end

    -- Sort: real labels first (alphabetical), then table-address fallback
    -- entries last (also alphabetical for a stable order).
    table.sort(out, function(a, b)
        local aRaw = a.key:match("^table:") and 1 or 0
        local bRaw = b.key:match("^table:") and 1 or 0
        if aRaw ~= bRaw then return aRaw < bRaw end
        return a.key < b.key
    end)
    return out
end

-- ----- Settings panels (Cairn.Settings.instances) -----------------------
local function listSettingsPanels()
    local L = lib("Cairn-Settings-1.0")
    if not (L and L.instances) then return {} end
    local out = {}
    for inst, addonName in pairs(L.instances) do
        local nEntries = inst._schema and #inst._schema or 0
        local hasCategory = inst._categoryID and "yes" or "no (stub mode)"
        out[#out + 1] = {
            key     = tostring(addonName),
            summary = string.format("%s  (entries=%d, blizzard=%s)",
                tostring(addonName), nEntries, hasCategory),
            detail  = string.format(
                "addon:           %s\nschema entries:  %d\nBlizzard category: %s\ncategoryID:      %s",
                tostring(addonName), nEntries, hasCategory, tostring(inst._categoryID or "(none)")),
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ----- Provider list ----------------------------------------------------
Sources.providers = {
    { name = "Addons",          describe = "Cairn.Addon.registry",        list = listAddons          },
    { name = "Hooks",           describe = "Cairn.Hooks._registry",       list = listHooks           },
    { name = "Timers",          describe = "Cairn.Timer.byOwner / .named", list = listTimers         },
    { name = "Events",          describe = "Cairn.Events.handlers",       list = listEvents          },
    { name = "DBs",             describe = "Cairn.DB.instances",          list = listDBs             },
    { name = "Slash",           describe = "Cairn.Slash.registry",        list = listSlash           },
    { name = "Locales",         describe = "Cairn.Locale.registry",       list = listLocales         },
    { name = "Comm",            describe = "Cairn.Comm.subscribers / .registered", list = listCommPrefixes },
    { name = "Callbacks",       describe = "Cairn.Callback.instances + LibStub scan", list = listCallbacks },
    { name = "Settings",        describe = "Cairn.Settings.instances",    list = listSettingsPanels  },
    { name = "Codex Modules",   describe = "LibCodex.modules",            list = listCodexModules    },
    { name = "Codex Consumers", describe = "addons depending on LibCodex-1.0", list = listCodexConsumers },
}

-- Lookup helper used by the UI.
function Sources.Get(name)
    for _, p in ipairs(Sources.providers) do
        if p.name == name then return p end
    end
    return nil
end

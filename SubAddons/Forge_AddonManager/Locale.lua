-- Forge_AddonManager.Locale: localization tables. Wired through
-- Cairn-Locale-1.0 (see Cairn-Locale-1.0.lua for the API).
--
-- enUS is authoritative; other locales fall back to enUS for missing keys
-- and ultimately to the bare key string. Add a new locale by adding a row
-- to the locales table below; community PRs welcome.

local ADDON, ns = ...

local CairnLocale = LibStub and LibStub("Cairn-Locale-1.0", true)
if not CairnLocale then
    -- Cairn isn't loaded for some reason. Fall back to a stub that returns
    -- the key as-is, so the addon still works (just in English) without
    -- erroring on every L["..."] access.
    ns.L = setmetatable({}, { __index = function(_, k) return k end,
                              __call  = function(_, k, ...)
                                  if select("#", ...) == 0 then return k end
                                  local ok, msg = pcall(string.format, k, ...)
                                  return ok and msg or k
                              end })
    return
end

ns.L = CairnLocale.New("Forge_AddonManager", {
    -- =====================================================================
    -- enUS: authoritative source. Always present. Keep keys readable so they
    -- double as documentation: a missing translation falls back to the key.
    -- =====================================================================
    enUS = {
        -- Status badges (in the per-row Status column).
        ["Loaded"]   = "Loaded",
        ["LoD"]      = "LoD",
        ["Pending"]  = "Pending",
        ["Disabled"] = "Disabled",

        -- Column headers.
        ["Name"]    = "Name",
        ["Status"]  = "Status",
        ["Memory"]  = "Memory",
        ["Recent"]  = "Recent",
        ["Peak"]    = "Peak",
        ["Spikes"]  = "Spikes",
        ["Version"] = "Version",

        -- Filter dropdown rows (full label) + toolbar button (short label).
        ["All addons"]                = "All addons",
        ["Loaded only"]               = "Loaded only",
        ["Disabled only"]             = "Disabled only",
        ["Load-on-demand only"]       = "Load-on-demand only",
        ["Pending (reload required)"] = "Pending (reload required)",
        ["Protected only"]            = "Protected only",
        ["All"]                       = "All",
        ["Loaded"]                    = "Loaded",
        ["Disabled"]                  = "Disabled",
        ["LoD"]                       = "LoD",
        ["Pending"]                   = "Pending",
        ["Protected"]                 = "Protected",

        -- Buttons + labels.
        ["Close"]              = "Close",
        ["Cancel"]             = "Cancel",
        ["OK"]                 = "OK",
        ["Apply + Reload"]     = "Apply + Reload",
        ["Reload UI"]          = "Reload UI",
        ["Enable selected"]    = "Enable selected",
        ["Load a set:"]        = "Load a set:",
        ["(no sets saved)"]    = "(no sets saved)",
        ["Name:"]              = "Name:",
        ["Set name"]           = "Set name",
        ["Filter by name..."]  = "Filter by name...",
        ["Auto-disable new"]   = "Auto-disable new",
        ["Recursive enable"]   = "Recursive enable",

        -- Tooltip block: addon row hover.
        ["Author"]                                           = "Author",
        ["Requires:"]                                        = "Requires:",
        ["Optional:"]                                        = "Optional:",
        ["Protected - survives Disable All"]                 = "Protected - survives Disable All",
        ["Essential - cannot be disabled (Forge depends on it)"] =
            "Essential - cannot be disabled (Forge depends on it)",
        ["[essential]"]                                      = "[essential]",

        -- Tooltip block: CPU profiler section.
        ["CPU profiler"]                       = "CPU profiler",
        ["Recent (rolling avg)"]               = "Recent (rolling avg)",
        ["Peak (worst spike)"]                 = "Peak (worst spike)",
        ["Encounter avg"]                      = "Encounter avg",
        ["Last frame"]                         = "Last frame",
        ["Spikes (>1 / >5 / >10 / >50 / >100 ms)"] =
            "Spikes (>1 / >5 / >10 / >50 / >100 ms)",

        -- Optional-dependencies prompt dialog.
        ["Optional dependencies"] = "Optional dependencies",
        ["These addons are listed as optional dependencies and are installed but disabled. Tick the ones you want to enable."] =
            "These addons are listed as optional dependencies and are installed but disabled. Tick the ones you want to enable.",
    },

    -- =====================================================================
    -- Other locales: stubs. Fill in translations as PRs arrive. Each missing
    -- key falls back to enUS automatically.
    -- =====================================================================
    deDE = {},
    frFR = {},
    esES = {},
    esMX = {},
    ruRU = {},
    koKR = {},
    zhCN = {},
    zhTW = {},
    ptBR = {},
    itIT = {},
}, { default = "enUS" })

-- Forge_CVars.RiskyList: allowlist of CVars that pop a confirm modal on edit.
--
-- "Risky" here means one of:
--   * setting a wrong value can soft-brick the client (gxApi, gxWindow)
--   * the change requires /reload to take effect (worth warning, not blocking)
--   * the CVar is read-only or protected (treat as can't-edit, not just risky)
--
-- This list is intentionally conservative. False positives are a minor UX
-- annoyance (extra confirm click); false negatives can lock a user out of
-- their client. Add freely; remove rarely.
--
-- Tags:
--   "danger"   - can soft-brick / make the client unusable
--   "audio"    - can damage hearing if mis-set (extreme volumes)
--   "reload"   - the change won't take effect until /reload
--   "readonly" - SetCVar errors or has no effect; UI greys the edit button

local ADDON, ns = ...

local RiskyList = {}
ns.RiskyList = RiskyList

-- name -> tag
RiskyList.entries = {
    -- Danger: graphics that can leave the client unusable on bad values
    ["gxApi"]                    = "danger",
    ["gxWindow"]                 = "danger",
    ["gxMaximize"]               = "danger",
    ["gxWindowedResolution"]     = "danger",
    ["gxFullscreenResolution"]   = "danger",
    ["gxMonitor"]                = "danger",

    -- Audio: extreme values can blow speakers / hearing or fully mute
    ["Sound_OutputDriverIndex"]  = "audio",
    ["Sound_MasterVolume"]       = "audio",

    -- Network / voice
    ["voiceChatMode"]            = "danger",
    ["useIPv6"]                  = "danger",

    -- Reload-required (warn, don't block)
    ["scriptErrors"]             = "reload",
    ["scriptProfile"]            = "reload",
    ["taintLog"]                 = "reload",
    ["lockTaint"]                = "reload",
}

-- Returns nil for unknown CVars (treated as not risky).
function RiskyList.Tag(name)
    return RiskyList.entries[name]
end

function RiskyList.IsRisky(name)
    return RiskyList.entries[name] ~= nil
end

-- Returns true if editing this CVar requires a /reload to fully apply.
function RiskyList.NeedsReload(name)
    return RiskyList.entries[name] == "reload"
end

-- Returns true if SetCVar on this name is expected to error or no-op. Read-
-- only CVars will be marked here as we discover them; for now this is a
-- conservative empty set so the UI doesn't grey-out anything by mistake.
function RiskyList.IsReadOnly(name)
    return RiskyList.entries[name] == "readonly"
end

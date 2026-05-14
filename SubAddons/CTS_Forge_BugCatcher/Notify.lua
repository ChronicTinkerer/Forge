-- Forge_BugCatcher.Notify: combat-aware notification surface.
--
-- During combat we still capture every error (Capture.Add) — but we DON'T
-- pop the Bug Catcher window or flash a toast at the user, because that's
-- the worst possible moment to lose focus. Errors get tallied silently.
-- On PLAYER_REGEN_ENABLED, if the tally > 0, we fire ONE batched toast
-- ("3 errors during last pull. Click to view.") and reset.
--
-- Outside combat, each new capture fires the toast immediately (rate-
-- limited so a steady-state error storm doesn't keep re-flashing).
--
-- Toast UI: small Cairn-Gui Container anchored to bottom-right of UIParent,
-- above the typical chat frame. Auto-dismisses after TOAST_LIFETIME seconds.
-- Clicking opens the BugCatcher tab (Forge.Window.OpenTab("BugCatcher")).

local ADDON, ns = ...

local Notify = {}
ns.Notify = Notify


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local TOAST_LIFETIME   = 8     -- seconds before auto-dismiss
local OUT_OF_COMBAT_THROTTLE = 5  -- min seconds between out-of-combat toasts


-- ---------------------------------------------------------------------------
-- Module-scope state
-- ---------------------------------------------------------------------------

local _initialized
local _inCombat            = false
local _pendingCount        = 0     -- captures during combat awaiting a batch toast
local _lastToastTs         = 0
local _lastEntryCount      = 0     -- snapshot of Capture entries; delta detects new captures
local _toast               -- Cairn-Gui Container (built lazily)
local _toastLabel          -- title label inside toast
local _toastSubLabel       -- detail label inside toast
local _toastTimer          -- C_Timer handle for auto-dismiss


-- ---------------------------------------------------------------------------
-- Toast UI
-- ---------------------------------------------------------------------------

local function buildToast()
    if _toast then return end
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    _toast = Gui:Acquire("Container", UIParent, {
        bg          = "color.bg.surface",
        border      = "color.border.default",
        borderWidth = 1,
        width       = 260,
        height      = 50,
    })
    _toast.Cairn:SetLayoutManual(true)
    _toast:ClearAllPoints()
    -- Bottom-right of the screen, above where the chat frame typically
    -- sits. 220 px up gives clearance for chat without intruding on the
    -- action bars / bag bar.
    _toast:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -20, 220)
    _toast:SetFrameStrata("HIGH")
    _toast:SetFrameLevel(50)
    _toast:Hide()

    _toastLabel = Gui:Acquire("Label", _toast, {
        text    = "Bug Catcher",
        variant = "heading",
    })
    _toastLabel.Cairn:SetLayoutManual(true)
    _toastLabel:ClearAllPoints()
    _toastLabel:SetPoint("TOPLEFT",  _toast, "TOPLEFT",   8,  -6)
    _toastLabel:SetPoint("TOPRIGHT", _toast, "TOPRIGHT", -8,  -6)

    _toastSubLabel = Gui:Acquire("Label", _toast, {
        text    = "",
        variant = "muted",
    })
    _toastSubLabel.Cairn:SetLayoutManual(true)
    _toastSubLabel:ClearAllPoints()
    _toastSubLabel:SetPoint("BOTTOMLEFT",  _toast, "BOTTOMLEFT",   8,  6)
    _toastSubLabel:SetPoint("BOTTOMRIGHT", _toast, "BOTTOMRIGHT", -8,  6)

    -- Toast is clickable: opens the BugCatcher tab and dismisses itself.
    _toast:EnableMouse(true)
    _toast:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        if Forge and Forge.Window and Forge.Window.OpenTab then
            Forge.Window.OpenTab("BugCatcher")
        end
        Notify.HideToast()
    end)
end


function Notify.ShowToast(message)
    buildToast()
    if not _toast then return end
    if _toastSubLabel and _toastSubLabel.Cairn then
        _toastSubLabel.Cairn:SetText(message .. "  |cffaaaaaa(click to view)|r")
    end
    _toast:Show()
    if _toastTimer and _toastTimer.Cancel then _toastTimer:Cancel() end
    if C_Timer and C_Timer.NewTimer then
        _toastTimer = C_Timer.NewTimer(TOAST_LIFETIME, function() Notify.HideToast() end)
    end
end


function Notify.HideToast()
    if _toastTimer and _toastTimer.Cancel then
        _toastTimer:Cancel()
        _toastTimer = nil
    end
    if _toast then _toast:Hide() end
end


-- ---------------------------------------------------------------------------
-- Combat-deferred batching
-- ---------------------------------------------------------------------------
-- The capture loop's OnChange fires on every Add (and on dedup bumps too).
-- We don't want a toast per bump — only on net-new entries. Track
-- _lastEntryCount and compare to Capture.GetAll() size to spot net additions.

local function entriesNow()
    if ns.Capture and ns.Capture.GetAll then
        return #ns.Capture.GetAll()
    end
    return 0
end


local function onCaptureChange()
    local current = entriesNow()
    local delta   = current - _lastEntryCount
    if delta <= 0 then
        -- Dedup bump (count++) — not a new entry. Keep the snapshot.
        _lastEntryCount = current
        return
    end
    _lastEntryCount = current

    if _inCombat then
        _pendingCount = _pendingCount + delta
        return
    end

    -- Out of combat: throttle so steady-state errors don't keep
    -- flashing the toast.
    local now = (GetTime and GetTime()) or 0
    if now - _lastToastTs < OUT_OF_COMBAT_THROTTLE then return end
    _lastToastTs = now
    Notify.ShowToast(("%d new error%s"):format(delta, delta == 1 and "" or "s"))
end


local function onCombatStart()
    _inCombat = true
end


local function onCombatEnd()
    _inCombat = false
    if _pendingCount > 0 then
        Notify.ShowToast(
            ("%d error%s during last pull"):format(_pendingCount, _pendingCount == 1 and "" or "s"))
        _pendingCount = 0
        _lastToastTs  = (GetTime and GetTime()) or 0
    end
end


-- ---------------------------------------------------------------------------
-- Public: Init
-- ---------------------------------------------------------------------------

function Notify.Init()
    if _initialized then return end
    _initialized = true
    _inCombat        = (InCombatLockdown and InCombatLockdown()) or false
    _lastEntryCount  = entriesNow()

    -- Subscribe to Capture changes for the per-entry detection.
    if ns.Capture and ns.Capture.OnChange then
        ns.Capture.OnChange(onCaptureChange)
    end

    -- Combat state events. Use a private frame because Cairn-Events isn't
    -- guaranteed to be wired up before this module runs.
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function(_, event)
        if     event == "PLAYER_REGEN_DISABLED" then onCombatStart()
        elseif event == "PLAYER_REGEN_ENABLED"  then onCombatEnd()
        end
    end)
end

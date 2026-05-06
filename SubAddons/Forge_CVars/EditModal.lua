-- Forge_CVars.EditModal: edit a CVar via a small modal dialog.
--
-- Flow:
--   1. UI's row-Edit click calls EditModal.Open(cvarName, onDone).
--   2. Modal lazy-builds a single shared frame, prefills the Input with
--      the current GetCVar value, shows current/default for context. If the
--      CVar is in RiskyList, a warning strip appears with tag-specific
--      copy (danger / audio / reload).
--   3. User clicks Confirm: EditModal.CommitImmediate runs SetCVar inside
--      pcall, modal hides, onDone(ok, err, value) fires so the list can
--      repaint the row.
--   4. User clicks Cancel: modal hides, onDone(false, "cancelled") fires.
--
-- The Confirm / Cancel controls and the value EditBox are
-- `Cairn-Gui-Core-1.0` widgets (Button / Input). The modal shell itself is
-- a plain backdrop Frame — same pattern Forge_AddonManager uses for its
-- name-prompt popup, since Cairn-Gui's `Window` widget is heavier than
-- needed for a small confirm dialog.

local ADDON, ns = ...

local EditModal = {}
ns.EditModal = EditModal

local _frame  -- single shared modal frame, lazy-built on first Open

-- --------------------------------------------------------------------------
-- Imperative SetCVar helpers.
-- --------------------------------------------------------------------------
function EditModal.CommitImmediate(name, newValue)
    if type(name) ~= "string" or name == "" then return false, "no cvar name" end
    if not SetCVar then return false, "SetCVar unavailable" end
    local ok, err = pcall(SetCVar, name, tostring(newValue or ""))
    if not ok then return false, tostring(err) end
    return true
end

function EditModal.ResetToDefault(name)
    local def = GetCVarDefault and GetCVarDefault(name)
    if def == nil then return false, "no default known" end
    return EditModal.CommitImmediate(name, def)
end

-- --------------------------------------------------------------------------
-- Modal builder. Backdrop Frame shell + Cairn-Gui widgets inside.
-- --------------------------------------------------------------------------
local function buildModal()
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)

    local f = CreateFrame("Frame", "ForgeCVarsEditModal", UIParent, "BackdropTemplate")
    f:SetSize(420, 230)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.95)
    f:SetBackdropBorderColor(0.85, 0.50, 0.20, 1)
    f:Hide()

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    f._title = title

    local currentLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    currentLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    currentLabel:SetText("Current:")

    local currentVal = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    currentVal:SetPoint("LEFT", currentLabel, "RIGHT", 6, 0)
    f._currentVal = currentVal

    local defaultLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    defaultLabel:SetPoint("TOPLEFT", currentLabel, "BOTTOMLEFT", 0, -4)
    defaultLabel:SetText("Default:")

    local defaultVal = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    defaultVal:SetPoint("LEFT", defaultLabel, "RIGHT", 6, 0)
    f._defaultVal = defaultVal

    local newLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    newLabel:SetPoint("TOPLEFT", defaultLabel, "BOTTOMLEFT", 0, -16)
    newLabel:SetText("New value:")

    -- Cairn-Gui Input widget for the value EditBox. Inner Blizzard EditBox is
    -- exposed at .editBox so we can SetFocus / hook OnEnterPressed etc.
    local input = Gui and Gui:Create("Input")
    local innerEb, getText, setText, setFocus
    if input then
        input:SetParent(f); input:ClearAllPoints()
        input:SetWidth(280); input:SetHeight(22)
        input:SetPoint("LEFT", newLabel, "RIGHT", 8, 0)
        innerEb  = input.editBox
        getText  = function() return input:GetText() or "" end
        setText  = function(s) input:SetText(s or "") end
        setFocus = function() input.editBox:SetFocus() end
        f._input = input
    else
        local raw = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        raw:SetSize(280, 22); raw:SetPoint("LEFT", newLabel, "RIGHT", 8, 0)
        raw:SetAutoFocus(true); raw:SetFontObject("ChatFontNormal")
        innerEb  = raw
        getText  = function() return raw:GetText() or "" end
        setText  = function(s) raw:SetText(s or "") end
        setFocus = function() raw:SetFocus() end
        f._input = raw
    end
    f._getText  = getText
    f._setText  = setText
    f._setFocus = setFocus
    f._innerEb  = innerEb

    -- Warning strip (hidden by default; shown for risky CVars).
    local warn = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    warn:SetPoint("TOPLEFT", newLabel, "BOTTOMLEFT", 0, -18)
    warn:SetPoint("RIGHT",   f, "RIGHT", -14, 0)
    warn:SetJustifyH("LEFT"); warn:SetJustifyV("TOP")
    warn:SetWordWrap(true)
    warn:SetText(""); warn:Hide()
    f._warn = warn

    -- Confirm / Cancel buttons. Per `diesal_button_empty_text` both get
    -- non-empty labels at create time.
    local function makeBtn(labelText)
        local widget = Gui and Gui:Create("Button")
        if widget then
            widget:SetParent(f); widget:ClearAllPoints()
            widget:SetWidth(100); widget:SetHeight(24)
            widget:SetText(labelText)
            return widget, widget.frame
        else
            local raw = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
            raw:SetSize(100, 24); raw:SetText(labelText)
            return raw, raw
        end
    end

    local cancel, cancelF = makeBtn("Cancel")
    cancel:ClearAllPoints(); cancel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 12)
    f._cancelBtn = cancel

    local confirm, confirmF = makeBtn("Confirm")
    confirm:ClearAllPoints(); confirm:SetPoint("RIGHT", cancelF, "LEFT", -8, 0)
    f._confirmBtn = confirm

    return f
end

-- --------------------------------------------------------------------------
-- Open the modal for a specific CVar.
--
-- onDone is called with (ok, err, value):
--   ok    = true if SetCVar succeeded
--   err   = nil on success, "cancelled" if cancelled, error message otherwise
--   value = the new value if ok, else nil
-- --------------------------------------------------------------------------
local function bindClick(widget, fn)
    if not widget then return end
    if widget.SetEventListener then
        widget:SetEventListener("OnClick", fn)
    else
        widget:SetScript("OnClick", fn)
    end
end

function EditModal.Open(name, onDone)
    if not _frame then _frame = buildModal() end
    local f = _frame

    local cur = (ns.Snapshot and ns.Snapshot.GetCurrent(name)) or ""
    local def = (ns.Snapshot and ns.Snapshot.GetDefault(name)) or "(unknown)"

    f._title:SetText("|cffd87f3aEdit CVar:|r " .. tostring(name))
    f._currentVal:SetText(tostring(cur))
    f._defaultVal:SetText(tostring(def))
    f._setText(tostring(cur))
    if f._innerEb and f._innerEb.HighlightText then f._innerEb:HighlightText() end

    local tag = ns.RiskyList and ns.RiskyList.Tag(name)
    if tag == "danger" then
        f._warn:Show()
        f._warn:SetText("|cffff4040Warning:|r setting an invalid value for this CVar can leave the client unusable. Make sure you know what you're doing.")
    elseif tag == "audio" then
        f._warn:Show()
        f._warn:SetText("|cffffaa20Warning:|r extreme audio values can damage hearing or speakers.")
    elseif tag == "reload" then
        f._warn:Show()
        f._warn:SetText("|cffffd200Note:|r this CVar requires |cffffffff/reload|r before the change takes effect in the running session.")
    else
        f._warn:Hide()
        f._warn:SetText("")
    end

    local function close(ok, err, value)
        f:Hide()
        if onDone then onDone(ok, err, value) end
    end

    local function fireConfirm()
        local newVal = f._getText() or ""
        local ok, err = EditModal.CommitImmediate(name, newVal)
        close(ok, err, ok and newVal or nil)
    end

    bindClick(f._confirmBtn, fireConfirm)
    bindClick(f._cancelBtn,  function() close(false, "cancelled", nil) end)

    if f._innerEb then
        f._innerEb:SetScript("OnEscapePressed", function() close(false, "cancelled", nil) end)
        f._innerEb:HookScript("OnEnterPressed", fireConfirm)
    end

    f:Show()
    f._setFocus()
end

-- --------------------------------------------------------------------------
-- Wrapper. If newValue is nil, opens the modal; otherwise commits directly.
-- --------------------------------------------------------------------------
function EditModal.Commit(name, newValue, onDone)
    if newValue == nil then
        return EditModal.Open(name, onDone)
    end
    local ok, err = EditModal.CommitImmediate(name, newValue)
    if onDone then onDone(ok, err, ok and newValue or nil) end
end

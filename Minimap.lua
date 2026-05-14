-- Forge.Minimap: optional minimap button.
--
-- Preferred path: LibDataBroker-1.1 + LibDBIcon-1.0 (the standard combo).
-- Gives the user a draggable, hideable, themed button that coexists with
-- every other addon's minimap button.
--
-- Fallback path: if LibDBIcon isn't installed, anchor a plain Button to
-- the top-right of the minimap. Less polished but always works.
--
-- Click behavior:
--   Left-click  -> toggle the Forge window
--   Right-click -> open the BugCatcher tab if loaded; else just toggle
--
-- Tooltip: Forge build + status of currently-loaded sub-modules. Refreshes
-- as the cursor lingers (we re-build on each OnEnter, not on a timer —
-- the user only sees it when they hover).
--
-- Position persistence: handled by LibDBIcon via db.profile.minimap. The
-- fallback path doesn't drag, so its position is fixed.

local ADDON, ns = ...

local Minimap = {}
ns.Minimap = Minimap


local _button         -- fallback button (only set when LibDBIcon is absent)
local _dbiRegistered  -- "<addon>" key passed to LibDBIcon — pinned for hide/show


-- ---------------------------------------------------------------------------
-- Click + tooltip handlers (shared between LibDBIcon and fallback)
-- ---------------------------------------------------------------------------

local function onClick(_, button)
    if button == "RightButton" and ns.Registry and ns.Registry.Get("BugCatcher") then
        if ns.Window and ns.Window.OpenTab then
            ns.Window.OpenTab("BugCatcher")
            return
        end
    end
    if ns.Window and ns.Window.Toggle then
        ns.Window.Toggle()
    end
end


local function fillTooltip(tt)
    tt:AddLine("|cffd87f3aForge|r")
    tt:AddLine("Build " .. tostring(ns.BUILD or "?"), 1, 1, 1)
    if ns.Registry then
        tt:AddLine("Sub-modules: " .. ns.Registry.CountString(), 0.7, 0.7, 0.7)
    end
    tt:AddLine(" ")
    tt:AddLine("|cffaaaaaaLeft-click:|r toggle window", 1, 1, 1)
    if ns.Registry and ns.Registry.Get("BugCatcher") then
        tt:AddLine("|cffaaaaaaRight-click:|r open Bug Catcher", 1, 1, 1)
    end
end


-- ---------------------------------------------------------------------------
-- LibDBIcon path
-- ---------------------------------------------------------------------------

local function setupViaLibDBIcon(db)
    local LDB    = LibStub("LibDataBroker-1.1", true)
    local LDBIcon = LibStub("LibDBIcon-1.0",    true)
    if not (LDB and LDBIcon) then return false end

    -- LibDBIcon persists hide/minimapPos under db.profile.minimap.
    -- Default to "shown" with no explicit angular position (LibDBIcon
    -- picks a sensible default).
    db.profile.minimap = db.profile.minimap or { hide = false }

    local dataobject = LDB:NewDataObject("Forge", {
        type    = "launcher",
        text    = "Forge",
        icon    = "Interface\\ICONS\\Trade_Engineering",
        OnClick = onClick,
        OnTooltipShow = fillTooltip,
    })

    -- The "Forge" name must be unique across the whole game's LDB
    -- registry; if another addon already registered under it,
    -- :NewDataObject returns nil. Bail without registering with the icon
    -- lib in that case.
    if not dataobject then return false end

    LDBIcon:Register("Forge", dataobject, db.profile.minimap)
    _dbiRegistered = "Forge"
    return true
end


-- ---------------------------------------------------------------------------
-- Fallback path: fixed-position Button anchored to the minimap
-- ---------------------------------------------------------------------------

local function setupFallback(db)
    if _button or not _G.Minimap then return end

    local b = CreateFrame("Button", "ForgeMinimapButton", _G.Minimap)
    b:SetSize(32, 32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel((_G.Minimap:GetFrameLevel() or 0) + 8)
    b:SetPoint("TOPRIGHT", _G.Minimap, "TOPRIGHT", -4, -4)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\ICONS\\Trade_Engineering")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("CENTER", b, "CENTER", 11, -11)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        fillTooltip(GameTooltip)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    _button = b
end


-- ---------------------------------------------------------------------------
-- Public: Create / Refresh / Hide
-- ---------------------------------------------------------------------------

function Minimap.Create(db)
    if not db then return end
    if setupViaLibDBIcon(db) then return end
    setupFallback(db)
end


-- Toggle visibility via LibDBIcon's hide/show. Fallback path doesn't
-- support hide (the button is always visible there for v1).
function Minimap.SetHidden(hidden, db)
    if _dbiRegistered then
        local LDBIcon = LibStub("LibDBIcon-1.0", true)
        if LDBIcon then
            if db and db.profile.minimap then
                db.profile.minimap.hide = hidden and true or false
            end
            if hidden then LDBIcon:Hide(_dbiRegistered)
            else            LDBIcon:Show(_dbiRegistered) end
        end
        return
    end
    if _button then
        if hidden then _button:Hide() else _button:Show() end
    end
end

-- Forge_BugCatcher.Minimap: simple minimap button with session error count badge.
--
-- v0.1: fixed position (top-right of the minimap). v0.2 will add drag-to-position
-- via LibDBIcon-1.0 if available.

local ADDON, ns = ...

local Minimap = {}
ns.Minimap = Minimap

local _button

function Minimap.Refresh()
    if not (_button and _button._countText) then return end
    local n = (ns.Capture and ns.Capture.SessionCount and ns.Capture.SessionCount()) or 0
    if n > 0 then
        _button._countText:SetText(tostring(n))
        _button._countText:Show()
    else
        _button._countText:Hide()
    end
end

function Minimap.Create()
    if _button then return _button end
    local anchor = _G.Minimap
    if not anchor then return end

    local b = CreateFrame("Button", "ForgeBugCatcherMinimapButton", anchor)
    b:SetSize(32, 32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel((anchor:GetFrameLevel() or 0) + 8)
    b:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -4, -4)
    b:RegisterForClicks("LeftButtonUp")

    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\ICONS\\Spell_ChargeNegative")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("CENTER", b, "CENTER", 11, -11)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local count = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, 2)
    count:SetTextColor(1, 0.3, 0.3, 1)
    count:Hide()
    b._countText = count

    b:SetScript("OnClick", function()
        if Forge and Forge.Window and Forge.Window.OpenTab then
            Forge.Window.OpenTab("BugCatcher")
        end
    end)
    b:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cffd87f3aForge Bug Catcher|r")
        local n = (ns.Capture and ns.Capture.SessionCount and ns.Capture.SessionCount()) or 0
        GameTooltip:AddLine("Session errors: " .. n, 1, 1, 1)
        GameTooltip:AddLine("|cffaaaaaaClick to open the viewer.|r")
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    _button = b

    if ns.Capture and ns.Capture.OnChange then
        ns.Capture.OnChange(function() Minimap.Refresh() end)
    end
    Minimap.Refresh()
    return b
end

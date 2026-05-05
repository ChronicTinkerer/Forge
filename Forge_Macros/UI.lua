-- Forge_Macros.UI: top-level mode switcher + composition of Macros / Sequences panels.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H = 28
local PAD       = 6
local _activeMod
local _mode = "macros"  -- "macros" or "sequences"

local function paint(btn, active)
    if not btn then return end
    if active then btn:LockHighlight() else btn:UnlockHighlight() end
end

function UI.SwitchMode(mode)
    _mode = mode
    local mod = _activeMod
    if not mod then return end
    paint(mod._modeMacros,    _mode == "macros")
    paint(mod._modeSequences, _mode == "sequences")
    if _mode == "macros" then
        if ns.UI_Sequences and ns.UI_Sequences.Hide then ns.UI_Sequences.Hide(mod) end
        if ns.UI_Macros and ns.UI_Macros.Show then ns.UI_Macros.Show(mod) end
    else
        if ns.UI_Macros and ns.UI_Macros.Hide then ns.UI_Macros.Hide(mod) end
        if ns.UI_Sequences and ns.UI_Sequences.Show then ns.UI_Sequences.Show(mod) end
    end
end

function UI.Build(parent, mod)
    _activeMod = mod
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  4, -4)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    bar:SetHeight(TOOLBAR_H)

    local macrosBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    macrosBtn:SetSize(110, 22)
    macrosBtn:SetPoint("LEFT", bar, "LEFT", 4, 0)
    macrosBtn:SetText("Macros")
    macrosBtn:SetScript("OnClick", function() UI.SwitchMode("macros") end)
    mod._modeMacros = macrosBtn

    local seqBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    seqBtn:SetSize(110, 22)
    seqBtn:SetPoint("LEFT", macrosBtn, "RIGHT", 4, 0)
    seqBtn:SetText("Sequences")
    seqBtn:SetScript("OnClick", function() UI.SwitchMode("sequences") end)
    mod._modeSequences = seqBtn

    local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", seqBtn, "RIGHT", 12, 0)
    hint:SetText("Macros: edit raw WoW macros.   Sequences: stack of lines that compile to a /castsequence macro.")

    -- Body panel that holds whichever mode's UI is currently visible.
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT",     bar,   "BOTTOMLEFT",  0, -PAD)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    mod._body = body

    -- Build both sub-panels parented to the body. Visibility toggled by mode.
    if ns.UI_Macros and ns.UI_Macros.Build then
        ns.UI_Macros.Build(body, mod)
    end
    if ns.UI_Sequences and ns.UI_Sequences.Build then
        ns.UI_Sequences.Build(body, mod)
    end

    UI.SwitchMode(_mode)
end

function UI.OnTabShow(mod)
    _activeMod = mod
    UI.SwitchMode(_mode)
end

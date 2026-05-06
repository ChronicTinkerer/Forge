-- Forge_Macros.UI: top-level mode switcher + composition of Macros / Sequences panels.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H = 28
local PAD       = 6
local _activeMod
local _mode = "macros"  -- "macros" or "sequences"

-- ObjectBase doesn't pass through LockHighlight, so for kit buttons we
-- delegate to the inner frame. Vanilla buttons accept LockHighlight directly.
local function paint(btn, active)
    if not btn then return end
    local target = btn.frame or btn
    if active then
        if target.LockHighlight then target:LockHighlight() end
    else
        if target.UnlockHighlight then target:UnlockHighlight() end
    end
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

    -- Mode tabs via Cairn-Gui Button with vanilla fallback. paint() above
    -- handles both backends for highlight state.
    local Gui = LibStub and LibStub("Cairn-Gui-Core-1.0", true)
    local function makeBtn(label, w, h, anchor, dx, onClick)
        local b = Gui and Gui:Create("Button")
        if b then
            b:SetParent(bar); b:ClearAllPoints()
            b:SetWidth(w); b:SetHeight(h); b:SetText(label)
            if anchor.point == "LEFT_OF_BAR" then
                b:SetPoint("LEFT", bar, "LEFT", dx, 0)
            else
                b:SetPoint("LEFT", anchor.frame, "RIGHT", dx, 0)
            end
            if onClick then b:SetEventListener("OnClick", function() onClick() end) end
            return b, b.frame
        else
            local raw = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
            raw:SetSize(w, h); raw:SetText(label)
            if anchor.point == "LEFT_OF_BAR" then
                raw:SetPoint("LEFT", bar, "LEFT", dx, 0)
            else
                raw:SetPoint("LEFT", anchor.frame, "RIGHT", dx, 0)
            end
            if onClick then raw:SetScript("OnClick", onClick) end
            return raw, raw
        end
    end

    local macrosBtn, macrosBtnFrame = makeBtn("Macros", 110, 22,
        { point = "LEFT_OF_BAR" }, 4,
        function() UI.SwitchMode("macros") end)
    mod._modeMacros = macrosBtn

    local seqBtn, seqBtnFrame = makeBtn("Sequences", 110, 22,
        { point = "LEFT_OF", frame = macrosBtnFrame }, 4,
        function() UI.SwitchMode("sequences") end)
    mod._modeSequences = seqBtn

    local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", seqBtnFrame, "RIGHT", 12, 0)
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

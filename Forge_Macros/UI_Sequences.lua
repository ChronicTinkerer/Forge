-- Forge_Macros.UI_Sequences: GSE-style sequence builder.
-- Stores named sequences (ordered list of lines). Compiles to a /castsequence
-- macro for spell-only sequences; for arbitrary lines, generates an
-- informational warning and a best-effort comma-joined macro body.

local ADDON, ns = ...

local S = {}
ns.UI_Sequences = S

local LIST_W   = 220
local ROW_H    = 22
local STEP_H   = 26
local PAD      = 6
local BTN_W    = 80
local BTN_H    = 22

local _activeMod
local _selectedName

local function fitsCastSequence(steps)
    -- All steps must be `/cast SpellName` (case-insensitive, optionally with
    -- spaces) with no conditions or extra args. Returns the spell list or nil.
    local spells = {}
    for _, line in ipairs(steps) do
        local s = (line or ""):match("^%s*(.-)%s*$") or ""
        local spell = s:match("^/cast%s+(.+)$") or s:match("^/cast%s+(.+)$")
        if not spell then return nil end
        spells[#spells + 1] = spell
    end
    return spells
end

local function compile(name, steps)
    -- Try /castsequence path first.
    local spells = fitsCastSequence(steps)
    if spells and #spells > 0 then
        local body = "/castsequence reset=target/combat " .. table.concat(spells, ", ")
        return body, "castsequence"
    end
    -- Fallback: emit one line per step. WoW will fire all of them on each
    -- press (no cycling) -- this matches a plain multi-line macro, not GSE.
    local out = {}
    for _, line in ipairs(steps) do
        local trimmed = (line or ""):match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            out[#out + 1] = trimmed
        end
    end
    return table.concat(out, "\n"), "plain-multi"
end

local function buildSequenceList(parent, mod)
    local pane = CreateFrame("Frame", nil, parent)
    pane:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    pane:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    pane:SetWidth(LIST_W)

    local newBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    newBtn:SetSize(LIST_W, 22)
    newBtn:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
    newBtn:SetText("+ New sequence")
    newBtn:SetScript("OnClick", function() S.NewSequence() end)

    local listBg = CreateFrame("Frame", nil, pane, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", newBtn, "BOTTOMLEFT", 0, -PAD)
    listBg:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
    listBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    listBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    listBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    local sf = CreateFrame("ScrollFrame", nil, listBg, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -22, 6)
    mod._seqListScroll = sf
    local content = CreateFrame("Frame", nil, sf); content:SetSize(1,1); sf:SetScrollChild(content)
    mod._seqListContent = content
    mod._seqListRows = {}

    return pane
end

local function buildEditor(parent, mod)
    local pane = CreateFrame("Frame", nil, parent)
    pane:SetPoint("TOPLEFT", parent, "TOPLEFT", LIST_W + PAD, 0)
    pane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

    local nameLabel = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -2)
    nameLabel:SetText("Sequence name")
    local nameEB = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    nameEB:SetSize(220, 20)
    nameEB:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 6, -2)
    nameEB:SetAutoFocus(false)
    mod._seqNameEB = nameEB
    nameEB:SetScript("OnEnterPressed", function(self) self:ClearFocus(); S.RenameCurrent(self:GetText()) end)

    local stepsLabel = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stepsLabel:SetPoint("TOPLEFT", nameEB, "BOTTOMLEFT", -6, -PAD)
    stepsLabel:SetText("Steps  |cffaaaaaa(one macro line per step)|r")

    local stepsBg = CreateFrame("Frame", nil, pane, "BackdropTemplate")
    stepsBg:SetPoint("TOPLEFT", stepsLabel, "BOTTOMLEFT", 0, -2)
    stepsBg:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, BTN_H + PAD + 4)
    stepsBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    stepsBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    stepsBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)

    local sf = CreateFrame("ScrollFrame", nil, stepsBg, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -28, 6)
    mod._stepsScroll = sf
    local content = CreateFrame("Frame", nil, sf); content:SetSize(1,1); sf:SetScrollChild(content)
    mod._stepsContent = content
    mod._stepRows = {}

    -- Bottom: Add Step | Delete Sequence | Compile.
    local addStepBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    addStepBtn:SetSize(BTN_W + 20, BTN_H)
    addStepBtn:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 0, 0)
    addStepBtn:SetText("+ Add step")
    addStepBtn:SetScript("OnClick", function() S.AddStep() end)

    local delBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    delBtn:SetSize(BTN_W + 20, BTN_H)
    delBtn:SetPoint("LEFT", addStepBtn, "RIGHT", 4, 0)
    delBtn:SetText("Delete sequence")
    delBtn:SetScript("OnClick", function() S.DeleteCurrent() end)

    local compileBtn = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    compileBtn:SetSize(140, BTN_H)
    compileBtn:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
    compileBtn:SetText("Compile to macro")
    compileBtn:SetScript("OnClick", function() S.CompileCurrent() end)

    return pane
end

local function refreshSequenceList(mod)
    if not (mod._seqListContent and ns.GetSequences) then return end
    for _, row in ipairs(mod._seqListRows) do row:Hide() end
    local names = {}
    for n in pairs(ns.GetSequences()) do names[#names + 1] = n end
    table.sort(names)

    local y = 0
    for i, name in ipairs(names) do
        local row = mod._seqListRows[i]
        if not row then
            row = CreateFrame("Button", nil, mod._seqListContent)
            row:SetHeight(ROW_H)
            local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
            hov:SetColorTexture(0.45, 0.32, 0.15, 0.30); hov:SetAllPoints(); hov:Hide()
            row._hov = hov
            local sel = row:CreateTexture(nil, "BACKGROUND", nil, -2)
            sel:SetColorTexture(0.85, 0.50, 0.20, 0.35); sel:SetAllPoints(); sel:Hide()
            row._sel = sel
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("LEFT", row, "LEFT", 6, 0); text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            text:SetJustifyH("LEFT"); text:SetWordWrap(false); text:SetMaxLines(1)
            row._text = text
            row:SetScript("OnEnter", function(self) self._hov:Show() end)
            row:SetScript("OnLeave", function(self) self._hov:Hide() end)
            row:SetScript("OnClick", function(self) S.Select(self._name) end)
            mod._seqListRows[i] = row
        end
        row._name = name
        local seq = ns.GetSequence(name) or { steps = {} }
        row._text:SetText(string.format("%s  |cffaaaaaa(%d)|r", name, #(seq.steps or {})))
        row._sel:SetShown(name == _selectedName)
        row:ClearAllPoints()
        row:SetWidth(mod._seqListScroll:GetWidth() - 24)
        row:SetPoint("TOPLEFT", mod._seqListContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + ROW_H
    end
    if y < 1 then y = 1 end
    mod._seqListContent:SetHeight(y)
    mod._seqListScroll:UpdateScrollChildRect()
end

local function buildStepRow(parent, idx)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(STEP_H)

    local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    upBtn:SetSize(20, 20); upBtn:SetPoint("LEFT", row, "LEFT", 0, 0); upBtn:SetText("^")
    local dnBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    dnBtn:SetSize(20, 20); dnBtn:SetPoint("LEFT", upBtn, "RIGHT", 2, 0); dnBtn:SetText("v")
    local rmBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    rmBtn:SetSize(20, 20); rmBtn:SetPoint("LEFT", dnBtn, "RIGHT", 2, 0); rmBtn:SetText("x")

    local idxLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    idxLabel:SetPoint("LEFT", rmBtn, "RIGHT", 4, 0)
    idxLabel:SetWidth(28); idxLabel:SetJustifyH("LEFT")
    idxLabel:SetTextColor(0.85, 0.7, 0.4, 1)
    row._idxLabel = idxLabel

    local eb = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    eb:SetSize(360, 20)
    eb:SetPoint("LEFT", idxLabel, "RIGHT", 6, 0); eb:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    eb:SetAutoFocus(false)
    row._eb = eb

    upBtn:SetScript("OnClick", function() S.MoveStep(row._index, -1) end)
    dnBtn:SetScript("OnClick", function() S.MoveStep(row._index, 1) end)
    rmBtn:SetScript("OnClick", function() S.RemoveStep(row._index) end)
    eb:SetScript("OnTextChanged", function(self) S.UpdateStep(row._index, self:GetText()) end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    return row
end

local function refreshSteps(mod)
    if not mod._stepsContent then return end
    for _, row in ipairs(mod._stepRows) do row:Hide() end
    local seq = _selectedName and ns.GetSequence(_selectedName)
    local steps = (seq and seq.steps) or {}
    local y = 0
    for i, line in ipairs(steps) do
        local row = mod._stepRows[i]
        if not row then
            row = buildStepRow(mod._stepsContent, i)
            mod._stepRows[i] = row
        end
        row._index = i
        row._idxLabel:SetText(tostring(i))
        row._eb:SetText(line or "")
        row:ClearAllPoints()
        row:SetWidth(mod._stepsScroll:GetWidth() - 4)
        row:SetPoint("TOPLEFT", mod._stepsContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + STEP_H + 2
    end
    if y < 1 then y = 1 end
    mod._stepsContent:SetHeight(y)
    mod._stepsScroll:UpdateScrollChildRect()
end

function S.Refresh()
    local mod = _activeMod
    if not mod then return end
    if mod._seqNameEB then mod._seqNameEB:SetText(_selectedName or "") end
    refreshSequenceList(mod)
    refreshSteps(mod)
end

function S.Select(name)
    _selectedName = name
    S.Refresh()
end

function S.NewSequence()
    if not (ns.SaveSequence) then return end
    local n = 1
    while ns.GetSequence("Sequence " .. n) do n = n + 1 end
    local name = "Sequence " .. n
    ns.SaveSequence(name, { steps = {} })
    _selectedName = name
    S.Refresh()
end

function S.RenameCurrent(newName)
    if not _selectedName or not newName or newName == "" or newName == _selectedName then return end
    if ns.RenameSequence and ns.RenameSequence(_selectedName, newName) then
        _selectedName = newName
        S.Refresh()
    end
end

function S.DeleteCurrent()
    if not _selectedName then return end
    if ns.DeleteSequence then ns.DeleteSequence(_selectedName) end
    _selectedName = nil
    S.Refresh()
end

function S.AddStep()
    if not _selectedName then return end
    local seq = ns.GetSequence(_selectedName) or { steps = {} }
    seq.steps[#seq.steps + 1] = ""
    ns.SaveSequence(_selectedName, seq)
    S.Refresh()
end

function S.RemoveStep(idx)
    if not _selectedName then return end
    local seq = ns.GetSequence(_selectedName)
    if not seq then return end
    table.remove(seq.steps, idx)
    ns.SaveSequence(_selectedName, seq)
    S.Refresh()
end

function S.MoveStep(idx, delta)
    if not _selectedName then return end
    local seq = ns.GetSequence(_selectedName)
    if not seq then return end
    local newIdx = idx + delta
    if newIdx < 1 or newIdx > #seq.steps then return end
    local tmp = seq.steps[idx]
    seq.steps[idx] = seq.steps[newIdx]
    seq.steps[newIdx] = tmp
    ns.SaveSequence(_selectedName, seq)
    S.Refresh()
end

function S.UpdateStep(idx, text)
    if not _selectedName then return end
    local seq = ns.GetSequence(_selectedName)
    if not seq or not seq.steps[idx] then return end
    seq.steps[idx] = text or ""
    ns.SaveSequence(_selectedName, seq, true)  -- silent save (don't refresh UI)
end

function S.CompileCurrent()
    if not _selectedName then return end
    local seq = ns.GetSequence(_selectedName)
    if not seq or #seq.steps == 0 then
        if ns.out then ns.out("sequence is empty.") end
        return
    end
    local body, mode = compile(_selectedName, seq.steps)
    -- Create a character macro with the compiled body.
    local idx = ns.MacroAPI.Create(_selectedName:sub(1, 16), "INV_Misc_QuestionMark", body, true)
    if idx then
        if ns.out then
            ns.out(string.format("compiled '%s' (%s) into macro slot #%d.", _selectedName, mode, idx))
            if mode == "plain-multi" then
                ns.out("|cffffaa00note:|r non-/cast steps don't cycle. Each press fires every line.")
            end
        end
    else
        if ns.out then ns.out("compile failed (character macro slots full?).") end
    end
end

function S.Build(parent, mod)
    _activeMod = mod
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._sequencesPanel = frame
    buildSequenceList(frame, mod)
    buildEditor(frame, mod)
    S.Refresh()
end

function S.Show(mod)
    _activeMod = mod
    if mod._sequencesPanel then mod._sequencesPanel:Show() end
    S.Refresh()
end

function S.Hide(mod)
    if mod._sequencesPanel then mod._sequencesPanel:Hide() end
end

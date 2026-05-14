-- Forge_CVars: WoW CVar viewer + editor.
--
-- v3 scope (this file):
--   * Cairn-Gui TreeView widget renders ~1600 CVars as collapsible
--     groups by camelCase prefix; filter chips (All / Changed) + live
--     substring search.
--   * Click a CVar leaf to select it; editor row loads name + current
--     value. Set / Reset / combat-aware disable.
--   * NEW: 'Bits' toggle next to the editor. When active, shows a row of
--     16 per-bit toggle buttons for integer-valued cvars. Generic - no
--     dependency on Blizzard's named-bit infrastructure.
--   * NEW: 'Presets...' popup (Window at DIALOG strata): save the
--     current changed-from-default snapshot under a name, then apply or
--     delete later. Persisted in db.global.presets so they're account-wide.
--
-- Out of scope for v3 (queued for v4):
--   * Combat-deferred set queue (currently combat = disable buttons).
--   * Categorical grouping beyond camelCase prefix.
--   * Per-cvar history / undo.
--
-- Grouping algorithm:
--   * Split each CVar name at the first lowercase->uppercase transition.
--     "nameplateMaxDistance" -> group "nameplate".
--     "screenshotQuality"    -> group "screenshot".
--     "fps"                  -> group "fps" (no transition; whole name).
--     "ALL_CAPS"             -> group "ALL_CAPS" (no transition).
--   * Groups with one or zero members are merged into a synthetic
--     "(misc)" branch so the tree doesn't sprout singleton groups.

local ADDON, ns = ...
_G.Forge_CVars = ns


Cairn.Register("CTS_Forge_CVars", ns, {
    dbName = "Forge_CVarsDB",
    Log = true, Events = true, Timer = true,
    dbDefaults = {
        profile = {},
        global  = { presets = {} },  -- v3: preset name -> {cvar = value}
    },
})

local _registry = Cairn.GetRegistry()
local _entry    = _registry["CTS_Forge_CVars"]
local db        = _entry and _entry.db
local addon     = _entry and _entry.cairnAddon
ns.db, ns.addon = db, addon


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

local VALUE_PREVIEW_MAX   = 60
local MIN_GROUP_SIZE      = 2     -- prefixes with < this many CVars go in (misc)
local TREE_ROW_HEIGHT     = 18
local TREE_INDENT         = 16

-- Layout offsets used by relayout().
local TOP_RESERVED_BASE   = 150  -- v2 layout: heading + hint + toolbar + editor + help + gaps
local BITS_ROW_HEIGHT     = 28
local BITS_ROW_GAP        = 6
local BOTTOM_PAD          = 10
local SIDE_PAD            = 10


-- ---------------------------------------------------------------------------
-- Module-scope state
-- ---------------------------------------------------------------------------

local _allCVars       = nil    -- array { name, help } sorted by name
local _searchFilter   = ""
local _filterMode     = "all"  -- "all" | "changed"
local _selectedCVar   = nil
local _bitsMode       = false  -- v3: when true, show per-bit toggle row for
                               -- the selected cvar (if its value parses as
                               -- a non-negative integer).

local BITS_VISIBLE    = 16     -- bits 0..15 shown in the panel. 16 covers
                               -- every well-known integer-flag CVar I've
                               -- run into; values above 0xFFFF still get
                               -- toggled correctly via the integer column.

local _pane
local _searchBox
local _statusLabel
local _filterChips    = {}
local _editorNameLabel
local _editorEdit
local _editorSetBtn
local _editorResetBtn
local _editorBitsBtn           -- v3: 'View as bits' toggle button
local _editorHelpLabel
local _bitsRow                 -- v3: container holding the bit-toggle buttons
local _bitsLabel               -- v3: 'Bits:' label + parse-failure hint
local _bitButtons     = {}     -- v3: array of TOP_N bit-toggle Buttons
local _treeScroll
local _treeView


-- Forward declarations.
local refreshTree
local refreshEditor
local refreshFilterChips
local refreshBitsPanel    -- v3: defined later in the file; refreshEditor calls it
local relayout            -- v3: defined later; setBitsMode calls it


-- ---------------------------------------------------------------------------
-- CVar API readers
-- ---------------------------------------------------------------------------

local function readCurrent(name)
    if C_CVar and C_CVar.GetCVar then return C_CVar.GetCVar(name) end
    if GetCVar then return GetCVar(name) end
    return nil
end


local function readDefault(name)
    if C_CVar and C_CVar.GetCVarDefault then
        return C_CVar.GetCVarDefault(name)
    end
    if GetCVarDefault then return GetCVarDefault(name) end
    return nil
end


local function isChangedFromDefault(name)
    local cur = readCurrent(name)
    local def = readDefault(name)
    if cur == nil or def == nil then return false end
    return cur ~= def
end


local function inCombat()
    return InCombatLockdown and InCombatLockdown() or false
end


-- Enumeration via C_Console.GetAllCommands + GetCVar truthiness ground
-- truth (see memory wow_cvars_commandtype_unreliable.md).
local function enumerateCVars()
    local getAllFn = (C_Console and C_Console.GetAllCommands)
                  or _G.ConsoleGetAllCommands
    if not getAllFn then return {} end
    local ok, commands = pcall(getAllFn)
    if not ok or type(commands) ~= "table" then return {} end

    local out, seen = {}, {}
    for _, cmd in ipairs(commands) do
        local name = cmd.command
        if name and name ~= "" and not seen[name]
           and readCurrent(name) ~= nil then
            seen[name] = true
            out[#out + 1] = { name = name, help = cmd.help or "" }
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end


local function trySetCVar(name, value)
    if inCombat() then return false, "in combat (SetCVar may taint)" end
    local setter = (C_CVar and C_CVar.SetCVar) or SetCVar
    if not setter then return false, "no SetCVar API available" end
    local ok, err = pcall(setter, name, value)
    if not ok then return false, tostring(err) end
    return true, readCurrent(name)
end


-- ---------------------------------------------------------------------------
-- Value formatting
-- ---------------------------------------------------------------------------

local function truncate(s, max)
    if not s then return "" end
    if #s <= max then return s end
    return s:sub(1, max) .. "..."
end


-- Type-colored value tag for the aux column. Per the color-code memory,
-- the helper uses `..` concat at color/text boundaries.
local function formatRowAux(name)
    local cur = readCurrent(name)
    local def = readDefault(name)
    local curText = truncate(cur or "", VALUE_PREVIEW_MAX)
    if cur == nil or def == nil then
        return "|cff888888" .. curText .. "|r"
    end
    if cur == def then
        return "|cff80c080" .. curText .. "|r"
    end
    return "|cffffd060" .. curText .. "|r"
end


-- ---------------------------------------------------------------------------
-- Grouping
-- ---------------------------------------------------------------------------
-- Find the first lowercase->uppercase transition. Everything before that
-- transition is the group prefix. Returns the whole name when there's
-- no transition (single segment, all-caps, snake_case, etc.).
local function groupKeyOf(name)
    local prevLower = false
    for i = 1, #name do
        local c = name:sub(i, i)
        if prevLower and c:match("[A-Z]") then
            return name:sub(1, i - 1)
        end
        prevLower = c:match("[a-z]") and true or false
    end
    return name
end


-- ---------------------------------------------------------------------------
-- Filtering
-- ---------------------------------------------------------------------------

local function passesSearch(name)
    if _searchFilter == "" then return true end
    return name:lower():find(_searchFilter:lower(), 1, true) ~= nil
end


local function passesFilterMode(name)
    if _filterMode == "all" then return true end
    if _filterMode == "changed" then return isChangedFromDefault(name) end
    return true
end


local function leafPasses(name)
    return passesSearch(name) and passesFilterMode(name)
end


-- ---------------------------------------------------------------------------
-- Tree construction
-- ---------------------------------------------------------------------------

local function buildTree()
    if not _allCVars then return {} end

    -- First pass: bucket by group key.
    local buckets = {}
    local order = {}
    for _, entry in ipairs(_allCVars) do
        if leafPasses(entry.name) then
            local key = groupKeyOf(entry.name)
            if not buckets[key] then
                buckets[key] = { name = key, members = {} }
                order[#order + 1] = key
            end
            local bucket = buckets[key]
            bucket.members[#bucket.members + 1] = entry
        end
    end

    -- Second pass: merge singletons into (misc).
    local misc = nil
    for _, key in ipairs(order) do
        local b = buckets[key]
        if #b.members < MIN_GROUP_SIZE then
            if not misc then
                misc = { name = "(misc)", members = {} }
            end
            for _, m in ipairs(b.members) do
                misc.members[#misc.members + 1] = m
            end
            buckets[key] = nil
        end
    end

    -- Build root array: groups in alphabetical order, (misc) last.
    local root = {}
    table.sort(order, function(a, b) return a:lower() < b:lower() end)
    for _, key in ipairs(order) do
        local b = buckets[key]
        if b then
            local children = {}
            for _, m in ipairs(b.members) do
                children[#children + 1] = {
                    id    = "cvar/" .. m.name,
                    label = m.name,
                    aux   = formatRowAux(m.name),
                    _kind = "cvar",
                    _name = m.name,
                    _help = m.help,
                }
            end
            root[#root + 1] = {
                id       = "group/" .. key,
                label    = key,
                aux      = ("|cff80c0ff(%d)|r"):format(#children),
                children = children,
                _kind    = "group",
            }
        end
    end

    if misc and #misc.members > 0 then
        local children = {}
        for _, m in ipairs(misc.members) do
            children[#children + 1] = {
                id    = "cvar/" .. m.name,
                label = m.name,
                aux   = formatRowAux(m.name),
                _kind = "cvar",
                _name = m.name,
                _help = m.help,
            }
        end
        root[#root + 1] = {
            id       = "group/__misc__",
            label    = "(misc)",
            aux      = ("|cff80c0ff(%d)|r"):format(#children),
            children = children,
            _kind    = "group",
        }
    end

    return root
end


-- ---------------------------------------------------------------------------
-- Selection + editor
-- ---------------------------------------------------------------------------

local function selectCVar(name)
    _selectedCVar = name
    refreshEditor()
    refreshTree()  -- so the selected leaf re-renders with selection state (if added)
end


local function commitSet()
    if not _selectedCVar then return end
    local newValue = (_editorEdit and _editorEdit.Cairn
                      and _editorEdit.Cairn:GetText()) or ""
    local ok, result = trySetCVar(_selectedCVar, newValue)
    if not ok then
        if _statusLabel and _statusLabel.Cairn then
            _statusLabel.Cairn:SetText(
                "|cffff8060SetCVar failed: " .. tostring(result) .. "|r")
        end
        return
    end
    if _statusLabel and _statusLabel.Cairn then
        _statusLabel.Cairn:SetText(("|cff80ff80Set %s = %s|r"):format(
            _selectedCVar, tostring(result)))
    end
    refreshTree()
    refreshEditor()
end


local function commitReset()
    if not _selectedCVar then return end
    local def = readDefault(_selectedCVar)
    if def == nil then
        if _statusLabel and _statusLabel.Cairn then
            _statusLabel.Cairn:SetText(
                "|cffff8060No default value reported for " .. _selectedCVar .. "|r")
        end
        return
    end
    local ok, result = trySetCVar(_selectedCVar, def)
    if not ok then
        if _statusLabel and _statusLabel.Cairn then
            _statusLabel.Cairn:SetText(
                "|cffff8060Reset failed: " .. tostring(result) .. "|r")
        end
        return
    end
    if _editorEdit and _editorEdit.Cairn then
        _editorEdit.Cairn:SetText(tostring(result))
    end
    if _statusLabel and _statusLabel.Cairn then
        _statusLabel.Cairn:SetText(("|cff80ff80Reset %s to %s|r"):format(
            _selectedCVar, tostring(result)))
    end
    refreshTree()
end


refreshEditor = function()
    if not _editorNameLabel then return end
    if _selectedCVar then
        _editorNameLabel.Cairn:SetText("|cffffd060" .. _selectedCVar .. "|r")
        if _editorEdit and _editorEdit.Cairn then
            _editorEdit.Cairn:SetText(readCurrent(_selectedCVar) or "")
            _editorEdit.Cairn:SetEnabled(true)
        end
        local locked = inCombat()
        if _editorSetBtn and _editorSetBtn.Cairn and _editorSetBtn.Cairn.SetEnabled then
            _editorSetBtn.Cairn:SetEnabled(not locked)
        end
        if _editorResetBtn and _editorResetBtn.Cairn and _editorResetBtn.Cairn.SetEnabled then
            _editorResetBtn.Cairn:SetEnabled(not locked)
        end
        if _editorBitsBtn and _editorBitsBtn.Cairn and _editorBitsBtn.Cairn.SetEnabled then
            _editorBitsBtn.Cairn:SetEnabled(true)
        end
        if _editorHelpLabel and _editorHelpLabel.Cairn then
            local help
            for _, e in ipairs(_allCVars or {}) do
                if e.name == _selectedCVar then help = e.help; break end
            end
            if help and help ~= "" then
                _editorHelpLabel.Cairn:SetText("|cff888888" .. help .. "|r")
            else
                _editorHelpLabel.Cairn:SetText("|cff666666(no help text)|r")
            end
        end
    else
        _editorNameLabel.Cairn:SetText("|cff888888Click a CVar leaf to select.|r")
        if _editorEdit and _editorEdit.Cairn then
            _editorEdit.Cairn:SetText("")
            _editorEdit.Cairn:SetEnabled(false)
        end
        if _editorSetBtn and _editorSetBtn.Cairn and _editorSetBtn.Cairn.SetEnabled then
            _editorSetBtn.Cairn:SetEnabled(false)
        end
        if _editorResetBtn and _editorResetBtn.Cairn and _editorResetBtn.Cairn.SetEnabled then
            _editorResetBtn.Cairn:SetEnabled(false)
        end
        if _editorBitsBtn and _editorBitsBtn.Cairn and _editorBitsBtn.Cairn.SetEnabled then
            _editorBitsBtn.Cairn:SetEnabled(false)
        end
        if _editorHelpLabel and _editorHelpLabel.Cairn then
            _editorHelpLabel.Cairn:SetText("")
        end
    end
    refreshBitsPanel()
end


-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

refreshTree = function()
    if not _treeView then return end
    _treeView.Cairn:SetNodes(buildTree())

    if _statusLabel and _statusLabel.Cairn then
        local total = (_allCVars and #_allCVars) or 0
        local visible = _treeView.Cairn:GetVisibleCount() or 0
        if _selectedCVar then
            -- Don't clobber selection status messages.
            return
        end
        _statusLabel.Cairn:SetText(
            ("|cff888888%d visible / %d CVars|r"):format(visible, total))
    end
end


refreshFilterChips = function()
    if not _filterChips then return end
    for mode, btn in pairs(_filterChips) do
        if btn.Cairn and btn.Cairn.SetVariant then
            btn.Cairn:SetVariant(mode == _filterMode and "primary" or "ghost")
        end
    end
end


local function setFilterMode(mode)
    _filterMode = mode
    refreshFilterChips()
    refreshTree()
end


-- ---------------------------------------------------------------------------
-- Bitfield panel (v3)
-- ---------------------------------------------------------------------------
-- We don't try to enumerate Blizzard's named-bit infrastructure
-- (C_CVar.GetCVarBitfield's bit names are per-cvar and not addon-enumerable).
-- Instead we offer a generic BITS_VISIBLE-wide toggle row that operates
-- on the integer value directly. Works for every integer-flag cvar
-- without needing a curated bit-name table.

local function parseIntegerCVarValue()
    local raw = _selectedCVar and readCurrent(_selectedCVar)
    if not raw then return nil end
    -- Tolerate leading/trailing whitespace; reject anything non-numeric.
    local trimmed = tostring(raw):match("^%s*(.-)%s*$")
    local n = tonumber(trimmed)
    if not n then return nil end
    if n < 0 or n ~= math.floor(n) then return nil end
    return n
end


-- bit32 is the WoW-supplied bit lib (Lua 5.1 doesn't have native bitops).
-- We guard accesses just in case a downstream client strips it; falling
-- back to math saves the user from a hard crash on unusual setups.
local function bitTest(n, i)
    if bit and bit.band then return bit.band(n, 2 ^ i) ~= 0 end
    if bit32 and bit32.band then return bit32.band(n, 2 ^ i) ~= 0 end
    return math.floor(n / (2 ^ i)) % 2 == 1
end


local function bitToggle(n, i)
    local mask = 2 ^ i
    if bitTest(n, i) then
        return n - mask
    end
    return n + mask
end


-- Assigned (not `local function`) so it binds to the forward-declared upvalue
-- at the top of the file. Without this, refreshEditor's call to
-- refreshBitsPanel resolves to a fresh local that's nil until this line runs.
refreshBitsPanel = function()
    if not _bitsRow then return end
    if not _bitsMode then
        _bitsRow:Hide()
        return
    end
    _bitsRow:Show()

    local n = parseIntegerCVarValue()
    if not n then
        if _bitsLabel and _bitsLabel.Cairn then
            _bitsLabel.Cairn:SetText(
                "|cffaa8060Bits: current value is not a non-negative integer.|r")
        end
        for i = 1, BITS_VISIBLE do
            local b = _bitButtons[i]
            if b then b:Hide() end
        end
        return
    end
    if _bitsLabel and _bitsLabel.Cairn then
        _bitsLabel.Cairn:SetText(
            ("|cff888888Bits (value = %d):|r"):format(n))
    end
    for i = 1, BITS_VISIBLE do
        local b = _bitButtons[i]
        if b then
            b:Show()
            if b.Cairn and b.Cairn.SetVariant then
                b.Cairn:SetVariant(bitTest(n, i - 1) and "primary" or "ghost")
            end
        end
    end
end


-- Click on a bit button. Toggles bit (i-1) in the current integer value
-- and writes via trySetCVar. Failures surface in the status label.
local function onBitClick(i)
    if not _selectedCVar then return end
    local n = parseIntegerCVarValue()
    if not n then return end
    local newN = bitToggle(n, i - 1)
    local ok, result = trySetCVar(_selectedCVar, tostring(newN))
    if not ok then
        if _statusLabel and _statusLabel.Cairn then
            _statusLabel.Cairn:SetText(
                "|cffff8060SetCVar bit failed: " .. tostring(result) .. "|r")
        end
        return
    end
    if _statusLabel and _statusLabel.Cairn then
        _statusLabel.Cairn:SetText(("|cff80ff80Toggled bit %d -> %s|r"):format(
            i - 1, tostring(result)))
    end
    if _editorEdit and _editorEdit.Cairn then
        _editorEdit.Cairn:SetText(tostring(result))
    end
    refreshBitsPanel()
    refreshTree()
end


local function setBitsMode(on)
    _bitsMode = on and true or false
    if _editorBitsBtn and _editorBitsBtn.Cairn
       and _editorBitsBtn.Cairn.SetVariant then
        _editorBitsBtn.Cairn:SetVariant(_bitsMode and "primary" or "ghost")
    end
    refreshBitsPanel()
    relayout()  -- tree slides up/down by BITS_ROW_HEIGHT+gap
end


-- ---------------------------------------------------------------------------
-- Presets (v3)
-- ---------------------------------------------------------------------------
-- Persisted under db.global.presets so they're per-account, not per-character
-- (the natural scope for "I want these graphics settings everywhere").
-- A preset is a flat {cvar = value} table; Apply walks it through
-- trySetCVar so combat-locked or protected entries fail gracefully.

local _presetsPopup
local _presetsListContent
local _presetSaveBox
local _presetRowPool = {}   -- index -> { container, nameLabel, applyBtn, deleteBtn }
local refreshPresetsList    -- forward decl


local function getPresets()
    if db and db.global then
        if type(db.global.presets) ~= "table" then
            db.global.presets = {}
        end
        return db.global.presets
    end
    return {}
end


-- Snapshot every cvar that differs from its default. This is the natural
-- "user settings" set: the things the user has actually touched. Unchanged
-- cvars stay out of the preset so applying a preset doesn't blanket-reset
-- defaults the user never customized.
local function captureChangedCVars()
    local out = {}
    local count = 0
    for _, e in ipairs(_allCVars or {}) do
        if isChangedFromDefault(e.name) then
            out[e.name] = readCurrent(e.name)
            count = count + 1
        end
    end
    return out, count
end


local function applyPreset(name)
    local presets = getPresets()
    local preset = presets[name]
    if not preset then return end
    local ok_count, fail_count = 0, 0
    for cvar, value in pairs(preset) do
        local ok = trySetCVar(cvar, value)
        if ok then ok_count = ok_count + 1 else fail_count = fail_count + 1 end
    end
    if _statusLabel and _statusLabel.Cairn then
        _statusLabel.Cairn:SetText(
            ("|cff80ff80Applied '%s': %d ok, %d failed|r"):format(
                name, ok_count, fail_count))
    end
    refreshTree()
    refreshEditor()
end


local function savePreset(name)
    if not name or name == "" then return false, "empty name" end
    local presets = getPresets()
    local snapshot, count = captureChangedCVars()
    presets[name] = snapshot
    return true, count
end


local function deletePreset(name)
    local presets = getPresets()
    presets[name] = nil
end


-- Sort preset names for stable display order across renders.
local function listPresetNames()
    local names = {}
    for name in pairs(getPresets()) do names[#names + 1] = name end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end


-- Count entries in a preset's cvar map. # doesn't work because it's a hash.
local function presetEntryCount(preset)
    if type(preset) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(preset) do n = n + 1 end
    return n
end


-- Build (or reuse a pooled) row in the presets list. The pool keeps the
-- same Buttons across refreshes so we don't churn Cairn-Gui widgets when
-- a single preset is added/deleted.
local function acquirePresetRow(Gui, idx)
    local existing = _presetRowPool[idx]
    if existing and existing.container then
        existing.container:Show()
        return existing
    end
    local row = {}
    row.container = Gui:Acquire("Container", _presetsListContent, {
        height = 28,
    })
    row.container.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 2 })
    row.nameLabel = Gui:Acquire("Label", row.container, { text = "" })
    row.applyBtn = Gui:Acquire("Button", row.container, {
        text = "Apply", variant = "primary", width = 70, height = 22,
    })
    row.deleteBtn = Gui:Acquire("Button", row.container, {
        text = "Delete", variant = "ghost", width = 70, height = 22,
    })
    _presetRowPool[idx] = row
    return row
end


refreshPresetsList = function()
    if not _presetsListContent then return end
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local names = listPresetNames()
    for i, name in ipairs(names) do
        local row = acquirePresetRow(Gui, i)
        local preset = getPresets()[name]
        row.nameLabel.Cairn:SetText(("|cffffd060%s|r |cff888888(%d cvars)|r")
            :format(name, presetEntryCount(preset)))
        -- Re-wire the button closures every refresh so they capture the
        -- CURRENT name (preset rows shift as presets are added/deleted).
        -- Cairn-Gui's On() replaces existing handlers, so this is safe.
        row.applyBtn.Cairn:On("Click", function() applyPreset(name) end)
        row.deleteBtn.Cairn:On("Click", function()
            deletePreset(name)
            refreshPresetsList()
        end)
    end
    -- Hide pooled rows beyond the current count.
    for i = #names + 1, #_presetRowPool do
        if _presetRowPool[i] and _presetRowPool[i].container then
            _presetRowPool[i].container:Hide()
        end
    end
end


local function buildPresetsPopup()
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end

    local win = Gui:Acquire("Window", UIParent, {
        title    = "CVar presets",
        width    = 480,
        height   = 420,
        strata   = "DIALOG",  -- floats above Forge's HIGH-strata main window
        closable = true,
        movable  = true,
    })
    win:Hide()
    win:ClearAllPoints()
    win:SetPoint("CENTER")

    local content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 8 })

    Gui:Acquire("Label", content, {
        text    = "Save snapshots of your changed-from-default CVars, then "
                  .. "re-apply them later. Apply runs each cvar through "
                  .. "the same pcall path as the main editor; combat-locked "
                  .. "entries fail individually rather than aborting the run.",
        variant = "muted",
    })

    -- Save row.
    local saveRow = Gui:Acquire("Container", content, { height = 28 })
    saveRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    Gui:Acquire("Label", saveRow, {
        text = "Save current state as:", variant = "muted",
    })

    _presetSaveBox = Gui:Acquire("EditBox", saveRow, {
        width       = 200,
        height      = 22,
        text        = "",
        placeholder = "preset name",
    })

    local saveBtn = Gui:Acquire("Button", saveRow, {
        text = "Save", variant = "primary", width = 70, height = 22,
    })
    local function doSave()
        local name = _presetSaveBox.Cairn and _presetSaveBox.Cairn:GetText() or ""
        local ok, info = savePreset(name)
        if not ok then
            -- info is the error string from savePreset's failure path.
            if _statusLabel and _statusLabel.Cairn then
                _statusLabel.Cairn:SetText(
                    "|cffff8060Save failed: " .. tostring(info) .. "|r")
            end
            return
        end
        if _presetSaveBox.Cairn then _presetSaveBox.Cairn:SetText("") end
        if _statusLabel and _statusLabel.Cairn then
            _statusLabel.Cairn:SetText(
                ("|cff80ff80Saved '%s' (%d cvars)|r"):format(name, info))
        end
        refreshPresetsList()
    end
    saveBtn.Cairn:On("Click", doSave)
    _presetSaveBox.Cairn:On("EnterPressed", doSave)

    Gui:Acquire("Label", content, {
        text = "|cff80c0ffSaved presets:|r", variant = "muted",
    })

    -- Scrollable list of preset rows.
    local listScroll = Gui:Acquire("ScrollFrame", content, {
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
        width         = 460,
        height        = 240,
    })
    _presetsListContent = listScroll.Cairn:GetContent()
    _presetsListContent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 2, padding = 4 })

    local closeBtn = Gui:Acquire("Button", content, {
        text = "Close", variant = "ghost", width = 80, height = 22,
    })
    closeBtn.Cairn:On("Click", function() win:Hide() end)
    win.Cairn:On("Close", function() win:Hide() end)

    _presetsPopup = win
end


local function showPresetsPopup()
    if not _presetsPopup then buildPresetsPopup() end
    if not _presetsPopup then return end
    refreshPresetsList()
    _presetsPopup:Show()
    _presetsPopup:Raise()
end


-- ---------------------------------------------------------------------------
-- Relayout
-- ---------------------------------------------------------------------------

-- Assigned (not `local function`) so setBitsMode's upvalue binding works.
-- See the refreshBitsPanel comment for the same pattern.
relayout = function()
    if not (_pane and _treeScroll) then return end
    local paneH = _pane:GetHeight() or 0
    if paneH < 200 then return end
    -- Top reservation grows by the bits row height + its gap when the
    -- panel is visible. _bitsMode flipping calls relayout() so the tree
    -- slides up/down to make room.
    local top = TOP_RESERVED_BASE
    if _bitsMode then top = top + BITS_ROW_HEIGHT + BITS_ROW_GAP end
    _treeScroll:ClearAllPoints()
    _treeScroll:SetPoint("TOPLEFT",     _pane, "TOPLEFT",      SIDE_PAD, -top)
    _treeScroll:SetPoint("BOTTOMRIGHT", _pane, "BOTTOMRIGHT", -SIDE_PAD,  BOTTOM_PAD)
end


-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function build(pane)
    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then return end
    _pane = pane

    pane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 10 })

    Gui:Acquire("Label", pane, { text = "CVars", variant = "heading" })

    Gui:Acquire("Label", pane, {
        text    = "|cff888888Search by name, expand a group, click a CVar to select, then Set or Reset. Changed-from-default values render in amber.|r",
        variant = "muted",
    })

    -- Toolbar: search + filter chips + status.
    local toolbar = Gui:Acquire("Container", pane, { height = 28 })
    toolbar.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    _searchBox = Gui:Acquire("EditBox", toolbar, {
        width       = 260,
        height      = 22,
        text        = "",
        placeholder = "Filter by name...",
    })
    _searchBox.Cairn:On("TextChanged", function(_, text)
        _searchFilter = text or ""
        refreshTree()
    end)

    local filterDefs = {
        { mode = "all",     label = "All"     },
        { mode = "changed", label = "Changed" },
    }
    for _, def in ipairs(filterDefs) do
        local chip = Gui:Acquire("Button", toolbar, {
            text = def.label, variant = "ghost", width = 80, height = 22,
        })
        chip.Cairn:On("Click", function() setFilterMode(def.mode) end)
        _filterChips[def.mode] = chip
    end

    -- v3: opens the preset save/apply/delete popup. Lazy-built on first click.
    local presetsBtn = Gui:Acquire("Button", toolbar, {
        text = "Presets...", variant = "ghost", width = 100, height = 22,
    })
    presetsBtn.Cairn:On("Click", showPresetsPopup)

    _statusLabel = Gui:Acquire("Label", toolbar, {
        text = "|cff888888loading CVars...|r", variant = "muted",
    })

    -- Editor row.
    local editorRow = Gui:Acquire("Container", pane, { height = 28 })
    editorRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 6, padding = 0 })

    _editorNameLabel = Gui:Acquire("Label", editorRow, {
        text = "|cff888888Click a CVar leaf to select.|r",
    })

    _editorEdit = Gui:Acquire("EditBox", editorRow, {
        width       = 240,
        height      = 22,
        text        = "",
        placeholder = "new value...",
    })
    _editorEdit.Cairn:On("EnterPressed", commitSet)
    if _editorEdit.Cairn.SetEnabled then _editorEdit.Cairn:SetEnabled(false) end

    _editorSetBtn = Gui:Acquire("Button", editorRow, {
        text = "Set", variant = "primary", width = 60, height = 22,
    })
    _editorSetBtn.Cairn:On("Click", commitSet)
    if _editorSetBtn.Cairn.SetEnabled then _editorSetBtn.Cairn:SetEnabled(false) end

    _editorResetBtn = Gui:Acquire("Button", editorRow, {
        text = "Reset", variant = "ghost", width = 70, height = 22,
    })
    _editorResetBtn.Cairn:On("Click", commitReset)
    if _editorResetBtn.Cairn.SetEnabled then _editorResetBtn.Cairn:SetEnabled(false) end

    -- v3: 'Bits' toggle. Acts as a sticky mode flag: when active, the
    -- bits row below shows per-bit toggles for the current value.
    _editorBitsBtn = Gui:Acquire("Button", editorRow, {
        text = "Bits", variant = "ghost", width = 60, height = 22,
    })
    _editorBitsBtn.Cairn:On("Click", function() setBitsMode(not _bitsMode) end)
    if _editorBitsBtn.Cairn.SetEnabled then _editorBitsBtn.Cairn:SetEnabled(false) end

    _editorHelpLabel = Gui:Acquire("Label", pane, {
        text = "", variant = "muted",
    })

    -- v3: bits panel row. Hidden unless _bitsMode. Contains a 'Bits:' label
    -- followed by BITS_VISIBLE small toggle Buttons. Each button's variant
    -- reflects whether that bit is set in the current integer value.
    _bitsRow = Gui:Acquire("Container", pane, { height = BITS_ROW_HEIGHT })
    _bitsRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 3, padding = 0 })

    _bitsLabel = Gui:Acquire("Label", _bitsRow, {
        text = "|cff888888Bits:|r", variant = "muted",
    })

    for i = 1, BITS_VISIBLE do
        local btn = Gui:Acquire("Button", _bitsRow, {
            text   = tostring(i - 1),
            variant = "ghost",
            width  = 26,
            height = 22,
        })
        btn.Cairn:On("Click", function() onBitClick(i) end)
        _bitButtons[i] = btn
    end
    _bitsRow:Hide()  -- starts hidden; setBitsMode flips it

    -- TreeView in ScrollFrame.
    _treeScroll = Gui:Acquire("ScrollFrame", pane, {
        bg            = "color.bg.surface",
        border        = "color.border.default",
        borderWidth   = 1,
        showScrollbar = true,
    })
    _treeScroll.Cairn:SetLayoutManual(true)

    local treeContent = _treeScroll.Cairn:GetContent()
    _treeView = Gui:Acquire("TreeView", treeContent, {
        nodes     = {},
        rowHeight = TREE_ROW_HEIGHT,
        indent    = TREE_INDENT,
    })
    _treeView.Cairn:SetLayoutManual(true)
    _treeView:ClearAllPoints()
    _treeView:SetPoint("TOPLEFT",  treeContent, "TOPLEFT",  0, 0)
    _treeView:SetPoint("TOPRIGHT", treeContent, "TOPRIGHT", 0, 0)

    _treeView.Cairn:On("Click", function(_, nodeId, node)
        if node._kind == "cvar" then
            selectCVar(node._name)
        end
    end)

    _treeView:HookScript("OnSizeChanged", function()
        if _treeScroll.Cairn and _treeScroll.Cairn.SetContentHeight then
            _treeScroll.Cairn:SetContentHeight(
                math.max(40, _treeView:GetHeight() or 40))
        end
    end)

    pane:HookScript("OnSizeChanged", relayout)
    relayout()

    -- First-time enumeration. Cached for the session.
    _allCVars = enumerateCVars()
    setFilterMode(_filterMode)
    refreshEditor()
end


-- ---------------------------------------------------------------------------
-- Tab descriptor
-- ---------------------------------------------------------------------------

ns.descriptor = {
    name        = "CVars",
    title       = "CVars",
    order       = 35,
    description = "WoW CVar viewer + editor (grouped by camelCase prefix).",

    OnTabShow = function(pane, mod)
        if not pane.Cairn._builtOnce then
            pane.Cairn._builtOnce = true
            build(pane)
        end
        relayout()
        refreshTree()
        refreshEditor()
    end,

    OnTabHide = function(pane, mod)
    end,
}


-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function addon:OnInit()
    if Forge and Forge.Registry and Forge.Registry.Register then
        Forge.Registry.Register(ns.descriptor)
    end
end


function addon:OnLogin()
    if ns.Events and ns.Events.Subscribe then
        ns.Events:Subscribe("PLAYER_REGEN_DISABLED", refreshEditor)
        ns.Events:Subscribe("PLAYER_REGEN_ENABLED",  refreshEditor)
    else
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_REGEN_DISABLED")
        f:RegisterEvent("PLAYER_REGEN_ENABLED")
        f:SetScript("OnEvent", refreshEditor)
    end
end

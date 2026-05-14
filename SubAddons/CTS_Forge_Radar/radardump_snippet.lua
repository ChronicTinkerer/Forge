-- Forge_Radar diagnostic snippet (v2: bypasses output-pane).
--
-- Standalone: no Forge_Radar dependency. Paste into Forge_Console and
-- click Run. Builds the report as a single string and pushes it
-- directly into Forge_Console's copy popup via ShowCopyPopupWithText
-- (added in Forge_Console 2026-05-14). This bypasses the output-buffer
-- timing problem: Eval batches snippet print() output and only flushes
-- to the pane AFTER the snippet returns, so any popup opened from
-- inside the snippet would see stale pane content.
--
-- The popup opens with everything already selected; press Ctrl-C
-- (or click Copy then Ctrl-C if you click into the textbox).

local lines = {}
local function p(s) lines[#lines + 1] = tostring(s) end

p("--- nameplate API state ---")

local pathACount = 0
if C_NamePlate and C_NamePlate.GetNamePlates then
    local plates = C_NamePlate.GetNamePlates()
    if plates then
        pathACount = #plates
        for i, plate in ipairs(plates) do
            if i > 5 then break end
            local unit   = plate and plate.namePlateUnitToken
            local name   = unit and UnitName and UnitName(unit)
            local exists = unit and UnitExists and UnitExists(unit)
            p(("  GetNamePlates[%d] token=%s name=%s exists=%s"):format(
                i, tostring(unit), tostring(name), tostring(exists)))
        end
    end
    p(("  GetNamePlates() returned %d plates"):format(pathACount))
else
    p("  C_NamePlate.GetNamePlates is nil")
end

local pathBCount = 0
for i = 1, 40 do
    local unit = "nameplate" .. i
    if UnitExists and UnitExists(unit) then
        pathBCount = pathBCount + 1
        if pathBCount <= 5 then
            local name = UnitName and UnitName(unit) or "?"
            local guid = UnitGUID and UnitGUID(unit) or "?"
            p(("  token-walk %s name=%s guid=%s"):format(
                unit, name, tostring(guid)))
        end
    end
end
p(("  nameplate1..40 walk found %d units"):format(pathBCount))

p("")
p("--- sticky tokens ---")
for _, u in ipairs({ "target", "focus", "mouseover" }) do
    local exists = UnitExists and UnitExists(u)
    local name   = exists and UnitName and UnitName(u)
    p(("  %s: exists=%s name=%s"):format(
        u, tostring(exists), tostring(name)))
end

p("")
if UnitPosition then
    local ok, py, px, _, pinst = pcall(UnitPosition, "player")
    if ok then
        p(("--- player pos: y=%s x=%s inst=%s"):format(
            tostring(py), tostring(px), tostring(pinst)))
    end
end

local report = table.concat(lines, "\n")

-- Also print a short summary to the output pane so the user sees that
-- the snippet ran. The full report goes to the popup.
print(("|cff80c0ff[Radar]|r dump complete: %d nameplates (path A=%d, "
       .. "path B=%d). Full report in popup."):format(
    math.max(pathACount, pathBCount), pathACount, pathBCount))

if Forge_Console and Forge_Console.UI
   and Forge_Console.UI.ShowCopyPopupWithText then
    Forge_Console.UI.ShowCopyPopupWithText(report)
elseif Forge_Console and Forge_Console.UI
       and Forge_Console.UI.ShowCopyPopup then
    print("|cffffaa00[Radar]|r ShowCopyPopupWithText not available; "
        .. "falling back to pane copy. Update Forge_Console to get "
        .. "the direct popup path.")
    -- Fall back: dump to pane via print, then schedule the pane-grab.
    for _, line in ipairs(lines) do print(line) end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.1, function()
            Forge_Console.UI.ShowCopyPopup()
        end)
    end
else
    -- Forge_Console missing entirely; fall back to chat dump.
    for _, line in ipairs(lines) do print(line) end
end

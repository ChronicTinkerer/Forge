-- Forge.Window: the main /forge window.
--
-- Minimal, no-rebuild design. Builds once, lazily, on first Show using a
-- snapshot of the Registry at that moment. Sub-addons that register later
-- won't appear until the user closes and re-opens the window. The previous
-- RefreshTabs-on-every-Registry.Register design caused TabGroup rebuilds
-- mid-session that corrupted pane state. Now: build once, leave alone.
--
-- Tabs come from Forge.Registry; clicking a tab invokes that descriptor's
-- OnTabShow (and the previously-active tab's OnTabHide). Geometry persists
-- via db.profile.window.

local ADDON, ns = ...

local Window = {}
ns.Window = Window

local _win        -- top-level Cairn-Gui Window widget
local _tabGroup   -- Cairn-Gui TabGroup inside _win
local _toolbar    -- global toolbar (Logout / Reload UI) above the tab strip
local _activeId   -- currently-shown tab id

local TOOLBAR_H = 28


-- ---------------------------------------------------------------------------
-- Secure macro overlay (for ReloadUI / Logout)
-- ---------------------------------------------------------------------------
-- ReloadUI() and Logout() are protected on Mainline; a normal click handler
-- triggers ADDON_ACTION_FORBIDDEN. The fix is a SecureActionButtonTemplate
-- frame overlaid on the visual button, dispatching via "type=macro".
--
-- Gotchas burned in:
--   * Strata HIGH (not DIALOG - DIALOG blocks secure dispatch on Retail).
--   * RegisterForClicks needs BOTH "AnyUp" and "AnyDown".
--   * No OnClick HookScripts - they taint the secure dispatch chain.

local _secureCounter = 0

local function attachSecureMacro(btn, macrotext)
    if not CreateFrame or not btn then return end
    _secureCounter = _secureCounter + 1
    local secure = CreateFrame(
        "Button",
        "ForgeSecureMacro" .. _secureCounter,
        UIParent,
        "SecureActionButtonTemplate")
    secure:SetFrameStrata("HIGH")
    secure:SetFrameLevel(50)
    secure:SetSize(btn:GetWidth() or 80, btn:GetHeight() or 22)
    secure:ClearAllPoints()
    secure:SetPoint("TOPLEFT",     btn, "TOPLEFT",     0, 0)
    secure:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
    secure:RegisterForClicks("AnyUp", "AnyDown")
    secure:SetAttribute("type",      "macro")
    secure:SetAttribute("macrotext", macrotext)
    btn:HookScript("OnShow", function() secure:Show() end)
    btn:HookScript("OnHide", function() secure:Hide() end)
    if not btn:IsShown() then secure:Hide() end
    btn._secureOverlay = secure  -- pin so it isn't GC'd
end


-- ---------------------------------------------------------------------------
-- Tab dispatch
-- ---------------------------------------------------------------------------

local function showTab(tabId, prevId)
    if not _tabGroup then return end

    if prevId and prevId ~= tabId then
        local prev = ns.Registry.Get(prevId)
        if prev and type(prev.OnTabHide) == "function" then
            local prevPane = _tabGroup.Cairn:GetTabContent(prevId)
            local ok, err = pcall(prev.OnTabHide, prevPane, prev)
            if not ok then geterrorhandler()(err) end
        end
    end

    local descriptor = ns.Registry.Get(tabId)
    if not descriptor then return end

    if type(descriptor.OnTabShow) == "function" then
        local pane = _tabGroup.Cairn:GetTabContent(tabId)
        local ok, err = pcall(descriptor.OnTabShow, pane, descriptor)
        if not ok then geterrorhandler()(err) end
    end

    _activeId = tabId
    if ns.db and ns.db.profile and ns.db.profile.window then
        ns.db.profile.window.activeTab = tabId
    end
end


-- ---------------------------------------------------------------------------
-- Build (once, on first Show)
-- ---------------------------------------------------------------------------

local function buildToolbar(Gui, content)
    _toolbar = Gui:Acquire("Container", content, {
        bg     = "color.bg.surface",
        height = TOOLBAR_H,
    })
    _toolbar.Cairn:SetLayoutManual(true)
    _toolbar:ClearAllPoints()
    _toolbar:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, 0)
    _toolbar:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)

    -- Right-to-left order: Reload UI, Exit to Main Menu, Exit Game.
    -- /logout returns to the character-select screen (NOT a true logout
    -- in the leave-the-game sense -- WoW calls it Logout but the user-
    -- facing concept is "back to the main menu"). /exit shuts the
    -- client down entirely. Both go through SecureActionButtonTemplate
    -- because they're protected actions; see attachSecureMacro above
    -- for the strata/click-binding gotchas.

    -- Reload UI (rightmost)
    local reloadBtn = Gui:Acquire("Button", _toolbar, {
        text    = "Reload UI",
        variant = "ghost",
        width   = 90,
        height  = 22,
    })
    reloadBtn.Cairn:SetLayoutManual(true)
    reloadBtn:ClearAllPoints()
    reloadBtn:SetPoint("RIGHT", _toolbar, "RIGHT", -4, 0)
    attachSecureMacro(reloadBtn, "/reload")

    -- Exit to Main Menu (to the left of Reload UI). Uses /logout under
    -- the hood; renamed in the UI so the label matches what actually
    -- happens (you land on character select, not at a true sign-off).
    local exitToMenuBtn = Gui:Acquire("Button", _toolbar, {
        text    = "Exit to Main Menu",
        variant = "ghost",
        width   = 140,
        height  = 22,
    })
    exitToMenuBtn.Cairn:SetLayoutManual(true)
    exitToMenuBtn:ClearAllPoints()
    exitToMenuBtn:SetPoint("RIGHT", reloadBtn, "LEFT", -4, 0)
    attachSecureMacro(exitToMenuBtn, "/logout")

    -- Exit Game (leftmost of the three). /exit (alias /quit) closes the
    -- WoW client. Same SecureActionButtonTemplate path as the other two.
    local exitGameBtn = Gui:Acquire("Button", _toolbar, {
        text    = "Exit Game",
        variant = "ghost",
        width   = 90,
        height  = 22,
    })
    exitGameBtn.Cairn:SetLayoutManual(true)
    exitGameBtn:ClearAllPoints()
    exitGameBtn:SetPoint("RIGHT", exitToMenuBtn, "LEFT", -4, 0)
    attachSecureMacro(exitGameBtn, "/exit")
end


local function buildTabs(Gui, content)
    local tabs = {}
    for name, descriptor in ns.Registry.Iter() do
        tabs[#tabs + 1] = { id = name, label = descriptor.title or name }
    end

    if #tabs == 0 then
        Gui:Acquire("Label", content, {
            text    = "No Forge sub-modules loaded.",
            variant = "muted",
        })
        return
    end

    -- Pick initial tab: prefer persisted activeTab if still registered.
    local p = (ns.db and ns.db.profile and ns.db.profile.window) or {}
    local initial = p.activeTab
    local found = false
    if initial then
        for _, t in ipairs(tabs) do
            if t.id == initial then found = true; break end
        end
    end
    if not found then initial = tabs[1].id end

    _tabGroup = Gui:Acquire("TabGroup", content, {
        tabs     = tabs,
        selected = initial,
    })
    _tabGroup:ClearAllPoints()
    _tabGroup:SetPoint("TOPLEFT",     _toolbar, "BOTTOMLEFT",  0, -2)
    _tabGroup:SetPoint("BOTTOMRIGHT", content,  "BOTTOMRIGHT", 0,  0)

    -- Initial tab: TabGroup's SetSelected with _silentInitial=true skips
    -- firing Changed, so we drive the first OnTabShow ourselves.
    showTab(initial, nil)

    _tabGroup.Cairn:On("Changed", function(_, tabId, prevId)
        showTab(tabId, prevId)
    end)
end


local function build()
    if _win then return end

    local Gui = LibStub("Cairn-Gui-2.0", true)
    if not Gui then
        if ns.out then ns.out("Cairn-Gui-2.0 not loaded; window unavailable.") end
        return
    end

    local p = (ns.db and ns.db.profile and ns.db.profile.window) or {}

    _win = Gui:Acquire("Window", UIParent, {
        title     = "Forge",
        width     = p.w or 880,
        height    = p.h or 560,
        closable  = true,
        movable   = true,
        resizable = true,
        minWidth  = 600,
        minHeight = 400,
    })

    if p.x and p.y and (p.x ~= 0 or p.y ~= 0) then
        _win:ClearAllPoints()
        _win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
    else
        _win:SetPoint("CENTER")
    end

    -- Persist geometry on hide.
    _win:HookScript("OnHide", function()
        if not (ns.db and ns.db.profile and ns.db.profile.window) then return end
        local pp = ns.db.profile.window
        pp.x = _win:GetLeft()   or 0
        pp.y = _win:GetTop()    or 0
        pp.w = _win:GetWidth()  or 880
        pp.h = _win:GetHeight() or 560
        pp.shown = false
    end)

    -- Persist size live as the user drags the resize grip. The Window
    -- widget fires Resized on every OnSizeChanged tick during drag plus
    -- once on mouse-up. Writing to db.profile is an in-memory assignment
    -- (the actual disk write happens at session end via SavedVariables),
    -- so the 60Hz event rate is essentially free. The OnHide handler
    -- above is still the safety net for sessions that don't trigger any
    -- resize at all.
    _win.Cairn:On("Resized", function(_, w, h)
        if not (ns.db and ns.db.profile and ns.db.profile.window) then return end
        local pp = ns.db.profile.window
        pp.w = w
        pp.h = h
    end)

    local content = _win.Cairn:GetContent()
    buildToolbar(Gui, content)
    buildTabs(Gui, content)
end


-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function Window.Show()
    build()
    if not _win then return end
    _win:Show()
    if ns.db and ns.db.profile and ns.db.profile.window then
        ns.db.profile.window.shown = true
    end
end


function Window.Hide()
    if _win then _win:Hide() end
end


function Window.Toggle()
    if Window.IsShown() then Window.Hide() else Window.Show() end
end


function Window.IsShown()
    return (_win and _win:IsShown()) or false
end


function Window.OpenTab(name)
    Window.Show()
    if _tabGroup and ns.Registry.Get(name) then
        _tabGroup.Cairn:SetSelected(name)
    end
end


-- No-op for back-compat. Registry.Register calls this on every registration
-- in older builds; we deliberately do nothing now. Rebuilding the TabGroup
-- mid-session was the source of the empty-tab / overlapping-pane bugs.
-- New sub-addons appear after a close+reopen of the window (or /reload).
function Window.RefreshTabs()
end

-- DPSReport_Graph.lua -- the DPS / HPS graph (2026-10-21).
--
-- WHAT THE GAME ALLOWS, measured with /dpsprobe (dummy, a dungeon boss, a key):
--   * In combat every C_DamageMeter total, rate, name and GUID is SECRET.
--     The session table itself, isLocalPlayer, classFilename and specIconID
--     are not -- so a source can be told apart by "is it me" or class + spec,
--     never by name, while the fight is on.
--   * A secret number draws: StatusBar:SetValue does the scaling C-side, and
--     AbbreviateNumbers + SetFormattedText print it. So each second of the
--     fight is a bar the game fills; nothing here ever reads the number.
--   * Values kept during combat STAY secret afterwards (tested at +0.5/3/10s).
--     So the graph cannot be saved: it lives in memory for this session
--     (the last MAX_FIGHTS fights) and is gone after a /reload. Only the final
--     totals, read fresh after combat, are plain -- they set the scale.
--   * No arithmetic on secrets, so no per-second deltas, peaks or smoothing:
--     DPS is the game's own running average (amountPerSecond), and the damage
--     view is the running total.
--
-- Two players with the same class AND spec cannot be told apart in combat, so
-- such a pair is left out of that fight rather than mixed together.

local _, ns = ...
local C = ns.colors   -- DPSReport's palette (DR_COLORS)

local SAMPLE_INTERVAL = 1     -- seconds
local MAX_FIGHTS = 10         -- kept in memory, this session only
local MAX_SAMPLES = 1800      -- 30 minutes per fight
local MIN_FIGHT = 3           -- seconds; shorter fights are dropped
local MIN_COLUMN = 3          -- pixels per bar before samples are thinned

local METRICS = {
    { key = "dps",  label = "DPS",     meter = "damage",  field = "amountPerSecond", rate = true },
    { key = "dmg",  label = "Damage",  meter = "damage",  field = "totalAmount" },
    { key = "hps",  label = "HPS",     meter = "healing", field = "amountPerSecond", rate = true },
    { key = "heal", label = "Healing", meter = "healing", field = "totalAmount" },
}

local function IsSecret(v)
    if issecretvalue and issecretvalue(v) then return true end
    if issecrettable and issecrettable(v) then return true end
    return false
end

local function Plain(v)
    if IsSecret(v) then return nil end
    return v
end

local function Has(v) return IsSecret(v) or v ~= nil end

-----------------------------------------------------------------------
-- Data
-----------------------------------------------------------------------

local fights = {}      -- oldest first; the last may be live
local live             -- the fight being recorded, or nil
local ticker

-- Who a source is, from the fields that stay readable in combat.
local function SourceKey(e)
    if e.isLocalPlayer == true then return "you" end
    local class, spec = Plain(e.classFilename), Plain(e.specIconID)
    if type(class) ~= "string" or class == "" then return nil end
    return class .. ":" .. tostring(spec or 0)
end

local function Session(meter)
    local mt = meter == "healing" and Enum.DamageMeterType.HealingDone or Enum.DamageMeterType.DamageDone
    local ok, s = pcall(C_DamageMeter.GetCombatSessionFromType, Enum.DamageMeterSessionType.Current, mt)
    if not ok or type(s) ~= "table" or IsSecret(s) then return nil end
    local sources = s.combatSources
    if type(sources) ~= "table" or IsSecret(sources) then return nil end
    return sources
end

local function Player(fight, key, e)
    local p = fight.players[key]
    if not p then
        p = { key = key, class = Plain(e.classFilename), dps = {}, dmg = {}, hps = {}, heal = {} }
        fight.players[key] = p
    end
    return p
end

local function Sample()
    local f = live
    if not f or f.n >= MAX_SAMPLES then return end
    f.n = f.n + 1
    local n = f.n
    for _, m in ipairs({ "damage", "healing" }) do
        local sources = Session(m)
        if sources then
            local seen = {}
            for _, e in ipairs(sources) do
                local key = SourceKey(e)
                if key and not f.ambiguous[key] then
                    if seen[key] then
                        -- Same class and spec twice: no way to keep them apart.
                        f.ambiguous[key] = true
                        f.players[key] = nil
                    else
                        seen[key] = true
                        local p = Player(f, key, e)
                        if m == "damage" then
                            p.dps[n], p.dmg[n] = e.amountPerSecond, e.totalAmount
                        else
                            p.hps[n], p.heal[n] = e.amountPerSecond, e.totalAmount
                        end
                    end
                end
            end
        end
    end
    if ns.Graph.OnSample then ns.Graph.OnSample(f) end
end

-- After combat the session is plain: names, and the final values that set
-- the scale. Retried briefly, since the restrictions lift a moment after.
local function Finalise(f, tries)
    local got = false
    for _, m in ipairs({ "damage", "healing" }) do
        local sources = Session(m)
        if sources then
            for _, e in ipairs(sources) do
                local key = SourceKey(e)
                local p = key and f.players[key]
                local total, rate = Plain(e.totalAmount), Plain(e.amountPerSecond)
                if p and total then
                    got = true
                    p.name = p.name or Plain(e.name) and (ns.ResolveName and ns.ResolveName(e) or Plain(e.name))
                    p.final = p.final or {}
                    if m == "damage" then
                        p.final.dmg, p.final.dps = total, rate
                    else
                        p.final.heal, p.final.hps = total, rate
                    end
                end
            end
        end
    end
    if not got and (tries or 0) < 5 then
        C_Timer.After(1, function() Finalise(f, (tries or 0) + 1) end)
        return
    end
    f.final = true
    if ns.Graph.OnFinalise then ns.Graph.OnFinalise(f) end
end

local function StartFight()
    if live then return end
    live = {
        started = GetTime(), clock = date("%H:%M"), n = 0,
        players = {}, ambiguous = {},
        zone = GetZoneText(),
    }
    fights[#fights + 1] = live
    while #fights > MAX_FIGHTS do table.remove(fights, 1) end
    Sample()
    ticker = C_Timer.NewTicker(SAMPLE_INTERVAL, Sample)
end

local function EndFight()
    if ticker then ticker:Cancel() ticker = nil end
    local f = live
    live = nil
    if not f then return end
    f.duration = GetTime() - f.started
    if f.duration < MIN_FIGHT or f.n == 0 then
        for i = #fights, 1, -1 do
            if fights[i] == f then table.remove(fights, i) end
        end
        if ns.Graph.OnFinalise then ns.Graph.OnFinalise(nil) end
        return
    end
    C_Timer.After(0.5, function() Finalise(f, 0) end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then StartFight() else EndFight() end
end)

-----------------------------------------------------------------------
-- Window
-----------------------------------------------------------------------

local Graph = {}
ns.Graph = Graph

local win, plot, bars, hoverText, maxText, startText, endText, emptyText
local fightLabel, playerBtn, metricBtns = nil, nil, {}
local view = { fight = nil, player = "you", metric = "dps", zoom = 1 }

local function GraphDB()
    if type(DPSReportDB) ~= "table" then return {} end
    DPSReportDB.graph = DPSReportDB.graph or {}
    return DPSReportDB.graph
end

local function Rgb(t) return t[1], t[2], t[3] end

local function MetricDef()
    for _, m in ipairs(METRICS) do if m.key == view.metric then return m end end
    return METRICS[1]
end

local function ShownFight()
    if view.fight and fights[view.fight] then return fights[view.fight] end
    return fights[#fights]
end

local function PlayerKeys(f)
    local keys = {}
    for key in pairs(f and f.players or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        if a == "you" then return true end
        if b == "you" then return false end
        return a < b
    end)
    return keys
end

local function PlayerLabel(p)
    if not p then return "?" end
    if p.key == "you" then return "You" end
    if p.name then return Ambiguate(p.name, "short") end
    local class = p.class and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[p.class]) or p.class
    return (class or "?") .. " (name after combat)"
end

-- The top of the y axis, in plain numbers. After combat: from the final value
-- (a running total ends exactly at its final; a running average can overshoot
-- early, hence the headroom). During combat: the same player's last finished
-- fight, scaled by elapsed time for totals -- a guess, corrected at the end.
local function AxisMax(f, p, m)
    local final = p and p.final and p.final[m.key]
    local top
    if final and final > 0 then
        top = m.rate and final * 1.5 or final
    else
        for i = #fights, 1, -1 do
            local old = fights[i] ~= f and fights[i].players[p and p.key or ""]
            local v = old and old.final and old.final[m.rate and m.key or (m.meter == "damage" and "dps" or "hps")]
            if v and v > 0 then
                top = m.rate and v * 1.5 or v * math.max(1, f.n) * SAMPLE_INTERVAL * 1.2
                break
            end
        end
    end
    top = (top or (m.rate and 100000 or 1000000)) / view.zoom
    return math.max(1, top)
end

local function Clock(seconds)
    seconds = math.floor(seconds + 0.5)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

function Graph.Render()
    if not (win and win:IsShown()) then return end
    local f = ShownFight()
    local m = MetricDef()

    for _, b in pairs(metricBtns) do
        local on = b.metric == view.metric
        b.text:SetTextColor(Rgb(on and C.accent or C.textDim))
    end

    if not f then
        fightLabel:SetText("No fights yet")
        playerBtn.text:SetText("")
        emptyText:Show()
        for _, b in ipairs(bars) do b:Hide() end
        maxText:SetText("") startText:SetText("") endText:SetText("")
        return
    end
    emptyText:Hide()

    local index = view.fight or #fights
    fightLabel:SetText(string.format("%s%s  %s  %s", f == live and "|cff40ff40LIVE|r  " or "",
        f.clock, f.zone or "", f.duration and Clock(f.duration) or Clock(f.n * SAMPLE_INTERVAL)))
    fightLabel.index = index

    if not f.players[view.player] then
        local keys = PlayerKeys(f)
        view.player = keys[1] or "you"
    end
    local p = f.players[view.player]
    playerBtn.text:SetText(PlayerLabel(p) .. "  |cff888888(click: next)|r")

    local values = p and p[m.key] or {}
    local top = AxisMax(f, p, m)
    maxText:SetText(AbbreviateNumbers(top))
    startText:SetText("0:00")
    endText:SetText(Clock(f.n * SAMPLE_INTERVAL))

    local width = plot:GetWidth()
    local height = plot:GetHeight()
    local n = f.n
    local cols = math.max(1, math.min(n, math.floor(width / MIN_COLUMN)))
    local colW = width / cols
    local r, g, b = Rgb(C.accent)
    local cc = p and p.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[p.class]
    if cc then r, g, b = cc.r, cc.g, cc.b end

    for i = 1, math.max(cols, #bars) do
        local bar = bars[i]
        if i <= cols then
            if not bar then
                bar = CreateFrame("StatusBar", nil, plot)
                bar:SetOrientation("VERTICAL")
                bar:SetStatusBarTexture("Interface\\BUTTONS\\WHITE8X8")
                bars[i] = bar
            end
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", (i - 1) * colW, 0)
            bar:SetSize(math.max(1, colW - 1), height)
            bar:SetStatusBarColor(r, g, b, 0.85)
            bar:SetMinMaxValues(0, top)
            -- Thinned when there are more seconds than room: show every k-th.
            local idx = math.max(1, math.floor(i * n / cols + 0.5))
            local v = values[idx]
            bar.sample = idx
            if Has(v) then bar:SetValue(v) else bar:SetValue(0) end
            bar:Show()
        elseif bar then
            bar:Hide()
        end
    end
    Graph.cols, Graph.colW = cols, colW
end

-- Hover: which bar the cursor is over, from plain cursor maths; the value is
-- printed C-side so a secret one still shows.
local hoverWait, hoverIdle = 0, false
local function UpdateHover(_, elapsed)
    hoverWait = hoverWait - (elapsed or 0)
    if hoverWait > 0 then return end
    hoverWait = 0.05
    local f = ShownFight()
    if not (f and plot:IsMouseOver() and Graph.cols) then
        if not hoverIdle then
            hoverIdle = true
            hoverText:SetText("Hover the graph for a value.")
        end
        return
    end
    hoverIdle = false
    local x = GetCursorPosition() / plot:GetEffectiveScale() - plot:GetLeft()
    local i = math.min(Graph.cols, math.max(1, math.floor(x / Graph.colW) + 1))
    local bar = bars[i]
    local m = MetricDef()
    local p = f.players[view.player]
    local v = bar and p and p[m.key][bar.sample]
    local when = Clock((bar and bar.sample or 0) * SAMPLE_INTERVAL)
    if Has(v) then
        local opts = m.rate and ns.AbbrevPS or ns.AbbrevTotal
        hoverText:SetFormattedText("%s   %s %s", when, m.label, AbbreviateNumbers(v, opts))
    else
        hoverText:SetFormattedText("%s   no reading", when)
    end
end

local function TextButton(parent, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    b.text:SetTextColor(Rgb(C.textDim))
    b:SetSize(math.max(16, b.text:GetStringWidth() + 10), 18)
    b:SetScript("OnEnter", function() b.text:SetTextColor(Rgb(C.accent)) end)
    b:SetScript("OnLeave", function() Graph.Render() if not b.metric then b.text:SetTextColor(Rgb(C.textDim)) end end)
    b:SetScript("OnClick", onClick)
    return b
end

local function SavePlace()
    local db = GraphDB()
    local point, _, rel, x, y = win:GetPoint(1)
    db.point, db.rel, db.x, db.y = point, rel, x, y
    db.w, db.h = win:GetWidth(), win:GetHeight()
end

local function Build()
    if win then return end
    local db = GraphDB()
    view.metric = db.metric or view.metric

    win = CreateFrame("Frame", "DPSReportGraphFrame", UIParent, "BackdropTemplate")
    win:SetSize(db.w or 520, db.h or 260)
    if db.point then
        win:SetPoint(db.point, UIParent, db.rel or db.point, db.x or 0, db.y or 0)
    else
        win:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    end
    win:SetFrameStrata("MEDIUM")
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:SetResizable(true)
    if win.SetResizeBounds then win:SetResizeBounds(360, 180, 1400, 800) end
    win:EnableMouse(true)
    ns.ApplyBackdrop(win)
    tinsert(UISpecialFrames, "DPSReportGraphFrame")

    local title = CreateFrame("Frame", nil, win, "BackdropTemplate")
    title:SetHeight(22)
    title:SetPoint("TOPLEFT", 1, -1)
    title:SetPoint("TOPRIGHT", -1, -1)
    title:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    title:SetBackdropColor(C.titleBar[1], C.titleBar[2], C.titleBar[3], C.titleBar[4] or 1)
    title:EnableMouse(true)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() win:StartMoving() end)
    title:SetScript("OnDragStop", function() win:StopMovingOrSizing() SavePlace() end)

    local name = title:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("LEFT", 8, 0)
    name:SetText("DPS Graph")
    name:SetTextColor(Rgb(C.accent))

    local close = TextButton(title, "X", function() win:Hide() end)
    close:SetPoint("RIGHT", -2, 0)

    -- Metric switches.
    local prev
    for i = #METRICS, 1, -1 do
        local m = METRICS[i]
        local b = TextButton(title, m.label, function()
            view.metric = m.key
            GraphDB().metric = m.key
            view.zoom = 1
            Graph.Render()
        end)
        b.metric = m.key
        b:SetPoint("RIGHT", prev or close, "LEFT", -4, 0)
        metricBtns[#metricBtns + 1] = b
        prev = b
    end

    -- Fight selector, under the title.
    local bar2 = CreateFrame("Frame", nil, win)
    bar2:SetHeight(20)
    bar2:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 6, -2)
    bar2:SetPoint("TOPRIGHT", title, "BOTTOMRIGHT", -6, -2)
    local older = TextButton(bar2, "<", function()
        local i = (view.fight or #fights) - 1
        if i >= 1 then view.fight = i view.zoom = 1 Graph.Render() end
    end)
    older:SetPoint("LEFT", 0, 0)
    fightLabel = bar2:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fightLabel:SetPoint("LEFT", older, "RIGHT", 4, 0)
    local newer = TextButton(bar2, ">", function()
        local i = (view.fight or #fights) + 1
        if i >= #fights then view.fight = nil else view.fight = i end
        view.zoom = 1
        Graph.Render()
    end)
    newer:SetPoint("LEFT", fightLabel, "RIGHT", 4, 0)

    local zoomIn = TextButton(bar2, "+", function() view.zoom = view.zoom * 1.5 Graph.Render() end)
    zoomIn:SetPoint("RIGHT", 0, 0)
    local zoomOut = TextButton(bar2, "-", function() view.zoom = view.zoom / 1.5 Graph.Render() end)
    zoomOut:SetPoint("RIGHT", zoomIn, "LEFT", -2, 0)
    local zoomLabel = bar2:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    zoomLabel:SetPoint("RIGHT", zoomOut, "LEFT", -2, 0)
    zoomLabel:SetText("Range")

    playerBtn = TextButton(bar2, "", function(_, button)
        local f = ShownFight()
        local keys = PlayerKeys(f)
        if #keys == 0 then return end
        local at = 1
        for i, k in ipairs(keys) do if k == view.player then at = i end end
        at = button == "RightButton" and (at - 2) % #keys + 1 or at % #keys + 1
        view.player = keys[at]
        view.zoom = 1
        Graph.Render()
    end)
    playerBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    playerBtn:SetPoint("LEFT", newer, "RIGHT", 14, 0)
    playerBtn:SetPoint("RIGHT", zoomLabel, "LEFT", -8, 0)
    playerBtn.text:ClearAllPoints()
    playerBtn.text:SetPoint("LEFT", 0, 0)
    playerBtn.text:SetPoint("RIGHT", 0, 0)
    playerBtn.text:SetJustifyH("LEFT")

    -- The plot, and its labels.
    plot = CreateFrame("Frame", nil, win, "BackdropTemplate")
    plot:SetPoint("TOPLEFT", bar2, "BOTTOMLEFT", 40, -6)
    plot:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 38)
    plot:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    plot:SetBackdropColor(0, 0, 0, 0.25)
    plot:EnableMouse(true)
    plot:SetScript("OnUpdate", UpdateHover)
    plot:SetScript("OnSizeChanged", function() Graph.Render() end)

    maxText = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    maxText:SetPoint("TOPRIGHT", plot, "TOPLEFT", -4, 0)
    local zero = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    zero:SetPoint("BOTTOMRIGHT", plot, "BOTTOMLEFT", -4, 0)
    zero:SetText("0")
    startText = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    startText:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", 0, -2)
    endText = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    endText:SetPoint("TOPRIGHT", plot, "BOTTOMRIGHT", 0, -2)

    hoverText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hoverText:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 10, 8)
    hoverText:SetPoint("RIGHT", win, "RIGHT", -24, 0)
    hoverText:SetJustifyH("LEFT")

    emptyText = plot:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("CENTER")
    emptyText:SetWidth(320)
    emptyText:SetText("Fight something: every fight this session is recorded, one bar per second. "
        .. "Graphs are kept until you /reload or log out -- the game does not let addons save them.")

    bars = {}

    local grip = CreateFrame("Button", nil, win)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() win:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() win:StopMovingOrSizing() SavePlace() Graph.Render() end)

    win:SetScript("OnShow", Graph.Render)
    win:Hide()
end

-- Live redraw: each new sample, if the live fight is the one on screen.
function Graph.OnSample(f)
    if win and win:IsShown() and ShownFight() == f then Graph.Render() end
end

-- A fight finished (or was dropped): rescale from its plain final values.
function Graph.OnFinalise(_fight)
    if win and win:IsShown() then Graph.Render() end
end

function DPSReport_ToggleGraph()
    Build()
    if win:IsShown() then win:Hide() else win:Show() end
end

SLASH_DPSREPORTGRAPH1 = "/dpsgraph"
SlashCmdList.DPSREPORTGRAPH = DPSReport_ToggleGraph

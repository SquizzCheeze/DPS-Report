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
local ghosts, compareText = {}, nil   -- the comparison run's bars, and its summary line
local fightLabel, playerBtn, metricBtns = nil, nil, {}
local view = { fight = nil, player = "you", metric = "dps", zoom = 1, smooth = 3, compare = nil }
local TextButton   -- defined with the window; used by the import box above it

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
        for _, b in ipairs(ghosts) do b:Hide() end
        if compareText then compareText:SetText("") end
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
    local width = plot:GetWidth()
    local height = plot:GetHeight()

    -- By ability: an imported fight that carries per-ability detail.
    if view.byAbility and f.imported and p and p.abilities then
        for _, b in ipairs(bars) do b:Hide() end
        for _, b in ipairs(ghosts) do b:Hide() end
        Graph.RenderAbilities(f, p, m, width, height)
        return
    end
    Graph.HideAbilities()

    -- Comparing: only between two imported fights, sharing one time axis.
    local cf = f.imported and view.compare ~= f and view.compare or nil
    local cp = cf and Graph.ComparePlayer(cf, p)
    local n = f.n
    if cf then n = math.max(f.n, cf.n) end
    local cols = math.max(1, math.min(n, math.floor(width / MIN_COLUMN)))
    local colW = width / cols

    -- What each bar shows, and the top of the axis.
    local colValue, colSample, top = {}, {}, nil
    local cmpValue = {}
    if f.imported then
        -- Imported values are plain: smooth them, bucket them, scale to fit.
        local window = m.rate and view.smooth or 1
        local series = Graph.Smoothed(values, f.n, window)
        local cseries = cp and Graph.Smoothed(cp[m.key] or {}, cf.n, window)
        local peak = 0
        for i = 1, cols do
            local from, to = Graph.Bucket(i, cols, n)
            colValue[i], colSample[i] = Graph.BucketValue(series, from, to, f.n, m.rate), from
            if colValue[i] > peak then peak = colValue[i] end
            if cseries then
                cmpValue[i] = Graph.BucketValue(cseries, from, to, cf.n, m.rate)
                if cmpValue[i] > peak then peak = cmpValue[i] end
            end
        end
        top = math.max(1, peak * 1.05 / view.zoom)
    else
        top = AxisMax(f, p, m)
        for i = 1, cols do
            -- Thinned when there are more seconds than room: show every k-th.
            local idx = math.max(1, math.floor(i * n / cols + 0.5))
            colValue[i], colSample[i] = values[idx], idx
        end
    end
    maxText:SetText(AbbreviateNumbers(top))
    startText:SetText("0:00")
    endText:SetText(Clock(n * SAMPLE_INTERVAL))
    Graph.DrawBosses(f, width, n)
    Graph.CompareSummary(f, p, cf, cp, m)

    local r, g, b = Rgb(C.accent)
    local cc = p and p.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[p.class]
    if cc then r, g, b = cc.r, cc.g, cc.b end

    -- Comparing: this run's bar on the left half of each column, the other
    -- run's in grey on the right half.
    local barW = cf and math.max(1, (colW - 1) / 2) or math.max(1, colW - 1)
    for i = 1, math.max(cols, #bars) do
        local bar, ghost = bars[i], ghosts[i]
        if i <= cols then
            if not bar then
                bar = Graph.NewBar()
                bars[i] = bar
            end
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", (i - 1) * colW, 0)
            bar:SetSize(barW, height)
            bar:SetStatusBarColor(r, g, b, 0.85)
            bar:SetMinMaxValues(0, top)
            local v = colValue[i]
            bar.sample, bar.value, bar.compare = colSample[i], v, cmpValue[i]
            if Has(v) then bar:SetValue(v) else bar:SetValue(0) end
            bar:Show()
            if cf then
                if not ghost then
                    ghost = Graph.NewBar()
                    ghosts[i] = ghost
                end
                ghost:ClearAllPoints()
                ghost:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", (i - 1) * colW + barW, 0)
                ghost:SetSize(barW, height)
                ghost:SetStatusBarColor(0.75, 0.75, 0.75, 0.6)
                ghost:SetMinMaxValues(0, top)
                ghost:SetValue(cmpValue[i] or 0)
                ghost:Show()
            elseif ghost then
                ghost:Hide()
            end
        else
            if bar then bar:Hide() end
            if ghost then ghost:Hide() end
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
    if Graph.abilityCols then
        hoverText:SetText(Graph.AbilityHover(i) or "")
        return
    end
    local bar = bars[i]
    local m = MetricDef()
    local v = bar and bar.value
    local sample = bar and bar.sample or 0
    local when = Clock(sample * SAMPLE_INTERVAL)
    -- Imported keys know their boss pulls: name the one under the cursor.
    for _, boss in ipairs(f.bosses or {}) do
        if sample >= boss.start and sample <= boss.stop then
            when = when .. "  |cffffd100" .. boss.name .. "|r"
            break
        end
    end
    if Has(v) then
        local opts = m.rate and ns.AbbrevPS or ns.AbbrevTotal
        if bar.compare then
            hoverText:SetFormattedText("%s   %s %s   |cffbbbbbbvs %s|r", when, m.label,
                AbbreviateNumbers(v, opts), AbbreviateNumbers(bar.compare, opts))
        else
            hoverText:SetFormattedText("%s   %s %s", when, m.label, AbbreviateNumbers(v, opts))
        end
    else
        hoverText:SetFormattedText("%s   no reading", when)
    end
end

-----------------------------------------------------------------------
-- Imported keys (Tools\DPSReportKeyExport.ps1 -> clipboard -> paste box)
-----------------------------------------------------------------------

-- A trailing average over `window` seconds. Imported values are plain, so
-- this is ordinary arithmetic -- the live graph can never do it.
function Graph.Smoothed(values, n, window)
    if window <= 1 then return values end
    local out, sum = {}, 0
    for i = 1, n do
        sum = sum + (values[i] or 0)
        if i > window then sum = sum - (values[i - window] or 0) end
        out[i] = sum / math.min(i, window)
    end
    return out
end

local bossShades = {}

-- Boss pulls shaded behind the bars (imported keys only). `span` is the time
-- axis in seconds: the fight's own length, or longer while comparing.
function Graph.DrawBosses(f, width, span)
    span = span or f.n
    local list = f.imported and f.bosses or {}
    for i = 1, math.max(#list, #bossShades) do
        local boss, tex = list[i], bossShades[i]
        if boss and span > 0 then
            if not tex then
                tex = plot:CreateTexture(nil, "BACKGROUND", nil, 1)
                bossShades[i] = tex
            end
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", plot, "TOPLEFT", boss.start / span * width, 0)
            tex:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", boss.start / span * width, 0)
            tex:SetWidth(math.max(1, (boss.stop - boss.start) / span * width))
            local c = boss.kill and C.accent or C.danger
            tex:SetColorTexture(c[1], c[2], c[3], 0.12)
            tex:Show()
        elseif tex then
            tex:Hide()
        end
    end
end

-----------------------------------------------------------------------
-- By ability (imported fights only): each column stacked by ability
-----------------------------------------------------------------------

local ABILITY_COLOURS = {
    { 0.95, 0.55, 0.20 }, { 0.30, 0.65, 1.00 }, { 0.55, 0.85, 0.30 }, { 0.85, 0.40, 0.85 },
    { 1.00, 0.85, 0.25 }, { 0.30, 0.85, 0.80 }, { 0.95, 0.35, 0.35 }, { 0.65, 0.55, 0.95 },
}
local OTHER_COLOUR = { 0.45, 0.45, 0.45 }
local segments = {}            -- [column][slot] = texture
local MIN_ABILITY_COLUMN = 5   -- wider than plain bars: up to 9 textures each

function Graph.HideAbilities()
    for _, col in pairs(segments) do
        for _, t in pairs(col) do t:Hide() end
    end
    Graph.abilityCols = nil
end

local function AbilityName(id)
    if id == 6603 then return "Melee" end
    return (C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or ("Spell " .. id)
end

function Graph.RenderAbilities(f, p, m, width, height)
    Graph.HideAbilities()
    local list = p.abilities[m.meter == "damage" and "D" or "H"] or {}
    local totals = m.meter == "damage" and p.dps or p.hps
    local n = f.n
    local cols = math.max(1, math.min(n, math.floor(width / MIN_ABILITY_COLUMN)))
    local colW = width / cols
    local window = view.smooth

    -- Each ability's per-second series, smoothed like the plain view.
    local series = {}
    for k, a in ipairs(list) do series[k] = Graph.Smoothed(a.per, n, window) end
    local total = Graph.Smoothed(totals or {}, n, window)

    local colData, peak = {}, 0
    for i = 1, cols do
        local from, to = Graph.Bucket(i, cols, n)
        local entry = { from = from, parts = {} }
        local sum = 0
        for k = 1, #list do
            local v = Graph.BucketValue(series[k], from, to, n, true)
            entry.parts[k] = v
            sum = sum + v
        end
        local all = Graph.BucketValue(total, from, to, n, true)
        entry.other = math.max(0, all - sum)
        entry.total = math.max(all, sum)
        if entry.total > peak then peak = entry.total end
        colData[i] = entry
    end
    local top = math.max(1, peak * 1.05 / view.zoom)

    for i, entry in ipairs(colData) do
        segments[i] = segments[i] or {}
        local y = 0
        local slots = #list + 1
        for k = 1, slots do
            local v = k <= #list and entry.parts[k] or entry.other
            local h = math.min(height - y, v / top * height)
            if h >= 0.5 then
                local t = segments[i][k]
                if not t then
                    t = plot:CreateTexture(nil, "ARTWORK")
                    segments[i][k] = t
                end
                local c = k <= #list and ABILITY_COLOURS[(k - 1) % #ABILITY_COLOURS + 1] or OTHER_COLOUR
                t:SetColorTexture(c[1], c[2], c[3], 0.9)
                t:ClearAllPoints()
                t:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", (i - 1) * colW, y)
                t:SetSize(math.max(1, colW - 1), h)
                t:Show()
                y = y + h
            end
        end
    end
    Graph.abilityCols, Graph.abilityList, Graph.cols, Graph.colW = colData, list, cols, colW

    maxText:SetText(AbbreviateNumbers(top))
    startText:SetText("0:00")
    endText:SetText(Clock(n * SAMPLE_INTERVAL))
    Graph.DrawBosses(f, width, n)

    -- The legend, on the line above the plot.
    if compareText then
        local parts = {}
        for k, a in ipairs(list) do
            local c = ABILITY_COLOURS[(k - 1) % #ABILITY_COLOURS + 1]
            parts[#parts + 1] = string.format("|cff%02x%02x%02x%s|r", c[1] * 255, c[2] * 255, c[3] * 255, AbilityName(a.id))
        end
        parts[#parts + 1] = "|cff737373Other|r"
        compareText:SetText(table.concat(parts, "  "))
    end
end

-- Hover text for a column in the ability view: its three biggest parts.
function Graph.AbilityHover(i)
    local entry = Graph.abilityCols and Graph.abilityCols[i]
    if not entry then return nil end
    local parts = {}
    for k, a in ipairs(Graph.abilityList or {}) do
        parts[#parts + 1] = { name = AbilityName(a.id), v = entry.parts[k] or 0 }
    end
    parts[#parts + 1] = { name = "Other", v = entry.other or 0 }
    table.sort(parts, function(a, b) return a.v > b.v end)
    local out = {}
    for k = 1, math.min(3, #parts) do
        if parts[k].v > 0 then out[#out + 1] = parts[k].name .. " " .. AbbreviateNumbers(math.floor(parts[k].v)) end
    end
    return Clock(entry.from * SAMPLE_INTERVAL) .. "   " .. table.concat(out, "  ")
end

-- One graph bar: a vertical StatusBar the game fills.
function Graph.NewBar()
    local bar = CreateFrame("StatusBar", nil, plot)
    bar:SetOrientation("VERTICAL")
    bar:SetStatusBarTexture("Interface\\BUTTONS\\WHITE8X8")
    return bar
end

-- Seconds covered by column i of `cols` across a `span`-second axis.
function Graph.Bucket(i, cols, span)
    local from = math.floor((i - 1) * span / cols) + 1
    local to = math.max(from, math.floor(i * span / cols))
    return from, to
end

-- A column's value from a plain series of length n: the average of a rate,
-- or where a running total stands at the column's end (held at its final
-- value once that run is over, so a shorter run ends flat, not at zero).
function Graph.BucketValue(series, from, to, n, rate)
    if rate then
        if from > n then return 0 end
        local sum, count = 0, 0
        for s = from, math.min(to, n) do
            sum, count = sum + (series[s] or 0), count + 1
        end
        return count > 0 and sum / count or 0
    end
    return series[math.min(to, n)] or 0
end

local function ShortName(name)
    return type(name) == "string" and (name:match("^([^%-]+)") or name) or nil
end

-- The same player in the comparison run: "you" to "you", else by name.
function Graph.ComparePlayer(cf, p)
    if not (cf and p) then return nil end
    if p.key == "you" and cf.players.you then return cf.players.you end
    local want = ShortName(p.name)
    for _, cp in pairs(cf.players) do
        if want and ShortName(cp.name) == want then return cp end
    end
    return nil
end

-- "vs <run>: total A vs B (+x%) . average A vs B" over the plot.
function Graph.CompareSummary(f, p, cf, cp, m)
    if not compareText then return end
    if not cf then
        compareText:SetText("")
        return
    end
    local label = (cf.clock or "?") .. "  " .. (cf.zone or "")
    if not (p and cp) then
        compareText:SetText("|cffbbbbbbvs " .. label .. "|r  -- " .. (PlayerLabel(p)) .. " isn't in that run")
        return
    end
    local key = m.meter == "damage" and "dmg" or "heal"
    local a, b = p[key] and p[key][f.n] or 0, cp[key] and cp[key][cf.n] or 0
    local change = b > 0 and string.format(" (%s%.1f%%)", a >= b and "+" or "", (a - b) / b * 100) or ""
    local rateA, rateB = f.n > 0 and a / f.n or 0, cf.n > 0 and b / cf.n or 0
    local colour = a >= b and "|cff40ff40" or "|cffff6060"
    compareText:SetText(string.format("|cffbbbbbbvs %s|r   %s %s vs %s%s|r   avg %s vs %s",
        label, m.meter == "damage" and "Damage" or "Healing",
        AbbreviateNumbers(a), AbbreviateNumbers(b), colour .. change,
        AbbreviateNumbers(rateA), AbbreviateNumbers(rateB)))
end

local function SpecClass(specID)
    local SI = C_SpecializationInfo
    local ok, classID = pcall(SI.GetClassIDFromSpecID, specID)
    if not (ok and type(classID) == "number") then return nil end
    local _, file = GetClassInfo(classID)
    return file
end

local function NumberList(list)
    local out, i = {}, 0
    for v in (list .. ","):gmatch("([^,]*),") do
        i = i + 1
        out[i] = tonumber(v) or 0
    end
    return out, i
end

local function Running(per, n)
    local out, sum = {}, 0
    for i = 1, n do
        sum = sum + (per[i] or 0)
        out[i] = sum
    end
    return out
end

-- Parse an export string into a fight. Returns fight or nil, message.
local function ParseKey(text)
    if type(text) ~= "string" or text:sub(1, 5) ~= "DRK1~" then
        return nil, "That isn't a key export -- it should start with DRK1~."
    end
    local f = { imported = true, players = {}, ambiguous = {}, bosses = {}, n = 0 }
    local byIndex = {}
    local me = UnitName("player")
    for rec in text:gmatch("[^~]+") do
        local kind, rest = rec:match("^(%u)%^(.*)$")
        if kind == "K" then
            -- kind: "mplus" (a key) or "raid" (one boss pull; level is its
            -- difficulty). Exports from before raid support have no kind.
            local name, level, secs, success, when, kind = strsplit("^", rest)
            f.kind = kind == "raid" and "raid" or "mplus"
            if f.kind == "raid" then
                f.zone = (name or "?") .. " (" .. (level or "?") .. ") " .. (success == "1" and "Kill" or "Wipe")
            else
                f.zone = (name or "?") .. " +" .. (level or "?") .. (success == "1" and "" or " (depleted)")
            end
            f.n = tonumber(secs) or 0
            f.duration = f.n
            f.clock = when or "?"
        elseif kind == "P" then
            local idx, name, spec = strsplit("^", rest)
            local short = (name or "?"):match("^([^%-]+)") or name
            local key = (short == me) and "you" or ("imported" .. (idx or "?"))
            local p = { key = key, name = name, class = SpecClass(tonumber(spec)) }
            f.players[key] = p
            byIndex[idx] = p
        elseif kind == "B" then
            local name, s, e, kill = strsplit("^", rest)
            f.bosses[#f.bosses + 1] = { name = name, start = tonumber(s) or 0, stop = tonumber(e) or 0, kill = kill == "1" }
        elseif kind == "D" or kind == "H" then
            local idx, list = rest:match("^(%d+)%^(.*)$")
            local p = idx and byIndex[idx]
            if p then
                local per = NumberList(list)
                if kind == "D" then p.dps = per else p.hps = per end
            end
        elseif kind == "A" then
            -- One ability: A^player^D|H^spellID^step^packed, the values in
            -- thousands per `step`-second block ("_n" = n empty blocks).
            -- Spread back out to per-second amounts for the chart.
            local idx, which, id, step, list = rest:match("^(%d+)%^([DH])%^(%d+)%^(%d+)%^(.*)$")
            local p = idx and byIndex[idx]
            if p then
                step = tonumber(step) or 1
                local per, block = {}, 0
                for v in (list .. ","):gmatch("([^,]*),") do
                    local run = v:match("^_(%d+)$")
                    if run then
                        block = block + tonumber(run)
                    else
                        block = block + 1
                        local amount = (tonumber(v) or 0) * 1000 / step
                        if amount > 0 then
                            for s = (block - 1) * step + 1, block * step do per[s] = amount end
                        end
                    end
                end
                p.abilities = p.abilities or { D = {}, H = {} }
                local listFor = p.abilities[which]
                listFor[#listFor + 1] = { id = tonumber(id), per = per }
            end
        elseif kind == "C" then
            -- Casts: C^player^spellID^tenths,... (for the cast timeline).
            local idx, id, list = rest:match("^(%d+)%^(%d+)%^(.*)$")
            local p = idx and byIndex[idx]
            if p then
                local times = {}
                for v in list:gmatch("[^,]+") do times[#times + 1] = (tonumber(v) or 0) / 10 end
                p.casts = p.casts or {}
                p.casts[#p.casts + 1] = { id = tonumber(id), times = times }
            end
        end
    end
    if f.n == 0 or not next(f.players) then return nil, "The export looks empty or cut short." end
    for _, p in pairs(f.players) do
        p.dps, p.hps = p.dps or {}, p.hps or {}
        p.dmg, p.heal = Running(p.dps, f.n), Running(p.hps, f.n)
    end
    return f
end

-----------------------------------------------------------------------
-- Saved keys: imports kept across reloads
-----------------------------------------------------------------------
--
-- Imported values are plain, so unlike live fights they CAN be saved. Each
-- import is kept per character in DPSReportCharDB.importedKeys as the raw
-- export text (~60 KB), and only parsed when opened. Its id is the export's
-- K record (dungeon, level, length, result, start time), so importing the
-- same key again replaces it instead of adding a copy. The newest
-- MAX_SAVED_KEYS are kept, plus any pinned, which are never trimmed.

local MAX_SAVED_KEYS = 20

local function SavedStore()
    if type(DPSReportCharDB) ~= "table" then return nil end
    DPSReportCharDB.importedKeys = DPSReportCharDB.importedKeys or {}
    return DPSReportCharDB.importedKeys
end

local function KeyId(text)
    return type(text) == "string" and text:match("^DRK1~(K%^[^~]*)") or nil
end

local function SaveImport(text, f)
    local store = SavedStore()
    local id = KeyId(text)
    if not (store and id) then return end
    f.savedId = id
    for _, e in ipairs(store) do
        if e.id == id then
            e.text, e.saved = text, time()
            return
        end
    end
    store[#store + 1] = { id = id, text = text, saved = time(), zone = f.zone, clock = f.clock, seconds = f.n }
    local unpinned = 0
    for _, e in ipairs(store) do if not e.pinned then unpinned = unpinned + 1 end end
    local i = 1
    while unpinned > MAX_SAVED_KEYS and i <= #store do
        if not store[i].pinned then
            table.remove(store, i)
            unpinned = unpinned - 1
        else
            i = i + 1
        end
    end
end

-- Put a fight in this session's list (or find it there) and show it.
local function ShowFight(f)
    for i, existing in ipairs(fights) do
        if f.savedId and existing.savedId == f.savedId then
            view.fight, view.zoom = i, 1
            Graph.Render()
            return existing
        end
    end
    fights[#fights + 1] = f
    while #fights > MAX_FIGHTS do table.remove(fights, 1) end
    view.fight, view.zoom = #fights, 1
    Graph.Render()
    return f
end

-- A saved key, as a fight: the copy already open this session, else parsed.
local function LoadSaved(e)
    for _, f in ipairs(fights) do
        if f.savedId == e.id then return f end
    end
    local f, err = ParseKey(e.text)
    if not f then
        print("|cff00ccff[DPSReport]|r Couldn't open that saved key: " .. tostring(err))
        return nil
    end
    f.savedId = e.id
    return f
end
Graph.LoadSaved = LoadSaved

local function OpenSaved(e)
    local f = LoadSaved(e)
    if f then ShowFight(f) end
end

local function DeleteSaved(e)
    local store = SavedStore()
    for i = #(store or {}), 1, -1 do
        if store[i] == e then table.remove(store, i) end
    end
end

-- Newest first.
local function SavedList()
    local list = {}
    for _, e in ipairs(SavedStore() or {}) do list[#list + 1] = e end
    table.sort(list, function(a, b) return (a.saved or 0) > (b.saved or 0) end)
    return list
end
Graph.SavedList = SavedList

local function SavedLabel(e)
    return string.format("%s%s  %s  %s", e.pinned and "|cffffd100*|r " or "", e.clock or "?",
        e.zone or "?", Clock(e.seconds or 0))
end
Graph.SavedLabel = SavedLabel

-- The Keys menu: every saved key, each with Open / Keep / Delete.
-- The Compare menu: any other saved key, drawn beside the one on screen.
local function OpenCompareMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    local shown = view.fight and fights[view.fight] or fights[#fights]
    MenuUtil.CreateContextMenu(owner, function(_, root)
        if not (shown and shown.imported) then
            root:CreateTitle("Open an imported key first (Import or Keys).")
            return
        end
        root:CreateTitle("Compare with")
        root:CreateButton(view.compare and "None (stop comparing)" or "|cff888888None|r", function()
            view.compare = nil
            Graph.Render()
        end)
        for _, e in ipairs(SavedList()) do
            if e.id ~= shown.savedId then
                root:CreateButton(SavedLabel(e), function()
                    view.compare = LoadSaved(e)
                    Graph.Render()
                end)
            end
        end
    end)
end

local function OpenKeysMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        print("|cff00ccff[DPSReport]|r The saved keys menu needs the game's menu system, which isn't available.")
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        local list = SavedList()
        root:CreateTitle(#list == 0 and "No saved keys yet -- use Import." or "Saved keys")
        for _, e in ipairs(list) do
            local item = root:CreateButton(SavedLabel(e), function() OpenSaved(e) end)
            item:CreateButton("Open", function() OpenSaved(e) end)
            item:CreateButton(e.pinned and "Unpin (can be trimmed)" or "Keep forever (pin)", function()
                e.pinned = not e.pinned
            end)
            item:CreateButton("|cffff6060Delete|r", function() DeleteSaved(e) end)
        end
    end)
end

local pasteBox

local function OpenImport()
    if not pasteBox then
        pasteBox = CreateFrame("Frame", nil, win, "BackdropTemplate")
        pasteBox:SetSize(380, 112)
        pasteBox:SetPoint("CENTER", win, "CENTER")
        pasteBox:SetFrameLevel(win:GetFrameLevel() + 20)
        pasteBox:EnableMouse(true)
        ns.ApplyBackdrop(pasteBox)

        local head = pasteBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        head:SetPoint("TOPLEFT", 10, -10)
        head:SetText("Import a key")
        head:SetTextColor(Rgb(C.accent))

        local help = pasteBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        help:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -6)
        help:SetPoint("RIGHT", -10, 0)
        help:SetJustifyH("LEFT")
        help:SetText("Run Export Last Key in DPSReport\\Tools (keys and raid bosses), then press Ctrl+V here.")

        local box = CreateFrame("EditBox", nil, pasteBox, "BackdropTemplate")
        box:SetHeight(22)
        box:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -8)
        box:SetPoint("RIGHT", -10, 0)
        ns.ApplyBackdrop(box, C.control, C.border)
        box:SetFontObject(GameFontHighlightSmall)
        box:SetTextInsets(6, 6, 0, 0)
        box:SetAutoFocus(false)
        box:SetMaxLetters(0)
        pasteBox.box = box

        local status = pasteBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        status:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -6)
        status:SetPoint("RIGHT", -10, 0)
        status:SetJustifyH("LEFT")
        pasteBox.status = status

        box:SetScript("OnEscapePressed", function() pasteBox:Hide() end)
        -- A paste arrives as ONE change: read it, clear the box, import.
        box:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then return end
            local text = self:GetText()
            if text == "" then return end
            self:SetText("")
            local fight, err = ParseKey(text)
            if not fight then
                status:SetText("|cffff6060" .. err .. "|r")
                return
            end
            SaveImport(text, fight)
            pasteBox:Hide()
            print("|cff00ccff[DPSReport]|r Imported and saved " .. fight.zone .. ".")
            ShowFight(fight)
        end)

        local close = TextButton(pasteBox, "X", function() pasteBox:Hide() end)
        close:SetPoint("TOPRIGHT", -4, -4)
    end
    pasteBox.status:SetText("")
    pasteBox.box:SetText("")
    pasteBox:Show()
    pasteBox.box:SetFocus()
end
Graph.OpenImport = OpenImport
Graph.ParseKey = ParseKey   -- exposed for testing outside the game

TextButton = function(parent, label, onClick)
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
    view.smooth = db.smooth or view.smooth
    view.byAbility = db.byAbility == true

    win = CreateFrame("Frame", "DPSReportGraphFrame", UIParent, "BackdropTemplate")
    win:SetSize(db.w or 520, db.h or 260)
    if db.point then
        win:SetPoint(db.point, UIParent, db.rel or db.point, db.x or 0, db.y or 0)
    else
        win:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    end
    -- HIGH, and to the front when clicked: on MEDIUM, unit frames and
    -- cooldown icons drew over it (user screenshot 2026-10-22).
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:SetResizable(true)
    if win.SetResizeBounds then win:SetResizeBounds(580, 200, 1400, 800) end
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

    -- Import a key exported from the combat log (Tools\DPSReportKeyExport.ps1).
    local import = TextButton(title, "Import", OpenImport)
    import:SetPoint("LEFT", name, "RIGHT", 12, 0)
    -- Saved imports, kept across reloads.
    local keys
    keys = TextButton(title, "Keys", function() OpenKeysMenu(keys) end)
    keys:SetPoint("LEFT", import, "RIGHT", 2, 0)
    -- Another saved key beside this one.
    local compare
    compare = TextButton(title, "Compare", function() OpenCompareMenu(compare) end)
    compare:SetPoint("LEFT", keys, "RIGHT", 2, 0)

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

    -- Smoothing for imported keys (their per-second values are real and
    -- spiky); the live graph's values are the game's running averages already.
    local smooth
    smooth = TextButton(bar2, "", function()
        view.smooth = view.smooth == 1 and 3 or (view.smooth == 3 and 5 or 1)
        GraphDB().smooth = view.smooth
        smooth.text:SetText("Avg " .. view.smooth .. "s")
        Graph.Render()
    end)
    smooth.text:SetText("Avg " .. view.smooth .. "s")
    smooth:SetWidth(46)
    smooth:SetPoint("RIGHT", zoomLabel, "LEFT", -8, 0)
    zoomLabel = smooth   -- the player button stops short of it

    -- By ability: stack each column by ability (imported fights that carry
    -- per-ability detail; anything else keeps the plain view).
    local byAbility
    byAbility = TextButton(bar2, "By ability", function()
        view.byAbility = not view.byAbility
        GraphDB().byAbility = view.byAbility
        byAbility.text:SetText(view.byAbility and "|cffffd100By ability|r" or "By ability")
        Graph.Render()
    end)
    byAbility.text:SetText(view.byAbility and "|cffffd100By ability|r" or "By ability")
    byAbility:SetPoint("RIGHT", zoomLabel, "LEFT", -6, 0)
    zoomLabel = byAbility

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
    -- The comparison summary sits between the controls and the plot.
    compareText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    compareText:SetPoint("TOPLEFT", bar2, "BOTTOMLEFT", 2, -3)
    compareText:SetPoint("RIGHT", win, "RIGHT", -10, 0)
    compareText:SetJustifyH("LEFT")
    compareText:SetWordWrap(false)

    plot:SetPoint("TOPLEFT", bar2, "BOTTOMLEFT", 40, -20)
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

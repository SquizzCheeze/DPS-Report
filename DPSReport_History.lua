-- DPSReport_History.lua -- fight history, comparing fights, personal bests
-- (2026-10-22).
--
-- Each boss pull's END totals, read from that fight's own C_DamageMeter
-- session (by ID) just after combat, and each Mythic+ run's from the Overall
-- session -- when they are plain (/dpsprobe: everything is secret DURING
-- combat, plain after). Kept per character in DPSReportCharDB.fightHistory,
-- newest MAX_FIGHTS. No per-second data: that is the graph's job, and the
-- live per-second values can never be saved anyway.
--
-- A fight that overlapped a boss encounter is named after it ("Nalorakk
-- (Heroic) Kill"); kills set PERSONAL BESTS per encounter and difficulty
-- (your DPS and your total), kept in DPSReportCharDB.personalBests, with a
-- line in your own chat when one is beaten.
--
-- Window: History on the DPS Graph, or /dpshistory. Fights tab: click a fight
-- to see everyone's numbers; right-click another to compare (green/red % on
-- every number, matched by player name). Personal bests tab.

local _, ns = ...
local C = ns.colors

local MAX_FIGHTS = 200
local MIN_SECONDS = 5
local PREFIX = "|cff00ccff[DPSReport]|r "

local function IsSecret(v)
    if issecretvalue and issecretvalue(v) then return true end
    if issecrettable and issecrettable(v) then return true end
    return false
end

local function Plain(v)
    if IsSecret(v) then return nil end
    return v
end

-- Only boss pulls and whole Mythic+ runs are kept (user decision
-- 2026-10-22: trash fights were noise). Entries saved before that -- plain
-- trash fights -- are dropped the first time the store is read.
local pruned = false
local function Store()
    if type(DPSReportCharDB) ~= "table" then return nil, nil end
    DPSReportCharDB.fightHistory = DPSReportCharDB.fightHistory or {}
    DPSReportCharDB.personalBests = DPSReportCharDB.personalBests or {}
    local history = DPSReportCharDB.fightHistory
    if not pruned then
        pruned = true
        for i = #history, 1, -1 do
            local f = history[i]
            if not (f.encounter or f.kind == "run") then table.remove(history, i) end
        end
    end
    return history, DPSReportCharDB.personalBests
end

local function Rgb(t) return t[1], t[2], t[3] end

local function Clock(seconds)
    seconds = math.floor((seconds or 0) + 0.5)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function Abbrev(v) return AbbreviateNumbers(math.floor((v or 0) + 0.5)) end

-----------------------------------------------------------------------
-- Recording
-----------------------------------------------------------------------

local current          -- the fight in progress
local encounter        -- the boss encounter in progress, if any

local function Context()
    local name, instanceType, difficultyID = GetInstanceInfo()
    local ctx = { zone = Plain(name) or GetZoneText() or "?", instanceType = instanceType }
    local ok, level = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
    level = ok and Plain(level)
    if type(level) == "number" and level > 0 then ctx.keyLevel = level end
    ctx.difficultyID = Plain(difficultyID)
    return ctx
end

local function FightName(f)
    local e = f.encounter
    if e then
        local diff = e.difficultyID and GetDifficultyInfo(e.difficultyID)
        local result = e.success == nil and "" or (e.success and " Kill" or " Wipe")
        return string.format("%s%s%s", e.name or "?", diff and (" (" .. diff .. ")") or "", result)
    end
    if f.keyLevel then return string.format("%s +%d trash", f.zone or "?", f.keyLevel) end
    return f.zone or "?"
end

local METERS = {
    { field = "d", type = "DamageDone" },
    { field = "h", type = "HealingDone" },
    { field = "i", type = "Interrupts" },
}

-- Read a session's totals as {name = row}; nil while it is still secret.
-- `which` is a sessionID when byID, else an Enum.DamageMeterSessionType.
local function ReadTotals(which, byID)
    local players, any = {}, false
    for _, m in ipairs(METERS) do
        local ok, s
        if byID then
            ok, s = pcall(C_DamageMeter.GetCombatSessionFromID, which, Enum.DamageMeterType[m.type])
        else
            ok, s = pcall(C_DamageMeter.GetCombatSessionFromType, which, Enum.DamageMeterType[m.type])
        end
        if ok and type(s) == "table" and not IsSecret(s) and type(s.combatSources) == "table" then
            for _, e in ipairs(s.combatSources) do
                local name, total = Plain(e.name), Plain(e.totalAmount)
                if name and total then
                    any = true
                    local key = Ambiguate(name, "short")
                    local p = players[key]
                    if not p then
                        p = { n = key, c = Plain(e.classFilename), d = 0, h = 0, i = 0 }
                        players[key] = p
                    end
                    if e.isLocalPlayer == true then p.me = true end
                    p[m.field] = total
                end
            end
        elseif ok and type(s) == "table" and (IsSecret(s) or IsSecret(s.combatSources)) then
            return nil   -- still restricted: the caller retries
        end
    end
    if not any then return nil end
    return players
end

local function Sorted(players)
    local list = {}
    for _, p in pairs(players) do list[#list + 1] = p end
    table.sort(list, function(a, b) return a.d > b.d end)
    return list
end

-- The game's own session for a fight that has just ended: the newest one no
-- longer than the fight itself. Reading "Current" instead went wrong two ways
-- (user report 2026-10-22): a retry that ran after the NEXT pull had begun
-- read that pull, and a boss kill that ended a key read the key's whole-run
-- session (Zul'jan was saved as a 27-minute kill).
local function FightSession(wall, maxID)
    local ok, list = pcall(C_DamageMeter.GetAvailableCombatSessions)
    if not ok or type(list) ~= "table" then return nil end
    local best, bestDur
    for _, s in ipairs(list) do
        local id, d = Plain(s.sessionID), Plain(s.durationSeconds)
        if type(id) == "number" and type(d) == "number" and d > 0 and d <= wall + 5
            and (not maxID or id <= maxID)
            and (not best or id > best) then
            best, bestDur = id, d
        end
    end
    return best, bestDur
end

local function CheckBest(f, quiet)
    local e = f.encounter
    if not (e and e.success and e.id) then return end
    local me
    for _, p in ipairs(f.players) do if p.me then me = p end end
    if not (me and f.duration and f.duration > 0) then return end
    local _, bests = Store()
    local key = e.id .. ":" .. (e.difficultyID or 0)
    local b = bests[key]
    local dps = me.d / f.duration
    if not b then
        bests[key] = { name = FightName(f):gsub(" Kill$", ""), dps = dps, dpsWhen = f.when,
                       total = me.d, totalWhen = f.when, kills = 1 }
        return
    end
    b.kills = (b.kills or 0) + 1
    if dps > (b.dps or 0) then
        if not quiet then
            print(PREFIX .. string.format("New personal best on %s: %s DPS (was %s).", b.name, Abbrev(dps), Abbrev(b.dps)))
        end
        b.dps, b.dpsWhen = dps, f.when
    end
    if me.d > (b.total or 0) then b.total, b.totalWhen = me.d, f.when end
end

local function Save(f)
    local history = Store()
    if not history then return end
    history[#history + 1] = f
    while #history > MAX_FIGHTS do table.remove(history, 1) end
    if ns.History.OnNewFight then ns.History.OnNewFight() end
end

-- A WHOLE Mythic+ run, read from the game's Overall session: the same numbers
-- as the meter's Overall. It used to add up every fight in the key, which
-- counted chain pulls twice (994M against the meter's 466M, user report
-- 2026-10-22). The Overall at the key's start is subtracted, so it is right
-- whether or not the meter resets on a new key. DPS is over COMBAT time, as
-- the meter shows it; the key's timer is kept as well (`keyTime`) and shown.
local run
local pending = 0       -- boss pulls still waiting for their totals

local function CloseRun(tries)
    if not (run and run.completed) then return end
    -- Wait for the key's last fight to end and the session to turn plain.
    local players = not (current or pending > 0) and ReadTotals(Enum.DamageMeterSessionType.Overall)
    if not players then
        if tries < 15 then C_Timer.After(2, function() CloseRun(tries + 1) end) end
        return
    end
    local r = run
    run = nil
    for name, p in pairs(players) do
        local b = r.base and r.base[name]
        if b then
            p.d, p.h, p.i = math.max(0, p.d - b.d), math.max(0, p.h - b.h), math.max(0, p.i - b.i)
        end
        if p.d + p.h + p.i == 0 then players[name] = nil end
    end
    local list = Sorted(players)
    if #list == 0 then return end
    local combat = ns.OverallDuration and Plain(ns.OverallDuration())
    combat = type(combat) == "number" and combat - (r.baseDur or 0) or 0
    local keyTime = r.keyTime or (GetTime() - r.started)
    Save({
        kind = "run", v = 2, when = r.when, zone = r.zone, keyLevel = r.level, onTime = r.onTime,
        duration = combat > 0 and combat or keyTime, keyTime = keyTime, players = list,
        name = string.format("%s +%d %s", r.zone or "?", r.level or 0,
            r.onTime == true and "(timed)" or (r.onTime == false and "(over time)" or "")),
    })
end

local function OpenRun()
    local ok, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
    mapID = ok and Plain(mapID)
    local name = mapID and C_ChallengeMode.GetMapUIInfo(mapID)
    local okL, level = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
    local r = { when = time(), started = GetTime(), zone = Plain(name) or Context().zone,
                level = okL and Plain(level) or 0 }
    run = r
    -- The baseline, a moment later so the meter's own reset-on-key-start has
    -- run first (its handler and ours fire in no fixed order).
    C_Timer.After(1, function()
        if run ~= r then return end
        r.base = ReadTotals(Enum.DamageMeterSessionType.Overall) or {}
        local d = ns.OverallDuration and Plain(ns.OverallDuration())
        r.baseDur = type(d) == "number" and d or 0
    end)
end

local function Finalise(f, tries)
    if not f.sessionID then f.sessionID, f.sessionDur = FightSession(f.wall, f.maxSession) end
    local players = f.sessionID and ReadTotals(f.sessionID, true)
    if not players then
        if tries < 6 then
            C_Timer.After(1, function() Finalise(f, tries + 1) end)
        else
            pending = pending - 1
        end
        return
    end
    pending = pending - 1
    f.duration = f.sessionDur
    f.sessionID, f.sessionDur, f.maxSession = nil, nil, nil
    if f.duration < MIN_SECONDS then return end
    f.players = Sorted(players)
    f.name = FightName(f)
    Save(f)
    CheckBest(f)
end

-- One-time repair of what the old recording saved (2026-10-22): whole runs
-- with every chain pull counted twice, and boss pulls that read the wrong
-- session (longer than the fight itself). Both are dropped, and the personal
-- bests, which started the same day, are rebuilt from what remains.
local function Repair()
    if type(DPSReportCharDB) ~= "table" or DPSReportCharDB.historyRepaired then return end
    local history, bests = Store()
    if not history then return end
    DPSReportCharDB.historyRepaired = true
    local dropped = 0
    for i = #history, 1, -1 do
        local f = history[i]
        local bad = (f.kind == "run" and f.v ~= 2)
            or (f.encounter and f.wall and f.duration and f.duration > f.wall + 5)
        if bad then
            table.remove(history, i)
            dropped = dropped + 1
        end
    end
    wipe(bests)
    for _, f in ipairs(history) do
        if f.encounter and f.players then CheckBest(f, true) end
    end
    if dropped > 0 then
        print(PREFIX .. string.format("Fight history: removed %d %s recorded with wrong totals; personal bests rebuilt.",
            dropped, dropped == 1 and "entry" or "entries"))
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("ENCOUNTER_START")
ev:RegisterEvent("ENCOUNTER_END")
ev:RegisterEvent("CHALLENGE_MODE_START")
ev:RegisterEvent("CHALLENGE_MODE_COMPLETED")
ev:RegisterEvent("CHALLENGE_MODE_RESET")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
    if event == "PLAYER_LOGIN" then
        Repair()
    elseif event == "CHALLENGE_MODE_START" then
        OpenRun()
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        if run then
            run.completed = true
            -- Read now: the completion info clears within seconds.
            local ok, info = pcall(C_ChallengeMode.GetChallengeCompletionInfo)
            info = ok and type(info) == "table" and info or {}
            local ms = Plain(info.time)
            if type(ms) == "number" and ms > 0 then run.keyTime = ms / 1000 end
            run.onTime = Plain(info.onTime)
            C_Timer.After(2, function() CloseRun(0) end)
        end
    elseif event == "CHALLENGE_MODE_RESET" then
        run = nil
    elseif event == "ENCOUNTER_START" then
        -- encounterID, name, difficultyID, groupSize
        encounter = { id = a1, name = a2, difficultyID = a3, size = a4 }
        if current then current.encounter = encounter end
    elseif event == "ENCOUNTER_END" then
        -- encounterID, name, difficultyID, groupSize, success
        if encounter and encounter.id == a1 then encounter.success = a5 == 1 end
        encounter = nil
    elseif event == "PLAYER_REGEN_DISABLED" then
        local ctx = Context()
        current = { when = time(), started = GetTime(), zone = ctx.zone, keyLevel = ctx.keyLevel,
                    encounter = encounter }
    elseif event == "PLAYER_REGEN_ENABLED" then
        local f = current
        current = nil
        if not f then return end
        f.wall = GetTime() - f.started
        f.started = nil
        -- Only boss pulls are kept on their own (a whole key comes from the
        -- Overall session, so its trash needs nothing here).
        if not f.encounter then return end
        -- The newest session that exists NOW: one a chained pull opens in
        -- the next second must not be mistaken for this fight's.
        local ok, list = pcall(C_DamageMeter.GetAvailableCombatSessions)
        for _, s in ipairs(ok and type(list) == "table" and list or {}) do
            local id = Plain(s.sessionID)
            if type(id) == "number" and id > (f.maxSession or -1) then f.maxSession = id end
        end
        pending = pending + 1
        C_Timer.After(1, function() Finalise(f, 0) end)
    end
end)

-----------------------------------------------------------------------
-- Window
-----------------------------------------------------------------------

local History = {}
ns.History = History

local win, listChild, listRows, detail, tabBtns = nil, nil, {}, nil, {}
local state = { tab = "fights", selected = nil, compare = nil }
local cells = {}

local function TextButton(parent, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    b.text:SetTextColor(Rgb(C.textDim))
    b:SetSize(math.max(16, b.text:GetStringWidth() + 10), 18)
    b:SetScript("OnEnter", function() b.text:SetTextColor(Rgb(C.accent)) end)
    b:SetScript("OnLeave", function() History.Render() end)
    b:SetScript("OnClick", onClick)
    return b
end

local function Change(a, b)
    if not (a and b) or b == 0 then return "" end
    local pct = (a - b) / b * 100
    return string.format(" %s%s%.0f%%|r", pct >= 0 and "|cff40ff40" or "|cffff6060", pct >= 0 and "+" or "", pct)
end

local function MyDps(f)
    for _, p in ipairs(f.players or {}) do
        if p.me then return f.duration and f.duration > 0 and p.d / f.duration or 0 end
    end
end

-- Newest first, narrowed by the search box: every word typed must appear in
-- the fight's name, zone or date ("nalorakk heroic", "+8 timed", "10/22").
local function Filtered()
    local history = Store() or {}
    local words = {}
    for w in (state.filter or ""):lower():gmatch("%S+") do words[#words + 1] = w end
    local out = {}
    for i = #history, 1, -1 do
        local f = history[i]
        local hay = ((f.name or "") .. " " .. (f.zone or "") .. " " .. date("%m/%d %Y-%m-%d", f.when or 0)):lower()
        local keep = true
        for _, w in ipairs(words) do
            if not hay:find(w, 1, true) then keep = false break end
        end
        if keep then out[#out + 1] = f end
    end
    return out
end

local function RenderList()
    local shown = Filtered()
    local n = #shown
    for i = 1, math.max(n, #listRows) do
        local row = listRows[i]
        local f = shown[i]
        if f then
            if not row then
                row = CreateFrame("Button", nil, listChild)
                row:SetHeight(18)
                row:SetPoint("TOPLEFT", 0, -(i - 1) * 18)
                row:SetPoint("TOPRIGHT", 0, -(i - 1) * 18)
                row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                row.bg = row:CreateTexture(nil, "BACKGROUND")
                row.bg:SetAllPoints()
                row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.text:SetPoint("LEFT", 4, 0)
                row.text:SetPoint("RIGHT", -4, 0)
                row.text:SetJustifyH("LEFT")
                row.text:SetWordWrap(false)
                row:SetScript("OnClick", function(self, button)
                    if button == "RightButton" then
                        state.compare = state.compare ~= self.fight and self.fight or nil
                    else
                        state.selected = self.fight
                        if state.compare == self.fight then state.compare = nil end
                    end
                    History.Render()
                end)
                listRows[i] = row
            end
            row.fight = f
            local dps = MyDps(f)
            row.text:SetText(string.format("%s  %s  |cff888888%s%s|r", date("%m/%d %H:%M", f.when), f.name or "?",
                Clock(f.keyTime or f.duration), dps and ("  " .. Abbrev(dps)) or ""))
            if f == state.selected then
                local r, g, b = Rgb(C.accent)
                row.bg:SetColorTexture(r, g, b, 0.25)
            elseif f == state.compare then
                row.bg:SetColorTexture(0.6, 0.6, 0.6, 0.25)
            else
                row.bg:SetColorTexture(0, 0, 0, 0)
            end
            row:Show()
        elseif row then
            row:Hide()
        end
    end
    listChild:SetHeight(math.max(1, n * 18))
    listChild.empty:SetShown(n == 0)
    listChild.empty:SetText((state.filter or "") ~= "" and "Nothing matches that search."
        or "Nothing recorded yet. Boss pulls and whole Mythic+ runs are kept from now on.")
end

local COLS = { { "Player", 120 }, { "DPS", 80 }, { "Damage", 80 }, { "HPS", 80 }, { "Healing", 80 }, { "Kicks", 50 } }

-- Column positions, fitted to the pane on every render: the name takes about
-- a quarter, the numbers share the rest. Fixed widths ran the last column off
-- the window's edge at its default size (user screenshot 2026-10-22).
local colX, colW = {}, {}
local function LayoutColumns()
    local width = detail:GetWidth()
    local nameW = math.max(90, math.floor(width * 0.26))
    local rest = (width - nameW) / (#COLS - 1)
    local x = 0
    for c = 1, #COLS do
        colW[c] = c == 1 and nameW or rest
        colX[c] = x
        x = x + colW[c]
    end
end

local function Cell(r, c)
    cells[r] = cells[r] or {}
    local fs = cells[r][c]
    if not fs then
        fs = detail:CreateFontString(nil, "OVERLAY", r == 0 and "GameFontNormalSmall" or "GameFontHighlightSmall")
        fs:SetJustifyH(c == 1 and "LEFT" or "RIGHT")
        fs:SetWordWrap(false)
        cells[r][c] = fs
    end
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", detail, "TOPLEFT", colX[c] or 0, -40 - r * 16)
    fs:SetWidth(math.max(10, (colW[c] or 60) - 4))
    fs:Show()
    return fs
end

local function HideCells(fromRow)
    for r, row in pairs(cells) do
        if r >= fromRow then for _, fs in pairs(row) do fs:Hide() end end
    end
end

local function RenderFight()
    local f = state.selected
    detail.title:SetText(f and f.name or "Click a fight on the left.")
    if not f then
        detail.sub:SetText("Right-click another fight to compare it with the selected one.")
        HideCells(0)
        return
    end
    local cmp = state.compare
    detail.sub:SetText(string.format("%s   %s   %s%s", date("%Y-%m-%d %H:%M", f.when), f.zone or "", f.keyTime and string.format("key %s, %s in combat", Clock(f.keyTime), Clock(f.duration)) or Clock(f.duration),
        cmp and ("   |cffbbbbbbvs " .. date("%m/%d %H:%M", cmp.when) .. " " .. (cmp.name or "") .. "|r") or ""))
    for c, col in ipairs(COLS) do Cell(0, c):SetText(col[1]) end
    local byName = {}
    for _, p in ipairs(cmp and cmp.players or {}) do byName[p.n] = p end
    local rows = 0
    for i, p in ipairs(f.players or {}) do
        local o = byName[p.n]
        local dur, odur = f.duration > 0 and f.duration or 1, cmp and cmp.duration > 0 and cmp.duration or 1
        local values = {
            { p.d / dur, o and o.d / odur }, { p.d, o and o.d },
            { p.h / dur, o and o.h / odur }, { p.h, o and o.h },
        }
        local nameCell = Cell(i, 1)
        local cc = p.c and RAID_CLASS_COLORS and RAID_CLASS_COLORS[p.c]
        nameCell:SetText(p.n)
        if cc then nameCell:SetTextColor(cc.r, cc.g, cc.b) else nameCell:SetTextColor(1, 1, 1) end
        for k, v in ipairs(values) do
            Cell(i, k + 1):SetText(Abbrev(v[1]) .. (cmp and Change(v[1], v[2]) or ""))
        end
        Cell(i, 6):SetText(tostring(p.i or 0) .. (cmp and o and Change(p.i, o.i) or ""))
        rows = i
        if 40 + (i + 1) * 16 > detail:GetHeight() then break end
    end
    HideCells(rows + 1)
end

local function RenderBests()
    local _, bests = Store()
    detail.title:SetText("Personal bests")
    detail.sub:SetText("Your best DPS and best total on each boss you have killed, by difficulty.")
    HideCells(0)
    local list = {}
    for _, b in pairs(bests or {}) do list[#list + 1] = b end
    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    local headers = { "Boss", "Best DPS", "When", "Best total", "Kills" }
    local widths = { 0, 1, 2, 3, 5 }
    for k, h in ipairs(headers) do Cell(0, widths[k] + 1):SetText(h) end
    for i, b in ipairs(list) do
        if 40 + (i + 1) * 16 > detail:GetHeight() then break end
        local c1 = Cell(i, 1)
        c1:SetText(b.name or "?")
        c1:SetTextColor(1, 1, 1)
        Cell(i, 2):SetText(Abbrev(b.dps))
        Cell(i, 3):SetText(b.dpsWhen and date("%m/%d", b.dpsWhen) or "")
        Cell(i, 4):SetText(Abbrev(b.total))
        Cell(i, 6):SetText(tostring(b.kills or 1))
    end
    if #list == 0 then detail.sub:SetText("No boss kills recorded yet -- bests appear after your next kill.") end
end

function History.Render()
    if not (win and win:IsShown()) then return end
    for key, b in pairs(tabBtns) do
        b.text:SetTextColor(Rgb(key == state.tab and C.accent or C.textDim))
    end
    RenderList()
    LayoutColumns()
    if state.tab == "bests" then RenderBests() else RenderFight() end
end

function History.OnNewFight()
    if win and win:IsShown() then History.Render() end
end

local function Build()
    if win then return end
    local db = (type(DPSReportDB) == "table") and DPSReportDB or {}
    db.history = db.history or {}
    local place = db.history

    win = CreateFrame("Frame", "DPSReportHistoryFrame", UIParent, "BackdropTemplate")
    win:SetSize(place.w or 760, place.h or 380)
    if place.point then
        win:SetPoint(place.point, UIParent, place.rel or place.point, place.x or 0, place.y or 0)
    else
        win:SetPoint("CENTER")
    end
    -- HIGH, and to the front when clicked: on MEDIUM, unit frames and
    -- cooldown icons drew over it (user screenshot 2026-10-22).
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:SetResizable(true)
    if win.SetResizeBounds then win:SetResizeBounds(700, 240, 1400, 900) end
    win:EnableMouse(true)
    ns.ApplyBackdrop(win)
    tinsert(UISpecialFrames, "DPSReportHistoryFrame")

    local function SavePlace()
        local point, _, rel, x, y = win:GetPoint(1)
        place.point, place.rel, place.x, place.y = point, rel, x, y
        place.w, place.h = win:GetWidth(), win:GetHeight()
    end

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
    name:SetText("Fight History")
    name:SetTextColor(Rgb(C.accent))

    local fightsTab = TextButton(title, "Fights", function() state.tab = "fights" History.Render() end)
    fightsTab:SetPoint("LEFT", name, "RIGHT", 14, 0)
    local bestsTab = TextButton(title, "Personal bests", function() state.tab = "bests" History.Render() end)
    bestsTab:SetPoint("LEFT", fightsTab, "RIGHT", 4, 0)
    tabBtns.fights, tabBtns.bests = fightsTab, bestsTab
    local close = TextButton(title, "X", function() win:Hide() end)
    close:SetPoint("RIGHT", -2, 0)

    -- The fight list.
    local sf = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    -- Search: narrows the list as you type (see Filtered).
    local search = CreateFrame("EditBox", nil, win, "BackdropTemplate")
    search:SetSize(250, 20)
    search:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 6, -6)
    ns.ApplyBackdrop(search, C.control, C.border)
    search:SetFontObject(GameFontHighlightSmall)
    search:SetTextInsets(6, 6, 0, 0)
    search:SetAutoFocus(false)
    local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 6, 0)
    hint:SetText("Search: boss, dungeon, +level, heroic, wipe...")
    search:SetScript("OnTextChanged", function(self)
        state.filter = self:GetText()
        hint:SetShown(state.filter == "")
        History.Render()
    end)
    search:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    sf:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -6)
    sf:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 6, 8)
    sf:SetWidth(250)
    listChild = CreateFrame("Frame", nil, sf)
    listChild:SetSize(250, 1)
    sf:SetScrollChild(listChild)
    listChild.empty = listChild:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    listChild.empty:SetPoint("TOPLEFT", 4, -4)
    listChild.empty:SetWidth(240)
    listChild.empty:SetJustifyH("LEFT")
    listChild.empty:SetText("No fights recorded yet. Every fight of 5 seconds or more is kept from now on.")

    -- The detail pane.
    detail = CreateFrame("Frame", nil, win)
    detail:SetPoint("TOPLEFT", sf, "TOPRIGHT", 28, 0)
    detail:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 8)
    detail:SetScript("OnSizeChanged", function() History.Render() end)
    detail.title = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detail.title:SetPoint("TOPLEFT", 0, 0)
    detail.sub = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    detail.sub:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -4)
    detail.sub:SetPoint("RIGHT", detail, "RIGHT", 0, 0)
    detail.sub:SetJustifyH("LEFT")
    detail.sub:SetWordWrap(false)

    local grip = CreateFrame("Button", nil, win)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetScript("OnMouseDown", function() win:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() win:StopMovingOrSizing() SavePlace() History.Render() end)

    win:SetScript("OnShow", History.Render)
    win:Hide()
end

function DPSReport_ToggleHistory()
    Build()
    if win:IsShown() then
        win:Hide()
    else
        local history = Store() or {}
        state.selected = state.selected or history[#history]
        win:Show()
    end
end

SLASH_DPSREPORTHISTORY1 = "/dpshistory"
SlashCmdList.DPSREPORTHISTORY = DPSReport_ToggleHistory

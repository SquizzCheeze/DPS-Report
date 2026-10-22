-- DPSReport_History.lua -- fight history, comparing fights, personal bests
-- (2026-10-22).
--
-- Every fight's END totals, read from C_DamageMeter's Current session just
-- after combat -- when they are plain (/dpsprobe: everything is secret DURING
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

local function Store()
    if type(DPSReportCharDB) ~= "table" then return nil, nil end
    DPSReportCharDB.fightHistory = DPSReportCharDB.fightHistory or {}
    DPSReportCharDB.personalBests = DPSReportCharDB.personalBests or {}
    return DPSReportCharDB.fightHistory, DPSReportCharDB.personalBests
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

-- Read the finished fight's totals; nil while the session is still secret.
local function ReadTotals()
    local players, any = {}, false
    for _, m in ipairs(METERS) do
        local ok, s = pcall(C_DamageMeter.GetCombatSessionFromType,
            Enum.DamageMeterSessionType.Current, Enum.DamageMeterType[m.type])
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
            return nil   -- still restricted: Finalise retries
        end
    end
    if not any then return nil end
    local list = {}
    for _, p in pairs(players) do list[#list + 1] = p end
    table.sort(list, function(a, b) return a.d > b.d end)
    return list
end

local function CheckBest(f)
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
        print(PREFIX .. string.format("New personal best on %s: %s DPS (was %s).", b.name, Abbrev(dps), Abbrev(b.dps)))
        b.dps, b.dpsWhen = dps, f.when
    end
    if me.d > (b.total or 0) then b.total, b.totalWhen = me.d, f.when end
end

local function Finalise(f, tries)
    local list = ReadTotals()
    if not list then
        if tries < 6 then C_Timer.After(1, function() Finalise(f, tries + 1) end) end
        return
    end
    local ok, dur = pcall(C_DamageMeter.GetSessionDurationSeconds, Enum.DamageMeterSessionType.Current)
    dur = ok and Plain(dur)
    f.duration = (type(dur) == "number" and dur > 0) and dur or f.wall
    if f.duration < MIN_SECONDS then return end
    f.players = list
    f.name = FightName(f)
    local history = Store()
    if not history then return end
    history[#history + 1] = f
    while #history > MAX_FIGHTS do table.remove(history, 1) end
    CheckBest(f)
    if ns.History.OnNewFight then ns.History.OnNewFight() end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("ENCOUNTER_START")
ev:RegisterEvent("ENCOUNTER_END")
ev:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
    if event == "ENCOUNTER_START" then
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
        if f.wall < MIN_SECONDS then return end
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

local function RenderList()
    local history = Store() or {}
    local n = #history
    for i = 1, math.max(n, #listRows) do
        local row = listRows[i]
        local f = history[n - i + 1]      -- newest first
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
                Clock(f.duration), dps and ("  " .. Abbrev(dps)) or ""))
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
    detail.sub:SetText(string.format("%s   %s   %s%s", date("%Y-%m-%d %H:%M", f.when), f.zone or "", Clock(f.duration),
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
    sf:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 6, -6)
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

-- DPSReport_Probe.lua -- a TEMPORARY diagnostic (/dpsprobe), 2026-10-21.
--
-- Two proof-of-concept tests from the "Rival" wishlist, measured before
-- anything is built on them:
--
--   1. THREAT NUMBERS (a ranked threat meter). For each group member against
--      your target: are UnitDetailedThreatSituation's five returns and
--      UnitThreatPercentageOfLead plain, secret or nil? And can a secret threat
--      percentage still be DRAWN (StatusBar:SetValue, SetFormattedText)? The
--      status call SquizzFrames' aggro indicators use, UnitThreatSituation with
--      no mob, is sampled too as a control: the user has seen those work in
--      keys and raids.
--
--   2. GRAPH SAMPLES (a saved DPS/HPS graph). In combat, read the Current
--      damage session every second and KEEP some raw values. After combat, at
--      +0.5s, +3s and +10s, test whether those stored values have become usable
--      (still secret? tostring? arithmetic?). Also: is the session duration
--      readable in combat, and does a secret total go into a StatusBar?
--
-- Counts are bucketed by the C_RestrictedActions restrictions in force plus
-- the instance type, and saved in DPSReportDB.probe so they can be read
-- straight from the SavedVariables file. Inert until switched on; stays on
-- across reloads until off. Nothing here touches a Blizzard frame: the only
-- widgets written are our own hidden bar and text.
--
-- REMOVE this file and its .toc line once the questions are answered.


local THREAT_INTERVAL = 0.25
local METER_INTERVAL = 1.0
local MAX_STORED = 40         -- raw meter values kept per fight
local MAX_ERRORS = 12
local AFTER = {0.5, 3, 10}    -- seconds after combat to re-test stored values

local RESTRICTIONS = {"Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map"}

local function IsSecret(v)
    if issecretvalue and issecretvalue(v) then return true end
    if issecrettable and issecrettable(v) then return true end
    return false
end

-- The secret test comes first: it is the one check that is always safe.
local function Classify(v)
    if IsSecret(v) then return "secret" end
    if v == nil then return "nil" end
    return "plain"
end

local function DB()
    if type(DPSReportDB) ~= "table" then return nil end
    DPSReportDB.probe = DPSReportDB.probe or {}
    local db = DPSReportDB.probe
    db.contexts = db.contexts or {}
    db.errors = db.errors or {}
    return db
end

local function ContextKey()
    local parts = {}
    local RA, types = C_RestrictedActions, Enum and Enum.AddOnRestrictionType
    if RA and RA.IsAddOnRestrictionActive and types then
        for _, name in ipairs(RESTRICTIONS) do
            local t = types[name]
            if t ~= nil and RA.IsAddOnRestrictionActive(t) then parts[#parts + 1] = name end
        end
    end
    if #parts == 0 and InCombatLockdown() then parts[1] = "lockdown only" end
    local _, instanceType = GetInstanceInfo()
    local where = (type(instanceType) == "string" and instanceType ~= "") and instanceType or "?"
    if #parts == 0 then return where .. ": no restriction" end
    return where .. ": " .. table.concat(parts, "+")
end

local function Context(db, key)
    local c = db.contexts[key]
    if not c then
        c = {}
        db.contexts[key] = c
    end
    return c
end

local function Bump(c, field)
    c[field] = (c[field] or 0) + 1
end

local function NoteError(db, where, err)
    if #db.errors >= MAX_ERRORS then return end
    local msg = where .. ": " .. tostring(err)
    for _, e in ipairs(db.errors) do if e == msg then return end end
    db.errors[#db.errors + 1] = msg
end

-- Our own hidden widgets: the display half of each test.
local holder = CreateFrame("Frame", nil, UIParent)
holder:Hide()
local bar = CreateFrame("StatusBar", nil, holder)
bar:SetMinMaxValues(0, 100)
local text = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")

local function Draw(c, field, value)
    Bump(c, field .. "Bar." .. (pcall(bar.SetValue, bar, value) and "ok" or "refused"))
    Bump(c, field .. "Text." .. (pcall(text.SetFormattedText, text, "%.0f", value) and "ok" or "refused"))
end

local function GroupUnits()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end
    return units
end

-----------------------------------------------------------------------
-- Test 1: threat
-----------------------------------------------------------------------

local function SampleThreat(db, c)
    if not (UnitExists("target") and UnitCanAttack("player", "target")) then return end
    Bump(c, "threatSamples")
    for _, unit in ipairs(GroupUnits()) do
        if UnitExists(unit) then
            local ok, tanking, status, scaled, raw, value = pcall(UnitDetailedThreatSituation, unit, "target")
            if not ok then
                Bump(c, "detailed.error")
                NoteError(db, "UnitDetailedThreatSituation", tanking)
            else
                Bump(c, "isTanking." .. Classify(tanking))
                Bump(c, "status." .. Classify(status))
                Bump(c, "scaledPercent." .. Classify(scaled))
                Bump(c, "rawPercent." .. Classify(raw))
                Bump(c, "threatValue." .. Classify(value))
                if IsSecret(scaled) or scaled ~= nil then Draw(c, "threatPercent", scaled) end
            end
            local okL, lead = pcall(UnitThreatPercentageOfLead, unit, "target")
            if okL then Bump(c, "percentOfLead." .. Classify(lead)) else NoteError(db, "UnitThreatPercentageOfLead", lead) end
            local okS, vs = pcall(UnitThreatSituation, unit, "target")
            if okS then Bump(c, "situationVsTarget." .. Classify(vs)) else NoteError(db, "UnitThreatSituation(target)", vs) end
            -- Control: the call SquizzFrames' aggro border makes.
            local okA, any = pcall(UnitThreatSituation, unit)
            if okA then Bump(c, "situationAny." .. Classify(any)) else NoteError(db, "UnitThreatSituation", any) end
        end
    end
end

-----------------------------------------------------------------------
-- Test 2: graph samples
-----------------------------------------------------------------------

local stored = {}       -- this fight's raw meter values, possibly secret
local fightKey          -- the context they were taken in

local function SampleMeter(db, c, key)
    local ST, MT = Enum.DamageMeterSessionType, Enum.DamageMeterType
    local ok, s = pcall(C_DamageMeter.GetCombatSessionFromType, ST.Current, MT.DamageDone)
    if not ok then
        Bump(c, "session.error")
        NoteError(db, "GetCombatSessionFromType", s)
        return
    end
    Bump(c, "meterSamples")
    Bump(c, "session." .. Classify(s))
    local okD, d = pcall(C_DamageMeter.GetSessionDurationSeconds, ST.Current)
    if okD then Bump(c, "durationCall." .. Classify(d)) else NoteError(db, "GetSessionDurationSeconds", d) end
    if type(s) ~= "table" or IsSecret(s) then return end
    Bump(c, "sessionTotal." .. Classify(s.totalAmount))
    Bump(c, "sessionDuration." .. Classify(s.durationSeconds))
    local sources = s.combatSources
    Bump(c, "sources." .. Classify(sources))
    if type(sources) ~= "table" or IsSecret(sources) then return end
    fightKey = key
    for i, e in ipairs(sources) do
        if i > 5 then break end
        Bump(c, "sourceName." .. Classify(e.name))
        Bump(c, "sourceGUID." .. Classify(e.sourceGUID))
        Bump(c, "sourceTotal." .. Classify(e.totalAmount))
        Bump(c, "sourceRate." .. Classify(e.amountPerSecond))
        if IsSecret(e.totalAmount) then Draw(c, "graphTotal", e.totalAmount) end
        if #stored < MAX_STORED then
            if IsSecret(e.totalAmount) or e.totalAmount ~= nil then stored[#stored + 1] = e.totalAmount end
            if IsSecret(e.amountPerSecond) or e.amountPerSecond ~= nil then stored[#stored + 1] = e.amountPerSecond end
        end
    end
end

-- After combat: have the values kept during the fight become usable?
local function TestStored(delay)
    local db = DB()
    if not db or #stored == 0 then return end
    local c = Context(db, (fightKey or "?") .. "  [stored, +" .. delay .. "s after combat]")
    for _, v in ipairs(stored) do
        Bump(c, "stillSecret." .. (IsSecret(v) and "yes" or "no"))
        Bump(c, "tostring." .. (pcall(tostring, v) and "ok" or "refused"))
        Bump(c, "arithmetic." .. (pcall(function() return v + 0 end) and "ok" or "refused"))
    end
end

-----------------------------------------------------------------------
-- Driver, events, commands
-----------------------------------------------------------------------

local running = false
local threatWait, meterWait = 0, 0

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(_, elapsed)
    if not InCombatLockdown() then return end
    local db = DB()
    if not db then return end
    threatWait, meterWait = threatWait - elapsed, meterWait - elapsed
    if threatWait > 0 and meterWait > 0 then return end
    local key = ContextKey()
    local c = Context(db, key)
    if threatWait <= 0 then
        threatWait = THREAT_INTERVAL
        SampleThreat(db, c)
    end
    if meterWait <= 0 then
        meterWait = METER_INTERVAL
        SampleMeter(db, c, key)
    end
end)

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        wipe(stored)
        fightKey = nil
        threatWait, meterWait = 0, 0
    elseif event == "PLAYER_REGEN_ENABLED" then
        for _, delay in ipairs(AFTER) do
            C_Timer.After(delay, function() if running then TestStored(delay) end end)
        end
    end
end)

local function SetRunning(on)
    running = on and true or false
    if running then
        events:RegisterEvent("PLAYER_REGEN_DISABLED")
        events:RegisterEvent("PLAYER_REGEN_ENABLED")
        driver:Show()
    else
        events:UnregisterAllEvents()
        driver:Hide()
    end
end

local KINDS = {"plain", "secret", "nil", "error", "ok", "refused", "yes", "no"}

local function Report()
    local db = DB()
    if not db then return end
    print("|cFF33CC99DPS Report probe|r -- " .. (db.on and "RUNNING" or "off"))
    local keys = {}
    for k in pairs(db.contexts) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then print("  Nothing recorded yet.") end
    for _, key in ipairs(keys) do
        local c = db.contexts[key]
        print("|cFFFFD100" .. key .. "|r")
        local fields = {}
        for k in pairs(c) do
            local f = k:match("^(.-)%.[a-z]+$")
            if f then fields[f] = true elseif type(c[k]) == "number" then print("    " .. k .. ": " .. c[k]) end
        end
        local names = {}
        for f in pairs(fields) do names[#names + 1] = f end
        table.sort(names)
        for _, f in ipairs(names) do
            local bits = {}
            for _, kind in ipairs(KINDS) do
                local n = c[f .. "." .. kind]
                if n then bits[#bits + 1] = kind .. "=" .. n end
            end
            print("    " .. f .. ": " .. table.concat(bits, "  "))
        end
    end
    for _, e in ipairs(db.errors) do print("|cFFFF5555  error|r " .. e) end
    print("  -- end of report --")
end

SLASH_DPSREPORTPROBE1 = "/dpsprobe"
SlashCmdList.DPSREPORTPROBE = function(msg)
    local db = DB()
    if not db then
        print("DPS Report probe: SavedVariables not loaded yet.")
        return
    end
    msg = strtrim(msg or ""):lower()
    if msg == "on" then
        db.on = true
        SetRunning(true)
        print("|cFF33CC99DPS Report probe|r on. Fight normally -- open world, key trash, a key boss, a raid "
            .. "boss -- then /reload and /dpsprobe report.")
    elseif msg == "off" then
        db.on = false
        SetRunning(false)
        print("DPS Report probe off. Counts kept; /dpsprobe report.")
    elseif msg == "clear" then
        wipe(db.contexts)
        wipe(db.errors)
        print("DPS Report probe counts cleared.")
    elseif msg == "report" then
        Report()
    else
        print("DPS Report probe: /dpsprobe on | off | report | clear")
    end
end

-- Stay on across a /reload once switched on.
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
    local db = DB()
    if db and db.on then SetRunning(true) end
end)

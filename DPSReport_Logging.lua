-- DPSReport_Logging.lua -- automatic combat logging in dungeons and raids
-- (2026-10-22). Feeds the key/raid exporter in Tools.
--
-- Off by default (settings.autoCombatLog, Mythic+ page): many players already
-- log through Archon / Warcraft Logs, which turn logging on themselves.
--
-- OWNERSHIP is the whole design. We only ever stop logging WE started:
--   * entering a dungeon or raid with logging already on (Archon, /combatlog,
--     another addon) -> leave it alone; it is theirs.
--   * we turned it on, and it is found OFF later in the same visit -> someone
--     stopped it on purpose; give up ownership and do not restart it until we
--     have left and come back.
--   * leaving the instance -> stop it only if we still own it.
-- Ownership is saved (DPSReportDB.autoLogOwned) so a /reload inside the
-- instance keeps it.
--
-- LoggingCombat is undocumented in the generated API docs but live on Retail:
-- Blizzard's own /combatlog, BigWigs and Details all call it.

local _, ns = ...

local PREFIX = "|cff00ccff[DPSReport]|r "
local suppressed = false     -- someone stopped our logging this visit
local advancedWarned = false

local function Owned() return type(DPSReportDB) == "table" and DPSReportDB.autoLogOwned == true end
local function SetOwned(on)
    if type(DPSReportDB) == "table" then DPSReportDB.autoLogOwned = on and true or nil end
end

local function Logging()
    local ok, on = pcall(LoggingCombat)
    return ok and on and true or false
end

local function SetLogging(on)
    pcall(LoggingCombat, on and true or false)
end

local function InDungeonOrRaid()
    local inside, kind = IsInInstance()
    return inside and (kind == "party" or kind == "raid")
end

function DPSReport_ApplyAutoCombatLog()
    local settings = ns.GetSettings and ns.GetSettings()
    local enabled = settings and settings.autoCombatLog == true

    -- Switched off in the options: stop at once, if the logging is ours.
    if not enabled then
        if Owned() then
            if Logging() then SetLogging(false) end
            SetOwned(false)
            print(PREFIX .. "Combat logging stopped.")
        end
        return
    end

    if InDungeonOrRaid() then
        if Owned() then
            if not Logging() then
                -- Stopped by someone else during this visit: theirs now.
                SetOwned(false)
                suppressed = true
            end
            return
        end
        if suppressed or Logging() then return end   -- not ours to manage
        SetLogging(true)
        if Logging() then
            SetOwned(true)
            print(PREFIX .. "Combat logging on for this instance (Logs folder).")
            if not advancedWarned and not GetCVarBool("advancedCombatLogging") then
                advancedWarned = true
                print(PREFIX .. "Tip: turn on Advanced Combat Logging (Options > Network) -- the "
                    .. "key/raid exporter needs it to credit pets and read specs.")
            end
        end
    else
        suppressed = false
        if Owned() then
            if Logging() then SetLogging(false) end
            SetOwned(false)
            print(PREFIX .. "Combat logging stopped (left the instance).")
        end
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("CHALLENGE_MODE_START")
ev:SetScript("OnEvent", function()
    -- A moment's delay: settings load and instance info settle on login.
    C_Timer.After(1, DPSReport_ApplyAutoCombatLog)
end)

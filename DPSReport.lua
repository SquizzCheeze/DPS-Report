-------------------------------------------------------------------------------
-- DPSReport: live damage meters and chat reporting built on Blizzard's
-- C_DamageMeter API (no combat log parsing).
--
-- /dps  - opens the settings panel. The slash command takes no arguments;
--         reporting is driven from the meter windows, the quick-report widget,
--         and the end-of-dungeon auto-announce configured under Auto Report.
--
-- See README.md for the feature tour and CLAUDE.md for the code tour, notably
-- the combat taint / secret-value rules that shape how values are read.
-------------------------------------------------------------------------------

local ADDON_NAME = "DPSReport"
local DEFAULT_TOP_COUNT = 5

-- Forward declarations
local reportWidget
local DPSMeter
local SnapshotSegment
local SnapshotMythicRun
local AggregateDeathEntries
local METER_MODE_MAP
local DR_COLORS
local ApplyDRBackdrop
local ApplyClassAccent
local settings


-- Per-character key (populated on PLAYER_LOGIN)
local charKey

-- Get the active profile name for the current character (per-character, defaults to "Default")
local function GetActiveProfile()
    if charKey and DPSReportDB and DPSReportDB.charData then
        local cd = DPSReportDB.charData[charKey]
        if cd and cd.activeProfile then return cd.activeProfile end
    end
    return "Default"
end

-- Set the active profile name for the current character
local function SetActiveProfile(profName)
    if not charKey or not DPSReportDB then return end
    if not DPSReportDB.charData then DPSReportDB.charData = {} end
    if not DPSReportDB.charData[charKey] then DPSReportDB.charData[charKey] = {} end
    DPSReportDB.charData[charKey].activeProfile = profName
end

-- Addon communication
local ADDON_MSG_PREFIX = "DPSReport"
local nicknameCache = {}  -- "Name-Realm" -> "Nickname" (received from others)
local nicknameBroadcastTimer = nil  -- debounce handle for GROUP_ROSTER_UPDATE re-broadcasts

-- Roster name cache: maps classFilename -> plain "Name-Realm" for group members.
-- Used to resolve secret/tainted name strings during combat.
local rosterNameCache = {}  -- classFilename -> "Name-Realm" (plain) or nil (ambiguous)

-- Spec-based name cache: maps specIconID -> plain "Name-Realm".
-- More granular than class-based: handles same-class players with different specs.
-- Populated from roster (via inspect) and from laundered API data after each combat.
local specNameCache = {}  -- specIconID (number) -> "Name-Realm" (plain) or nil (ambiguous)

-- GUID-based name cache: maps UnitGUID -> short plain name (no realm).
local guidNameCache = {}  -- GUID (string) -> short name (string)

-- Spec display name cache: maps specIconID -> spec name (e.g., "Fire", "Frost").
-- Never wiped -- spec names are constants and don't need re-resolution.
local specIconToSpecName = {}  -- specIconID -> spec display name string

-- Spec role cache: maps specIconID -> "TANK" / "HEALER" / "DAMAGER".
-- Filled from the same GetSpecializationInfo* calls that fill specIconToSpecName,
-- so it costs nothing extra. Snapshot entries carry specIconID, which makes this
-- the only role source that still works after the run, when the units are gone.
-- Never wiped -- a spec's role is a constant.
local specIconToRole = {}  -- specIconID -> role string

-- Role by short name, from UnitGroupRolesAssigned. Fallback for players whose
-- spec was never resolved (inspect is out-of-combat only and can miss people).
-- Wiped and rebuilt with the roster, since roles change between groups.
local roleByName = {}  -- short name -> role string

-- Persistent seen-name cache: GUID -> short plain name.
-- Keyed by the player's unique GUID string (e.g. "Player-1234-ABCDEF12").
-- Never wiped during a session; persisted to DPSReportDB.seenNames across reloads.
-- Lets us show real names for players no longer in the group (e.g. old overall data).
-- GUIDs are globally unique per character, so no cross-player collision is possible.
local seenNameCache = {}  -- GUID (string) -> short name (string)

local function RefreshRosterCache()
    wipe(rosterNameCache)
    wipe(guidNameCache)
    wipe(roleByName)
    local seen = {}     -- track which classes we've seen (for collision detection)
    local specSeen = {} -- track which specIconIDs we've seen (for collision detection)

    -- Add self
    local selfClass = select(2, UnitClass("player"))
    if selfClass and not issecretvalue(selfClass) and charKey then
        rosterNameCache[selfClass] = charKey
        seen[selfClass] = true
    end
    -- Cache own GUID -> short name
    local selfGUID = UnitGUID("player")
    if selfGUID and not issecretvalue(selfGUID) and charKey then
        local shortSelf = charKey:match("^[^-]+") or charKey
        guidNameCache[selfGUID] = shortSelf
    end
    -- Cache own specIconID
    local currentSpec = GetSpecialization and GetSpecialization()
    if currentSpec then
        local _, specName, _, icon, specRole = GetSpecializationInfo(currentSpec)
        if icon and charKey then
            specNameCache[icon] = charKey
            specSeen[icon] = true
            if specName then specIconToSpecName[icon] = specName end
            if specRole then specIconToRole[icon] = specRole end
        end
    end

    local numGroup = GetNumGroupMembers()
    if numGroup > 1 then
        local prefix, count
        if IsInRaid() then
            prefix = "raid"
            count = numGroup
        else
            prefix = "party"
            count = numGroup - 1
        end

        local realmName = GetRealmName()
        for i = 1, count do
            local unit = prefix .. i
            if not UnitIsUnit(unit, "player") then
                local name, realm = UnitName(unit)
                -- UnitName/UnitClass/UnitGUID/GetInspectSpecialization are all identity-
                -- restricted: each returns a secret value when the unit isn't player-
                -- controlled (e.g. a mind-controlled group member), and secrets throw when
                -- concatenated, compared, or used as a table key. Guard each one separately
                -- rather than once up front: as of 12.1 UnitName is governed by
                -- SecretWhenUnitNameIdentityRestricted (which has a PvP exception) while the
                -- others use SecretWhenUnitIdentityRestricted, so a plain name does not
                -- imply a plain class, GUID, or spec.
                if name and not issecretvalue(name) then
                    local cls = select(2, UnitClass(unit))
                    if issecretvalue(cls) then cls = nil end
                    if issecretvalue(realm) then realm = nil end
                    local fullName = (realm and realm ~= "") and (name .. "-" .. realm) or (name .. "-" .. realmName)
                    if cls then
                        if seen[cls] then
                            rosterNameCache[cls] = nil  -- class collision: two players same class
                        else
                            rosterNameCache[cls] = fullName
                            seen[cls] = true
                        end
                    end
                    -- Cache GUID -> short name (no realm)
                    local guid = UnitGUID(unit)
                    if guid and not issecretvalue(guid) then
                        guidNameCache[guid] = name
                    end
                    -- Cache by specIconID — more granular than class, handles same-class players
                    -- specSeen collision detection handles the same-class same-spec case.
                    -- Assigned group role: plain, needs no inspect, and is the
                    -- fallback when a member's spec never resolves. Keyed by short
                    -- name to match the names snapshot entries carry.
                    local assignedRole = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
                    if assignedRole and not issecretvalue(assignedRole)
                        and assignedRole ~= "NONE" then
                        roleByName[name] = assignedRole
                    end
                    local specID = GetInspectSpecialization and GetInspectSpecialization(unit)
                    if specID and not issecretvalue(specID) and specID > 0 then
                        local _, specName, _, icon, specRole = GetSpecializationInfoByID(specID)
                        if icon then
                            if specName then specIconToSpecName[icon] = specName end
                            if specRole then specIconToRole[icon] = specRole end
                            if specSeen[icon] then
                                specNameCache[icon] = nil  -- spec collision: two players same spec
                            else
                                specNameCache[icon] = fullName
                                specSeen[icon] = true
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- Inspection queue (resolves spec icons for uninspected raid members)
-- NotifyInspect is blocked during combat, so the queue runs out-of-combat only.
-- ============================================================================
local inspectQueue          = {}
local inspectActive         = false
local inspectActiveUnit     = nil  -- unit token currently being inspected
local ilvlCache             = {}   -- GUID → { ilvl, time }
local pendingIlvlCallbacks  = {}   -- GUID → function(ilvl)
local wantIlvlGUIDs         = {}   -- GUIDs we want ilvl for but couldn't inspect (out of range)

local function ProcessInspectQueue()
    if inspectActive or #inspectQueue == 0 then return end
    if InCombatLockdown() then return end
    local unit = table.remove(inspectQueue, 1)
    if UnitExists(unit) and CanInspect(unit) then
        inspectActive     = true
        inspectActiveUnit = unit
        NotifyInspect(unit)
        -- Safety timer: clear flag if INSPECT_READY never fires (e.g. target out of range)
        C_Timer.After(2, function()
            if inspectActive then
                inspectActive     = false
                inspectActiveUnit = nil
                ProcessInspectQueue()
            end
        end)
    else
        -- Unit gone or can't be inspected; move on immediately
        ProcessInspectQueue()
    end
end

local function QueueGroupInspections()
    -- Always refresh caches and update meters — UnitName/UnitClass work both in and out
    -- of combat, since their secrecy is unit-based (identity restriction), not combat-based.
    -- They still return secrets for units that aren't player-controlled, so RefreshRosterCache
    -- guards each result with issecretvalue rather than assuming plain values.
    RefreshRosterCache()
    if DPSMeter and DPSMeter.meters then
        for _, meter in ipairs(DPSMeter.meters) do
            if meter.frame and meter.frame:IsShown() then
                meter:LoadFromAPI()
                meter:RefreshDisplay()
            end
        end
    end
    -- NotifyInspect is blocked during combat; skip queuing until we're out.
    if InCombatLockdown() then return end
    local numGroup = GetNumGroupMembers()
    if numGroup <= 1 then return end
    local prefix = IsInRaid() and "raid" or "party"
    local count  = IsInRaid() and numGroup or (numGroup - 1)
    for i = 1, count do
        local unit = prefix .. i
        if not UnitIsUnit(unit, "player") and UnitExists(unit) then
            local specID = GetInspectSpecialization and GetInspectSpecialization(unit)
            -- A secret specID means the unit is identity-restricted, so inspecting it can
            -- never resolve a spec — skip it instead of queuing work that cannot succeed.
            if not issecretvalue(specID) and (not specID or specID == 0) then
                table.insert(inspectQueue, unit)
            end
        end
    end
    ProcessInspectQueue()
end

-- ============================================================================
-- Death tracking (feign-death aware)
-- ============================================================================
-- C_DamageMeter's Deaths metric counts Feign Death as a real death: the hunter
-- is flagged dead for the duration and the session records an entry for it, so
-- a hunter who never actually died routinely reports five or six.
--
-- Polling UnitIsDeadOrGhost() per group unit and edge-detecting the false->true
-- transition does not have that problem -- a feigning hunter reads as alive
-- there -- and it keeps working mid-key, where C_DamageMeter's own values are
-- secret. Polling is also the only option left: the combat log is gone from the
-- addon API in 12.0, and UNIT_DIED never fired reliably for off-screen members.
-- Squizzumables' M+ death tally is built the same way and is where the approach
-- was proven.
--
-- So for deaths we do not correct the API's list -- mid-key its rows carry no
-- readable name or GUID to match against, so correcting row by row is
-- impossible. We source the list ourselves and substitute it wholesale, and
-- fall back to the API only when we cannot prove our own tally is complete.
local DeathTracker = {
    overall  = {},   -- GUID -> deaths since the Overall session was reset
    current  = {},   -- GUID -> deaths in the combat currently in progress
    run      = {},   -- GUID -> deaths since the key started (Blizzard's scope)
    info     = {},   -- GUID -> { name = full name, class = classFilename }
    wasDead  = {},   -- GUID -> true while this death has already been counted
    armed    = {},   -- scope -> true once a poll has run since that scope reset
    startedAt = {},  -- scope -> GetTime() when the current tally began
    keyDeaths = nil, -- GetDeathCount() captured at CHALLENGE_MODE_COMPLETED
    runFromStart = false, -- true when we were polling from CHALLENGE_MODE_START
    keepAlive = false,
    ticker   = nil,
}

local DEATH_SCOPES = { "overall", "current", "run" }

local function IsKeyActive()
    return (C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
        and C_ChallengeMode.IsChallengeModeActive()) and true or false
end

function DeathTracker:Poll()
    local numGroup = GetNumGroupMembers()
    local prefix, count
    if numGroup > 1 then
        prefix = IsInRaid() and "raid" or "party"
        count  = IsInRaid() and numGroup or (numGroup - 1)
    end
    -- i == 0 is "player": in a party the player has no partyN token, and in a
    -- raid they have both. Duplicates are harmless -- everything is keyed by
    -- GUID, and wasDead stops the second visit counting again.
    for i = 0, (count or 0) do
        local unit = (i == 0) and "player" or (prefix .. i)
        -- UnitIsPlayer keeps pets and guardians out: they die constantly and
        -- are not people the report should be naming.
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local guid  = UnitGUID(unit)
            local dead  = UnitIsDeadOrGhost(unit)
            local feign = UnitIsFeignDeath(unit)
            -- These read plain for group members in practice, keys included --
            -- but an identity-restricted unit would hand back secrets, and
            -- comparing one throws, so skip a unit we cannot read rather than
            -- guess at it. PrintDiagnostics reports which ones those were.
            if guid and not issecretvalue(guid)
               and not issecretvalue(dead) and not issecretvalue(feign) then
                local uname, realm = UnitName(unit)
                if uname and not issecretvalue(uname) then
                    if realm and realm ~= "" and not issecretvalue(realm) then
                        uname = uname .. "-" .. realm
                    end
                    local _, classFile = UnitClass(unit)
                    if issecretvalue(classFile) then classFile = nil end
                    self.info[guid] = { name = uname, class = classFile }
                end

                -- UnitIsFeignDeath is belt and braces: a feigning hunter
                -- already reads as alive above. It costs nothing and covers us
                -- if that ever stops being true.
                if dead and not feign then
                    if not self.wasDead[guid] then
                        self.wasDead[guid] = true
                        self.overall[guid] = (self.overall[guid] or 0) + 1
                        self.current[guid] = (self.current[guid] or 0) + 1
                        self.run[guid]     = (self.run[guid]     or 0) + 1
                    end
                else
                    self.wasDead[guid] = nil
                end
            end
        end
    end

    -- Stamp when a tally started covering its session, so the completeness
    -- tests below can tell later whether it saw the whole thing.
    for _, scope in ipairs(DEATH_SCOPES) do
        if not self.armed[scope] then
            self.startedAt[scope] = GetTime()
            self.armed[scope] = true
        end
    end

    -- Self-healing: an abandoned key never fires CHALLENGE_MODE_COMPLETED, so
    -- drop the keep-alive as soon as the key is gone rather than tick forever.
    if self.keepAlive and not IsKeyActive() then self.keepAlive = false end
end

function DeathTracker:Start()
    -- Poll immediately so anyone alive at the start clears their stale wasDead
    -- flag from a previous fight; without that a player who died, ran back and
    -- died again would only ever be counted once.
    self:Poll()
    if self.ticker then return end
    self.ticker = C_Timer.NewTicker(0.5, function() DeathTracker:Poll() end)
end

function DeathTracker:Stop()
    -- Bail before Poll if we were never started: polling arms the tally, and an
    -- unarmed tally is exactly what tells the callers not to trust it.
    if not self.ticker then return end
    -- Inside a key we keep polling between pulls. Those deaths are what the run
    -- summary reports, and combat in a key stops and starts constantly.
    if self.keepAlive then
        self:Poll()
        return
    end
    self.ticker:Cancel()
    self.ticker = nil
    self:Poll()  -- final sample, so a death in the last half second still lands
end

-- Reset a tally to match a session reset. wasDead is deliberately NOT cleared:
-- someone lying dead across the reset has already been counted, and re-arming
-- their flag would credit them a second death on the next poll.
function DeathTracker:Reset(scope)
    wipe(self[scope])
    self.armed[scope] = false
end

function DeathTracker:Total(scope)
    local n = 0
    for _, v in pairs(self[scope]) do n = n + v end
    return n
end

-- Blizzard's own death counter for the key. It is plain even mid-key, and it is
-- feign-free by construction -- it is what adds the timer penalty, so a
-- feigning hunter would be griefing every key if it counted them. It carries no
-- per-player breakdown, which is why we still tally ourselves; as a *total* it
-- is the proof that our breakdown is not missing anything.
function DeathTracker:KeyDeathCount()
    if IsKeyActive() then
        local ok, n = pcall(C_ChallengeMode.GetDeathCount)
        if ok and n and not issecretvalue(n) and type(n) == "number" then return n end
        return nil
    end
    return self.keyDeaths  -- captured at CHALLENGE_MODE_COMPLETED
end

-- Fallback completeness test for the Overall session outside a key, where there
-- is no GetDeathCount to check against. Watched time is wall clock and session
-- duration counts only combat, so watched >= duration holds comfortably
-- whenever we have been running since the session began, and fails clearly
-- after a /reload mid-run -- where the Overall session survives but our table
-- restarts empty, and trusting it would erase real deaths instead of feigns.
--
-- durationSeconds is on the secret list, and comparing a secret throws. Thrown
-- from here it took the meter's refresh ticker down with it, which is what
-- "deaths stopped updating mid-run" looked like.
function DeathTracker:CoversOverallByDuration()
    if not self.armed.overall or not self.startedAt.overall then return false end
    local ok, dur = pcall(C_DamageMeter.GetSessionDurationSeconds,
        Enum.DamageMeterSessionType.Overall)
    if not ok or not dur or issecretvalue(dur) or type(dur) ~= "number" then
        return false
    end
    return (GetTime() - self.startedAt.overall) + 3 >= dur
end

-- The deaths list for `scope` built from our own tally, or nil meaning "fall
-- back to whatever C_DamageMeter reports". An EMPTY table is a real answer --
-- we watched and nobody died -- so callers must test for nil, not emptiness.
function DeathTracker:BuildEntries(scope)
    local tally
    if scope == "current" then
        -- We reset this and start polling at the pull, so once armed it has
        -- seen the whole combat by construction.
        if not self.armed.current then return nil end
        tally = self.current
    elseif scope == "overall" then
        -- In a key, and for as long as the Overall session still holds only
        -- that key, the run tally IS the overall session.
        if self.armed.run and (self.runFromStart or self.keyDeaths) then
            if not self.runFromStart then
                -- We joined the key late (logged in or reloaded mid-run), so
                -- only Blizzard's own total can say whether we caught all of
                -- it. Short of it, leave the game's counts alone.
                local keyTotal = self:KeyDeathCount()
                if not keyTotal or self:Total("run") < keyTotal then return nil end
            end
            -- Note we do NOT re-check the total when runFromStart: we polled the
            -- whole key, and GetDeathCount can lead our poll by up to one tick,
            -- which would flicker the list back to the API's on every death.
            tally = self.run
        else
            if not self:CoversOverallByDuration() then return nil end
            tally = self.overall
        end
    else
        return nil
    end

    local selfGUID = UnitGUID("player")
    local out = {}
    for guid, n in pairs(tally) do
        if n > 0 then
            local info = self.info[guid]
            local full = info and info.name
            -- `name` must be the SHORT name. SnapshotMythicRun stores every
            -- mode's entries under a short name, and CollectSummaryPlayers keys
            -- its rows off it -- a "Bob-Realm" here would not merge with the
            -- "Bob" the damage list carries, and the summary would rank a
            -- phantom player who did nothing but die.
            local short = full and (full:match("^([^%-]+)") or full) or "?"
            out[#out + 1] = {
                name            = short,
                plainName       = full,
                class           = info and info.class,
                sourceGUID      = guid,
                isPlayer        = (guid == selfGUID),
                displayValue    = n,
                totalAmount     = n,
                amountPerSecond = 0,
            }
        end
    end
    -- pairs() order is undefined, so ties must break on something stable or the
    -- bars shuffle on every refresh.
    table.sort(out, function(a, b)
        if a.totalAmount ~= b.totalAmount then return a.totalAmount > b.totalAmount end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

-- Print what the poll can and cannot see, to your own chat frame only.
--
-- Which units the game lets an addon read is not documented and varies with the
-- restrictions in force, so this is the only way to check it from in game.
function DeathTracker:PrintDiagnostics()
    local function P(s) print("|cff00ccff[DPSReport]|r " .. s) end
    local keyTotal = self:KeyDeathCount()
    P(string.format("Death tracking: poll %s, key active=%s, key deaths=%s, "
        .. "our run total=%d, own list used for Overall=%s",
        self.ticker and "running" or "stopped", tostring(IsKeyActive()),
        keyTotal and tostring(keyTotal) or "n/a", self:Total("run"),
        tostring(self:BuildEntries("overall") ~= nil)))

    local numGroup = GetNumGroupMembers()
    local prefix, count
    if numGroup > 1 then
        prefix = IsInRaid() and "raid" or "party"
        count  = IsInRaid() and numGroup or (numGroup - 1)
    end
    for i = 0, (count or 0) do
        local unit = (i == 0) and "player" or (prefix .. i)
        if UnitExists(unit) then
            local guid  = UnitGUID(unit)
            local dead  = UnitIsDeadOrGhost(unit)
            local feign = UnitIsFeignDeath(unit)
            local uname = UnitName(unit)
            if not uname or issecretvalue(uname) then uname = "?" end

            local blocked = {}
            if not UnitIsPlayer(unit) then blocked[#blocked + 1] = "not a player" end
            if not guid or issecretvalue(guid) then blocked[#blocked + 1] = "guid" end
            if issecretvalue(dead) then blocked[#blocked + 1] = "dead" end
            if issecretvalue(feign) then blocked[#blocked + 1] = "feign" end

            if #blocked == 0 then
                P(string.format("  %s (%s): readable, dead=%s feign=%s, counted run=%d overall=%d current=%d",
                    unit, uname, dead and "yes" or "no", feign and "yes" or "no",
                    self.run[guid] or 0, self.overall[guid] or 0, self.current[guid] or 0))
            else
                P(string.format("  %s (%s): SKIPPED on %s - keeps the game's own count",
                    unit, uname, table.concat(blocked, ", ")))
            end
        end
    end
end

-- ============================================================================
-- Default Settings
-- ============================================================================

local DEFAULT_SETTINGS = {
    defaultType = "dps",
    defaultSession = "current",
    defaultTopCount = 5,
    defaultChannel = "auto",
    showSelfMarker = true,
    showPercentages = true,
    showTotalInHeader = true,
    autoReport = false,
    autoReportDelay = 2,
    autoReportChannel = "party",
    resetOnMythicStart = false,

    -- "summary" = the highlight reel below; "single" = one metric, whole group
    -- ranked highest to lowest. autoReportType only applies to "single", and
    -- its values are METER_MODE_MAP keys (segment mode names), not TYPE_MAP
    -- keys -- a segment is the only thing the auto-report reads.
    autoReportFormat = "summary",
    autoReportType = "dps",

    -- End-of-dungeon summary. Each line is individually toggleable so the
    -- announce can be pared back to just the parts a group cares about.
    -- Flat keys rather than a nested table: LoadSettings fills missing keys by
    -- reference, so a nested default would be shared across every profile.
    autoSummaryHeader     = true,  -- "Dungeon +N completed in MM:SS"
    autoSummaryMVP        = true,
    autoSummaryTopDamage  = true,
    autoSummaryTopHealing = true,
    autoSummaryInterrupts = true,
    autoSummaryDispels    = true,
    autoSummaryAvoidable  = true,
    autoSummaryDeaths     = true,

    shortNames = true,
    widgetShown = true,
    widgetLocked = false,
    -- Meter display
    meterShown     = true,
    meterLocked    = false,
    meterBarHeight = 18,
    meterBgAlpha   = 0.85,  -- frame/background opacity
    meterBarAlpha  = 0.8,   -- bar fill opacity
    pinSelf        = false, -- always show player at bottom of meter
}

local function LoadSettings()
    if not DPSReportDB then DPSReportDB = {} end

    -- Initialise profiles table (account-wide)
    if not DPSReportDB.profiles then
        DPSReportDB.profiles = {}
    end

    -- Migrate legacy account-wide activeProfile into per-character storage
    if DPSReportDB.activeProfile then
        -- If a charKey is available and doesn't have a profile yet, carry it forward
        if charKey then
            if not DPSReportDB.charData then DPSReportDB.charData = {} end
            if not DPSReportDB.charData[charKey] then DPSReportDB.charData[charKey] = {} end
            if not DPSReportDB.charData[charKey].activeProfile then
                DPSReportDB.charData[charKey].activeProfile = DPSReportDB.activeProfile
            end
        end
        DPSReportDB.activeProfile = nil
    end

    -- Migrate pre-profile settings into the Default profile
    if DPSReportDB.settings and not DPSReportDB.profiles["Default"] then
        DPSReportDB.profiles["Default"] = DPSReportDB.settings
        DPSReportDB.settings = nil
    end

    -- Resolve active profile for this character (defaults to "Default")
    local profName = GetActiveProfile()
    if not DPSReportDB.profiles[profName] then
        DPSReportDB.profiles[profName] = CopyTable(DEFAULT_SETTINGS)
    end

    -- Fill missing keys with defaults
    local prof = DPSReportDB.profiles[profName]
    for k, v in pairs(DEFAULT_SETTINGS) do
        if prof[k] == nil then
            prof[k] = v
        end
    end

    -- Migrate legacy "raid" channel to "instance"
    if prof.autoReportChannel == "raid" then
        prof.autoReportChannel = "instance"
    end

    -- autoReportType used to hold TYPE_MAP keys, but the auto-report reads a
    -- segment, which is keyed by METER_MODE_MAP names. "dtaken" has a direct
    -- equivalent; "edamage" has none (enemy damage is never snapshotted), so
    -- fall back to DPS rather than leave a value that can never resolve.
    if prof.autoReportType == "dtaken" then
        prof.autoReportType = "taken"
    elseif prof.autoReportType == "edamage" then
        prof.autoReportType = "dps"
    end
    if prof.defaultChannel == "raid" then
        prof.defaultChannel = "instance"
    end

    -- Initialise nicknames table (account-wide)
    if not DPSReportDB.nicknames then
        DPSReportDB.nicknames = {}
    end
    -- Initialise persistent seen-name cache (account-wide)
    if not DPSReportDB.seenNames then
        DPSReportDB.seenNames = {}
    end

    return prof
end

local function SaveSettings()
    -- Already stored in DPSReportDB.profiles[activeProfile] by reference
end

-- Snapshot current meter frame positions/sizes into settings.meterLayout
local function SaveMeterLayoutToSettings()
    if not settings or not DPSMeter or not DPSMeter.meters then return end
    local layout = {}
    for _, meter in ipairs(DPSMeter.meters) do
        local entry = {
            id      = meter.id,
            mode    = meter.mode,
            session = meter.session,
            snapTo  = (meter.snapTo and next(meter.snapTo)) and CopyTable(meter.snapTo) or nil,
        }
        -- Only snapshot absolute position for free (non-snapped) frames.
        -- Snapped frames are anchored to another frame; their position is
        -- restored by MeterSnapSystem.RestoreAnchors() instead.
        if meter.frame and not (meter.snapTo and meter.snapTo._parent) then
            local point, _, relativePoint, xOfs, yOfs = meter.frame:GetPoint()
            entry.pos = {
                point = point,
                relativePoint = relativePoint,
                x = xOfs,
                y = yOfs,
                width = meter.frame:GetWidth(),
                height = meter.frame:GetHeight(),
            }
        elseif meter.frame then
            -- Still save the size so the frame keeps its dimensions when recreated
            entry.pos = {
                width  = meter.frame:GetWidth(),
                height = meter.frame:GetHeight(),
            }
        end
        table.insert(layout, entry)
    end
    settings.meterLayout = layout
end

-- Apply meterLayout from settings to existing meter frames.
-- Creates missing meters and removes extras to match the profile.
local function ApplyMeterLayoutFromSettings()
    if not DPSMeter then return end
    local layout = settings and settings.meterLayout
    if not layout or #layout == 0 then return end

    -- Build a lookup of saved IDs for quick membership test
    local savedIDs = {}
    for _, saved in ipairs(layout) do
        savedIDs[saved.id] = true
    end

    -- Remove meters that are NOT in the profile layout (iterate in reverse)
    for i = #DPSMeter.meters, 1, -1 do
        local meter = DPSMeter.meters[i]
        if not savedIDs[meter.id] then
            if meter.ticker then meter:StopRefreshTicker() end
            if meter.frame then meter.frame:Hide() end
            if meter.breakdownFrame then meter.breakdownFrame:Hide() end
            if meter.tooltipFrame then meter.tooltipFrame:Hide() end
            table.remove(DPSMeter.meters, i)
        end
    end

    -- Build a lookup of existing meter IDs
    local existingByID = {}
    for _, meter in ipairs(DPSMeter.meters) do
        existingByID[meter.id] = meter
    end

    -- Create missing meters and apply positions
    for _, saved in ipairs(layout) do
        local meter = existingByID[saved.id]
        if not meter then
            -- Create the missing meter
            meter = DPSMeter:NewMeter({
                id      = saved.id,
                mode    = saved.mode or "dps",
                session = saved.session or "current",
            })
            meter:CreateMeterFrame()
            meter:LoadFromAPI()
            meter:RefreshDisplay()
        else
            -- Update mode/session on existing meter if the profile has different values
            local needsRefresh = false
            if saved.mode and meter.mode ~= saved.mode then
                meter.mode = saved.mode
                if meter.modeDropdown then meter.modeDropdown:SetSelectedValue(saved.mode) end
                needsRefresh = true
            end
            if saved.session and meter.session ~= saved.session then
                meter.session = saved.session
                if meter.sessionDropdown then meter.sessionDropdown:SetSelectedValue(saved.session) end
                needsRefresh = true
            end
            if needsRefresh then
                meter:LoadFromAPI()
                meter:RefreshDisplay()
            end
        end
        -- Apply position/size
        if meter.frame and saved.pos then
            -- Restore the saved snap relationship first so LoadPosition honours it
            if saved.snapTo then
                meter.snapTo = CopyTable(saved.snapTo)
            end
            -- Only apply absolute SetPoint for free (non-snapped) frames.
            -- Snapped frames get their anchor restored by RestoreAnchors() below.
            if not (meter.snapTo and meter.snapTo._parent) then
                if saved.pos.point then
                    meter.frame:ClearAllPoints()
                    meter.frame:SetPoint(saved.pos.point, UIParent, saved.pos.relativePoint, saved.pos.x, saved.pos.y)
                end
            end
            if saved.pos.width then
                meter.frame:SetWidth(saved.pos.width)
                if meter.barContainer then
                    meter.barContainer:SetWidth(saved.pos.width - 2)
                end
            end
            if saved.pos.height then
                meter.frame:SetHeight(saved.pos.height)
            end
        end
    end

    -- Re-apply WoW snap anchors now that all frames are in their free positions
    MeterSnapSystem.RestoreAnchors()

    DPSMeter:SaveAllMeters()
end

local function SwitchProfile(profName)
    if not DPSReportDB.profiles[profName] then
        DPSReportDB.profiles[profName] = CopyTable(DEFAULT_SETTINGS)
    end
    SetActiveProfile(profName)
    settings = LoadSettings()
    -- Defer layout re-application to next frame (functions defined later in file)
    C_Timer.After(0, function()
        -- Re-apply profile settings to existing meter frames
        if DPSMeter and DPSMeter.meters then
            local bgAlpha = settings.meterBgAlpha or 0.85
            for _, meter in ipairs(DPSMeter.meters) do
                if meter.frame then
                    -- Visibility
                    if settings.meterShown ~= false then meter.frame:Show() else meter.frame:Hide() end
                    -- Background alpha
                    ApplyDRBackdrop(meter.frame, {0.04, 0.04, 0.06, bgAlpha}, DR_COLORS.border)
                    -- Rebuild bars for new bar height
                    meter:RebuildBars()
                end
            end
        end
        -- Restore saved meter positions/sizes from profile
        ApplyMeterLayoutFromSettings()
        -- Re-apply widget visibility
        if reportWidget then
            if settings.widgetShown == false then reportWidget:Hide() else reportWidget:Show() end
        end
    end)
end

-- Mapping from user-friendly names to Enum.DamageMeterType values
local TYPE_MAP = {
    dps       = Enum.DamageMeterType.Dps,
    damage    = Enum.DamageMeterType.DamageDone,
    hps       = Enum.DamageMeterType.Hps,
    healing   = Enum.DamageMeterType.HealingDone,
    absorbs   = Enum.DamageMeterType.Absorbs,
    interrupts = Enum.DamageMeterType.Interrupts,
    dispels   = Enum.DamageMeterType.Dispels,
    dtaken    = Enum.DamageMeterType.DamageTaken,
    avoidable = Enum.DamageMeterType.AvoidableDamageTaken,
    deaths    = Enum.DamageMeterType.Deaths,
    edamage   = Enum.DamageMeterType.EnemyDamageTaken,
}

-- Display labels for each type
local TYPE_LABELS = {
    [Enum.DamageMeterType.DamageDone]          = "Damage Done",
    [Enum.DamageMeterType.Dps]                 = "DPS",
    [Enum.DamageMeterType.HealingDone]         = "Healing Done",
    [Enum.DamageMeterType.Hps]                 = "HPS",
    [Enum.DamageMeterType.Absorbs]             = "Absorbs",
    [Enum.DamageMeterType.Interrupts]          = "Interrupts",
    [Enum.DamageMeterType.Dispels]             = "Dispels",
    [Enum.DamageMeterType.DamageTaken]         = "Damage Taken",
    [Enum.DamageMeterType.AvoidableDamageTaken]= "Avoidable Damage",
    [Enum.DamageMeterType.Deaths]              = "Deaths",
    [Enum.DamageMeterType.EnemyDamageTaken]    = "Enemy Damage Taken",
}

-- Is this a "per second" type where amountPerSecond is the primary display?
local PER_SECOND_TYPES = {
    [Enum.DamageMeterType.Dps] = true,
    [Enum.DamageMeterType.Hps] = true,
}

-- Format large numbers: 1234567 -> "1.23M", 12345 -> "12.3K"
local function FormatNumber(num)
    if num >= 1000000 then
        return string.format("%.2fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.1fK", num / 1000)
    else
        return string.format("%.0f", num)
    end
end

-- Launder a tainted/secret value to a plain Lua string via tostring().
-- Returns "?" if conversion fails (Blizzard may restrict this in the future).
local function SafeStr(secretVal)
    if not issecretvalue(secretVal) then return secretVal ~= nil and tostring(secretVal) or "?" end
    local ok, str = pcall(tostring, secretVal)
    if ok and str and not issecretvalue(str) then return str end
    return "?"
end

-- Convert a tainted/secret number to a plain Lua number via tostring→tonumber.
local function LaunderNumber(secretNum)
    if secretNum == nil then return 0 end
    local ok, str = pcall(tostring, secretNum)
    -- tostring() on a secret value can hand back a TAINTED string rather than
    -- erroring; tonumber() would then yield a tainted number that poisons every
    -- later arithmetic op and gets written straight into SavedVariables.
    if ok and str and not issecretvalue(str) then
        return tonumber(str) or 0
    end
    return 0
end

-- Format a tainted number with K/M suffixes (Details!-style).
local function FormatSecret(secretNum)
    return FormatNumber(LaunderNumber(secretNum))
end

-- Strip realm from "Name-Realm" strings; handles tainted values gracefully
local function ShortName(fullName)
    if not fullName then return "" end
    if settings and settings.shortNames == false then return fullName end
    local ok, short = pcall(function()
        local dash = fullName:find("-", 1, true)
        return dash and fullName:sub(1, dash - 1) or fullName
    end)
    return ok and short or fullName
end

-- Resolve display name: nickname > short name > full name.
-- Accepts plain strings (post-combat / roster-resolved) or secret strings
-- (fallback during combat — pcalls protect against taint errors).
local function DisplayName(fullName)
    if not fullName then return "" end

    -- Try to extract the plain base name for nickname lookup.
    -- On secret strings the pcall will fail harmlessly.
    local ok, plain = pcall(function()
        return fullName:match("^[^-]+")
    end)
    local baseName = ok and plain or nil

    -- Check nickname cache (from other addon users)
    if baseName then
        -- nicknameCache[fullName] would throw if fullName is a tainted string;
        -- wrap in pcall so the fallback path is always safe.
        local ok2, nick = pcall(function()
            return nicknameCache[fullName] or nicknameCache[baseName]
        end)
        if ok2 and nick then return nick end
    end

    -- Check our own nickname (for our own character)
    if charKey and DPSReportDB and DPSReportDB.nicknames then
        local myNick = DPSReportDB.nicknames[charKey]
        if myNick and myNick ~= "" then
            -- Is this entry us? Check both full key and base name
            local myBase = charKey:match("^[^-]+")
            if baseName and (baseName == myBase or fullName == charKey) then
                return myNick
            end
        end
    end

    return ShortName(fullName)
end

-- Resolve display name for a meter entry.
-- Resolved (plain) names honour the Short names setting via DisplayName.
-- Unresolved entries use Ambiguate() on the raw secret src.name to strip the
-- realm suffix during combat (mirrors Details!'s approach for TWW 11.2+).
local function EntryDisplayName(entry)
    if entry.plainName then
        local resolved = DisplayName(entry.plainName)
        if resolved and resolved ~= "" then return resolved end
    end
    -- No plain name resolved — fall back to the raw API value.
    -- Secret values can't be string-operated on, so use Ambiguate to extract
    -- a displayable name: "short" strips realm, "none" keeps it.
    local apiName = entry.apiName or entry.name
    if apiName and issecretvalue(apiName) then
        if settings and settings.shortNames == false then
            return Ambiguate(apiName, "none")
        end
        return Ambiguate(apiName, "short")
    end
    return apiName or ""
end

-- Resolve a plain source name for live API entries.
-- Uses the strongest identifiers first (GUID), then spec/class caches as fallback.
local function ResolveSourcePlainName(src)
    if not src then return nil end
    if src.isLocalPlayer then
        return charKey
    end

    local guid
    if src.sourceGUID and not issecretvalue(src.sourceGUID) then
        guid = src.sourceGUID
    end

    -- Best case: restrictions lifted, we can read source name directly.
    -- Keep the full name (with realm) so cross-realm same-name players stay distinct.
    -- seenNameCache keyed by GUID stores the full name for future lookups.
    if guid and not issecretvalue(src.name) then
        local full = src.name
        if not seenNameCache[guid] then
            seenNameCache[guid] = full
            if DPSReportDB and DPSReportDB.seenNames then
                DPSReportDB.seenNames[guid] = full
            end
        end
        return full
    end

    -- GUID caches survive combat restrictions and are the most accurate fallback.
    if guid and guid ~= "" then
        if seenNameCache[guid] and seenNameCache[guid] ~= "" then
            return seenNameCache[guid]
        end
        if guidNameCache[guid] and guidNameCache[guid] ~= "" then
            return guidNameCache[guid]
        end
    end

    -- Do NOT fall back to spec/class caches: they map a single name per slot and
    -- will incorrectly assign that name to any other player sharing the same
    -- class or spec (e.g. two BM hunters). When GUID resolution fails, return nil
    -- so the caller uses the raw src.name from C_DamageMeter, which is always
    -- unique per player and is SetText-safe even when tainted.
    return nil
end

-- Broadcast our nickname to the group
local function BroadcastNickname()
    if not charKey or not DPSReportDB or not DPSReportDB.nicknames then return end
    local nick = DPSReportDB.nicknames[charKey]
    if not nick or nick == "" then
        nick = "\0"  -- empty marker: clear nickname
    end
    local msg = "NICK:" .. charKey .. ":" .. nick
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        C_ChatInfo.SendAddonMessage(ADDON_MSG_PREFIX, msg, "INSTANCE_CHAT")
    elseif IsInRaid() then
        C_ChatInfo.SendAddonMessage(ADDON_MSG_PREFIX, msg, "RAID")
    elseif IsInGroup() then
        C_ChatInfo.SendAddonMessage(ADDON_MSG_PREFIX, msg, "PARTY")
    end
end

-- Handle incoming addon messages
local function OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= ADDON_MSG_PREFIX then return end
    if text:sub(1, 5) == "NICK:" then
        local rest = text:sub(6)
        local key, nick = rest:match("^([^:]+):(.+)$")
        if key and nick then
            if nick == "\0" then
                nicknameCache[key] = nil
            else
                nicknameCache[key] = nick
                -- Also cache by base name for tainted string matching
                local base = key:match("^[^-]+")
                if base then nicknameCache[base] = nick end
            end
            -- Refresh all meter displays
            if DPSMeter and DPSMeter.meters then
                for _, meter in ipairs(DPSMeter.meters) do
                    meter:RefreshDisplay()
                end
            end
        end
    end
end

-- Format duration: 125.4 -> "2:05"
local function FormatDuration(seconds)
    if not seconds then return "N/A" end
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    return string.format("%d:%02d", m, s)
end

-- Determine which chat channel to send to
local function GetChatChannel(overrideChannel, whisperTarget)
    if whisperTarget then
        return "WHISPER", whisperTarget
    end
    if overrideChannel then
        local ch = overrideChannel:upper()
        if ch == "INSTANCE" then ch = "INSTANCE_CHAT" end
        if ch == "SAY" or ch == "YELL" or ch == "GUILD" or ch == "OFFICER"
           or ch == "PARTY" or ch == "RAID" or ch == "INSTANCE_CHAT" then
            return ch, nil
        end
    end
    if IsInRaid() then
        return IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT" or "RAID", nil
    elseif IsInGroup() then
        return IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT" or "PARTY", nil
    end
    -- Solo fallback: print locally
    return nil, nil
end

local function SendLine(text, channel, whisperTarget)
    if channel then
        SendChatMessage(text, channel, nil, whisperTarget)
    else
        print("|cff00ccff[DPSReport]|r " .. text)
    end
end

-- Send multiple lines with a small stagger to preserve order in guild/whisper
local function SendLines(lines, channel, target)
    if not lines or #lines == 0 then return end
    for i, line in ipairs(lines) do
        C_Timer.After((i - 1) * 0.1, function()
            SendLine(line, channel, target)
        end)
    end
end

-- Build a chat report.  C_DamageMeter values are tainted/secret in 12.0+;
-- we use tostring() to coerce them into printable strings.  If Blizzard
-- blocks that in a future build the pcall wrapper will catch it cleanly.

local function BuildReport(meterType, sessionType, topCount)
    local isAvailable, failureReason = C_DamageMeter.IsDamageMeterAvailable()
    if not isAvailable then
        return nil, "Damage Meter is not available: " .. (failureReason or "unknown")
    end

    if UnitAffectingCombat("player") then
        return nil, "Cannot generate report while in combat (API restriction)."
    end

    local session = C_DamageMeter.GetCombatSessionFromType(sessionType, meterType)
    if not session then
        return nil, "No session data available."
    end

    local sources = session.combatSources
    if not sources or #sources == 0 then
        return nil, "No combat data recorded yet."
    end

    -- Sources arrive pre-sorted from the API – do NOT table.sort.
    local isPerSecond = PER_SECOND_TYPES[meterType]
    local label = TYPE_LABELS[meterType] or "Unknown"

    -- Deaths is one row per death EVENT, every one of them valued zero, so the
    -- generic path below reports a column of "0" under duplicated names. Fold it
    -- the way the meters do -- which also strips the Feign Death rows the API
    -- counts as deaths -- and report plain counts: a percentage of a death toll
    -- means nothing, and neither does an abbreviated "3".
    if meterType == Enum.DamageMeterType.Deaths then
        local entries = {}
        for i = 1, #sources do
            local src = sources[i]
            local plainName = ResolveSourcePlainName(src)
            entries[i] = {
                name        = plainName or SafeStr(src.name),
                plainName   = plainName,
                totalAmount = src.totalAmount,
                isPlayer    = src.isLocalPlayer,
                sourceGUID  = src.sourceGUID ~= nil and SafeStr(src.sourceGUID) or nil,
            }
        end
        entries = AggregateDeathEntries(entries,
            sessionType == Enum.DamageMeterSessionType.Overall and "overall" or "current")
        if #entries == 0 then
            return nil, "No deaths recorded."
        end
        local total = 0
        for _, e in ipairs(entries) do total = total + e.totalAmount end

        local lines = {}
        if settings and settings.showTotalInHeader ~= false then
            table.insert(lines, string.format("--- %s Report - Total: %d ---", label, total))
        else
            table.insert(lines, string.format("--- %s Report ---", label))
        end
        for i = 1, math.min(topCount, #entries) do
            local e = entries[i]
            local marker = (settings and settings.showSelfMarker ~= false) and e.isPlayer and " (*)" or ""
            table.insert(lines, string.format("%d. %s%s - %d",
                i, DisplayName(e.name), marker, e.totalAmount))
        end
        return lines
    end

    local lines = {}
    if settings and settings.showTotalInHeader ~= false then
        table.insert(lines, string.format("--- %s Report - Total: %s ---",
            label, FormatSecret(session.totalAmount)))
    else
        table.insert(lines, string.format("--- %s Report ---", label))
    end

    local count = math.min(topCount, #sources)
    for i = 1, count do
        local src = sources[i]
        local value
        if isPerSecond then
            value = FormatSecret(src.amountPerSecond)
        else
            value = FormatSecret(src.totalAmount)
        end

        local pct = ""
        local total = LaunderNumber(session.totalAmount)
        local srcTotal = LaunderNumber(src.totalAmount)
        if settings and settings.showPercentages ~= false and total > 0 then
            pct = string.format(", %.1f%%", (srcTotal / total) * 100)
        end

        local marker = (settings and settings.showSelfMarker ~= false) and src.isLocalPlayer and " (*)" or ""
        table.insert(lines, string.format("%d. %s%s - %s (%s%s)",
            i, DisplayName(SafeStr(src.name)), marker, value, FormatSecret(src.totalAmount), pct))
    end

    return lines
end

local function BuildSegmentReport(modeName, segIndex, topCount)
    local seg = DPSMeter and DPSMeter.segments and DPSMeter.segments[segIndex]
    if not seg then
        return nil, "Segment not found."
    end
    local modeData = seg.modes[modeName]
    if not modeData or not modeData.entries or #modeData.entries == 0 then
        return nil, "No data for this mode in segment."
    end

    local isPerSecond = (modeName == "dps" or modeName == "hps")
    local label = TYPE_LABELS[METER_MODE_MAP[modeName]] or modeName:upper()

    local lines = {}
    local headerExtra = string.format(" (%s %s)", seg.name, FormatDuration(seg.duration))
    if settings and settings.showTotalInHeader ~= false then
        table.insert(lines, string.format("--- %s Report%s - Total: %s ---",
            label, headerExtra, FormatNumber(modeData.totalAmount)))
    else
        table.insert(lines, string.format("--- %s Report%s ---", label, headerExtra))
    end

    -- Sort a copy, highest first. The API usually hands sources back in order
    -- already, but nothing documents that, and the entry list is shared with
    -- the live meter -- so never sort it in place.
    local ranked = {}
    for i, e in ipairs(modeData.entries) do ranked[i] = e end
    local function RankValue(e)
        return (isPerSecond and (e.amountPerSecond or 0)) or (e.totalAmount or 0)
    end
    table.sort(ranked, function(a, b) return RankValue(a) > RankValue(b) end)

    -- No topCount means report the whole group.
    local count = topCount and math.min(topCount, #ranked) or #ranked
    for i = 1, count do
        local e = ranked[i]
        local value = isPerSecond and FormatNumber(e.amountPerSecond) or FormatNumber(e.totalAmount)
        local pct = ""
        if settings and settings.showPercentages ~= false and modeData.totalAmount > 0 then
            pct = string.format(", %.1f%%", (e.totalAmount / modeData.totalAmount) * 100)
        end
        local marker = (settings and settings.showSelfMarker ~= false) and e.isPlayer and " (*)" or ""
        table.insert(lines, string.format("%d. %s%s - %s (%s%s)",
            i, DisplayName(e.name), marker, value, FormatNumber(e.totalAmount), pct))
    end

    return lines
end

-- ============================================================================
-- End-of-dungeon summary report
-- ============================================================================
-- Builds the highlight lines announced after a M+ run. Everything here reads
-- from the segment SnapshotMythicRun already captured, which holds every mode
-- in METER_MODE_MAP with values already laundered to plain Lua -- so this runs
-- no C_DamageMeter calls of its own and has no taint constraints to respect.

-- Role weights for the MVP score. Each row sums to 1.0, so a player who topped
-- every metric their role is judged on scores 1.0 before penalties.
local MVP_WEIGHTS = {
    TANK    = { damage = 0.25, healing = 0.05, interrupts = 0.40, dispels = 0.10 },
    HEALER  = { damage = 0.10, healing = 0.50, interrupts = 0.15, dispels = 0.25 },
    DAMAGER = { damage = 0.50, healing = 0.05, interrupts = 0.30, dispels = 0.15 },
}
local MVP_DEATH_PENALTY     = 0.10  -- per death
local MVP_AVOIDABLE_PENALTY = 0.20  -- times the player's share of group avoidable damage

-- Counts (interrupts, dispels, deaths) must not go through FormatNumber -- it
-- would render 1400 interrupts as "1.4K", and more importantly renders small
-- counts with decimals in some locales.
local function FormatCount(n)
    return string.format("%d", math.floor((tonumber(n) or 0) + 0.5))
end

-- The role a snapshot entry should be judged as. specIconID travels with the
-- entry and survives the run ending, so it is preferred; the assigned-role map
-- covers players whose spec never got inspected.
local function ResolveEntryRole(e)
    if e.specIconID and specIconToRole[e.specIconID] then
        return specIconToRole[e.specIconID]
    end
    if e.name and roleByName[e.name] then
        return roleByName[e.name]
    end
    return "DAMAGER"
end

-- True for a real group member, false for a pet or guardian.
--
-- C_DamageMeter lists pets as their own sources rather than folding them into
-- the owner, and the summary lines have no business ranking them: a mage's
-- water elemental takes no avoidable damage, so it won a "least avoidable
-- damage" award that belongs to a player. Only a character's GUID starts with
-- "Player-" (a pet's starts with "Pet-" or "Creature-"), which is the one
-- signal that never lies, so it is checked first. Segments captured before the
-- GUID was stored fall back to specIconID, which the API sets on players and
-- never on pets.
local function IsGroupPlayerEntry(e)
    if e.isPlayer then return true end  -- the local player, GUID or not
    local guid = e.sourceGUID
    -- SafeStr can hand back a still-tainted string, and comparing one throws.
    if guid and not issecretvalue(guid) and type(guid) == "string"
       and guid ~= "" and guid ~= "?" then
        return guid:sub(1, 7) == "Player-"
    end
    return e.specIconID ~= nil
end

-- Collapse a segment's per-mode entry lists into one row per player.
-- The roster is the union of every mode, because a mode omits players with no
-- data for it -- a DPS who took zero avoidable damage simply isn't in that
-- list, and treating "absent" as "no data" instead of "zero" is what makes
-- "least avoidable damage" pick the right person.
-- Pets are skipped entirely: they are group damage, but they are not people and
-- cannot win or lose an award.
local function CollectSummaryPlayers(seg)
    local players, order = {}, {}
    local function Row(name)
        local r = players[name]
        if not r then
            r = { name = name, damage = 0, healing = 0, dps = 0, hps = 0,
                  interrupts = 0, dispels = 0, deaths = 0, avoidable = 0 }
            players[name] = r
            order[#order + 1] = r
        end
        return r
    end

    -- Deaths is NOT in here: that session returns one entry per death event,
    -- not one per player, and every entry's totalAmount is 0 (the count is the
    -- number of rows). Reading totalAmount gave "Deaths: none" on a run with
    -- ten of them. It is counted separately below.
    local FIELD_BY_MODE = {
        damage     = "damage",
        healing    = "healing",
        interrupts = "interrupts",
        dispels    = "dispels",
        avoidable  = "avoidable",
    }

    -- Seed the roster from damage, then healing: between them they cover
    -- everyone who did anything at all.
    for _, seedMode in ipairs({ "damage", "healing", "dps" }) do
        local md = seg.modes and seg.modes[seedMode]
        if md and md.entries then
            for _, e in ipairs(md.entries) do
                if e.name and e.name ~= "" and e.name ~= "?" and IsGroupPlayerEntry(e) then
                    local r = Row(e.name)
                    r.specIconID = r.specIconID or e.specIconID
                    r.class      = r.class or e.class
                    r.isPlayer   = r.isPlayer or e.isPlayer
                end
            end
        end
    end

    for modeName, field in pairs(FIELD_BY_MODE) do
        local md = seg.modes and seg.modes[modeName]
        if md and md.entries then
            for _, e in ipairs(md.entries) do
                if e.name and e.name ~= "" and e.name ~= "?" and IsGroupPlayerEntry(e) then
                    local r = Row(e.name)
                    r.specIconID = r.specIconID or e.specIconID
                    r.class      = r.class or e.class
                    r.isPlayer   = r.isPlayer or e.isPlayer
                    r[field]     = tonumber(e.totalAmount) or 0
                end
            end
        end
    end

    -- Deaths. New segments arrive already folded to one entry per player with
    -- totalAmount holding the count, so that is used when present. Segments
    -- recorded before that fix still hold one zero-valued entry per death, and
    -- counting rows gets those right too -- which keeps old saved runs readable.
    do
        local md = seg.modes and seg.modes.deaths
        if md and md.entries then
            for _, e in ipairs(md.entries) do
                if e.name and e.name ~= "" and e.name ~= "?" and IsGroupPlayerEntry(e) then
                    local r = Row(e.name)
                    r.specIconID = r.specIconID or e.specIconID
                    r.class      = r.class or e.class
                    local n = tonumber(e.totalAmount) or 0
                    r.deaths = r.deaths + (n > 0 and n or 1)
                end
            end
        end
    end

    -- Rate modes are read from amountPerSecond rather than totalAmount, which
    -- on a dps/hps session is the same running total the damage mode carries.
    for _, modeName in ipairs({ "dps", "hps" }) do
        local md = seg.modes and seg.modes[modeName]
        if md and md.entries then
            for _, e in ipairs(md.entries) do
                if e.name and e.name ~= "" and e.name ~= "?" and IsGroupPlayerEntry(e) then
                    Row(e.name)[modeName] = tonumber(e.amountPerSecond) or 0
                end
            end
        end
    end

    return order
end

-- Highest value of `field`, with every player tied at that value.
-- Returns nil when nobody has a non-zero value, so the caller can drop the line
-- rather than announce "Top Dispels: Someone (0)".
local function TopBy(rows, field)
    local best, names = 0, {}
    for _, r in ipairs(rows) do
        local v = r[field] or 0
        if v > best then
            best, names = v, { r.name }
        elseif v == best and v > 0 then
            names[#names + 1] = r.name
        end
    end
    if best <= 0 then return nil end
    return best, names
end

-- Lowest value of `field` across the whole roster, ties included. Unlike TopBy
-- a result of zero is meaningful here ("took no avoidable damage at all").
local function LowestBy(rows, field)
    if #rows == 0 then return nil end
    local best, names = math.huge, {}
    for _, r in ipairs(rows) do
        local v = r[field] or 0
        if v < best then
            best, names = v, { r.name }
        elseif v == best then
            names[#names + 1] = r.name
        end
    end
    if best == math.huge then return nil end
    return best, names
end

-- Join names for a chat line, capped so a five-way tie doesn't fill the screen.
local function JoinNames(names, maxShown)
    maxShown = maxShown or 3
    local shown = {}
    for i = 1, math.min(maxShown, #names) do
        shown[i] = DisplayName(names[i])
    end
    local s = table.concat(shown, ", ")
    if #names > maxShown then
        s = s .. string.format(" +%d more", #names - maxShown)
    end
    return s
end

-- Role-weighted MVP, following the same shape StormsDungeonData uses: each
-- metric scored as a share of the group total, weighted by what the player's
-- role is actually responsible for, then penalised for dying and for standing
-- in things. Returns nil when there is nothing to score.
local function ComputeMVP(rows)
    if #rows == 0 then return nil end

    local totals = { damage = 0, healing = 0, interrupts = 0, dispels = 0, avoidable = 0 }
    for _, r in ipairs(rows) do
        for k in pairs(totals) do
            totals[k] = totals[k] + (r[k] or 0)
        end
    end

    local function Share(v, total)
        if not total or total <= 0 then return 0 end
        return (v or 0) / total
    end

    local bestRow, bestScore
    for _, r in ipairs(rows) do
        local w = MVP_WEIGHTS[ResolveEntryRole(r)] or MVP_WEIGHTS.DAMAGER
        local score = w.damage     * Share(r.damage,     totals.damage)
                    + w.healing    * Share(r.healing,    totals.healing)
                    + w.interrupts * Share(r.interrupts, totals.interrupts)
                    + w.dispels    * Share(r.dispels,    totals.dispels)
                    - MVP_DEATH_PENALTY     * (r.deaths or 0)
                    - MVP_AVOIDABLE_PENALTY * Share(r.avoidable, totals.avoidable)
        if not bestScore or score > bestScore then
            bestRow, bestScore = r, score
        end
    end
    return bestRow
end

-- Builds the announce lines for a completed run. Returns lines, or nil + reason.
local function BuildMythicSummaryReport(segIndex)
    local seg = DPSMeter and DPSMeter.segments and DPSMeter.segments[segIndex]
    if not seg then
        return nil, "Segment not found."
    end

    local rows = CollectSummaryPlayers(seg)
    if #rows == 0 then
        return nil, "No player data in segment."
    end

    local s = settings or {}
    local lines = {}

    if s.autoSummaryHeader ~= false then
        table.insert(lines, string.format("--- %s completed in %s ---",
            seg.name or "M+ Run", FormatDuration(seg.duration or 0)))
    end

    if s.autoSummaryMVP ~= false then
        local mvp = ComputeMVP(rows)
        if mvp then
            table.insert(lines, "MVP: " .. DisplayName(mvp.name))
        end
    end

    -- The setting keys still say Damage/Healing: renaming them would reset the
    -- toggle for anyone who had already turned one off, for no gain.
    if s.autoSummaryTopDamage ~= false then
        local v, names = TopBy(rows, "dps")
        if v then
            table.insert(lines, string.format("Top DPS: %s (%s)", JoinNames(names), FormatNumber(v)))
        end
    end

    if s.autoSummaryTopHealing ~= false then
        local v, names = TopBy(rows, "hps")
        if v then
            table.insert(lines, string.format("Top HPS: %s (%s)", JoinNames(names), FormatNumber(v)))
        end
    end

    if s.autoSummaryInterrupts ~= false then
        local v, names = TopBy(rows, "interrupts")
        if v then
            table.insert(lines, string.format("Top Interrupts: %s (%s)", JoinNames(names), FormatCount(v)))
        end
    end

    if s.autoSummaryDispels ~= false then
        local v, names = TopBy(rows, "dispels")
        if v then
            table.insert(lines, string.format("Top Dispels: %s (%s)", JoinNames(names), FormatCount(v)))
        end
    end

    if s.autoSummaryAvoidable ~= false then
        -- Only worth announcing when somebody actually took avoidable damage.
        -- With no data at all every player sits at zero and the line would name
        -- the whole group as joint best, which reads as a bug.
        local anyAvoidable = false
        for _, r in ipairs(rows) do
            if (r.avoidable or 0) > 0 then
                anyAvoidable = true
                break
            end
        end
        if anyAvoidable then
            local v, names = LowestBy(rows, "avoidable")
            if v then
                table.insert(lines, string.format("Least Avoidable DMG: %s (%s)",
                    JoinNames(names), FormatNumber(v)))
            end
        end
    end

    if s.autoSummaryDeaths ~= false then
        local total = 0
        for _, r in ipairs(rows) do total = total + (r.deaths or 0) end
        if total <= 0 then
            table.insert(lines, "Deaths: none")
        else
            local v, names = TopBy(rows, "deaths")
            if v then
                table.insert(lines, string.format("Deaths: %s total (most: %s with %s)",
                    FormatCount(total), JoinNames(names), FormatCount(v)))
            else
                table.insert(lines, "Deaths: " .. FormatCount(total))
            end
        end
    end

    if #lines == 0 then
        return nil, "Every summary line is switched off."
    end
    return lines
end

-- What the end-of-run auto-report announces, in whichever format is configured.
-- Both the real announce and the Tools preview button go through here, so the
-- preview cannot drift out of step with what actually gets posted.
local function BuildMythicAnnounce(segIndex)
    if (settings and settings.autoReportFormat) == "single" then
        -- Whole group, highest to lowest: no topCount. A key is five players,
        -- so there is no reason to truncate the way a raid report would.
        local modeName = (settings and settings.autoReportType) or "dps"
        return BuildSegmentReport(modeName, segIndex, nil)
    end
    return BuildMythicSummaryReport(segIndex)
end

-- Most recent stored segment, or nil if nothing has been recorded yet.
local function LatestSegmentIndex()
    local segs = DPSMeter and DPSMeter.segments
    if not segs or #segs == 0 then return nil end
    return #segs
end

-- Register slash command
SLASH_DPSREPORT1 = "/dps"
SlashCmdList["DPSREPORT"] = function()
    DPSReport_OpenOptionsPanel()
end

-- Addon Compartment callbacks (for minimap addon list)
function DPSReport_OnAddonCompartmentClick()
    DPSReport_OpenOptionsPanel()
end

function DPSReport_OnAddonCompartmentEnter(addonName, menuButtonFrame)
    GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_LEFT")
    GameTooltip:AddLine("DPSReport", 1, 1, 1)
    GameTooltip:AddLine("|cffccccccLeft-click:|r Open settings", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffccccccRight-click:|r Quick report", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function DPSReport_OnAddonCompartmentLeave(addonName, menuButtonFrame)
    GameTooltip:Hide()
end

-- Returns true if the local player OR any group/raid member is in combat.
-- Used to keep the meter running when the player dies mid-fight.
local function IsAnyoneInCombat()
    if UnitAffectingCombat("player") then return true end
    local numGroup = GetNumGroupMembers()
    if numGroup <= 1 then return false end
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and numGroup or (numGroup - 1)
    for i = 1, count do
        if UnitAffectingCombat(prefix .. i) then return true end
    end
    return false
end

-- Returns true once C_DamageMeter values can be read as plain Lua.
-- Two independent restrictions keep them secret: the combat restriction (any
-- group member still fighting) and the ChallengeMode restriction (active key).
-- issecretvalue() on live session data is the only authoritative test that both
-- have dropped -- pcall(tostring) can silently hand back a TAINTED string, and
-- LaunderNumber then yields 0 while SafeStr yields "?".
local function DamageMeterValuesReadable()
    if IsAnyoneInCombat() then return false end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.Dps)
    -- Nothing to probe (no Overall session at all): fall back to the combat
    -- check alone rather than stalling until the poll times out.
    if not ok or not session then return true end
    if issecretvalue(session.totalAmount) then return false end
    local src = session.combatSources and session.combatSources[1]
    if not src then return true end  -- no rows to read; nothing left to wait for
    if issecretvalue(src.name) or issecretvalue(src.totalAmount) then return false end
    return true
end

-- Shared combat-end cleanup: stop tickers, snapshot, rebuild caches.
local function DoCombatEnd()
    DeathTracker:Stop()
    for _, meter in ipairs(DPSMeter.meters) do
        meter.inCombat = false
        meter:StopRefreshTicker()
    end
    -- Retry every 0.5s until AddOn restrictions have fully lifted.
    -- issecretvalue() is the authoritative check: SafeStr via pcall(tostring) can
    -- silently return a TAINTED string (not "?"), which corrupts caches and SavedVariables.
    -- Both the Combat restriction and the ChallengeMode (M+) restriction keep src.name
    -- tainted; we must wait for both to drop before updating caches.
    local function DoPostCombatLoad()
        if IsAnyoneInCombat() then return end  -- another party member still fighting
        local dpsSession = C_DamageMeter.GetCombatSessionFromType(
            Enum.DamageMeterSessionType.Current, Enum.DamageMeterType.Dps)
        -- If the first source name is still secret, restrictions haven't lifted yet.
        if dpsSession and dpsSession.combatSources and dpsSession.combatSources[1] then
            if issecretvalue(dpsSession.combatSources[1].name) then
                C_Timer.After(0.5, DoPostCombatLoad)
                return
            end
        end
        -- Persist GUID→name mappings and refresh spec cache while names are plain.
        SnapshotSegment()
        if dpsSession and dpsSession.combatSources then
            wipe(specNameCache)
            local specSeen = {}
            for _, src in ipairs(dpsSession.combatSources) do
                if src.specIconID and not issecretvalue(src.name) then
                    local name = src.name:match("^([^%-]+)") or src.name
                    if name ~= "" then
                        if specSeen[src.specIconID] then
                            specNameCache[src.specIconID] = nil
                        else
                            specNameCache[src.specIconID] = name
                            specSeen[src.specIconID] = true
                        end
                    end
                end
            end
        end
        for _, meter in ipairs(DPSMeter.meters) do
            meter:LoadFromAPI()
            meter:RefreshDisplay()
        end
    end
    C_Timer.After(0.5, DoPostCombatLoad)
end

-- Main event frame
local f = CreateFrame("Frame")
local MAIN_EVENTS = {
    "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
    "PLAYER_LOGOUT",
    "CHAT_MSG_ADDON", "GROUP_JOINED", "GROUP_ROSTER_UPDATE",
    "INSPECT_READY", "UNIT_IN_RANGE_UPDATE",
    "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED",
}
local activeRunInfo = { mapID = nil, level = nil, name = nil }
local function RegisterMainEvents()
    for _, ev in ipairs(MAIN_EVENTS) do
        f:RegisterEvent(ev)
    end
end
RegisterMainEvents()
C_ChatInfo.RegisterAddonMessagePrefix(ADDON_MSG_PREFIX)
f:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
        return
    elseif event == "INSPECT_READY" then
        -- An inspection completed; refresh spec caches and update meter names.
        local finishedUnit = inspectActiveUnit
        inspectActive     = false
        inspectActiveUnit = nil
        -- Cache ilvl and fire any pending callback for this unit.
        if finishedUnit and UnitExists(finishedUnit) then
            local guid = UnitGUID(finishedUnit)
            local ilvl
            do
                local pd = rawget(_G, "C_PaperDollInfo")
                ilvl = pd and pd.GetInspectItemLevel and pd.GetInspectItemLevel(finishedUnit)
            end
            if guid and ilvl and ilvl > 0 then
                ilvlCache[guid] = { ilvl = math.floor(ilvl), time = GetTime() }
            end
            if guid and pendingIlvlCallbacks[guid] then
                local cb = pendingIlvlCallbacks[guid]
                pendingIlvlCallbacks[guid] = nil
                cb(ilvl and ilvl > 0 and math.floor(ilvl) or nil)
            end
        end
        RefreshRosterCache()
        for _, meter in ipairs(DPSMeter.meters) do
            if meter.frame and meter.frame:IsShown() then
                meter:LoadFromAPI()
                meter:RefreshDisplay()
            end
        end
        -- Continue draining the queue
        ProcessInspectQueue()
        return
    elseif event == "GROUP_JOINED" then
        wipe(specNameCache)
        RefreshRosterCache()
        -- Queue inspections for uninspected members. Two passes: 2s for players
        -- already loaded, 6s for late arrivals still zoning in.
        C_Timer.After(2, QueueGroupInspections)
        C_Timer.After(6, QueueGroupInspections)
        C_Timer.After(2, BroadcastNickname)
        return
    elseif event == "UNIT_IN_RANGE_UPDATE" then
        -- A party/raid member just came into range. If we were waiting on their
        -- ilvl and don't have a fresh cache entry, queue an inspect now.
        local unit = ...
        if unit and not InCombatLockdown() and CanInspect(unit) then
            local guid = UnitGUID(unit)
            if guid and not issecretvalue(guid) and wantIlvlGUIDs[guid] then
                local cached = ilvlCache[guid]
                if not cached or (GetTime() - cached.time) >= 300 then
                    wantIlvlGUIDs[guid] = nil
                    table.insert(inspectQueue, unit)
                    ProcessInspectQueue()
                else
                    wantIlvlGUIDs[guid] = nil  -- already have fresh cache
                end
            end
        end
        return
    elseif event == "GROUP_ROSTER_UPDATE" then
        RefreshRosterCache()
        C_Timer.After(2, QueueGroupInspections)
        C_Timer.After(6, QueueGroupInspections)
        -- Re-broadcast nickname so any newly joined member learns ours.
        -- Debounce: cancel any pending re-broadcast and schedule a fresh one.
        if nicknameBroadcastTimer then
            nicknameBroadcastTimer:Cancel()
            nicknameBroadcastTimer = nil
        end
        nicknameBroadcastTimer = C_Timer.NewTimer(3, function()
            nicknameBroadcastTimer = nil
            BroadcastNickname()
        end)
        return
    elseif event == "PLAYER_LOGOUT" then
        DPSMeter:SaveAllMeters()
        return
    elseif event == "PLAYER_LOGIN" then
        charKey = UnitName("player") .. "-" .. GetRealmName()
        -- Re-run in case UnitClass wasn't answerable at file load. Mutates the
        -- accent tables in place, and every frame is built after this point.
        ApplyClassAccent()
        settings = LoadSettings()
        -- Populate own nickname in cache for display
        if DPSReportDB.nicknames[charKey] and DPSReportDB.nicknames[charKey] ~= "" then
            nicknameCache[charKey] = DPSReportDB.nicknames[charKey]
            local base = charKey:match("^[^-]+")
            if base then nicknameCache[base] = DPSReportDB.nicknames[charKey] end
        end
        -- Restore persistent seen-name cache (GUID-keyed; skip legacy integer specIconID keys)
        if DPSReportDB.seenNames then
            for k, v in pairs(DPSReportDB.seenNames) do
                if type(k) == "string" then
                    seenNameCache[k] = v
                end
            end
        end
        print("|cff00ccff[DPSReport]|r Loaded. Type /dps to open settings.")
        C_Timer.After(2, function()
            DPSMeter:LoadAllMeters()
        end)
        C_Timer.After(4, BroadcastNickname)
        -- A /reload mid-key misses CHALLENGE_MODE_START, and the run tally
        -- depends on it. Pick the key back up here. The tally still starts from
        -- zero and so will read short of GetDeathCount for the rest of the run,
        -- which is exactly how the callers know to leave the game's counts alone.
        C_Timer.After(2, function()
            if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
               and C_ChallengeMode.IsChallengeModeActive() then
                DeathTracker.keepAlive = true
                DeathTracker:Start()
            end
        end)
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Tally this fight's deaths ourselves; C_DamageMeter's Deaths metric
        -- counts Feign Death as one and we cannot tell them apart after the fact.
        DeathTracker:Reset("current")
        -- A fight that is not part of a key means the Overall session no longer
        -- holds only the last key, so the run tally stops standing in for it.
        if not (C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
                and C_ChallengeMode.IsChallengeModeActive()) then
            DeathTracker.keyDeaths = nil
            DeathTracker.runFromStart = false
        end
        DeathTracker:Start()
        RefreshRosterCache()
        -- Mark in-combat for all meter instances
        for _, meter in ipairs(DPSMeter.meters) do
            meter.inCombat = true
            meter:StartRefreshTicker()
            meter:RefreshDisplay()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- PLAYER_REGEN_ENABLED fires when the local player leaves combat, which
        -- includes dying while the group is still fighting. Only do cleanup when
        -- no group member is in combat.
        if IsAnyoneInCombat() then
            -- Keep tickers running; poll until the group fully leaves combat.
            local function WaitForGroupCombatEnd(attempt)
                if attempt > 300 then  -- give up after 5 min
                    DoCombatEnd()
                    return
                end
                if IsAnyoneInCombat() then
                    C_Timer.After(1, function() WaitForGroupCombatEnd(attempt + 1) end)
                else
                    DoCombatEnd()
                    QueueGroupInspections()
                end
            end
            C_Timer.After(1, function() WaitForGroupCombatEnd(1) end)
            return
        end
        DoCombatEnd()
        -- Resume inspection queue now that combat is over.
        QueueGroupInspections()
    elseif event == "CHALLENGE_MODE_START" then
        -- GetActiveChallengeMapID returns the ChallengeMode mapID (works at start, not at completion)
        local cmID = C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID()
        activeRunInfo.mapID = cmID
        activeRunInfo.level = C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo and C_ChallengeMode.GetActiveKeystoneInfo() or nil
        activeRunInfo.name = nil
        if cmID and C_ChallengeMode.GetMapUIInfo then
            local n = select(1, C_ChallengeMode.GetMapUIInfo(cmID))
            if n and n ~= "" then activeRunInfo.name = n end
        end
        -- Track deaths for the whole key, not just for combat: keepAlive holds
        -- the poll open between pulls so a death after a wipe still lands, and
        -- the run tally is what the summary reports.
        DeathTracker.keyDeaths = nil
        DeathTracker:Reset("run")
        DeathTracker.keepAlive = true
        DeathTracker.runFromStart = true
        DeathTracker:Start()
        -- Reset all meters (including overallTime) when a new key starts
        if settings and settings.resetOnMythicStart then
            DPSMeter:ResetAll()
        end
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        do
            local savedName  = activeRunInfo.name
            local savedLevel = activeRunInfo.level

            -- Capture ALL completion data immediately at event time.
            -- GetChallengeCompletionInfo clears very quickly so this must happen now.
            local runTimeMs = 0
            local completionMembers = nil  -- plain-string {memberGUID, name} pairs
            if C_ChallengeMode and C_ChallengeMode.GetChallengeCompletionInfo then
                local info = C_ChallengeMode.GetChallengeCompletionInfo()
                if info then
                    if info.time and info.time > 0 then
                        runTimeMs = info.time
                    end
                    -- info.members has plain-string GUIDs and names for all completers
                    if info.members and #info.members > 0 then
                        completionMembers = info.members
                    end
                end
            end

            -- Blizzard's key death total, captured here for the same reason as
            -- everything else in this block: GetDeathCount stops answering once
            -- the key is over, and the snapshot happens seconds later. It is
            -- what proves our own per-player tally did not miss anything.
            DeathTracker:Poll()  -- final sample before the run tally is judged
            if C_ChallengeMode and C_ChallengeMode.GetDeathCount then
                local okD, deaths = pcall(C_ChallengeMode.GetDeathCount)
                if okD and deaths and not issecretvalue(deaths) and type(deaths) == "number" then
                    DeathTracker.keyDeaths = deaths
                end
            end

            -- Snapshot only once C_DamageMeter values are readable as plain Lua.
            -- A fixed delay used to snapshot straight through lingering combat
            -- (adds still alive after the last boss), which stores "?" for every
            -- name and 0 for every amount, and then announces that to chat.
            -- Poll instead, but cap the wait: once the group leaves the instance
            -- GetCombatSessionFromType(Overall) goes empty and we lose the run.
            -- Auto-report is chained so it always uses the correct segment index.
            local function DoMythicAutoReport(segIdx)
                local channel, target = GetChatChannel(settings.autoReportChannel, nil)
                local lines, err
                if segIdx > 0 then
                    -- Both formats read the snapshot segment, so neither works
                    -- without one -- fall back to a plain DPS report below.
                    lines, err = BuildMythicAnnounce(segIdx)
                else
                    local topCount = settings.defaultTopCount or DEFAULT_TOP_COUNT
                    lines, err = BuildReport(Enum.DamageMeterType.Dps,
                        Enum.DamageMeterSessionType.Overall, topCount)
                end
                if err then
                    print("|cff00ccff[DPSReport]|r " .. err)
                elseif lines then
                    SendLines(lines, channel, target)
                end
            end

            local function DoMythicSnapshot(readable)
                SnapshotMythicRun(savedName, savedLevel, runTimeMs, completionMembers)
                if not readable then
                    -- Values were still secret: the segment holds "?" names and
                    -- zeroed amounts, so don't broadcast it to the group.
                    print("|cff00ccff[DPSReport]|r M+ snapshot taken while AddOn "
                        .. "restrictions were still active - names/amounts are "
                        .. "incomplete, auto-report skipped.")
                    return
                end
                if not (settings and settings.autoReport) then return end
                local segIdx = #DPSMeter.segments
                local delay  = settings.autoReportDelay or 2
                C_Timer.After(delay, function() DoMythicAutoReport(segIdx) end)
            end

            -- Poll every 0.5s, giving up after 60s (group usually lingers longer).
            local function WaitForReadableValues(elapsed)
                if DamageMeterValuesReadable() then
                    DoMythicSnapshot(true)
                elseif elapsed >= 60 then
                    DoMythicSnapshot(false)
                else
                    C_Timer.After(0.5, function() WaitForReadableValues(elapsed + 0.5) end)
                end
            end

            C_Timer.After(3, function() WaitForReadableValues(3) end)
        end
    end
end)

-- ============================================================================
-- Minimap Button (LibDBIcon-free, manual implementation)
-- ============================================================================

local function CreateMinimapButton()
    local minimapButton = CreateFrame("Button", "DPSReportMinimapButton", Minimap)
    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:SetMovable(true)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Background (dark circle behind icon)
    local bg = minimapButton:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(26, 26)
    bg:SetPoint("CENTER", 0, 0)
    bg:SetColorTexture(0, 0, 0, 0.6)

    -- Icon texture
    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture("Interface\\AddOns\\DPSReport\\Textures\\dpsreportingameicon")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    minimapButton.icon = icon

    -- Border overlay (standard minimap tracking button border)
    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- Circular mask so the icon clips to a circle like other minimap buttons
    local maskTex = minimapButton:CreateMaskTexture()
    maskTex:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    maskTex:SetSize(18, 18)
    maskTex:SetPoint("CENTER", icon)
    icon:AddMaskTexture(maskTex)
    bg:AddMaskTexture(maskTex)

    -- Position around the minimap using angle (in degrees)
    local function UpdatePosition(angle)
        local rads = math.rad(angle)
        local x = math.cos(rads) * 80
        local y = math.sin(rads) * 80
        minimapButton:ClearAllPoints()
        minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    -- Dragging logic
    local isDragging = false
    minimapButton:SetScript("OnDragStart", function(self)
        isDragging = true
        self:SetScript("OnUpdate", function(self)
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            local angle = math.deg(math.atan2(cy - my, cx - mx))
            DPSReportDB.minimapAngle = angle
            UpdatePosition(angle)
        end)
    end)

    minimapButton:SetScript("OnDragStop", function(self)
        isDragging = false
        self:SetScript("OnUpdate", nil)
    end)

    -- Click handlers
    minimapButton:SetScript("OnClick", function()
        DPSReport_OpenOptionsPanel()
    end)

    -- Tooltip
    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("DPSReport", 1, 1, 1)
        GameTooltip:AddLine("|cffccccccLeft-click:|r Open settings", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffccccccRight-click:|r Quick report", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Load saved angle or default
    local angle = DPSReportDB and DPSReportDB.minimapAngle or 225
    UpdatePosition(angle)

    return minimapButton
end

-- Create minimap button after settings are loaded
local minimapFrame = CreateFrame("Frame")
minimapFrame:SetScript("OnEvent", function()
    if not DPSReportDB then DPSReportDB = {} end
    CreateMinimapButton()
end)
minimapFrame:RegisterEvent("PLAYER_LOGIN")

-- ============================================================================
-- Options Panel (Squizzumables-style GUI)
-- ============================================================================

-- Color palette (matching Squizzumables design)
DR_COLORS = {
    bg          = { 0.06, 0.06, 0.08, 0.96 },
    titleBar    = { 0.10, 0.10, 0.13, 1 },
    border      = { 0.25, 0.25, 0.30, 1 },
    -- Overwritten in place with the player's class colour by ApplyClassAccent
    -- below; the gold is only what shows if the class can't be resolved.
    accent      = { 0.78, 0.65, 0.30, 1 },
    accentDim   = { 0.55, 0.45, 0.20, 0.6 },
    text        = { 0.90, 0.90, 0.90, 1 },
    textDim     = { 0.55, 0.55, 0.58, 1 },
    textBright  = { 1, 1, 1, 1 },
    control     = { 0.14, 0.14, 0.17, 1 },
    controlHi   = { 0.20, 0.20, 0.24, 1 },
    danger      = { 0.75, 0.25, 0.25, 1 },
    dangerDim   = { 0.55, 0.20, 0.20, 0.6 },
    section     = { 0.18, 0.18, 0.22, 0.5 },
    tabActive   = { 0.14, 0.14, 0.17, 1 },
    tabInactive = { 0.08, 0.08, 0.10, 1 },
}

-- Repoint the accent at the player's class colour.
--
-- Every widget reads DR_COLORS.accent[1..3] once, when it is built, so the two
-- colour tables are mutated IN PLACE rather than replaced: that way this only
-- has to run before the UI exists, and no call site needs to know about it.
-- Called at file load (where UnitClass is usually already answerable) and again
-- on PLAYER_LOGIN, which is the first point it is guaranteed to work. Both the
-- options panel and the meters are built later than that.
ApplyClassAccent = function()
    local _, classFile = UnitClass("player")
    if not classFile or issecretvalue(classFile) then return false end
    local c = (C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(classFile))
        or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile])
    if not c or not c.r then return false end

    DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3] = c.r, c.g, c.b
    -- accentDim is the pressed/inactive shade of the same hue. Some class
    -- colours are already dark (warlock purple, rogue yellow is not), so scale
    -- rather than subtract to keep the hue intact.
    DR_COLORS.accentDim[1] = c.r * 0.7
    DR_COLORS.accentDim[2] = c.g * 0.7
    DR_COLORS.accentDim[3] = c.b * 0.7
    return true
end
ApplyClassAccent()

-- Tint a UIPanelScrollFrameTemplate's scrollbar to match the accent.
-- The template's internals have changed shape across expansions, so probe for
-- both: modern retail exposes .Track/.Thumb, older builds a ThumbTexture plus
-- separate up/down buttons. Anything not found is skipped rather than assumed.
local function SkinDRScrollBar(scrollFrame)
    local sb = scrollFrame and (scrollFrame.ScrollBar or scrollFrame.scrollBar)
    if not sb then return end
    local a = DR_COLORS.accent

    local thumb = sb.Thumb or sb.ThumbTexture or (sb.GetThumbTexture and sb:GetThumbTexture())
    if thumb then
        local tex = thumb.SetVertexColor and thumb
            or (thumb.Texture or (thumb.GetNormalTexture and thumb:GetNormalTexture()))
        if tex and tex.SetVertexColor then
            tex:SetVertexColor(a[1], a[2], a[3], 0.9)
        end
    end

    for _, key in ipairs({ "Back", "Forward", "ScrollUpButton", "ScrollDownButton" }) do
        local btn = sb[key]
        if btn then
            for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture" }) do
                local t = btn[getter] and btn[getter](btn)
                if t and t.SetVertexColor then t:SetVertexColor(a[1], a[2], a[3], 0.9) end
            end
        end
    end
end

-- Helper: thin-bordered backdrop
ApplyDRBackdrop = function(frame, bgColor, borderColor)
    if not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
    end
    frame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(unpack(bgColor or DR_COLORS.bg))
    frame:SetBackdropBorderColor(unpack(borderColor or DR_COLORS.border))
end

-- Helper: styled button
local function CreateDRButton(parent, text, width, height, color)
    color = color or DR_COLORS.accent
    local dimColor = (color == DR_COLORS.danger) and DR_COLORS.dangerDim or DR_COLORS.accentDim
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width or 100, height or 26)
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(DR_COLORS.control[1], DR_COLORS.control[2], DR_COLORS.control[3], 1)
    btn:SetBackdropBorderColor(dimColor[1], dimColor[2], dimColor[3], dimColor[4])
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText(text)
    label:SetTextColor(color[1], color[2], color[3])
    btn.label = label
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(DR_COLORS.controlHi[1], DR_COLORS.controlHi[2], DR_COLORS.controlHi[3], 1)
        self:SetBackdropBorderColor(color[1], color[2], color[3], 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(DR_COLORS.control[1], DR_COLORS.control[2], DR_COLORS.control[3], 1)
        self:SetBackdropBorderColor(dimColor[1], dimColor[2], dimColor[3], dimColor[4])
    end)
    btn.SetText = function(self, t) self.label:SetText(t) end
    btn.GetText = function(self) return self.label:GetText() end
    return btn
end

-- Helper: styled slider
local function CreateDRSlider(parent, labelText, width, minVal, maxVal, step)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, 40)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)
    label:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    local valueText = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valueText:SetPoint("TOPRIGHT", 0, 0)
    valueText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])

    local track = CreateFrame("Frame", nil, container, "BackdropTemplate")
    track:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
    track:SetSize(width, 6)
    track:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    track:SetBackdropColor(DR_COLORS.control[1], DR_COLORS.control[2], DR_COLORS.control[3], 1)
    track:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.5)

    local slider = CreateFrame("Slider", nil, container, "BackdropTemplate")
    slider:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 3)
    slider:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", 0, -3)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetOrientation("HORIZONTAL")

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 14)
    thumb:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.9)
    slider:SetThumbTexture(thumb)

    local fill = slider:CreateTexture(nil, "ARTWORK")
    fill:SetHeight(4)
    fill:SetPoint("LEFT", track, "LEFT", 1, 0)
    fill:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.35)

    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / step + 0.5) * step
        local displayVal = self.displayTransform and self.displayTransform(value) or value
        local displayStr = self.valueFormat and string.format(self.valueFormat, displayVal) or tostring(math.floor(displayVal))
        valueText:SetText(displayStr)
        local range = maxVal - minVal
        if range > 0 then
            local pct = (value - minVal) / range
            fill:SetWidth(math.max(1, pct * width))
        end
        if self.onValueChanged then self.onValueChanged(value) end
    end)

    container.slider = slider
    container.SetValue = function(self, v) self.slider:SetValue(v) end
    container.GetValue = function(self) return self.slider:GetValue() end
    container.SetAfterValueChanged = function(self, fn) self.slider.onValueChanged = fn end
    container.SetValueFormat = function(self, fmt) self.slider.valueFormat = fmt end
    container.SetDisplayTransform = function(self, fn) self.slider.displayTransform = fn end
    return container
end

-- Helper: styled checkbox
local function CreateDRCheckbox(parent, labelText, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(250, 22)

    local box = CreateFrame("CheckButton", nil, container)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", 0, 0)

    local boxBG = box:CreateTexture(nil, "BACKGROUND")
    boxBG:SetAllPoints()
    boxBG:SetColorTexture(DR_COLORS.control[1], DR_COLORS.control[2], DR_COLORS.control[3], 1)

    local boxBorder = CreateFrame("Frame", nil, box, "BackdropTemplate")
    boxBorder:SetAllPoints()
    boxBorder:SetBackdrop({ edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1 })
    boxBorder:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.8)

    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetSize(12, 12)
    check:SetPoint("CENTER")
    check:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.9)
    box:SetCheckedTexture(check)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", box, "RIGHT", 8, 0)
    label:SetText(labelText)
    label:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])

    box:SetScript("OnClick", function(self) if onChange then onChange(self:GetChecked()) end end)
    box:SetScript("OnEnter", function() boxBorder:SetBackdropBorderColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.6) end)
    box:SetScript("OnLeave", function() boxBorder:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.8) end)

    container.checkbox = box
    container.SetChecked = function(self, v) self.checkbox:SetChecked(v) end
    container.GetChecked = function(self) return self.checkbox:GetChecked() end
    return container
end

-- Helper: reusable confirmation dialog
-- ShowDRConfirm(message, onYes)  – shows a Yes/No popup; calls onYes() if confirmed.
local confirmDialog
local function ShowDRConfirm(message, onYes)
    if not confirmDialog then
        local f = CreateFrame("Frame", "DPSReportConfirm", UIParent, "BackdropTemplate")
        f:SetSize(270, 110)
        f:SetFrameStrata("DIALOG")
        f:SetClampedToScreen(true)
        ApplyDRBackdrop(f, {0.04, 0.04, 0.06, 0.97}, DR_COLORS.border)

        local msg = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        msg:SetPoint("TOP", 0, -18)
        msg:SetWidth(250)
        msg:SetJustifyH("CENTER")
        msg:SetWordWrap(true)
        msg:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])
        f.msg = msg

        local yesBtn = CreateDRButton(f, "Yes", 95, 26, DR_COLORS.danger)
        yesBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 14)
        f.yesBtn = yesBtn

        local noBtn = CreateDRButton(f, "No", 95, 26)
        noBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 14)
        noBtn:SetScript("OnClick", function() f:Hide() end)

        confirmDialog = f
    end

    confirmDialog.msg:SetText(message)
    confirmDialog.yesBtn:SetScript("OnClick", function()
        confirmDialog:Hide()
        onYes()
    end)
    confirmDialog:ClearAllPoints()
    confirmDialog:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    confirmDialog:Show()
end

-- Helper: styled dropdown
local function CreateDRDropdown(parent, labelText, width, items, onSelect)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, 44)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)
    label:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetSize(width, 24)
    btn:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(DR_COLORS.control[1], DR_COLORS.control[2], DR_COLORS.control[3], 1)
    btn:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.8)

    local selectedText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    selectedText:SetPoint("LEFT", 8, 0)
    selectedText:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])

    local arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetText("v")
    arrow:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    local menu = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menu:SetWidth(width)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    menu:SetBackdropColor(DR_COLORS.bg[1], DR_COLORS.bg[2], DR_COLORS.bg[3], 0.98)
    menu:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 1)
    menu:Hide()

    local selectedValue = nil

    local function BuildMenu()
        for _, child in pairs({menu:GetChildren()}) do child:Hide(); child:SetParent(nil) end
        local y = -4
        for _, item in ipairs(items) do
            local opt = CreateFrame("Button", nil, menu)
            opt:SetSize(width - 8, 20)
            opt:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, y)

            local optBG = opt:CreateTexture(nil, "BACKGROUND")
            optBG:SetAllPoints()
            optBG:SetColorTexture(0, 0, 0, 0)

            local optText = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            optText:SetPoint("LEFT", 6, 0)
            optText:SetText(item.text)
            if item.value == selectedValue then
                optText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
            else
                optText:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])
            end

            opt:SetScript("OnEnter", function() optBG:SetColorTexture(DR_COLORS.controlHi[1], DR_COLORS.controlHi[2], DR_COLORS.controlHi[3], 1) end)
            opt:SetScript("OnLeave", function() optBG:SetColorTexture(0, 0, 0, 0) end)
            opt:SetScript("OnClick", function()
                selectedValue = item.value
                selectedText:SetText(item.text)
                menu:Hide()
                if onSelect then onSelect(item.value) end
            end)
            y = y - 20
        end
        menu:SetHeight(math.abs(y) + 4)
    end

    btn:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide() else BuildMenu(); menu:Show() end
    end)
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.6)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.8)
    end)

    -- Close menu on outside click
    local closer = CreateFrame("Button", nil, menu)
    closer:SetAllPoints(UIParent)
    closer:SetFrameStrata("FULLSCREEN")
    closer:SetScript("OnClick", function() menu:Hide(); closer:Hide() end)
    closer:Hide()
    menu:HookScript("OnShow", function() closer:Show() end)
    menu:HookScript("OnHide", function() closer:Hide() end)

    container.btn = btn
    container.selectedText = selectedText
    container.SetSelectedValue = function(self, val)
        selectedValue = val
        for _, item in ipairs(items) do
            if item.value == val then selectedText:SetText(item.text); break end
        end
    end
    container.GetSelectedValue = function(self) return selectedValue end
    container.SetItems = function(self, newItems) items = newItems end
    return container
end

-- Helper: section divider
local function CreateDRDivider(parent, yOffset)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yOffset)
    line:SetColorTexture(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.3)
    return line
end

-- ============================================================================
-- Build the Options Panel
-- ============================================================================

local optionsPanel = nil
local panelWidgets = {}

local function RefreshOptionsPanel()
    if not panelWidgets or not settings then return end
    if panelWidgets.selfMarkerCB then
        panelWidgets.selfMarkerCB:SetChecked(settings.showSelfMarker ~= false)
    end
    if panelWidgets.percentCB then
        panelWidgets.percentCB:SetChecked(settings.showPercentages ~= false)
    end
    if panelWidgets.totalHeaderCB then
        panelWidgets.totalHeaderCB:SetChecked(settings.showTotalInHeader ~= false)
    end
    if panelWidgets.autoReportCB then
        panelWidgets.autoReportCB:SetChecked(settings.autoReport or false)
    end
    if panelWidgets.autoDelaySlider then
        panelWidgets.autoDelaySlider:SetValue(settings.autoReportDelay or 2)
    end
    if panelWidgets.autoFormatDropdown then
        panelWidgets.autoFormatDropdown:SetSelectedValue(settings.autoReportFormat or "summary")
    end
    if panelWidgets.autoTypeDropdown then
        panelWidgets.autoTypeDropdown:SetSelectedValue(settings.autoReportType or "dps")
    end
    if panelWidgets.summaryCBs then
        for key, cb in pairs(panelWidgets.summaryCBs) do
            cb:SetChecked(settings[key] ~= false)
        end
    end
    if panelWidgets.autoChannelDropdown then
        panelWidgets.autoChannelDropdown:SetSelectedValue(settings.autoReportChannel or "party")
    end
    if panelWidgets.resetMythicCB then
        panelWidgets.resetMythicCB:SetChecked(settings.resetOnMythicStart or false)
    end
    if panelWidgets.shortNamesCB then
        panelWidgets.shortNamesCB:SetChecked(settings.shortNames ~= false)
    end
    if panelWidgets.meterShownCB then
        panelWidgets.meterShownCB:SetChecked(settings.meterShown ~= false)
    end
    if panelWidgets.meterLockedCB then
        panelWidgets.meterLockedCB:SetChecked(settings.meterLocked or false)
    end
    if panelWidgets.pinSelfCB then
        panelWidgets.pinSelfCB:SetChecked(settings.pinSelf or false)
    end

    if panelWidgets.barHeightSlider then
        panelWidgets.barHeightSlider:SetValue(settings.meterBarHeight or 18)
    end
    if panelWidgets.opacitySlider then
        panelWidgets.opacitySlider:SetValue(math.floor((settings.meterBgAlpha or 0.85) * 100 + 0.5))
    end
    if panelWidgets.barOpacitySlider then
        panelWidgets.barOpacitySlider:SetValue(math.floor((settings.meterBarAlpha or 0.8) * 100 + 0.5))
    end
    if panelWidgets.refreshRateSlider then
        local rate = settings.meterRefreshRate or 0.3
        panelWidgets.refreshRateSlider:SetValue(math.floor(rate * 10 + 0.5))
    end
    if panelWidgets.nicknameBox then
        local nick = (DPSReportDB and DPSReportDB.nicknames and DPSReportDB.nicknames[charKey]) or ""
        panelWidgets.nicknameBox:SetText(nick)
    end
    if panelWidgets.profileDropdown then
        panelWidgets.profileDropdown:SetSelectedValue(GetActiveProfile())
    end
    if panelWidgets.profLabel then
        panelWidgets.profLabel:SetText("Active: " .. GetActiveProfile())
    end
end

function DPSReport_OpenOptionsPanel()
    if optionsPanel then
        RefreshOptionsPanel()
        optionsPanel:Show()
        return
    end

    -- Main frame
    local panel = CreateFrame("Frame", "DPSReportOptions", UIParent, "BackdropTemplate")
    -- Wide enough for the 150px category sidebar plus the same content column
    -- the single-scroll layout used, so no widget had to be resized.
    panel:SetSize(580, 600)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    ApplyDRBackdrop(panel, DR_COLORS.bg, DR_COLORS.border)
    optionsPanel = panel

    -- Combat protection
    panel:RegisterEvent("PLAYER_REGEN_DISABLED")
    panel:RegisterEvent("PLAYER_REGEN_ENABLED")
    panel.wasShown = false
    panel:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if self:IsShown() then self.wasShown = true; self:Hide() end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if self.wasShown then self.wasShown = false; self:Show() end
        end
    end)

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    titleBar:SetHeight(32)
    titleBar:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -1)
    titleBar:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    titleBar:SetBackdropColor(DR_COLORS.titleBar[1], DR_COLORS.titleBar[2], DR_COLORS.titleBar[3], DR_COLORS.titleBar[4])
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() panel:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)

    local titleMain = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleMain:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
    titleMain:SetText("DPSREPORT")
    titleMain:SetTextColor(DR_COLORS.textBright[1], DR_COLORS.textBright[2], DR_COLORS.textBright[3])

    local titleSub = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleSub:SetPoint("LEFT", titleMain, "RIGHT", 6, 0)
    titleSub:SetText("Settings")
    titleSub:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    -- Close button (X)
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(32, 32)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    local closeText = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    closeText:SetPoint("CENTER")
    closeText:SetText("X")
    closeText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    closeBtn:SetScript("OnEnter", function() closeText:SetTextColor(DR_COLORS.danger[1], DR_COLORS.danger[2], DR_COLORS.danger[3]) end)
    closeBtn:SetScript("OnLeave", function() closeText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3]) end)
    closeBtn:SetScript("OnClick", function() panel:Hide() end)
    table.insert(UISpecialFrames, "DPSReportOptions")

    -- Accent line under title
    local accentLine = titleBar:CreateTexture(nil, "OVERLAY")
    accentLine:SetHeight(1)
    accentLine:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    accentLine:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.4)

    -- Content: a sidebar of categories, each with its own scrolling page.
    -- These sections used to be stacked in one long scroll, which meant paging
    -- past four unrelated groups to reach the meter options.
    local NAV_WIDTH   = 150
    local NAV_ITEM_H  = 26
    local PAGE_WIDTH  = 390   -- scroll child; same as the old single column

    local navBar = CreateFrame("Frame", nil, panel)
    navBar:SetWidth(NAV_WIDTH)
    navBar:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -1)
    navBar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 1, 40)

    local navEdge = navBar:CreateTexture(nil, "OVERLAY")
    navEdge:SetWidth(1)
    navEdge:SetPoint("TOPRIGHT", navBar, "TOPRIGHT", 0, 0)
    navEdge:SetPoint("BOTTOMRIGHT", navBar, "BOTTOMRIGHT", 0, 0)
    navEdge:SetColorTexture(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.5)

    local contentArea = CreateFrame("Frame", nil, panel)
    contentArea:SetPoint("TOPLEFT", navBar, "TOPRIGHT", 1, 0)
    contentArea:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -1, 40)

    -- `content` and `yOffset` are reassigned by NewPage as each category is
    -- built, so every section below keeps laying its widgets out against
    -- "the current page" exactly as it did against the single column.
    local content, yOffset
    local leftPad = 14
    local pages = {}
    local navCursorY = -6

    local function SwitchPage(target)
        for _, p in ipairs(pages) do
            local on = (p == target)
            p.active = on
            if on then
                p.frame:Show()
                p.btn:SetBackdropColor(DR_COLORS.tabActive[1], DR_COLORS.tabActive[2],
                    DR_COLORS.tabActive[3], 1)
                p.label:SetTextColor(DR_COLORS.textBright[1], DR_COLORS.textBright[2],
                    DR_COLORS.textBright[3])
                p.marker:Show()
            else
                p.frame:Hide()
                p.btn:SetBackdropColor(0, 0, 0, 0)
                p.label:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2],
                    DR_COLORS.textDim[3])
                p.marker:Hide()
            end
        end
    end

    -- Close off the page currently being built: its scroll child has to be as
    -- tall as the widgets that landed on it, or the scrollbar won't reach them.
    local function FinishPage()
        if content then
            content:SetHeight(math.abs(yOffset) + 20)
        end
    end

    local function NewPage(label)
        FinishPage()

        local btn = CreateFrame("Button", nil, navBar, "BackdropTemplate")
        btn:SetHeight(NAV_ITEM_H)
        btn:SetPoint("TOPLEFT", navBar, "TOPLEFT", 0, navCursorY)
        btn:SetPoint("TOPRIGHT", navBar, "TOPRIGHT", -1, navCursorY)
        navCursorY = navCursorY - NAV_ITEM_H
        btn:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
        btn:SetBackdropColor(0, 0, 0, 0)

        local btnLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btnLabel:SetPoint("LEFT", btn, "LEFT", 14, 0)
        btnLabel:SetJustifyH("LEFT")
        btnLabel:SetText(label)
        btnLabel:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

        local marker = btn:CreateTexture(nil, "OVERLAY")
        marker:SetWidth(3)
        marker:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
        marker:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
        marker:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 1)
        marker:Hide()

        local pageFrame = CreateFrame("Frame", nil, contentArea)
        pageFrame:SetAllPoints()
        pageFrame:Hide()

        local scroll = CreateFrame("ScrollFrame", nil, pageFrame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", pageFrame, "TOPLEFT", 0, 0)
        scroll:SetPoint("BOTTOMRIGHT", pageFrame, "BOTTOMRIGHT", -22, 0)
        SkinDRScrollBar(scroll)

        local child = CreateFrame("Frame", nil, scroll)
        child:SetWidth(PAGE_WIDTH)
        scroll:SetScrollChild(child)

        local page = { btn = btn, label = btnLabel, marker = marker,
                       frame = pageFrame, child = child }
        pages[#pages + 1] = page

        btn:SetScript("OnEnter", function(self)
            if not page.active then
                self:SetBackdropColor(DR_COLORS.controlHi[1], DR_COLORS.controlHi[2],
                    DR_COLORS.controlHi[3], 0.5)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if not page.active then self:SetBackdropColor(0, 0, 0, 0) end
        end)
        btn:SetScript("OnClick", function() SwitchPage(page) end)

        content = child
        yOffset = -14
        return page
    end

    -- === FORMATTING ===
    NewPage("Formatting")

    local selfMarkerCB = CreateDRCheckbox(content, "Show self marker (*)", function(checked)
        settings.showSelfMarker = checked
    end)
    selfMarkerCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.selfMarkerCB = selfMarkerCB
    yOffset = yOffset - 28

    local percentCB = CreateDRCheckbox(content, "Show percentages", function(checked)
        settings.showPercentages = checked
    end)
    percentCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.percentCB = percentCB
    yOffset = yOffset - 28

    local totalHeaderCB = CreateDRCheckbox(content, "Show total in report header", function(checked)
        settings.showTotalInHeader = checked
    end)
    totalHeaderCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.totalHeaderCB = totalHeaderCB
    yOffset = yOffset - 28

    local shortNamesCB = CreateDRCheckbox(content, "Short names (hide realm)", function(checked)
        settings.shortNames = checked
    end)
    shortNamesCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.shortNamesCB = shortNamesCB
    yOffset = yOffset - 28

    -- Nickname input
    local nickLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nickLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    nickLabel:SetText("Nickname (shared with other DPSReport users)")
    nickLabel:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    yOffset = yOffset - 18

    local nicknameBox = CreateFrame("EditBox", nil, content, "BackdropTemplate")
    nicknameBox:SetSize(200, 22)
    nicknameBox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    nicknameBox:SetAutoFocus(false)
    nicknameBox:SetMaxLetters(24)
    nicknameBox:SetFontObject(GameFontHighlightSmall)
    nicknameBox:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1 })
    nicknameBox:SetBackdropColor(DR_COLORS.bg[1], DR_COLORS.bg[2], DR_COLORS.bg[3], 0.9)
    nicknameBox:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 1)
    nicknameBox:SetTextInsets(6, 6, 0, 0)
    local currentNick = (DPSReportDB and DPSReportDB.nicknames and DPSReportDB.nicknames[charKey]) or ""
    nicknameBox:SetText(currentNick)

    local function CommitNickname()
        local nick = nicknameBox:GetText():match("^%s*(.-)%s*$") or ""
        if not DPSReportDB.nicknames then DPSReportDB.nicknames = {} end
        if nick == "" then
            DPSReportDB.nicknames[charKey] = nil
            nicknameCache[charKey] = nil
            local base = charKey:match("^[^-]+")
            if base then nicknameCache[base] = nil end
        else
            DPSReportDB.nicknames[charKey] = nick
            nicknameCache[charKey] = nick
            local base = charKey:match("^[^-]+")
            if base then nicknameCache[base] = nick end
        end
        nicknameBox:ClearFocus()
        BroadcastNickname()
        -- Refresh meters to show updated name
        if DPSMeter and DPSMeter.meters then
            for _, meter in ipairs(DPSMeter.meters) do
                meter:RefreshDisplay()
            end
        end
    end
    nicknameBox:SetScript("OnEnterPressed", CommitNickname)
    nicknameBox:SetScript("OnEscapePressed", function()
        nicknameBox:SetText(currentNick)
        nicknameBox:ClearFocus()
    end)
    nicknameBox:SetScript("OnEditFocusLost", CommitNickname)
    panelWidgets.nicknameBox = nicknameBox
    yOffset = yOffset - 32

    -- === AUTO REPORT ===
    NewPage("Auto Report")

    local autoReportCB = CreateDRCheckbox(content, "Auto-report at end of M+ dungeon", function(checked)
        settings.autoReport = checked
    end)
    autoReportCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.autoReportCB = autoReportCB
    yOffset = yOffset - 28

    local autoDelaySlider = CreateDRSlider(content, "Delay (seconds)", 300, 0, 10, 1)
    autoDelaySlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    autoDelaySlider:SetAfterValueChanged(function(value)
        settings.autoReportDelay = value
    end)
    panelWidgets.autoDelaySlider = autoDelaySlider
    yOffset = yOffset - 50

    local autoFormatItems = {
        { text = "Run summary",   value = "summary" },
        { text = "Single metric", value = "single" },
    }
    local autoFormatDropdown = CreateDRDropdown(content, "Format", 200, autoFormatItems, function(value)
        settings.autoReportFormat = value
    end)
    autoFormatDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.autoFormatDropdown = autoFormatDropdown
    yOffset = yOffset - 52

    -- Single-metric mode. Values are METER_MODE_MAP keys, matching the keys
    -- SnapshotMythicRun writes under seg.modes -- picking them straight from
    -- that namespace is what avoids the translation step the report widget
    -- still needs. Enemy Damage Taken is absent on purpose: METER_MODE_MAP has
    -- no entry for it, so it is never captured into a segment.
    local autoTypeItems = {
        { text = "DPS", value = "dps" },
        { text = "HPS", value = "hps" },
        { text = "Damage Done", value = "damage" },
        { text = "Healing Done", value = "healing" },
        { text = "Absorbs", value = "absorbs" },
        { text = "Interrupts", value = "interrupts" },
        { text = "Dispels", value = "dispels" },
        { text = "Damage Taken", value = "taken" },
        { text = "Avoidable Damage", value = "avoidable" },
        { text = "Deaths", value = "deaths" },
    }
    local autoTypeDropdown = CreateDRDropdown(content, "Metric (single metric only)", 200, autoTypeItems, function(value)
        settings.autoReportType = value
    end)
    autoTypeDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.autoTypeDropdown = autoTypeDropdown
    yOffset = yOffset - 46

    local singleNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    singleNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    singleNote:SetWidth(340)
    singleNote:SetJustifyH("LEFT")
    singleNote:SetText("Single metric lists the whole group, highest to lowest.")
    singleNote:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    yOffset = yOffset - 26

    -- Summary lines. Only apply to the "Run summary" format; each line is a
    -- toggle so the announce can be pared back to what a group cares about.
    local summaryLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    summaryLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    summaryLabel:SetText("Summary lines (run summary only)")
    summaryLabel:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
    yOffset = yOffset - 22

    local summaryLines = {
        { key = "autoSummaryHeader",     text = "Dungeon name, level and time" },
        { key = "autoSummaryMVP",        text = "MVP" },
        { key = "autoSummaryTopDamage",  text = "Top DPS" },
        { key = "autoSummaryTopHealing", text = "Top HPS" },
        { key = "autoSummaryInterrupts", text = "Top interrupts" },
        { key = "autoSummaryDispels",    text = "Top dispels" },
        { key = "autoSummaryAvoidable",  text = "Least avoidable damage" },
        { key = "autoSummaryDeaths",     text = "Deaths (total and who died most)" },
    }
    panelWidgets.summaryCBs = {}
    for _, line in ipairs(summaryLines) do
        local key = line.key
        local cb = CreateDRCheckbox(content, line.text, function(checked)
            settings[key] = checked
        end)
        cb:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
        panelWidgets.summaryCBs[key] = cb
        yOffset = yOffset - 26
    end
    yOffset = yOffset - 10

    local autoChannelItems = {
        { text = "Say", value = "say" },
        { text = "Yell", value = "yell" },
        { text = "Party", value = "party" },
        { text = "Instance", value = "instance" },
        { text = "Guild", value = "guild" },
        { text = "Officer", value = "officer" },
    }
    local autoChannelDropdown = CreateDRDropdown(content, "Auto Report Channel", 200, autoChannelItems, function(value)
        settings.autoReportChannel = value
    end)
    autoChannelDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.autoChannelDropdown = autoChannelDropdown
    yOffset = yOffset - 52

    -- === MYTHIC+ ===
    NewPage("Mythic+")

    local resetMythicCB = CreateDRCheckbox(content, "Reset meters when M+ starts", function(checked)
        settings.resetOnMythicStart = checked
    end)
    resetMythicCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.resetMythicCB = resetMythicCB
    yOffset = yOffset - 24

    -- === REAL-TIME METER ===
    NewPage("Meter")

    local meterShownCB = CreateDRCheckbox(content, "Show meter", function(checked)
        settings.meterShown = checked
        if DPSMeter and DPSMeter.meters then
            for _, meter in ipairs(DPSMeter.meters) do
                if meter.frame then
                    if checked then meter.frame:Show() else meter.frame:Hide() end
                end
            end
        end
    end)
    meterShownCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.meterShownCB = meterShownCB
    yOffset = yOffset - 28

    local meterLockedCB = CreateDRCheckbox(content, "Lock meter position", function(checked)
        settings.meterLocked = checked
    end)
    meterLockedCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.meterLockedCB = meterLockedCB
    yOffset = yOffset - 28

    local pinSelfCB = CreateDRCheckbox(content, "Always show self", function(checked)
        settings.pinSelf = checked
        if DPSMeter and DPSMeter.meters then
            for _, meter in ipairs(DPSMeter.meters) do
                meter:UpdateSelfPin()
            end
        end
    end)
    pinSelfCB:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    panelWidgets.pinSelfCB = pinSelfCB
    yOffset = yOffset - 32

    local barHeightSlider = CreateDRSlider(content, "Bar Height", 300, 10, 32, 1)
    barHeightSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    barHeightSlider:SetAfterValueChanged(function(value)
        settings.meterBarHeight = value
        if DPSMeter and DPSMeter.meters then
            for _, meter in ipairs(DPSMeter.meters) do
                if meter.frame then meter:RebuildBars() end
            end
        end
    end)
    panelWidgets.barHeightSlider = barHeightSlider
    yOffset = yOffset - 50

    local opacitySlider = CreateDRSlider(content, "Frame Opacity (%)", 300, 10, 100, 5)
    opacitySlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    opacitySlider:SetAfterValueChanged(function(value)
        settings.meterBgAlpha = value / 100
        if DPSMeter and DPSMeter.meters then
            for _, meter in ipairs(DPSMeter.meters) do
                if meter.frame then
                    ApplyDRBackdrop(meter.frame, {0.04, 0.04, 0.06, settings.meterBgAlpha}, DR_COLORS.border)
                end
            end
        end
    end)
    panelWidgets.opacitySlider = opacitySlider
    yOffset = yOffset - 50

    local barOpacitySlider = CreateDRSlider(content, "Bar Opacity (%)", 300, 10, 100, 5)
    barOpacitySlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    barOpacitySlider:SetAfterValueChanged(function(value)
        settings.meterBarAlpha = value / 100
        if DPSMeter and DPSMeter.meters then
            for _, meter in ipairs(DPSMeter.meters) do
                meter:RefreshDisplay()
            end
        end
    end)
    panelWidgets.barOpacitySlider = barOpacitySlider
    yOffset = yOffset - 50

    local refreshRateSlider = CreateDRSlider(content, "Refresh Rate (seconds)", 300, 1, 20, 1)
    refreshRateSlider:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    refreshRateSlider:SetValueFormat("%.1f s")
    refreshRateSlider:SetDisplayTransform(function(v) return v / 10 end)
    refreshRateSlider:SetAfterValueChanged(function(value)
        local rate = value / 10
        settings.meterRefreshRate = rate
        -- Restart running tickers with the new interval
        if DPSMeter and DPSMeter.meters then
            for _, meter in ipairs(DPSMeter.meters) do
                if meter.ticker then
                    meter:StopRefreshTicker()
                    meter:StartRefreshTicker()
                end
            end
        end
    end)
    panelWidgets.refreshRateSlider = refreshRateSlider
    yOffset = yOffset - 50

    -- === PROFILES ===
    NewPage("Profiles")
    -- Kept as an in-page header: unlike the other sections this one carries the
    -- active profile name, which RefreshOptionsPanel updates.
    local profLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    profLabel:SetText("Active: " .. GetActiveProfile())
    profLabel:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
    panelWidgets.profLabel = profLabel
    yOffset = yOffset - 22

    -- Build profile dropdown items
    local function BuildProfileItems()
        local items = {}
        for name in pairs(DPSReportDB.profiles) do
            table.insert(items, { text = name, value = name })
        end
        table.sort(items, function(a, b) return a.text < b.text end)
        return items
    end

    -- Dropdown only selects a profile name — does NOT auto-load
    local profileDropdown = CreateDRDropdown(content, "Select Profile", 200, BuildProfileItems(), nil)
    profileDropdown:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    profileDropdown:SetSelectedValue(GetActiveProfile())
    panelWidgets.profileDropdown = profileDropdown
    yOffset = yOffset - 52

    -- Load / Save buttons on one row
    local loadProfBtn = CreateDRButton(content, "Load Profile", 100, 22)
    loadProfBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    loadProfBtn:SetScript("OnClick", function()
        local selected = profileDropdown:GetSelectedValue()
        if not selected then return end
        if not DPSReportDB.profiles[selected] then
            print("|cff00ccff[DPSReport]|r Profile '" .. selected .. "' does not exist.")
            return
        end
        SwitchProfile(selected)
        RefreshOptionsPanel()
        print("|cff00ccff[DPSReport]|r Profile '" .. selected .. "' loaded.")
    end)

    local saveProfBtn = CreateDRButton(content, "Save Current", 100, 22)
    saveProfBtn:SetPoint("LEFT", loadProfBtn, "RIGHT", 8, 0)
    saveProfBtn:SetScript("OnClick", function()
        local current = GetActiveProfile()
        SaveMeterLayoutToSettings()
        DPSReportDB.profiles[current] = CopyTable(settings)
        settings = DPSReportDB.profiles[current]
        print("|cff00ccff[DPSReport]|r Profile '" .. current .. "' saved.")
    end)
    yOffset = yOffset - 30

    -- New profile: name input + save button on same row
    local newProfLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    newProfLabel:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    newProfLabel:SetText("New Profile Name")
    newProfLabel:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    yOffset = yOffset - 18

    local newProfBox = CreateFrame("EditBox", nil, content, "BackdropTemplate")
    newProfBox:SetSize(140, 22)
    newProfBox:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    newProfBox:SetAutoFocus(false)
    newProfBox:SetMaxLetters(20)
    newProfBox:SetFontObject(GameFontHighlightSmall)
    newProfBox:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1 })
    newProfBox:SetBackdropColor(DR_COLORS.bg[1], DR_COLORS.bg[2], DR_COLORS.bg[3], 0.9)
    newProfBox:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 1)
    newProfBox:SetTextInsets(6, 6, 0, 0)

    local saveProfileBtn = CreateDRButton(content, "Save", 60, 22)
    saveProfileBtn:SetPoint("LEFT", newProfBox, "RIGHT", 6, 0)
    saveProfileBtn:SetScript("OnClick", function()
        local name = newProfBox:GetText():match("^%s*(.-)%s*$") or ""
        if name == "" then return end
        -- Copy current settings + layout into the new profile
        SaveMeterLayoutToSettings()
        DPSReportDB.profiles[name] = CopyTable(settings)
        SwitchProfile(name)
        profileDropdown:SetItems(BuildProfileItems())
        profileDropdown:SetSelectedValue(name)
        newProfBox:SetText("")
        newProfBox:ClearFocus()
        RefreshOptionsPanel()
        print("|cff00ccff[DPSReport]|r Profile '" .. name .. "' saved.")
    end)
    newProfBox:SetScript("OnEnterPressed", function() saveProfileBtn:GetScript("OnClick")() end)
    newProfBox:SetScript("OnEscapePressed", function() newProfBox:SetText(""); newProfBox:ClearFocus() end)
    yOffset = yOffset - 30

    local deleteProfBtn = CreateDRButton(content, "Delete Current Profile", 160, 22, DR_COLORS.danger)
    deleteProfBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    deleteProfBtn:SetScript("OnClick", function()
        local current = GetActiveProfile()
        if current == "Default" then
            print("|cff00ccff[DPSReport]|r Cannot delete the Default profile.")
            return
        end
        DPSReportDB.profiles[current] = nil
        SwitchProfile("Default")
        profileDropdown:SetItems(BuildProfileItems())
        profileDropdown:SetSelectedValue("Default")
        RefreshOptionsPanel()
        print("|cff00ccff[DPSReport]|r Profile '" .. current .. "' deleted.")
    end)
    yOffset = yOffset - 32

    -- === TOOLS ===
    NewPage("Tools")

    -- Preview goes to your own chat frame only, never to the group -- the whole
    -- point is checking what a run would announce without announcing it.
    local previewBtn = CreateDRButton(content, "Preview Last Run Announce", 200, 26)
    previewBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    previewBtn:SetScript("OnClick", function()
        local segIdx = LatestSegmentIndex()
        if not segIdx then
            print("|cff00ccff[DPSReport]|r No run recorded yet - finish a Mythic+ "
                .. "key (or any fight that creates a segment) first.")
            return
        end
        local lines, err = BuildMythicAnnounce(segIdx)
        if err or not lines then
            print("|cff00ccff[DPSReport]|r " .. (err or "Nothing to preview."))
            return
        end
        print("|cff00ccff[DPSReport]|r Preview - shown to you only, not sent to chat:")
        for _, line in ipairs(lines) do
            print("|cff999999" .. line .. "|r")
        end
    end)
    yOffset = yOffset - 34

    local previewNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    previewNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    previewNote:SetWidth(340)
    previewNote:SetJustifyH("LEFT")
    previewNote:SetText("Uses the most recent recorded segment and the Auto Report "
        .. "settings above.")
    previewNote:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    yOffset = yOffset - 34

    local deathDiagBtn = CreateDRButton(content, "Death Tracking Diagnostics", 200, 26)
    deathDiagBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    deathDiagBtn:SetScript("OnClick", function()
        DeathTracker:PrintDiagnostics()
    end)
    yOffset = yOffset - 34

    local deathDiagNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    deathDiagNote:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    deathDiagNote:SetWidth(340)
    deathDiagNote:SetJustifyH("LEFT")
    deathDiagNote:SetText("Prints which group members the addon can read death "
        .. "state for. Feign Death is only filtered out for readable players; "
        .. "the rest keep the game's own count. Your chat frame only.")
    deathDiagNote:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    yOffset = yOffset - 46

    local resetBtn = CreateDRButton(content, "Reset to Defaults", 140, 26, DR_COLORS.danger)
    resetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, yOffset)
    resetBtn:SetScript("OnClick", function()
        local profName = GetActiveProfile()
        DPSReportDB.profiles[profName] = CopyTable(DEFAULT_SETTINGS)
        settings = DPSReportDB.profiles[profName]
        RefreshOptionsPanel()
        print("|cff00ccff[DPSReport]|r Settings reset to defaults.")
    end)
    yOffset = yOffset - 40

    -- Close off the last page and open on the first one.
    FinishPage()
    SwitchPage(pages[1])

    -- Bottom bar
    local bottomBar = CreateFrame("Frame", nil, panel)
    bottomBar:SetHeight(40)
    bottomBar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 1, 1)
    bottomBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -1, 1)

    local bottomLine = bottomBar:CreateTexture(nil, "OVERLAY")
    bottomLine:SetHeight(1)
    bottomLine:SetPoint("TOPLEFT", bottomBar, "TOPLEFT", 0, 0)
    bottomLine:SetPoint("TOPRIGHT", bottomBar, "TOPRIGHT", 0, 0)
    bottomLine:SetColorTexture(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.3)

    local closeBtnBottom = CreateDRButton(bottomBar, "Close", 80, 26)
    closeBtnBottom:SetPoint("CENTER", bottomBar, "CENTER", 0, 0)
    closeBtnBottom:SetScript("OnClick", function() panel:Hide() end)

    RefreshOptionsPanel()
    panel:Show()
end

-- ============================================================================
-- Quick Report Widget (compact in-game toolbar)
-- ============================================================================

reportWidget = nil
local widgetState = {
    type = "dps",
    session = "current",
    channel = "say",
    topCount = 5,
}

-- Compact inline dropdown for the widget (opens upward or downward)
local function CreateWidgetDropdown(parent, width, items, defaultValue, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, 20)

    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetSize(width, 20)
    btn:SetPoint("LEFT")
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(DR_COLORS.control[1], DR_COLORS.control[2], DR_COLORS.control[3], 1)
    btn:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.6)

    local selectedText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    selectedText:SetPoint("LEFT", 6, 0)
    selectedText:SetPoint("RIGHT", -14, 0)
    selectedText:SetWordWrap(false)
    selectedText:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])

    local arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", -4, 0)
    arrow:SetText("v")
    arrow:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    local menu = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    local menuMinWidth = width
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    menu:SetBackdropColor(DR_COLORS.bg[1], DR_COLORS.bg[2], DR_COLORS.bg[3], 0.98)
    menu:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 1)
    menu:Hide()

    local selectedValue = defaultValue

    -- Set initial text
    for _, item in ipairs(items) do
        if item.value == defaultValue then
            selectedText:SetText(item.text)
            break
        end
    end

    local W_ROW_H = 18
    local W_MAX_SEGMENT_ROWS = 5

    local function BuildMenu()
        for _, child in pairs({menu:GetChildren()}) do child:Hide(); child:SetParent(nil) end
        -- Measure widest item to auto-size menu
        local measureFS = menu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        local maxTextW = 0
        for _, item in ipairs(items) do
            if item.value ~= "_separator" then
                measureFS:SetText(item.text)
                local w = measureFS:GetStringWidth()
                if w > maxTextW then maxTextW = w end
            end
        end
        measureFS:Hide()
        local menuW = math.max(menuMinWidth, maxTextW + 20)
        menu:SetWidth(menuW)

        -- Split items into fixed (before separator) and scrollable (after)
        local fixedItems = {}
        local segItems = {}
        local pastSep = false
        for _, item in ipairs(items) do
            if item.value == "_separator" then
                pastSep = true
            elseif pastSep then
                table.insert(segItems, item)
            else
                table.insert(fixedItems, item)
            end
        end

        local y = -4
        -- Render fixed items
        for _, item in ipairs(fixedItems) do
            local opt = CreateFrame("Button", nil, menu)
            opt:SetSize(menuW - 8, W_ROW_H)
            opt:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, y)
            local optBG = opt:CreateTexture(nil, "BACKGROUND")
            optBG:SetAllPoints()
            optBG:SetColorTexture(0, 0, 0, 0)
            local iconOffset = 4
            if item.icon then
                local optIcon = opt:CreateTexture(nil, "OVERLAY")
                optIcon:SetSize(14, 14)
                optIcon:SetPoint("LEFT", 4, 0)
                optIcon:SetTexture(item.icon)
                iconOffset = 22
            end
            local optText = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            optText:SetPoint("LEFT", iconOffset, 0)
            optText:SetText(item.text)
            if item.value == selectedValue then
                optText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
            else
                optText:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])
            end
            opt:SetScript("OnEnter", function() optBG:SetColorTexture(DR_COLORS.controlHi[1], DR_COLORS.controlHi[2], DR_COLORS.controlHi[3], 1) end)
            opt:SetScript("OnLeave", function() optBG:SetColorTexture(0, 0, 0, 0) end)
            opt:SetScript("OnClick", function()
                selectedValue = item.value
                selectedText:SetText(item.text)
                menu:Hide()
                if onChange then onChange(item.value) end
            end)
            y = y - W_ROW_H
        end

        -- Separator + scrollable segments
        if #segItems > 0 then
            local sep = menu:CreateTexture(nil, "ARTWORK")
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, y - 3)
            sep:SetPoint("RIGHT", menu, "RIGHT", -6, 0)
            sep:SetColorTexture(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.5)
            y = y - 7

            local visibleCount = math.min(#segItems, W_MAX_SEGMENT_ROWS)
            local scrollAreaH = visibleCount * W_ROW_H
            local contentH = #segItems * W_ROW_H

            local scrollFrame = CreateFrame("ScrollFrame", nil, menu)
            scrollFrame:SetSize(menuW - 8, scrollAreaH)
            scrollFrame:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, y)

            local scrollChild = CreateFrame("Frame", nil, scrollFrame)
            scrollChild:SetSize(menuW - 8, contentH)
            scrollFrame:SetScrollChild(scrollChild)

            local sy = 0
            for _, item in ipairs(segItems) do
                local opt = CreateFrame("Button", nil, scrollChild)
                opt:SetSize(menuW - 8, W_ROW_H)
                opt:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, sy)
                local optBG = opt:CreateTexture(nil, "BACKGROUND")
                optBG:SetAllPoints()
                optBG:SetColorTexture(0, 0, 0, 0)
                local iconOffset = 4
                if item.icon then
                    local optIcon = opt:CreateTexture(nil, "OVERLAY")
                    optIcon:SetSize(14, 14)
                    optIcon:SetPoint("LEFT", 4, 0)
                    optIcon:SetTexture(item.icon)
                    iconOffset = 22
                end
                local optText = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                optText:SetPoint("LEFT", iconOffset, 0)
                optText:SetPoint("RIGHT", -4, 0)
                optText:SetWordWrap(false)
                optText:SetText(item.text)
                if item.value == selectedValue then
                    optText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
                else
                    optText:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])
                end
                opt:SetScript("OnEnter", function() optBG:SetColorTexture(DR_COLORS.controlHi[1], DR_COLORS.controlHi[2], DR_COLORS.controlHi[3], 1) end)
                opt:SetScript("OnLeave", function() optBG:SetColorTexture(0, 0, 0, 0) end)
                opt:SetScript("OnClick", function()
                    selectedValue = item.value
                    selectedText:SetText(item.text)
                    menu:Hide()
                    if onChange then onChange(item.value) end
                end)
                sy = sy - W_ROW_H
            end

            if #segItems > W_MAX_SEGMENT_ROWS then
                scrollFrame:EnableMouseWheel(true)
                scrollFrame:SetScript("OnMouseWheel", function(self, delta)
                    local cur = self:GetVerticalScroll()
                    local maxScroll = contentH - scrollAreaH
                    self:SetVerticalScroll(math.max(0, math.min(maxScroll, cur - delta * W_ROW_H)))
                end)
            end

            y = y - scrollAreaH
        end

        menu:SetHeight(math.abs(y) + 4)
    end

    btn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            -- Position menu above the button if near bottom of screen
            menu:ClearAllPoints()
            local _, screenHeight = GetPhysicalScreenSize()
            local btnBottom = btn:GetBottom() or 0
            if btnBottom < 200 then
                menu:SetPoint("BOTTOMLEFT", btn, "TOPLEFT", 0, 2)
            else
                menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
            end
            BuildMenu()
            menu:Show()
        end
    end)
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.5)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.6)
    end)

    -- Close menu on outside click
    local closer = CreateFrame("Button", nil, menu)
    closer:SetAllPoints(UIParent)
    closer:SetFrameStrata("FULLSCREEN")
    closer:SetScript("OnClick", function() menu:Hide(); closer:Hide() end)
    closer:Hide()
    menu:HookScript("OnShow", function() closer:Show() end)
    menu:HookScript("OnHide", function() closer:Hide() end)

    container.SetSelectedValue = function(self, val)
        selectedValue = val
        for _, item in ipairs(items) do
            if item.value == val then selectedText:SetText(item.text); break end
        end
    end
    container.GetSelectedValue = function(self) return selectedValue end
    container.SetItems = function(self, newItems)
        items = newItems
    end
    return container
end

local function SaveWidgetPosition()
    if not reportWidget then return end
    if not DPSReportDB then DPSReportDB = {} end
    local point, _, relativePoint, xOfs, yOfs = reportWidget:GetPoint()
    DPSReportDB.widgetPosition = {
        point = point,
        relativePoint = relativePoint,
        x = xOfs,
        y = yOfs,
    }
end

local function SaveWidgetSettings()
    if not DPSReportDB then DPSReportDB = {} end
    DPSReportDB.widgetState = {
        type = widgetState.type,
        session = widgetState.session,
        channel = widgetState.channel,
        topCount = widgetState.topCount,
    }
end

local function LoadWidgetSettings()
    if DPSReportDB and DPSReportDB.widgetState then
        local s = DPSReportDB.widgetState
        widgetState.type = s.type or widgetState.type
        widgetState.session = s.session or widgetState.session
        local ch = s.channel or widgetState.channel
        -- Migrate removed options
        if ch == "auto" or ch == "self" then ch = "say" end
        if ch == "raid" then ch = "instance" end
        widgetState.channel = ch
        widgetState.topCount = s.topCount or widgetState.topCount
    end
end

local function LoadWidgetPosition()
    if not reportWidget then return end
    if DPSReportDB and DPSReportDB.widgetPosition then
        local pos = DPSReportDB.widgetPosition
        reportWidget:ClearAllPoints()
        reportWidget:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    end
end

-- Forward declarations (implementations follow DPSMeter init section)
local GetAvailableAPISessions
local FindAPISession

local function CreateReportWidget()
    if reportWidget then return reportWidget end

    local typeItems = {
        { text = "DPS", value = "dps" },
        { text = "HPS", value = "hps" },
        { text = "Damage", value = "damage" },
        { text = "Healing", value = "healing" },
        { text = "Absorbs", value = "absorbs" },
        { text = "Interrupts", value = "interrupts" },
        { text = "Dispels", value = "dispels" },
        { text = "Dmg Taken", value = "dtaken" },
        { text = "Avoidable", value = "avoidable" },
        { text = "Deaths", value = "deaths" },
        { text = "Enemy Dmg", value = "edamage" },
    }
    local sessionItems = {
        { text = "Current", value = "current" },
        { text = "Overall", value = "overall" },
    }
    local function BuildWidgetSessionItems()
        local items = {}
        table.insert(items, { text = "Current", value = "current" })
        table.insert(items, { text = "Overall", value = "overall" })
        local apiSessions = GetAvailableAPISessions()
        if #apiSessions > 0 then
            table.insert(items, { text = "", value = "_separator" })
            for i = #apiSessions, 1, -1 do
                local s = apiSessions[i]
                local dur = (s.durationSeconds and s.durationSeconds > 0)
                    and (" (" .. FormatDuration(s.durationSeconds) .. ")") or ""
                table.insert(items, { text = (s.name or "Combat") .. dur, value = "sid:" .. s.sessionID })
            end
        end
        if #DPSMeter.segments > 0 then
            table.insert(items, { text = "", value = "_separator" })
            for i = #DPSMeter.segments, 1, -1 do
                local seg = DPSMeter.segments[i]
                local label = seg.name .. " (" .. FormatDuration(seg.duration) .. ")"
                table.insert(items, { text = label, value = "seg:" .. i })
            end
        end
        return items
    end
    DPSMeter.BuildWidgetSessionItems = BuildWidgetSessionItems
    local channelItems = {
        { text = "Say", value = "say" },
        { text = "Party", value = "party" },
        { text = "Instance", value = "instance" },
        { text = "Guild", value = "guild" },
        { text = "Yell", value = "yell" },
    }

    -- Build channel list with online BNet friends appended
    local function BuildChannelItems()
        local items = {
            { text = "Say", value = "say" },
        }
        if IsInGroup() then
            table.insert(items, { text = "Party", value = "party" })
        end
        table.insert(items, { text = "Instance", value = "instance" })
        table.insert(items, { text = "Guild", value = "guild" })
        table.insert(items, { text = "Yell", value = "yell" })
        -- Append online BNet friends
        local numTotal, numOnline = BNGetNumFriends()
        if numOnline and numOnline > 0 then
            table.insert(items, { text = "--- Friends ---", value = "_separator" })
            for i = 1, numTotal do
                local info = C_BattleNet.GetFriendAccountInfo(i)
                if info and info.gameAccountInfo and info.gameAccountInfo.isOnline then
                    local charName = info.gameAccountInfo.characterName
                    local bTag = info.accountName or ""
                    local presenceID = info.bnetAccountID
                    local label = charName or bTag
                    if charName and bTag and bTag ~= "" then
                        label = charName .. " (" .. bTag .. ")"
                    end
                    if presenceID then
                        table.insert(items, { text = label, value = "bn:" .. presenceID, icon = "Interface\\FriendsFrame\\Battlenet-Battleneticon" })
                    end
                end
            end
        end
        return items
    end
    -- Load persisted widget settings (overrides defaults)
    LoadWidgetSettings()

    -- Main frame
    local widget = CreateFrame("Frame", "DPSReportWidget", UIParent, "BackdropTemplate")
    widget:SetSize(220, 160)
    widget:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    widget:SetFrameStrata("MEDIUM")
    widget:SetMovable(true)
    widget:EnableMouse(true)
    widget:SetClampedToScreen(true)
    ApplyDRBackdrop(widget, DR_COLORS.bg, DR_COLORS.border)
    reportWidget = widget

    -- Combat protection
    widget:RegisterEvent("PLAYER_REGEN_DISABLED")
    widget:RegisterEvent("PLAYER_REGEN_ENABLED")
    widget.wasShown = false
    widget:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if self:IsShown() then self.wasShown = true; self:Hide() end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if self.wasShown then self.wasShown = false; self:Show() end
        end
    end)

    -- Title bar (thin, doubles as drag handle)
    local titleBar = CreateFrame("Frame", nil, widget, "BackdropTemplate")
    titleBar:SetHeight(18)
    titleBar:SetPoint("TOPLEFT", widget, "TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", widget, "TOPRIGHT", -1, -1)
    titleBar:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    titleBar:SetBackdropColor(DR_COLORS.titleBar[1], DR_COLORS.titleBar[2], DR_COLORS.titleBar[3], 1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function()
        if not settings or not settings.widgetLocked then
            widget:StartMoving()
        end
    end)
    titleBar:SetScript("OnDragStop", function()
        widget:StopMovingOrSizing()
        SaveWidgetPosition()
    end)

    -- Title text
    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("LEFT", 6, 0)
    titleText:SetText("DPSReport")
    titleText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])

    -- Gear icon (opens settings)
    local gearBtn = CreateFrame("Button", nil, titleBar)
    gearBtn:SetSize(16, 16)
    gearBtn:SetPoint("RIGHT", titleBar, "RIGHT", -18, 0)
    local gearText = gearBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gearText:SetPoint("CENTER")
    gearText:SetText("\226\154\153") -- gear unicode ⚙
    gearText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    gearBtn:SetScript("OnEnter", function() gearText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3]) end)
    gearBtn:SetScript("OnLeave", function() gearText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3]) end)
    gearBtn:SetScript("OnClick", function() DPSReport_OpenOptionsPanel() end)

    -- Close/hide button
    local hideBtn = CreateFrame("Button", nil, titleBar)
    hideBtn:SetSize(16, 16)
    hideBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    local hideText = hideBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hideText:SetPoint("CENTER")
    hideText:SetText("X")
    hideText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    hideBtn:SetScript("OnEnter", function() hideText:SetTextColor(DR_COLORS.danger[1], DR_COLORS.danger[2], DR_COLORS.danger[3]) end)
    hideBtn:SetScript("OnLeave", function() hideText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3]) end)
    hideBtn:SetScript("OnClick", function()
        widget:Hide()
        if settings then settings.widgetShown = false end
    end)

    -- Accent line
    local accentLine = titleBar:CreateTexture(nil, "OVERLAY")
    accentLine:SetHeight(1)
    accentLine:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    accentLine:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.3)

    -- Content area: single row of compact dropdowns + report button
    local content = CreateFrame("Frame", nil, widget)
    content:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 4, -4)
    content:SetPoint("BOTTOMRIGHT", widget, "BOTTOMRIGHT", -4, 4)

    -- Vertical layout: one setting per row with label + dropdown
    local labelW = 60
    local dropW = 140
    local rowH = 22
    local y = 0

    -- Row 1: Type
    local typeLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    typeLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y - 3)
    typeLabel:SetText("Type")
    typeLabel:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    local typeDrop = CreateWidgetDropdown(content, dropW, typeItems, widgetState.type, function(val)
        widgetState.type = val
        SaveWidgetSettings()
    end)
    typeDrop:SetPoint("TOPLEFT", content, "TOPLEFT", labelW, -y)
    y = y + rowH

    -- Row 2: Session
    local sessionLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessionLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y - 3)
    sessionLabel:SetText("Session")
    sessionLabel:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    local sessionDrop = CreateWidgetDropdown(content, dropW, BuildWidgetSessionItems(), widgetState.session, function(val)
        widgetState.session = val
        SaveWidgetSettings()
    end)
    sessionDrop:SetPoint("TOPLEFT", content, "TOPLEFT", labelW, -y)
    -- Store reference for external refresh
    DPSMeter.widgetSessionDrop = sessionDrop
    y = y + rowH

    -- Row 3: Count (text input, 1-40)
    local countLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y - 3)
    countLabel:SetText("Top #")
    countLabel:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    local countBox = CreateFrame("EditBox", nil, content, "BackdropTemplate")
    countBox:SetSize(dropW, 18)
    countBox:SetPoint("TOPLEFT", content, "TOPLEFT", labelW, -y)
    countBox:SetAutoFocus(false)
    countBox:SetNumeric(true)
    countBox:SetMaxLetters(2)
    countBox:SetFontObject(GameFontHighlightSmall)
    countBox:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1 })
    countBox:SetBackdropColor(DR_COLORS.bg[1], DR_COLORS.bg[2], DR_COLORS.bg[3], 0.9)
    countBox:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 1)
    countBox:SetTextInsets(6, 6, 0, 0)
    countBox:SetText(tostring(widgetState.topCount or 5))

    local function CommitCount()
        local num = countBox:GetNumber()
        if num < 1 then num = 1 end
        if num > 40 then num = 40 end
        countBox:SetText(tostring(num))
        widgetState.topCount = num
        SaveWidgetSettings()
        countBox:ClearFocus()
    end
    countBox:SetScript("OnEnterPressed", CommitCount)
    countBox:SetScript("OnEscapePressed", function()
        countBox:SetText(tostring(widgetState.topCount or 5))
        countBox:ClearFocus()
    end)
    countBox:SetScript("OnEditFocusLost", CommitCount)
    y = y + rowH

    -- Row 4: Channel
    local chanLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chanLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y - 3)
    chanLabel:SetText("Channel")
    chanLabel:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    local chanDrop = CreateWidgetDropdown(content, dropW, channelItems, widgetState.channel, function(val)
        if val == "_separator" then return end -- ignore separator clicks
        widgetState.channel = val
        SaveWidgetSettings()
    end)
    chanDrop:SetPoint("TOPLEFT", content, "TOPLEFT", labelW, -y)

    -- Refresh BNet friends in the channel dropdown whenever the widget is shown
    widget:HookScript("OnShow", function()
        chanDrop:SetItems(BuildChannelItems())
    end)
    y = y + rowH + 4

    -- Report button (full width)
    local reportBtn = CreateDRButton(content, "Report", 0, 22)
    reportBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    reportBtn:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    reportBtn:SetScript("OnClick", function()
        local topN = widgetState.topCount or 10

        local lines, err
        local ws = widgetState.session or "current"
        if ws:sub(1, 4) == "seg:" then
            -- Map widget type names (TYPE_MAP keys) to segment storage mode
            -- names (METER_MODE_MAP keys). Only the names that actually differ
            -- belong here: "avoidable" is its own segment mode, so mapping it
            -- to "taken" silently reported Damage Taken instead.
            -- "edamage" has no segment mode -- METER_MODE_MAP has no
            -- EnemyDamageTaken entry, so SnapshotMythicRun never captures it --
            -- and it falls through to the "no data for this mode" error rather
            -- than reporting player damage under an enemy-damage heading.
            local WIDGET_TO_SEG_MODE = {
                dtaken = "taken",
            }
            local modeName = WIDGET_TO_SEG_MODE[widgetState.type] or widgetState.type or "dps"
            local idx = tonumber(ws:sub(5))
            lines, err = BuildSegmentReport(modeName, idx, topN)
        else
            local rType = TYPE_MAP[widgetState.type] or Enum.DamageMeterType.Dps
            local sType = ws == "overall"
                and Enum.DamageMeterSessionType.Overall
                or Enum.DamageMeterSessionType.Current
            lines, err = BuildReport(rType, sType, topN)
        end

        if err then
            print("|cff00ccff[DPSReport]|r " .. err)
            return
        end
        if not lines then return end

        -- BNet whisper: channel value is "bn:<presenceID>"
        local chanVal = widgetState.channel
        if chanVal and chanVal:sub(1, 3) == "bn:" then
            local presenceID = tonumber(chanVal:sub(4))
            if presenceID then
                for i, line in ipairs(lines) do
                    C_Timer.After((i - 1) * 0.1, function()
                        BNSendWhisper(presenceID, line)
                    end)
                end
            else
                print("|cff00ccff[DPSReport]|r Invalid friend target.")
            end
        else
            local channel, target = GetChatChannel(chanVal, nil)
            SendLines(lines, channel, target)
        end
    end)

    -- Load position
    LoadWidgetPosition()

    -- Visibility from settings
    if settings and settings.widgetShown == false then
        widget:Hide()
    else
        widget:Show()
    end

    return widget
end

function DPSReport_ToggleWidget()
    if not reportWidget then
        CreateReportWidget()
    end
    if not reportWidget then return end
    if reportWidget:IsShown() then
        reportWidget:Hide()
        if settings then settings.widgetShown = false end
    else
        reportWidget:Show()
        if settings then settings.widgetShown = true end
    end
end

-- Create the widget on login
local widgetLoader = CreateFrame("Frame")
widgetLoader:SetScript("OnEvent", function()
    C_Timer.After(1, function()
        CreateReportWidget()
    end)
end)
widgetLoader:RegisterEvent("PLAYER_LOGIN")

-- ============================================================================
-- DPS Meter (C_DamageMeter-based, post-combat display)
-- ============================================================================

-- Meter instance prototype (each meter window is an independent instance)
local MeterProto = {}
MeterProto.__index = MeterProto
MeterProto.MAX_BARS = 40

-- Global meter manager
-- ============================================================================
-- Meter Snap / Anchor System  (inspired by Details!)
-- Visual: numbered ID badges + dotted connecting line while dragging.
-- Snap:   dropping within SNAP_DIST px of another frame's edge commits a
--         WoW SetPoint anchor so the child follows the parent on future drags.
-- Drag:   title bar OR bottom report bar.  Snapped children follow parent.
-- Break:  small accent dot button in the title bar (visible when snapped).
-- ============================================================================
MeterSnapSystem = {}

local SNAP_DIST   = 20   -- edge proximity (px) required to snap
local DOT_SPACING = 12   -- spacing between dotted-line dots (px)
local DOT_SIZE    = 5    -- size of each dot square

-- Dot pool ------------------------------------------------------------------
local _dots = {}
local function _getDot(i)
    if _dots[i] then return _dots[i] end
    local d = CreateFrame("Frame", nil, UIParent)
    d:SetSize(DOT_SIZE, DOT_SIZE)
    d:SetFrameStrata("FULLSCREEN_DIALOG")
    d:SetFrameLevel(200)
    local tex = d:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetColorTexture(1, 0.85, 0.1, 0.9)
    d:Hide()
    _dots[i] = d
    return d
end
local function _hideDots()
    for _, d in ipairs(_dots) do d:Hide() end
end

-- ID overlay pool (numbered badges shown on every frame while dragging) -----
local _overlays = {}
local function _getOrCreateOverlay(meter)
    local id = meter.id
    if _overlays[id] then return _overlays[id] end
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(56, 56)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(201)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)
    local txt = f:CreateFontString(nil, "OVERLAY")
    txt:SetFont("Fonts\\FRIZQT__.TTF", 34, "THICKOUTLINE")
    txt:SetAllPoints()
    txt:SetJustifyH("CENTER")
    txt:SetJustifyV("MIDDLE")
    txt:SetTextColor(1, 0.85, 0.1, 1)
    txt:SetText(tostring(id))
    f:Hide()
    _overlays[id] = f
    return f
end
local function _showOverlays()
    for _, m in ipairs(DPSMeter.meters) do
        if m.frame and m.frame:IsShown() then
            local ov = _getOrCreateOverlay(m)
            ov:ClearAllPoints()
            ov:SetPoint("CENTER", m.frame, "CENTER", 0, 0)
            ov:Show()
        end
    end
end
local function _hideOverlays()
    for _, f in pairs(_overlays) do f:Hide() end
end

-- Dotted line between two UIParent-BOTTOMLEFT coords ----------------------
local function _drawLine(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then return end
    local n = math.max(1, math.floor(dist / DOT_SPACING))
    for i = 0, n do
        local t = i / n
        local dot = _getDot(i + 1)
        dot:ClearAllPoints()
        dot:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x1 + dx * t, y1 + dy * t)
        dot:Show()
    end
    for i = n + 2, #_dots do _dots[i]:Hide() end
end

-- Snap proximity check: returns WoW SetPoint args (srcPt, tgtPt) or nil ----
local function _checkSnap(sf, tf)
    local sl, sr = sf:GetLeft() or 0, sf:GetRight() or 0
    local sb, st = sf:GetBottom() or 0, sf:GetTop() or 0
    local tl, tr = tf:GetLeft() or 0, tf:GetRight() or 0
    local tb, tt = tf:GetBottom() or 0, tf:GetTop() or 0
    local D = SNAP_DIST
    local vOvl = st > tb and sb < tt  -- vertical overlap (side-by-side snap)
    local hOvl = sr > tl and sl < tr  -- horizontal overlap (top/bottom snap)
    if vOvl then
        if math.abs(sr - tl) < D then return "TOPRIGHT",   "TOPLEFT"   end  -- src left of tgt
        if math.abs(sl - tr) < D then return "TOPLEFT",    "TOPRIGHT"  end  -- src right of tgt
    end
    if hOvl then
        -- WoW Y-axis goes up: sb≈tt means sf.bottom touches tf.top → sf is ABOVE tf
        if math.abs(sb - tt) < D then return "BOTTOMLEFT", "TOPLEFT"   end  -- sf above tf
        -- st≈tb means sf.top touches tf.bottom → sf is BELOW tf
        if math.abs(st - tb) < D then return "TOPLEFT",    "BOTTOMLEFT" end  -- sf below tf
    end
    return nil
end

-- OnUpdate driver: reposition overlays + redraw dotted line -----------------
local _dragUpdateFrame = CreateFrame("Frame", nil, UIParent)
_dragUpdateFrame:Hide()
local _dragging = nil
local _dotTick  = 0
_dragUpdateFrame:SetScript("OnUpdate", function(_, elapsed)
    _dotTick = _dotTick + elapsed
    if _dotTick < 0.016 then return end
    _dotTick = 0
    if not _dragging then _dragUpdateFrame:Hide(); return end
    -- Keep badges centred (frames may have moved)
    for _, m in ipairs(DPSMeter.meters) do
        if m.frame and m.frame:IsShown() then
            local ov = _overlays[m.id]
            if ov and ov:IsShown() then
                ov:ClearAllPoints()
                ov:SetPoint("CENTER", m.frame, "CENTER", 0, 0)
            end
        end
    end
    -- Dotted line from dragged frame center to nearest other frame center
    local cx, cy = _dragging.frame:GetCenter()
    if not cx then return end
    local best, bestD = nil, math.huge
    for _, m in ipairs(DPSMeter.meters) do
        if m ~= _dragging and m.frame and m.frame:IsShown() then
            local mx, my = m.frame:GetCenter()
            if mx then
                local d = (cx - mx) ^ 2 + (cy - my) ^ 2
                if d < bestD then bestD = d; best = m end
            end
        end
    end
    _hideDots()
    if best then
        local mx, my = best.frame:GetCenter()
        _drawLine(cx, cy, mx, my)
    end
end)

-- Public: start dragging ---------------------------------------------------
function MeterSnapSystem.StartDrag(meter)
    if settings and settings.meterLocked then return end
    if _dragging then return end
    _dragging = meter
    -- If this frame is currently a snapped child, detach so it can move freely.
    -- Clear snapTo completely so StopDrag gets a clean slate for the cycle check.
    if meter.snapTo and meter.snapTo._parent then
        local cx, cy = meter.frame:GetCenter()
        meter.frame:ClearAllPoints()
        meter.frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx or 0, cy or 0)
        meter.snapTo = {}
    end
    meter.frame:StartMoving()
    _showOverlays()
    _dragUpdateFrame:Show()
end

-- Public: stop dragging, commit snap if in range ---------------------------
function MeterSnapSystem.StopDrag(meter)
    if _dragging ~= meter then return end
    _dragging = nil
    meter.frame:StopMovingOrSizing()
    _dragUpdateFrame:Hide()
    _hideDots()
    _hideOverlays()
    -- Find the NEAREST frame within snap range
    local bestTgt, bestSrcPt, bestTgtPt, bestDist = nil, nil, nil, math.huge
    for _, tgt in ipairs(DPSMeter.meters) do
        if tgt ~= meter and tgt.frame and tgt.frame:IsShown() then
            local srcPt, tgtPt = _checkSnap(meter.frame, tgt.frame)
            if srcPt then
                local cx1, cy1 = meter.frame:GetCenter()
                local cx2, cy2 = tgt.frame:GetCenter()
                if cx1 and cx2 then
                    local d = (cx1 - cx2) ^ 2 + (cy1 - cy2) ^ 2
                    if d < bestDist then
                        bestDist = d; bestTgt = tgt; bestSrcPt = srcPt; bestTgtPt = tgtPt
                    end
                end
            end
        end
    end
    local snapped = false
    if bestTgt then
        -- Enforce: lower ID = parent so frame 1 is always the chain root.
        -- Regardless of which frame was dragged, the higher-ID frame becomes the child.
        local parent, child, snapSrcPt, snapTgtPt
        if meter.id < bestTgt.id then
            parent = meter
            child  = bestTgt
            -- Re-compute anchor from child's perspective onto parent
            snapSrcPt, snapTgtPt = _checkSnap(child.frame, parent.frame)
        else
            parent = bestTgt
            child  = meter
            snapSrcPt, snapTgtPt = bestSrcPt, bestTgtPt
        end
        if snapSrcPt then
            -- Walk parent's transitive chain to break any back-link to child
            -- (prevents "Cannot anchor to a region dependent on it")
            local chain = parent
            while chain and chain.snapTo and chain.snapTo._parent do
                if chain.snapTo._parent == child.id then
                    local cx, cy = chain.frame:GetCenter()
                    chain.frame:ClearAllPoints()
                    chain.frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx or 0, cy or 0)
                    chain.snapTo = {}
                    if chain.breakSnapBtn then chain.breakSnapBtn:Hide() end
                    break
                end
                local nextId = chain.snapTo._parent
                chain = nil
                for _, m in ipairs(DPSMeter.meters) do
                    if m.id == nextId then chain = m; break end
                end
            end
            -- If child is already snapped somewhere other than this parent, break that link
            if child.snapTo and child.snapTo._parent and child.snapTo._parent ~= parent.id then
                local cx, cy = child.frame:GetCenter()
                child.frame:ClearAllPoints()
                child.frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx or 0, cy or 0)
                child.snapTo = {}
                if child.breakSnapBtn then child.breakSnapBtn:Hide() end
            end
            -- Commit the anchor: child follows parent via WoW SetPoint
            child.frame:ClearAllPoints()
            child.frame:SetPoint(snapSrcPt, parent.frame, snapTgtPt, 0, 0)
            child.snapTo = { _parent = parent.id, _srcPt = snapSrcPt, _tgtPt = snapTgtPt }
            -- Parent stays free (no anchor to anyone from this operation)
            if parent == meter then
                meter.snapTo = {}
                if meter.breakSnapBtn then meter.breakSnapBtn:Hide() end
            end
            -- Break-snap button: only visible on the child (the frame that has an anchor)
            if child.breakSnapBtn then child.breakSnapBtn:Show() end
            snapped = true
        end
    end
    if not snapped then
        meter.snapTo = {}
        if meter.breakSnapBtn then meter.breakSnapBtn:Hide() end
    end
    meter:SavePosition()
    DPSMeter:SaveAllMeters()
end

-- Public: break all snaps involving this meter ----------------------------
function MeterSnapSystem.BreakSnap(meter)
    if meter.frame then
        local cx, cy = meter.frame:GetCenter()
        meter.frame:ClearAllPoints()
        meter.frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx or 0, cy or 0)
    end
    meter.snapTo = {}
    if meter.breakSnapBtn then meter.breakSnapBtn:Hide() end
    -- Also detach any meters that are anchored to this one
    for _, m in ipairs(DPSMeter.meters) do
        if m ~= meter and m.snapTo and m.snapTo._parent == meter.id then
            if m.frame then
                local cx, cy = m.frame:GetCenter()
                m.frame:ClearAllPoints()
                m.frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx or 0, cy or 0)
            end
            m.snapTo = {}
            if m.breakSnapBtn then m.breakSnapBtn:Hide() end
        end
    end
    DPSMeter:SaveAllMeters()
end

-- Public: re-apply WoW anchors after all frames are loaded -----------------
function MeterSnapSystem.RestoreAnchors()
    for _, m in ipairs(DPSMeter.meters) do
        if m.snapTo and m.snapTo._parent and m.snapTo._srcPt and m.snapTo._tgtPt then
            local parentFound = false
            for _, parent in ipairs(DPSMeter.meters) do
                if parent.id == m.snapTo._parent and parent.frame then
                    m.frame:ClearAllPoints()
                    m.frame:SetPoint(m.snapTo._srcPt, parent.frame, m.snapTo._tgtPt, 0, 0)
                    if m.breakSnapBtn then m.breakSnapBtn:Show() end
                    parentFound = true
                    break
                end
            end
            if not parentFound then
                -- Parent no longer exists; clear stale snap
                m.snapTo = {}
                if m.breakSnapBtn then m.breakSnapBtn:Hide() end
            end
        end
    end
end

-- ============================================================================
DPSMeter = {}
DPSMeter.meters = {}
DPSMeter.segments = {}  -- M+ stored segments only (persisted until reset)

-- Set true by LoadAllMeters. Until then `meters` is empty, and SaveAllMeters
-- refuses to write, because persisting an empty list wipes every saved meter
-- and position. LoadAllMeters is deferred ~2s after PLAYER_LOGIN, and plenty
-- fires inside that window: PLAYER_REGEN_ENABLED -> DoCombatEnd ->
-- SnapshotSegment -> SaveAllMeters is the one that bites, since reloading mid
-- fight means combat routinely ends a second later. The wipe was invisible
-- until the next login, which then took the "first run" branch and rebuilt one
-- default meter at the default position.
DPSMeter.metersLoaded = false

-- Reset all meter data and M+ stored segments
function DPSMeter:ResetAll()
    C_DamageMeter.ResetAllCombatSessions()
    -- Our own death tally is scoped to the Overall session, so it has to be
    -- cleared with it or a fresh key inherits the last one's deaths.
    DeathTracker:Reset("overall")
    DeathTracker:Reset("current")
    -- The run tally stands in for the Overall session inside a key, so a manual
    -- reset mid-key has to clear it too or Overall keeps showing pre-reset deaths.
    DeathTracker:Reset("run")
    self.segments = {}
    for _, m in ipairs(self.meters) do
        m.entries = {}
        if m.session and m.session:sub(1, 4) == "seg:" then
            m.session = "current"
            if m.sessionDropdown then
                m.sessionDropdown:SetSelectedValue("current")
            end
        end
        if m.RefreshSessionDropdown then m:RefreshSessionDropdown() end
        m:RefreshDisplay()
    end
    if self.widgetSessionDrop and self.BuildWidgetSessionItems then
        self.widgetSessionDrop:SetItems(self.BuildWidgetSessionItems())
    end
    self:SaveAllMeters()
end

-- Create a new independent meter instance
function DPSMeter:NewMeter(cfg)
    cfg = cfg or {}
    -- Find next available id if not specified
    local id = cfg.id
    if not id then
        id = 1
        for _, m in ipairs(self.meters) do
            if m.id >= id then id = m.id + 1 end
        end
    end
    local meter = setmetatable({
        id         = id,
        mode       = cfg.mode or "dps",
        session    = cfg.session or "current",
        frame      = nil,
        bars       = {},
        entries    = {},
        ticker     = nil,
        inCombat   = false,
        tooltipFrame = nil,
        tooltipRows  = {},
        breakdownFrame = nil,
        breakdownSelectedGUID = nil,
        snapTo     = {},
    }, MeterProto)
    table.insert(self.meters, meter)
    return meter
end

-- Remove an extra meter (id > 1)
function DPSMeter:RemoveMeter(meter)
    if meter.ticker then meter:StopRefreshTicker() end
    if meter.frame then meter.frame:Hide() end
    if meter.breakdownFrame then meter.breakdownFrame:Hide() end
    if meter.tooltipFrame then meter.tooltipFrame:Hide() end
    for i, m in ipairs(self.meters) do
        if m == meter then
            table.remove(self.meters, i)
            break
        end
    end
    DPSMeter:SaveAllMeters()
end

-- C_DamageMeter values are tainted/secret in 12.0+.  The ONLY way to display
-- them formatted is through C-side functions:
--   AbbreviateNumbers(secretNum, opts)  -> tainted string like "1.2K" or "7.33M"
--   FontString:SetFormattedText("%s", taintedStr) -> renders it
-- We cannot launder them to plain Lua numbers (GetText also returns tainted).
-- For chat reports (out of combat), SafeStr/LaunderNumber use pcall(tostring)
-- which works only outside combat.  In the meter UI we use the C-side path.

-- Breakpoint options for AbbreviateNumbers (K/M format, matches Details! style)
local ABBREVIATE_OPTS_TOTAL = {
    breakpointData = {
        { breakpoint = 1000000000, abbreviation = "B", significandDivisor = 10000000, fractionDivisor = 100, abbreviationIsGlobal = false },
        { breakpoint = 1000000,    abbreviation = "M", significandDivisor = 10000,    fractionDivisor = 100, abbreviationIsGlobal = false },
        { breakpoint = 10000,      abbreviation = "K", significandDivisor = 1000,     fractionDivisor = 1,   abbreviationIsGlobal = false },
        { breakpoint = 1000,       abbreviation = "K", significandDivisor = 100,      fractionDivisor = 10,  abbreviationIsGlobal = false },
        { breakpoint = 1,          abbreviation = "",  significandDivisor = 1,        fractionDivisor = 1,   abbreviationIsGlobal = false },
    },
}

local ABBREVIATE_OPTS_PS = {
    breakpointData = {
        { breakpoint = 1000000000, abbreviation = "B", significandDivisor = 10000000, fractionDivisor = 100, abbreviationIsGlobal = false },
        { breakpoint = 1000000,    abbreviation = "M", significandDivisor = 10000,    fractionDivisor = 100, abbreviationIsGlobal = false },
        { breakpoint = 1000,       abbreviation = "K", significandDivisor = 100,      fractionDivisor = 10,  abbreviationIsGlobal = false },
        { breakpoint = 1,          abbreviation = "",  significandDivisor = 1,        fractionDivisor = 1,   abbreviationIsGlobal = false },
    },
}

-- Pre-create config objects for optimal performance (if available)
if CreateAbbreviateConfig then
    ABBREVIATE_OPTS_TOTAL.config = CreateAbbreviateConfig(ABBREVIATE_OPTS_TOTAL.breakpointData)
    ABBREVIATE_OPTS_PS.config    = CreateAbbreviateConfig(ABBREVIATE_OPTS_PS.breakpointData)
end

-- Mode -> C_DamageMeter type mapping (supports all Blizzard meter types)
METER_MODE_MAP = {
    dps        = Enum.DamageMeterType.Dps,
    hps        = Enum.DamageMeterType.Hps,
    damage     = Enum.DamageMeterType.DamageDone,
    healing    = Enum.DamageMeterType.HealingDone,
    absorbs    = Enum.DamageMeterType.Absorbs,
    interrupts = Enum.DamageMeterType.Interrupts,
    dispels    = Enum.DamageMeterType.Dispels,
    taken      = Enum.DamageMeterType.DamageTaken,
    deaths     = Enum.DamageMeterType.Deaths,
    avoidable  = Enum.DamageMeterType.AvoidableDamageTaken,
}

local CLASS_COLORS = RAID_CLASS_COLORS

-- ============================================================================
-- C_DamageMeter session helpers
-- ============================================================================

-- Returns all sessions currently tracked by C_DamageMeter, including expired
-- ones from previous fights / the just-finished dungeon run.
GetAvailableAPISessions = function()
    local ok, sessions = pcall(C_DamageMeter.GetAvailableCombatSessions)
    return (ok and sessions) or {}
end

-- Finds a single available-session entry by its numeric ID.
FindAPISession = function(sessionID)
    for _, s in ipairs(GetAvailableAPISessions()) do
        if s.sessionID == sessionID then return s end
    end
    return nil
end

-- Produce a deaths list of one entry per player.
--
-- `scope` ("overall" / "current") lets DeathTracker answer instead. That is the
-- preferred path: its tally never counts Feign Death, and it holds plain names
-- and GUIDs even mid-key, where C_DamageMeter's rows carry neither. Pass nil
-- for data the tracker holds no tally for -- a saved combat session pulled back
-- by ID -- and the API's own rows are used. An empty list from the tracker is a
-- real answer ("nobody died"), which is why it is tested for nil, not for #.
--
-- The fallback below folds the API's rows, which are not shaped like any other
-- metric: the session returns one combatSource per death EVENT, each with
-- totalAmount 0, so a player who died twice appears twice and their count is
-- the number of rows. Unfolded it shows a column of zeroes with duplicated
-- names. Takes entries the caller has already built, so name resolution stays
-- in one place.
AggregateDeathEntries = function(entries, scope)
    local own = scope and DeathTracker:BuildEntries(scope)
    if own then return own end

    local byKey, order = {}, {}
    for i, e in ipairs(entries) do
        -- Read the incoming amount BEFORE any table is zeroed below: the first
        -- row of a player becomes the accumulator itself.
        local n = LaunderNumber(e.totalAmount)
        local add = (n and n > 0) and n or 1

        local guid = e.sourceGUID
        if guid == "?" or guid == "" then guid = nil end
        -- A table key must be plain -- a secret name would throw. A row with
        -- neither a resolved name nor a plain GUID (mid-combat) gets a unique
        -- key so it stands alone instead of merging with somebody else.
        local key = e.plainName or guid or ("row" .. i)

        local acc = byKey[key]
        if not acc then
            acc = e
            acc.displayValue, acc.totalAmount, acc.amountPerSecond = 0, 0, 0
            byKey[key] = acc
            order[#order + 1] = acc
        end
        acc.displayValue = acc.displayValue + add
        acc.totalAmount  = acc.totalAmount + add
    end

    table.sort(order, function(a, b) return a.totalAmount > b.totalAmount end)
    return order
end

-- Shared helper: build entries from GetCombatSessionFromID for a given mode.
-- Returns a table of entry objects (same shape as LoadFromAPI entries).
local function BuildEntriesFromSessionID(sessionID, modeName, maxCount)
    local meterType = METER_MODE_MAP[modeName]
    if not meterType then return {} end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromID, sessionID, meterType)
    if not ok or not session then return {} end
    local sources = session.combatSources
    if not sources or #sources == 0 then return {} end
    local isPerSecond = (modeName == "dps" or modeName == "hps")
    local count = math.min(maxCount or 40, #sources)
    local entries = {}
    for i = 1, count do
        local src = sources[i]
        local plainName = ResolveSourcePlainName(src)
        table.insert(entries, {
            name            = plainName or src.name,
            plainName       = plainName,
            apiName         = src.name,
            class           = src.classFilename,
            displayValue    = isPerSecond and src.amountPerSecond or src.totalAmount,
            totalAmount     = src.totalAmount,
            amountPerSecond = src.amountPerSecond,
            isPlayer        = src.isLocalPlayer,
            sourceGUID      = src.sourceGUID ~= nil and SafeStr(src.sourceGUID) or nil,
            specIconID      = src.specIconID,
        })
    end
    if modeName == "deaths" then
        return AggregateDeathEntries(entries)
    end
    return entries
end

-- Snapshot the full M+ run as a named segment when the key completes.
SnapshotMythicRun = function(savedName, savedLevel, runTimeMs, completionMembers)
    -- Build segment name: "Dungeon Name +N" (e.g. "Pit of Saron +8")
    -- savedName/savedLevel captured at CHALLENGE_MODE_START before APIs clear
    local dungeonName = savedName or "M+ Run"
    if savedLevel and savedLevel > 0 then
        dungeonName = dungeonName .. " +" .. savedLevel
    end

    -- Duration: prefer the real M+ timer captured at CHALLENGE_MODE_COMPLETED.
    local duration = 0
    if runTimeMs and runTimeMs > 0 then
        duration = math.floor(runTimeMs / 1000)
    else
        local d = C_DamageMeter.GetSessionDurationSeconds(Enum.DamageMeterSessionType.Overall)
        duration = d or 0
    end

    -- Build a GUID→name lookup from the completion members list (plain strings,
    -- always available at event time regardless of combat/taint restrictions).
    local memberNameByGUID = {}
    if completionMembers then
        for _, m in ipairs(completionMembers) do
            if m.memberGUID and m.name then
                memberNameByGUID[m.memberGUID] = m.name
            end
        end
    end

    -- GetCombatSessionFromType(Overall) is called 3s after CHALLENGE_MODE_COMPLETED
    -- while still inside the instance — data is guaranteed available here.
    -- LaunderNumber safely extracts tainted numbers if still in combat.
    local modes = {}
    for modeName, meterType in pairs(METER_MODE_MAP) do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            Enum.DamageMeterSessionType.Overall, meterType)
        if ok and session and session.combatSources and #session.combatSources > 0 then
            local isPerSecond = (modeName == "dps" or modeName == "hps")
            local entries = {}
            for i = 1, math.min(40, #session.combatSources) do
                local src = session.combatSources[i]
                -- Resolve name: prefer completionMembers (plain), then SafeStr fallback.
                -- SafeStr returns "?" for a still-secret GUID; treat that as "no
                -- GUID" so every row doesn't collide on the same bogus key (which
                -- would also make GetCombatSessionSourceFromType return junk).
                local guid
                if src.isLocalPlayer then
                    guid = UnitGUID("player")
                else
                    local g = SafeStr(src.sourceGUID)
                    if g and g ~= "" and g ~= "?" then guid = g end
                end
                local resolvedName = (src.isLocalPlayer and charKey)
                    or (guid and memberNameByGUID[guid])
                    or (guid and seenNameCache[guid])
                    or SafeStr(src.name)
                local shortN = (resolvedName or "?"):match("^([^%-]+)") or (resolvedName or "?")
                local spells = {}
                local ok2, srcData = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
                    Enum.DamageMeterSessionType.Overall, meterType, guid)
                if ok2 and srcData and srcData.combatSpells then
                    for _, sp in ipairs(srcData.combatSpells) do
                        local spellInfo = sp.spellID and C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sp.spellID)
                        table.insert(spells, {
                            spellID         = sp.spellID,
                            name            = (spellInfo and spellInfo.name) or sp.name or "",
                            iconID          = (spellInfo and spellInfo.iconID) or sp.iconID or 136243,
                            totalAmount     = LaunderNumber(sp.totalAmount),
                            amountPerSecond = LaunderNumber(sp.amountPerSecond),
                        })
                    end
                end
                table.insert(entries, {
                    name            = shortN,
                    class           = src.classFilename,
                    displayValue    = isPerSecond and LaunderNumber(src.amountPerSecond) or LaunderNumber(src.totalAmount),
                    totalAmount     = LaunderNumber(src.totalAmount),
                    amountPerSecond = LaunderNumber(src.amountPerSecond),
                    isPlayer        = src.isLocalPlayer,
                    sourceGUID      = guid,
                    specIconID      = src.specIconID,
                    spells          = spells,
                })
            end
            local total = LaunderNumber(session.totalAmount)
            if modeName == "deaths" then
                -- Fold the per-event rows into per-player counts before they are
                -- stored, so the segment holds one entry per player and every
                -- later reader (chat reports, the seg: meter mode, the run
                -- summary) sees a real count instead of a list of zeroes.
                entries = AggregateDeathEntries(entries, "overall")
                total = 0
                for _, e in ipairs(entries) do total = total + (e.totalAmount or 0) end
            end
            modes[modeName] = { entries = entries, totalAmount = total }
        end
    end

    -- Bail if we got no data at all
    if not next(modes) then
        print("|cff00ccff[DPSReport]|r M+ snapshot: no session data available, segment not saved.")
        return
    end

    -- Snapshot enemy targets
    local targets = {}
    local edamageSession = C_DamageMeter.GetCombatSessionFromType(
        Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.EnemyDamageTaken)
    if edamageSession and edamageSession.combatSources then
        for _, enemy in ipairs(edamageSession.combatSources) do
            table.insert(targets, {
                name          = SafeStr(enemy.name),
                totalAmount   = LaunderNumber(enemy.totalAmount),
                classFilename = enemy.classFilename,
                specIconID    = enemy.specIconID,
            })
        end
    end

    -- Recalculate amountPerSecond for dps/hps modes using full run duration.
    -- Blizzard's value only counts active combat time; dividing totalAmount by the
    -- real dungeon timer gives the true effective DPS/HPS over the whole key.
    if duration > 0 then
        for modeName, modeData in pairs(modes) do
            if modeName == "dps" or modeName == "hps" then
                for _, entry in ipairs(modeData.entries) do
                    local perSec = entry.totalAmount / duration
                    entry.amountPerSecond = perSec
                    entry.displayValue    = perSec
                end
            end
        end
    end

    local segment = {
        name     = dungeonName,
        duration = duration,
        modes    = modes,
        targets  = targets,
    }
    table.insert(DPSMeter.segments, segment)
    DPSMeter:SaveAllMeters()

    for _, meter in ipairs(DPSMeter.meters) do
        if meter.RefreshSessionDropdown then meter:RefreshSessionDropdown() end
    end
    if DPSMeter.widgetSessionDrop and DPSMeter.BuildWidgetSessionItems then
        DPSMeter.widgetSessionDrop:SetItems(DPSMeter.BuildWidgetSessionItems())
    end
end

-- SnapshotSegment is no longer needed: C_DamageMeter.GetAvailableCombatSessions()
-- tracks all past sessions (including Expired) natively.  We still update the
-- seenName cache here so player names survive the group disbanding.
SnapshotSegment = function()
    if IsAnyoneInCombat() then return end

    -- Persist name → GUID mappings while restrictions have lifted.
    local dpsSession = C_DamageMeter.GetCombatSessionFromType(
        Enum.DamageMeterSessionType.Current, Enum.DamageMeterType.Dps)
    if dpsSession and dpsSession.combatSources then
        for _, src in ipairs(dpsSession.combatSources) do
            if not src.isLocalPlayer
                and not issecretvalue(src.sourceGUID)
                and not issecretvalue(src.name) then
                local guid   = src.sourceGUID
                local shortN = src.name:match("^([^%-]+)") or src.name
                if guid and guid ~= "" and shortN ~= "" then
                    seenNameCache[guid] = shortN
                    if DPSReportDB and DPSReportDB.seenNames then
                        DPSReportDB.seenNames[guid] = shortN
                    end
                end
            end
        end
    end

    -- Refresh all meter session dropdowns so new API sessions appear.
    for _, meter in ipairs(DPSMeter.meters) do
        if meter.RefreshSessionDropdown then meter:RefreshSessionDropdown() end
    end
    if DPSMeter.widgetSessionDrop and DPSMeter.BuildWidgetSessionItems then
        DPSMeter.widgetSessionDrop:SetItems(DPSMeter.BuildWidgetSessionItems())
    end
end

-- Compute combat duration; session-aware:
--   "current"   = current/last fight via GetSessionDurationSeconds
--   "overall"   = overall session via GetSessionDurationSeconds
--   "sid:NNNN" = API-tracked expired session (durationSeconds from available list)
--   "seg:N"    = M+ stored segment duration
function MeterProto:GetCombatDuration()
    if self.session and self.session:sub(1, 4) == "seg:" then
        local idx = tonumber(self.session:sub(5))
        local seg = idx and DPSMeter.segments[idx]
        return seg and seg.duration or 0
    end
    if self.session and self.session:sub(1, 4) == "sid:" then
        local id = tonumber(self.session:sub(5))
        local s = FindAPISession(id)
        return (s and s.durationSeconds) or 0
    end
    if self.session == "overall" then
        return C_DamageMeter.GetSessionDurationSeconds(Enum.DamageMeterSessionType.Overall) or 0
    else -- "current"
        return C_DamageMeter.GetSessionDurationSeconds(Enum.DamageMeterSessionType.Current) or 0
    end
end

-- Pull data from C_DamageMeter API.
-- IMPORTANT:  amountPerSecond, totalAmount, durationSeconds, and name are
-- "secret" / tainted values in Midnight 12.0+.  They CANNOT be used in
-- Lua arithmetic, comparisons, string.format, table.sort, etc.
-- They CAN be passed directly to UI widget methods:
--   FontString:SetText(secretValue)   StatusBar:SetValue(secretNumber)
--   StatusBar:SetMinMaxValues(0, secretNumber)
-- The API returns combatSources already sorted by the relevant metric.
function MeterProto:LoadFromAPI()
    -- Avoidable damage is only meaningful out of combat; skip ticker updates mid-fight
    if self.mode == "avoidable" and self.inCombat then return end

    self.entries = {}

    -- M+ stored segment: load from snapshot (plain numbers)
    if self.session and self.session:sub(1, 4) == "seg:" then
        local idx = tonumber(self.session:sub(5))
        local seg = idx and DPSMeter.segments[idx]
        if seg and seg.modes and seg.modes[self.mode] then
            local modeData = seg.modes[self.mode]
            for _, e in ipairs(modeData.entries) do
                table.insert(self.entries, e)
            end
        end
        return
    end

    -- API-tracked expired session: fetch live from C_DamageMeter by session ID.
    if self.session and self.session:sub(1, 4) == "sid:" then
        local id = tonumber(self.session:sub(5))
        for _, e in ipairs(BuildEntriesFromSessionID(id, self.mode, self.MAX_BARS)) do
            table.insert(self.entries, e)
        end
        return
    end

    local meterType = METER_MODE_MAP[self.mode]
    if not meterType then return end

    local isAvailable = C_DamageMeter.IsDamageMeterAvailable()
    if not isAvailable then return end

    local session = C_DamageMeter.GetCombatSessionFromType(
        self.session == "overall" and Enum.DamageMeterSessionType.Overall or Enum.DamageMeterSessionType.Current,
        meterType
    )
    if not session then return end

    local sources = session.combatSources
    if not sources or #sources == 0 then return end

    -- Sources arrive pre-sorted from the API – do NOT table.sort.
    local isPerSecond = (self.mode == "dps" or self.mode == "hps")
    local count = math.min(self.MAX_BARS, #sources)
    for i = 1, count do
        local src = sources[i]
        local displayValue = isPerSecond and src.amountPerSecond or src.totalAmount

        -- plainName: plain string used for chat reports, saving, and nickname lookup.
        -- During combat this relies on GUID/spec/class roster caches.
        local plainName = ResolveSourcePlainName(src)

        -- Fallback display name: exactly what C_DamageMeter gives us (src.name).
        -- May be a secret/tainted string when restrictions are active; it is still
        -- SetText-safe, matching Blizzard's own UI and Details' nocleu approach.
        local name = plainName or src.name

        table.insert(self.entries, {
            name         = name,
            plainName    = plainName,
            apiName      = src.name,
            class        = src.classFilename,
            displayValue = displayValue,
            totalAmount  = src.totalAmount,
            amountPerSecond = src.amountPerSecond,
            isPlayer     = src.isLocalPlayer,
            sourceGUID   = src.sourceGUID ~= nil and SafeStr(src.sourceGUID) or nil,
            specIconID   = src.specIconID,
        })
    end

    -- This mode returns one row per death event; fold to one row per player,
    -- and correct the count against observed deaths (see AggregateDeathEntries).
    if self.mode == "deaths" then
        self.entries = AggregateDeathEntries(self.entries,
            self.session == "overall" and "overall" or "current")
    end
end

-- Live refresh ticker (queries C_DamageMeter periodically during combat)
function MeterProto:StartRefreshTicker()
    self:StopRefreshTicker()
    local meter = self
    local interval = (settings and settings.meterRefreshRate) or 0.3
    self.ticker = C_Timer.NewTicker(interval, function()
        meter:LoadFromAPI()
        meter:RefreshDisplay()
    end)
end

function MeterProto:StopRefreshTicker()
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
end

-- ============================================================================
-- Meter Display
-- ============================================================================

local METER_DEFAULT_SETTINGS = {
    meterShown = true,
    meterLocked = false,
    meterWidth = 220,
    meterHeight = 200,
    meterBarHeight = 18,
    meterBgAlpha = 0.85,
    meterBarAlpha = 0.8,
    meterRefreshRate = 0.3,
}

-- Merge meter defaults into main settings
for k, v in pairs(METER_DEFAULT_SETTINGS) do
    if DEFAULT_SETTINGS[k] == nil then
        DEFAULT_SETTINGS[k] = v
    end
end

-- Compact dropdown for the meter title bar (no label, short height, opens downward)
local function CreateMeterDropdown(parent, width, items, initialValue, onSelect)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width, 16)
    btn:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(DR_COLORS.control[1], DR_COLORS.control[2], DR_COLORS.control[3], 0.6)
    btn:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.5)

    local selectedText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    selectedText:SetPoint("LEFT", 4, 0)
    selectedText:SetPoint("RIGHT", -12, 0)
    selectedText:SetWordWrap(false)
    selectedText:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])

    local arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", -3, 0)
    arrow:SetText("v")
    arrow:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    local menu = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -1)
    local menuMinWidth = width
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    menu:SetBackdropColor(DR_COLORS.bg[1], DR_COLORS.bg[2], DR_COLORS.bg[3], 0.98)
    menu:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 1)
    menu:Hide()

    local selectedValue = initialValue

    -- Set initial display text
    for _, item in ipairs(items) do
        if item.value == initialValue then
            selectedText:SetText(item.text)
            break
        end
    end

    local ROW_H = 16
    local MAX_SEGMENT_ROWS = 5

    local function BuildMenu()
        for _, child in pairs({menu:GetChildren()}) do child:Hide(); child:SetParent(nil) end
        -- Measure widest item to auto-size menu
        local measureFS = menu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        local maxTextW = 0
        for _, item in ipairs(items) do
            if item.value ~= "_separator" then
                measureFS:SetText(item.text)
                local w = measureFS:GetStringWidth()
                if w > maxTextW then maxTextW = w end
            end
        end
        measureFS:Hide()
        local menuW = math.max(menuMinWidth, maxTextW + 16)
        menu:SetWidth(menuW)

        -- Split items into fixed (before separator) and scrollable (after)
        local fixedItems = {}
        local segItems = {}
        local pastSep = false
        for _, item in ipairs(items) do
            if item.value == "_separator" then
                pastSep = true
            elseif pastSep then
                table.insert(segItems, item)
            else
                table.insert(fixedItems, item)
            end
        end

        local y = -2
        -- Render fixed items (Current, Overall)
        for _, item in ipairs(fixedItems) do
            local opt = CreateFrame("Button", nil, menu)
            opt:SetSize(menuW - 4, ROW_H)
            opt:SetPoint("TOPLEFT", menu, "TOPLEFT", 2, y)
            local optBG = opt:CreateTexture(nil, "BACKGROUND")
            optBG:SetAllPoints()
            optBG:SetColorTexture(0, 0, 0, 0)
            local optText = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            optText:SetPoint("LEFT", 4, 0)
            optText:SetText(item.text)
            if item.value == selectedValue then
                optText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
            else
                optText:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])
            end
            opt:SetScript("OnEnter", function() optBG:SetColorTexture(DR_COLORS.controlHi[1], DR_COLORS.controlHi[2], DR_COLORS.controlHi[3], 1) end)
            opt:SetScript("OnLeave", function() optBG:SetColorTexture(0, 0, 0, 0) end)
            opt:SetScript("OnClick", function()
                selectedValue = item.value
                selectedText:SetText(item.text)
                menu:Hide()
                if onSelect then onSelect(item.value) end
            end)
            y = y - ROW_H
        end

        -- Separator + scrollable segments
        if #segItems > 0 then
            -- Separator line
            local sep = menu:CreateTexture(nil, "ARTWORK")
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, y - 3)
            sep:SetPoint("RIGHT", menu, "RIGHT", -4, 0)
            sep:SetColorTexture(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.5)
            y = y - 7

            local visibleCount = math.min(#segItems, MAX_SEGMENT_ROWS)
            local scrollAreaH = visibleCount * ROW_H
            local contentH = #segItems * ROW_H

            local scrollFrame = CreateFrame("ScrollFrame", nil, menu)
            scrollFrame:SetSize(menuW - 4, scrollAreaH)
            scrollFrame:SetPoint("TOPLEFT", menu, "TOPLEFT", 2, y)

            local scrollChild = CreateFrame("Frame", nil, scrollFrame)
            scrollChild:SetSize(menuW - 4, contentH)
            scrollFrame:SetScrollChild(scrollChild)

            local sy = 0
            for _, item in ipairs(segItems) do
                local opt = CreateFrame("Button", nil, scrollChild)
                opt:SetSize(menuW - 4, ROW_H)
                opt:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, sy)
                local optBG = opt:CreateTexture(nil, "BACKGROUND")
                optBG:SetAllPoints()
                optBG:SetColorTexture(0, 0, 0, 0)
                local optText = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                optText:SetPoint("LEFT", 4, 0)
                optText:SetPoint("RIGHT", -4, 0)
                optText:SetWordWrap(false)
                optText:SetText(item.text)
                if item.value == selectedValue then
                    optText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
                else
                    optText:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])
                end
                opt:SetScript("OnEnter", function() optBG:SetColorTexture(DR_COLORS.controlHi[1], DR_COLORS.controlHi[2], DR_COLORS.controlHi[3], 1) end)
                opt:SetScript("OnLeave", function() optBG:SetColorTexture(0, 0, 0, 0) end)
                opt:SetScript("OnClick", function()
                    selectedValue = item.value
                    selectedText:SetText(item.text)
                    menu:Hide()
                    if onSelect then onSelect(item.value) end
                end)
                sy = sy - ROW_H
            end

            -- MouseWheel scrolling
            if #segItems > MAX_SEGMENT_ROWS then
                scrollFrame:EnableMouseWheel(true)
                scrollFrame:SetScript("OnMouseWheel", function(self, delta)
                    local cur = self:GetVerticalScroll()
                    local maxScroll = contentH - scrollAreaH
                    self:SetVerticalScroll(math.max(0, math.min(maxScroll, cur - delta * ROW_H)))
                end)
            end

            y = y - scrollAreaH
        end

        menu:SetHeight(math.abs(y) + 2)
    end

    btn:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide() else BuildMenu(); menu:Show() end
    end)
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.6)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.5)
    end)

    -- Close menu on outside click
    local closer = CreateFrame("Button", nil, menu)
    closer:SetAllPoints(UIParent)
    closer:SetFrameStrata("FULLSCREEN")
    closer:SetScript("OnClick", function() menu:Hide(); closer:Hide() end)
    closer:Hide()
    menu:HookScript("OnShow", function() closer:Show() end)
    menu:HookScript("OnHide", function() closer:Hide() end)

    btn.SetSelectedValue = function(self, val)
        selectedValue = val
        for _, item in ipairs(items) do
            if item.value == val then selectedText:SetText(item.text); break end
        end
    end
    btn.GetSelectedValue = function() return selectedValue end
    btn.SetItems = function(self, newItems)
        items = newItems
    end

    return btn
end

-- Show item level on a bar's name text for 5 seconds when its icon is clicked.
-- Only works out of combat. Inspects other players if needed (reuses the
-- existing inspect queue). Cached for 5 minutes per player GUID.
function MeterProto:ShowIlvlOnBar(entry, bar)
    if InCombatLockdown() then return end

    -- Cancel any in-progress revert timer for this bar.
    if bar.ilvlRevertTimer then
        bar.ilvlRevertTimer:Cancel()
        bar.ilvlRevertTimer = nil
    end

    local function DisplayIlvl(ilvl)
        if not bar or not bar.nameText then return end
        local displayName = bar.lastResolvedName or EntryDisplayName(bar.entry or entry)
        if ilvl and ilvl > 0 then
            bar.nameText:SetText(string.format("|cffffff00%d ilvl|r  %s", ilvl, displayName))
        else
            bar.nameText:SetText(string.format("|cffaaaaaa? ilvl|r  %s", displayName))
        end
        -- Revert to normal name after 5 seconds.
        if bar.ilvlRevertTimer then bar.ilvlRevertTimer:Cancel() end
        bar.ilvlRevertTimer = C_Timer.NewTimer(5, function()
            bar.ilvlRevertTimer = nil
            if bar.nameText then
                bar.nameText:SetText(bar.lastResolvedName or EntryDisplayName(bar.entry or entry))
            end
        end)
    end

    local guid = entry.sourceGUID

    -- Local player: available immediately, no inspect needed.
    if entry.isPlayer then
        local equipped = select(1, GetAverageItemLevel())
        DisplayIlvl(equipped and math.floor(equipped))
        return
    end

    -- Serve from cache if fresh (< 5 minutes old).
    if guid and ilvlCache[guid] and (GetTime() - ilvlCache[guid].time) < 300 then
        DisplayIlvl(ilvlCache[guid].ilvl)
        return
    end

    -- Find the live unit token for this player.
    local unitToken
    local numGroup = GetNumGroupMembers()
    if numGroup > 0 then
        local prefix = IsInRaid() and "raid" or "party"
        local count  = IsInRaid() and numGroup or (numGroup - 1)
        for j = 1, count do
            local u = prefix .. j
            if UnitGUID(u) == guid then
                unitToken = u
                break
            end
        end
    end

    if not unitToken or not CanInspect(unitToken) then
        -- Out of range — show whatever is cached (or ? ilvl).
        local cached = guid and ilvlCache[guid]
        DisplayIlvl(cached and cached.ilvl or nil)
        -- Remember this GUID so we inspect them the moment they come in range.
        if guid and not (cached and (GetTime() - cached.time) < 300) then
            wantIlvlGUIDs[guid] = true
        end
        return
    end

    -- Register callback and insert at front of queue (user-initiated, high priority).
    if guid then
        pendingIlvlCallbacks[guid] = DisplayIlvl
    end
    -- Insert at front so the ilvl request runs before any background spec inspects.
    table.insert(inspectQueue, 1, unitToken)
    ProcessInspectQueue()
end

function MeterProto:CreateBar(parent, index)
    local barHeight = (settings and settings.meterBarHeight) or 18
    local fontSize = math.max(8, math.floor(barHeight * 0.55 + 0.5))
    local meter = self
    local iconSize = barHeight - 2

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(barHeight)

    -- Background (full width including icon area)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.6)
    bar.bg = bg

    -- Class/spec icon (left side)
    local icon = bar:CreateTexture(nil, "OVERLAY")
    icon:SetSize(iconSize, iconSize)
    icon:SetPoint("LEFT", 1, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    bar.icon = icon

    -- Invisible button overlaid on the icon so it can receive clicks independently.
    local iconBtn = CreateFrame("Button", nil, bar)
    iconBtn:SetSize(iconSize, iconSize)
    iconBtn:SetPoint("LEFT", 1, 0)
    iconBtn:SetFrameLevel(bar:GetFrameLevel() + 2)
    iconBtn:RegisterForClicks("LeftButtonUp")
    iconBtn:SetScript("OnClick", function()
        if InCombatLockdown() then return end
        if not bar.entry then return end
        meter:ShowIlvlOnBar(bar.entry, bar)
    end)
    bar.iconBtn = iconBtn

    -- Inner StatusBar (starts after icon)
    local sb = CreateFrame("StatusBar", nil, bar)
    sb:SetPoint("TOPLEFT", icon, "TOPRIGHT", 1, 0)
    sb:SetPoint("BOTTOMRIGHT", 0, 0)
    sb:SetStatusBarTexture("Interface\\BUTTONS\\WHITE8X8")
    sb:SetStatusBarColor(0.3, 0.3, 0.3, 0.8)
    sb:SetMinMaxValues(0, 100)
    sb:SetValue(0)

    bar.SetMinMaxValues = function(_, ...) sb:SetMinMaxValues(...) end
    bar.SetValue = function(_, ...) sb:SetValue(...) end
    bar.SetStatusBarColor = function(_, ...) sb:SetStatusBarColor(...) end

    -- Rank number
    local rank = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rank:SetFont(rank:GetFont(), fontSize, "OUTLINE")
    rank:SetPoint("LEFT", 2, 0)
    rank:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    bar.rank = rank

    -- Name text
    local nameText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetFont(nameText:GetFont(), fontSize, "")
    nameText:SetPoint("LEFT", rank, "RIGHT", 2, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetTextColor(1, 1, 1)
    bar.nameText = nameText

    -- Value text (right side)
    local valueText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valueText:SetFont(valueText:GetFont(), fontSize, "")
    valueText:SetPoint("RIGHT", -3, 0)
    valueText:SetJustifyH("RIGHT")
    valueText:SetTextColor(1, 1, 1)
    bar.valueText = valueText

    -- Limit name text so it doesn't overlap value
    nameText:SetPoint("RIGHT", valueText, "LEFT", -4, 0)

    -- Enable mouse for tooltip and click
    bar:EnableMouse(true)

    bar:SetScript("OnEnter", function(self)
        if not self.entry then return end
        meter:ShowBarTooltip(self)
    end)

    bar:SetScript("OnLeave", function()
        meter:HideBarTooltip()
    end)

    bar:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.entry then
            meter:ShowBreakdown(self.entry)
        end
    end)

    bar:Hide()
    return bar
end

function MeterProto:CreateMeterFrame()
    if self.frame then return self.frame end

    local meter = self
    local meterWidth = (settings and settings.meterWidth) or 220
    local barHeight = (settings and settings.meterBarHeight) or 18

    -- Main frame
    local frameName = "DPSReportMeter" .. (self.id > 1 and self.id or "")
    local frame = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
    local meterHeight = (settings and settings.meterHeight) or 200
    frame:SetSize(meterWidth, meterHeight)
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -400)
    frame:SetFrameStrata("MEDIUM")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(150, 60, 500, 800)
    end
    ApplyDRBackdrop(frame, {0.04, 0.04, 0.06, settings and settings.meterBgAlpha or 0.85}, DR_COLORS.border)
    self.frame = frame

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(20)
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    titleBar:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    titleBar:SetBackdropColor(DR_COLORS.titleBar[1], DR_COLORS.titleBar[2], DR_COLORS.titleBar[3], 1)
    titleBar:EnableMouse(true)
    titleBar:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then MeterSnapSystem.StartDrag(meter) end
    end)
    titleBar:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            MeterSnapSystem.StopDrag(meter)
        elseif button == "RightButton" then
            meter:ReportToChat()
        end
    end)
    self.titleBar = titleBar

    -- Timer text (left side, before dropdowns, bigger font)
    local timerText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    timerText:SetPoint("LEFT", titleBar, "LEFT", 4, 0)
    timerText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    timerText:SetText("0:00")
    self.timerText = timerText

    -- Mode dropdown (replaces old text tabs)
    local modeItems = {
        { text = "DPS",        value = "dps" },
        { text = "HPS",        value = "hps" },
        { text = "Damage",     value = "damage" },
        { text = "Healing",    value = "healing" },
        { text = "Absorbs",    value = "absorbs" },
        { text = "Interrupts", value = "interrupts" },
        { text = "Dispels",    value = "dispels" },
        { text = "Dmg Taken",  value = "taken" },
        { text = "Deaths",     value = "deaths" },
        { text = "Avoidable",  value = "avoidable" },
    }
    local modeDropdown = CreateMeterDropdown(titleBar, 72, modeItems, self.mode, function(value)
        meter.mode = value
        meter:LoadFromAPI()
        meter:RefreshDisplay()
        DPSMeter:SaveAllMeters()
    end)
    modeDropdown:SetPoint("LEFT", timerText, "RIGHT", 4, 0)
    self.modeDropdown = modeDropdown

    -- Session dropdown (current / overall / API sessions / M+ stored segments)
    local function BuildSessionItems()
        local items = {}
        table.insert(items, { text = "Current", value = "current" })
        table.insert(items, { text = "Overall", value = "overall" })
        local apiSessions = GetAvailableAPISessions()
        if #apiSessions > 0 then
            table.insert(items, { text = "", value = "_separator" })
            for i = #apiSessions, 1, -1 do
                local s = apiSessions[i]
                local dur = (s.durationSeconds and s.durationSeconds > 0)
                    and (" (" .. FormatDuration(s.durationSeconds) .. ")") or ""
                table.insert(items, { text = (s.name or "Combat") .. dur, value = "sid:" .. s.sessionID })
            end
        end
        if #DPSMeter.segments > 0 then
            table.insert(items, { text = "", value = "_separator" })
            for i = #DPSMeter.segments, 1, -1 do
                local seg = DPSMeter.segments[i]
                local label = seg.name .. " (" .. FormatDuration(seg.duration) .. ")"
                table.insert(items, { text = label, value = "seg:" .. i })
            end
        end
        return items
    end
    local sessionItems = BuildSessionItems()
    local sessionDropdown = CreateMeterDropdown(titleBar, 74, sessionItems, self.session, function(value)
        meter.session = value
        meter:LoadFromAPI()
        meter:RefreshDisplay()
        DPSMeter:SaveAllMeters()
    end)
    sessionDropdown:SetPoint("LEFT", modeDropdown, "RIGHT", 2, 0)
    self.sessionDropdown = sessionDropdown

    -- Method to refresh session dropdown items (called when segments change)
    function meter:RefreshSessionDropdown()
        if self.sessionDropdown then
            self.sessionDropdown:SetItems(BuildSessionItems())
        end
    end

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(14, 14)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -3, 0)
    local closeText = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    closeText:SetPoint("CENTER")
    closeText:SetText("X")
    closeText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    closeBtn:SetScript("OnEnter", function() closeText:SetTextColor(DR_COLORS.danger[1], DR_COLORS.danger[2], DR_COLORS.danger[3]) end)
    closeBtn:SetScript("OnLeave", function() closeText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3]) end)
    closeBtn:SetScript("OnClick", function()
        local msg = meter.id == 1
            and "Hide this meter?\n"
            or  "Close this meter window?"
        ShowDRConfirm(msg, function()
            if meter.id == 1 then
                frame:Hide()
                if settings then settings.meterShown = false end
                print("|cff00ccff[DPSReport]|r Meter hidden. Use /dpsreport meter to show.")
            else
                DPSMeter:RemoveMeter(meter)
            end
        end)
    end)

    -- Reset button (left of close)
    local clearBtn = CreateFrame("Button", nil, titleBar)
    clearBtn:SetSize(14, 14)
    clearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    local clearText = clearBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clearText:SetPoint("CENTER")
    clearText:SetText("R")
    clearText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    clearBtn:SetScript("OnEnter", function()
        clearText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
        GameTooltip:SetOwner(clearBtn, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Reset meter data")
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function()
        clearText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
        GameTooltip:Hide()
    end)
    clearBtn:SetScript("OnClick", function()
        ShowDRConfirm("Reset all meter data?", function()
            DPSMeter:ResetAll()
        end)
    end)

    -- "+" button to create a new independent meter (left of clear)
    local addBtn = CreateFrame("Button", nil, titleBar)
    addBtn:SetSize(14, 14)
    addBtn:SetPoint("RIGHT", clearBtn, "LEFT", -2, 0)
    local addText = addBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addText:SetFont(addText:GetFont(), 26, "OUTLINE")
    addText:SetPoint("CENTER", 0, 0)
    addText:SetText("+")
    addText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    addBtn:SetScript("OnEnter", function()
        addText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
        GameTooltip:SetOwner(addBtn, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Create new meter window")
        GameTooltip:Show()
    end)
    addBtn:SetScript("OnLeave", function()
        addText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
        GameTooltip:Hide()
    end)
    addBtn:SetScript("OnClick", function()
        local srcW = frame:GetWidth()
        local srcH = frame:GetHeight()
        local newMeter = DPSMeter:NewMeter({ mode = "dps", session = "current" })
        newMeter:CreateMeterFrame()
        -- Match the size of the source frame, then centre on screen
        newMeter.frame:SetSize(srcW, srcH)
        if newMeter.barContainer then newMeter.barContainer:SetWidth(srcW - 2) end
        newMeter.frame:ClearAllPoints()
        newMeter.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        -- Sync combat state if currently in combat
        if meter.inCombat then
            newMeter.inCombat = true
            newMeter:StartRefreshTicker()
        end
        newMeter:LoadFromAPI()
        newMeter:RefreshDisplay()
        DPSMeter:SaveAllMeters()
    end)

    -- Break-snap button: small accent dot at the bottom-right of the frame,
    -- visible only when this frame is snapped to another.
    local breakSnapBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    breakSnapBtn:SetSize(10, 10)
    breakSnapBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 5)
    breakSnapBtn:SetFrameStrata("HIGH")
    breakSnapBtn:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    breakSnapBtn:SetBackdropColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.85)
    breakSnapBtn:SetScript("OnEnter", function()
        breakSnapBtn:SetBackdropColor(1, 0.3, 0.3, 1)
        GameTooltip:SetOwner(breakSnapBtn, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Break frame snap", 1, 1, 1)
        GameTooltip:Show()
    end)
    breakSnapBtn:SetScript("OnLeave", function()
        breakSnapBtn:SetBackdropColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.85)
        GameTooltip:Hide()
    end)
    breakSnapBtn:SetScript("OnClick", function()
        MeterSnapSystem.BreakSnap(meter)
    end)
    breakSnapBtn:Hide()
    meter.breakSnapBtn = breakSnapBtn

    -- Accent line
    local accentLine = titleBar:CreateTexture(nil, "OVERLAY")
    accentLine:SetHeight(1)
    accentLine:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    accentLine:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.3)

    -- Scrollable bar container (plain ScrollFrame, no template scrollbar)
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame)
    scrollFrame:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 1, -1)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 19)
    self.scrollFrame = scrollFrame

    local barContainer = CreateFrame("Frame", nil, scrollFrame)
    barContainer:SetSize(meterWidth, self.MAX_BARS * (barHeight + 1))
    scrollFrame:SetScrollChild(barContainer)
    self.barContainer = barContainer

    -- Keep bar container width in sync when frame resizes
    scrollFrame:SetScript("OnSizeChanged", function(sf, w)
        barContainer:SetWidth(w)
    end)
    frame:HookScript("OnShow", function()
        barContainer:SetWidth(scrollFrame:GetWidth())
    end)

    -- Pre-create bars
    for i = 1, self.MAX_BARS do
        local bar = self:CreateBar(barContainer, i)
        bar:SetPoint("TOPLEFT", barContainer, "TOPLEFT", 0, -(i - 1) * (barHeight + 1))
        bar:SetPoint("RIGHT", barContainer, "RIGHT", 0, 0)
        self.bars[i] = bar
    end

    -- Self-pin bar: always-visible player row anchored above the report bar.
    -- Visually overlaps the bottom of the scrollable area when active.
    local selfPinBar = self:CreateBar(frame, self.MAX_BARS + 1)
    selfPinBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 19)
    selfPinBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 19)
    selfPinBar:SetFrameLevel(selfPinBar:GetFrameLevel() + 2)
    -- Solid background so pinned row visually separates from scrolled content below it
    selfPinBar.bg:SetColorTexture(0.05, 0.05, 0.07, 1)
    selfPinBar:Hide()
    self.selfPinBar = selfPinBar

    -- Separator line above pin bar (accent-colored, 1 px)
    local selfPinSep = frame:CreateTexture(nil, "OVERLAY")
    selfPinSep:SetHeight(1)
    selfPinSep:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 19 + barHeight)
    selfPinSep:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 19 + barHeight)
    selfPinSep:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.6)
    selfPinSep:Hide()
    self.selfPinSep = selfPinSep

    -- Trigger pin update whenever the scroll position changes
    scrollFrame:SetScript("OnVerticalScroll", function()
        meter:UpdateSelfPin()
    end)

    -- Mouse wheel scrolling on the main frame too
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        local current = scrollFrame:GetVerticalScroll()
        local maxScroll = barContainer:GetHeight() - scrollFrame:GetHeight()
        local newScroll = current - (delta * (barHeight + 1))
        newScroll = math.max(0, math.min(newScroll, maxScroll))
        scrollFrame:SetVerticalScroll(newScroll)
    end)

    -- Resize handle (bottom-right corner)
    local resizer = CreateFrame("Button", nil, frame)
    resizer:SetSize(12, 12)
    resizer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizer:SetScript("OnMouseDown", function()
        if not settings or not settings.meterLocked then
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizer:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        -- Update bar container to match new frame width
        if meter.barContainer then
            meter.barContainer:SetWidth(frame:GetWidth() - 2)
        end
        meter:RefreshDisplay()
        meter:SavePosition()
    end)

    -- ================================================================
    -- Bottom report toolbar
    -- ================================================================
    local reportBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    reportBar:SetHeight(18)
    reportBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
    reportBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    reportBar:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    reportBar:SetBackdropColor(DR_COLORS.titleBar[1], DR_COLORS.titleBar[2], DR_COLORS.titleBar[3], 1)
    -- Report bar is also a drag zone (useful for narrow frames or when title bar is crowded)
    reportBar:EnableMouse(true)
    reportBar:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then MeterSnapSystem.StartDrag(meter) end
    end)
    reportBar:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then MeterSnapSystem.StopDrag(meter) end
    end)
    self.reportBar = reportBar

    -- "Report:" label (clickable — opens report widget)
    local reportLabelBtn = CreateFrame("Button", nil, reportBar)
    reportLabelBtn:SetHeight(16)
    local reportLabel = reportLabelBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    reportLabel:SetPoint("LEFT", 0, 0)
    reportLabel:SetText("Report")
    reportLabel:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    reportLabelBtn:SetWidth(reportLabel:GetStringWidth() + 4)
    reportLabelBtn:SetPoint("LEFT", reportBar, "LEFT", 4, 0)
    reportLabelBtn:SetScript("OnEnter", function()
        reportLabel:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
    end)
    reportLabelBtn:SetScript("OnLeave", function()
        reportLabel:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    end)
    reportLabelBtn:SetScript("OnClick", function()
        DPSReport_ToggleWidget()
    end)

    self:LoadPosition()

    -- Primary meter respects the global meterShown setting; extras always show
    if self.id == 1 and settings and settings.meterShown == false then
        frame:Hide()
    else
        frame:Show()
    end

    return frame
end

-- Rebuild all bars with the current bar height setting
function MeterProto:RebuildBars()
    if not self.barContainer or not self.bars then return end
    local barHeight = (settings and settings.meterBarHeight) or 18
    local fontSize = math.max(8, math.floor(barHeight * 0.55 + 0.5))

    for i = 1, self.MAX_BARS do
        local bar = self.bars[i]
        if bar then
            bar:SetHeight(barHeight)
            bar:ClearAllPoints()
            bar:SetPoint("TOPLEFT", self.barContainer, "TOPLEFT", 0, -(i - 1) * (barHeight + 1))
            bar:SetPoint("RIGHT", self.barContainer, "RIGHT", 0, 0)
            -- Resize icon to match
            if bar.icon then bar.icon:SetSize(barHeight - 2, barHeight - 2) end
            -- Scale fonts
            if bar.rank then
                local fontFile = bar.rank:GetFont()
                bar.rank:SetFont(fontFile, fontSize, "OUTLINE")
            end
            if bar.nameText then
                local fontFile = bar.nameText:GetFont()
                bar.nameText:SetFont(fontFile, fontSize, "")
            end
            if bar.valueText then
                local fontFile = bar.valueText:GetFont()
                bar.valueText:SetFont(fontFile, fontSize, "")
            end
        end
    end

    self.barContainer:SetHeight(self.MAX_BARS * (barHeight + 1))

    -- Update the self-pin bar height and fonts; position is handled by UpdateSelfPin
    if self.selfPinBar then
        self.selfPinBar:SetHeight(barHeight)
        if self.selfPinBar.icon then self.selfPinBar.icon:SetSize(barHeight - 2, barHeight - 2) end
        if self.selfPinBar.rank then
            local fontFile = self.selfPinBar.rank:GetFont()
            self.selfPinBar.rank:SetFont(fontFile, fontSize, "OUTLINE")
        end
        if self.selfPinBar.nameText then
            local fontFile = self.selfPinBar.nameText:GetFont()
            self.selfPinBar.nameText:SetFont(fontFile, fontSize, "")
        end
        if self.selfPinBar.valueText then
            local fontFile = self.selfPinBar.valueText:GetFont()
            self.selfPinBar.valueText:SetFont(fontFile, fontSize, "")
        end
    end

    -- Update mouse wheel step
    if self.frame then
        self.frame:SetScript("OnMouseWheel", function(_, delta)
            local current = self.scrollFrame:GetVerticalScroll()
            local maxScroll = self.barContainer:GetHeight() - self.scrollFrame:GetHeight()
            local newScroll = current - (delta * (barHeight + 1))
            newScroll = math.max(0, math.min(newScroll, math.max(0, maxScroll)))
            self.scrollFrame:SetVerticalScroll(newScroll)
        end)
    end

    self:RefreshDisplay()
end

-- ============================================================================
-- Self-pin: keep the local player visible, snapping to top or bottom
-- ============================================================================

function MeterProto:UpdateSelfPin()
    local selfPinBar = self.selfPinBar
    if not selfPinBar then return end

    -- Feature disabled, or nothing to show
    if not (settings and settings.pinSelf)
        or not self.entries or #self.entries == 0
        or not self.scrollFrame
    then
        selfPinBar:Hide()
        if self.selfPinSep then self.selfPinSep:Hide() end
        return
    end

    -- Find the local player's entry and rank
    local playerEntry, playerRank
    for i, entry in ipairs(self.entries) do
        if entry.isPlayer then
            playerEntry = entry
            playerRank  = i
            break
        end
    end

    if not playerEntry then
        selfPinBar:Hide()
        if self.selfPinSep then self.selfPinSep:Hide() end
        return
    end

    local barHeight = (settings and settings.meterBarHeight) or 18
    local rowH      = barHeight + 1
    local scrollY   = self.scrollFrame:GetVerticalScroll()
    local viewH     = self.scrollFrame:GetHeight()

    local rowTop = (playerRank - 1) * rowH
    local rowBot = rowTop + barHeight

    -- Determine which edge to pin to:
    --   "top"    – player row is above the visible area (scroll down past them)
    --   "bottom" – player row is below the visible area (scroll up past them)
    local pinDir
    if rowBot <= scrollY then
        pinDir = "top"
    elseif rowTop >= scrollY + viewH then
        pinDir = "bottom"
    end

    if not pinDir then
        -- Player row is visible – release the pin
        selfPinBar:Hide()
        if self.selfPinSep then self.selfPinSep:Hide() end
        return
    end

    -- Reposition bar and separator for the correct edge
    selfPinBar:ClearAllPoints()
    if self.selfPinSep then self.selfPinSep:ClearAllPoints() end

    if pinDir == "bottom" then
        selfPinBar:SetPoint("BOTTOMLEFT",  self.frame, "BOTTOMLEFT",  1, 19)
        selfPinBar:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -1, 19)
        if self.selfPinSep then
            -- Separator sits just above the bottom pin bar
            self.selfPinSep:SetPoint("BOTTOMLEFT",  self.frame, "BOTTOMLEFT",  1, 19 + barHeight)
            self.selfPinSep:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -1, 19 + barHeight)
        end
    else -- "top"
        selfPinBar:SetPoint("TOPLEFT",  self.titleBar, "BOTTOMLEFT",  1, -1)
        selfPinBar:SetPoint("TOPRIGHT", self.titleBar, "BOTTOMRIGHT", -1, -1)
        if self.selfPinSep then
            -- Separator sits just below the top pin bar
            self.selfPinSep:SetPoint("TOPLEFT",  self.titleBar, "BOTTOMLEFT",  1, -(1 + barHeight))
            self.selfPinSep:SetPoint("TOPRIGHT", self.titleBar, "BOTTOMRIGHT", -1, -(1 + barHeight))
        end
    end

    -- Populate bar data
    local topEntry = self.entries[1]
    if topEntry then
        selfPinBar:SetMinMaxValues(0, topEntry.displayValue)
    end
    selfPinBar:SetValue(playerEntry.displayValue)

    -- Class colour
    local r, g, b = 0.5, 0.5, 0.5
    if playerEntry.class and CLASS_COLORS[playerEntry.class] then
        local cc = CLASS_COLORS[playerEntry.class]
        r, g, b = cc.r, cc.g, cc.b
    else
        r, g, b = DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3]
    end
    local barAlpha = settings and settings.meterBarAlpha or 0.8
    selfPinBar:SetStatusBarColor(r, g, b, barAlpha)

    -- Icon
    if playerEntry.specIconID then
        selfPinBar.icon:SetTexture(playerEntry.specIconID)
        selfPinBar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    elseif playerEntry.class and CLASS_ICON_TCOORDS[playerEntry.class] then
        selfPinBar.icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
        local coords = CLASS_ICON_TCOORDS[playerEntry.class]
        selfPinBar.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        selfPinBar.icon:SetTexture(136243)
        selfPinBar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    selfPinBar.icon:SetAlpha(barAlpha)

    -- Rank, name, value
    selfPinBar.entry      = playerEntry
    selfPinBar.entryIndex = playerRank
    selfPinBar.rank:SetText(playerRank .. ".")
    selfPinBar.nameText:SetText(EntryDisplayName(playerEntry))

    local isPerSecond = (self.mode == "dps" or self.mode == "hps")
    if isPerSecond then
        selfPinBar.valueText:SetFormattedText("%s  %s",
            AbbreviateNumbers(playerEntry.amountPerSecond, ABBREVIATE_OPTS_PS),
            AbbreviateNumbers(playerEntry.totalAmount, ABBREVIATE_OPTS_TOTAL)
        )
    else
        selfPinBar.valueText:SetFormattedText("%s",
            AbbreviateNumbers(playerEntry.displayValue, ABBREVIATE_OPTS_TOTAL)
        )
    end

    selfPinBar:Show()
    if self.selfPinSep then self.selfPinSep:Show() end
end


function MeterProto:RefreshDisplay()
    if not self.frame or not self.frame:IsShown() then return end

    local entries = self.entries
    local barHeight = (settings and settings.meterBarHeight) or 18

    -- Build a short-name frequency map using only plain-string plainNames.
    -- When two entries share the same short name (cross-realm same-name players),
    -- show the full name (with realm) instead so bars are distinguishable.
    local shortNameCount = {}
    for _, e in ipairs(entries) do
        if e.plainName then
            local short = ShortName(e.plainName)
            shortNameCount[short] = (shortNameCount[short] or 0) + 1
        end
    end
    local function ResolvedBarName(entry)
        if entry.plainName and (shortNameCount[ShortName(entry.plainName)] or 0) > 1 then
            -- Collision: show nickname if set, otherwise full name with realm
            local nick
            local ok = pcall(function() nick = nicknameCache[entry.plainName] end)
            if ok and nick then return nick end
            return entry.plainName
        end
        return EntryDisplayName(entry)
    end

    -- Update timer using our own plain-number duration
    if self.timerText then
        self.timerText:SetText(FormatDuration(self:GetCombatDuration()))
    end

    -- In-combat with no data: show status indicator
    if self.inCombat and #entries == 0 then
        local bar = self.bars[1]
        if bar then
            bar:SetMinMaxValues(0, 100)
            bar:SetValue(100)
            bar:SetStatusBarColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.4)
            bar.rank:SetText("")
            bar.nameText:SetText("In Combat...")
            bar.valueText:SetText("")
            bar:Show()
        end
        for i = 2, self.MAX_BARS do self.bars[i]:Hide() end
        self.barContainer:SetHeight(barHeight + 1)
        return
    end

    -- First entry has the highest value (API returns pre-sorted desc).
    -- Use its displayValue as the bar max so relative bar widths are correct.
    -- These are secret/tainted numbers – pass directly to StatusBar widgets.
    local topEntry = entries[1]

    local visibleBars = 0
    for i = 1, self.MAX_BARS do
        local bar = self.bars[i]
        local entry = entries[i]

        if entry then
            visibleBars = visibleBars + 1

            -- Set bar fill relative to top entry (secret numbers to widgets)
            if topEntry then
                bar:SetMinMaxValues(0, topEntry.displayValue)
            end
            bar:SetValue(entry.displayValue)

            -- Class color (classFilename is a plain string)
            local r, g, b = 0.5, 0.5, 0.5
            if entry.class and CLASS_COLORS[entry.class] then
                local cc = CLASS_COLORS[entry.class]
                r, g, b = cc.r, cc.g, cc.b
            elseif entry.isPlayer then
                r, g, b = DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3]
            end
            local barAlpha = settings and settings.meterBarAlpha or 0.8
            bar:SetStatusBarColor(r, g, b, barAlpha)

            -- Class/spec icon
            if entry.specIconID then
                bar.icon:SetTexture(entry.specIconID)
                bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            elseif entry.class and CLASS_ICON_TCOORDS[entry.class] then
                bar.icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
                local coords = CLASS_ICON_TCOORDS[entry.class]
                bar.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
            else
                bar.icon:SetTexture(136243) -- question mark
                bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            end
            bar.icon:SetAlpha(barAlpha)

            -- Store entry reference on bar for tooltip/click
            bar.entry = entry
            bar.entryIndex = i

            -- Rank (plain number)
            bar.rank:SetText(i .. ".")

            -- Name – use plain name from roster cache when available; show full
            -- name (with realm) when two entries share the same short name.
            local resolvedName = ResolvedBarName(entry)
            bar.lastResolvedName = resolvedName
            -- Only overwrite name text if no ilvl display is active on this bar.
            if not bar.ilvlRevertTimer then
                bar.nameText:SetText(resolvedName)
            end

            -- Value text: use C-side AbbreviateNumbers for taint-safe K/M display
            -- e.g. "1.2K", "7.33M" for per-second; "65.2K" for totals
            local isPerSecond = (self.mode == "dps" or self.mode == "hps")
            if isPerSecond then
                bar.valueText:SetFormattedText("%s  %s",
                    AbbreviateNumbers(entry.amountPerSecond, ABBREVIATE_OPTS_PS),
                    AbbreviateNumbers(entry.totalAmount, ABBREVIATE_OPTS_TOTAL)
                )
            else
                bar.valueText:SetFormattedText("%s",
                    AbbreviateNumbers(entry.displayValue, ABBREVIATE_OPTS_TOTAL)
                )
            end

            bar:Show()
        else
            bar:Hide()
        end
    end

    -- Update scroll child height to fit content (scrollbar appears if needed)
    self.barContainer:SetHeight(math.max(1, visibleBars) * (barHeight + 1))

    -- Refresh the pinned-self bar (may show/hide depending on scroll position)
    self:UpdateSelfPin()
end

-- ============================================================================
-- Tooltip (custom frame with bars + aligned columns, hover over bar)
-- ============================================================================

local TOOLTIP_ROW_HEIGHT = 16
local TOOLTIP_WIDTH = 310
local TOOLTIP_MAX_SPELLS = 15

function MeterProto:CreateTooltipFrame()
    if self.tooltipFrame then return self.tooltipFrame end

    local tipName = "DPSReportTooltip" .. (self.id > 1 and self.id or "")
    local tip = CreateFrame("Frame", tipName, UIParent, "BackdropTemplate")
    tip:SetSize(TOOLTIP_WIDTH, 40)
    tip:SetFrameStrata("TOOLTIP")
    tip:SetClampedToScreen(true)
    ApplyDRBackdrop(tip, {0.04, 0.04, 0.06, 0.96}, DR_COLORS.border)

    -- Title
    local title = tip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 6, -5)
    tip.title = title

    -- Column headers
    local hdrFrame = CreateFrame("Frame", nil, tip)
    hdrFrame:SetHeight(14)
    hdrFrame:SetPoint("TOPLEFT", tip, "TOPLEFT", 4, -22)
    hdrFrame:SetPoint("TOPRIGHT", tip, "TOPRIGHT", -4, -22)
    tip.hdrFrame = hdrFrame

    local hSpell = hdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hSpell:SetPoint("LEFT", 20, 0)
    hSpell:SetText("Spell Name")
    hSpell:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    local hPct = hdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hPct:SetPoint("RIGHT", -2, 0)
    hPct:SetWidth(36)
    hPct:SetJustifyH("RIGHT")
    hPct:SetText("%")
    hPct:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    tip.hPct = hPct

    local hDPS = hdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hDPS:SetPoint("RIGHT", hPct, "LEFT", -4, 0)
    hDPS:SetWidth(36)
    hDPS:SetJustifyH("RIGHT")
    hDPS:SetText("DPS")
    hDPS:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    tip.hDPS = hDPS

    local hAmt = hdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hAmt:SetPoint("RIGHT", hDPS, "LEFT", -4, 0)
    hAmt:SetWidth(38)
    hAmt:SetJustifyH("RIGHT")
    hAmt:SetText("Amount")
    hAmt:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    -- Footer
    local footer = tip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footer:SetPoint("BOTTOMLEFT", tip, "BOTTOMLEFT", 6, 4)
    footer:SetText("Click for details")
    footer:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    tip.footer = footer

    tip:Hide()
    self.tooltipFrame = tip
    return tip
end

function MeterProto:GetTooltipRow(index)
    if self.tooltipRows[index] then return self.tooltipRows[index] end

    local tip = self.tooltipFrame
    local rh = TOOLTIP_ROW_HEIGHT
    local contentW = TOOLTIP_WIDTH - 8
    local iconSize = rh - 2

    local row = CreateFrame("Frame", nil, tip)
    row:SetHeight(rh)
    row:SetPoint("TOPLEFT", tip, "TOPLEFT", 4, -(36 + (index - 1) * (rh + 1)))
    row:SetPoint("RIGHT", tip, "RIGHT", -4, 0)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.4)

    local icon = row:CreateTexture(nil, "OVERLAY")
    icon:SetSize(iconSize, iconSize)
    icon:SetPoint("LEFT", 1, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    -- Inner StatusBar (starts after icon)
    local sb = CreateFrame("StatusBar", nil, row)
    sb:SetPoint("TOPLEFT", icon, "TOPRIGHT", 1, 0)
    sb:SetPoint("BOTTOMRIGHT", 0, 0)
    sb:SetStatusBarTexture("Interface\\BUTTONS\\WHITE8X8")
    sb:SetStatusBarColor(0.3, 0.3, 0.3, 0.6)
    sb:SetMinMaxValues(0, 100)
    sb:SetValue(0)

    row.SetMinMaxValues = function(_, ...) sb:SetMinMaxValues(...) end
    row.SetValue = function(_, ...) sb:SetValue(...) end
    row.SetStatusBarColor = function(_, ...) sb:SetStatusBarColor(...) end

    local nameText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", 3, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetTextColor(1, 1, 1)
    row.nameText = nameText

    local pctText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pctText:SetPoint("RIGHT", -2, 0)
    pctText:SetWidth(36)
    pctText:SetJustifyH("RIGHT")
    pctText:SetTextColor(1, 0.82, 0)
    row.pctText = pctText

    local dpsText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dpsText:SetPoint("RIGHT", pctText, "LEFT", -4, 0)
    dpsText:SetWidth(36)
    dpsText:SetJustifyH("RIGHT")
    dpsText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    row.dpsText = dpsText

    local amtText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    amtText:SetPoint("RIGHT", dpsText, "LEFT", -4, 0)
    amtText:SetWidth(38)
    amtText:SetJustifyH("RIGHT")
    amtText:SetTextColor(1, 1, 1)
    row.amtText = amtText

    nameText:SetPoint("RIGHT", amtText, "LEFT", -4, 0)

    self.tooltipRows[index] = row
    return row
end

function MeterProto:ShowBarTooltip(bar)
    local entry = bar.entry
    if not entry then return end

    local tip = self:CreateTooltipFrame()

    -- Title: character name in class color
    local r, g, b = 1, 1, 1
    if entry.class and CLASS_COLORS[entry.class] then
        local cc = CLASS_COLORS[entry.class]
        r, g, b = cc.r, cc.g, cc.b
    end
    tip.title:SetText(EntryDisplayName(entry))
    tip.title:SetTextColor(r, g, b)

    local isPerSecond = (self.mode == "dps" or self.mode == "hps")
    tip.hDPS:SetText(isPerSecond and "DPS" or "")

    -- Fetch spell breakdown.
    -- For saved segments, use per-spell data stored in the snapshot (entry.spells)
    -- rather than querying the live API, which would return current-fight data.
    -- For current/overall, query the live API; substitute UnitGUID("player") for
    -- the local player so tooltips still work mid-fight (sourceGUID is tainted then).
    local meterType = METER_MODE_MAP[self.mode] or Enum.DamageMeterType.Dps
    local isSavedSeg = self.session and self.session:sub(1, 4) == "seg:"
    local ok, spellData
    if isSavedSeg then
        if entry.spells and #entry.spells > 0 then
            ok = true
            spellData = { combatSpells = entry.spells, totalAmount = entry.totalAmount }
        end
    else
        local sessionEnum = self.session == "overall"
            and Enum.DamageMeterSessionType.Overall
            or Enum.DamageMeterSessionType.Current
        local guid = (entry.isPlayer and UnitGUID("player")) or entry.sourceGUID
        ok, spellData = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
            sessionEnum, meterType, guid)
    end

    -- Hide all existing rows
    for _, row in pairs(self.tooltipRows) do row:Hide() end

    local spellCount = 0
    if ok and spellData and spellData.combatSpells then
        local spells = spellData.combatSpells
        local topSpell = spells[1]
        spellCount = math.min(TOOLTIP_MAX_SPELLS, #spells)

        -- Bar tint color
        local br, bg2, bb = 0.4, 0.4, 0.5
        if entry.class and CLASS_COLORS[entry.class] then
            local cc = CLASS_COLORS[entry.class]
            br, bg2, bb = cc.r * 0.7, cc.g * 0.7, cc.b * 0.7
        end

        for i = 1, spellCount do
            local spell = spells[i]
            local row = self:GetTooltipRow(i)

            -- Bar fill
            if topSpell then
                row:SetMinMaxValues(0, topSpell.totalAmount)
            end
            row:SetValue(spell.totalAmount)
            row:SetStatusBarColor(br, bg2, bb, 0.6)

            -- Icon + name (fall back to stored name/iconID for snapshot entries)
            local spellInfo = spell.spellID and C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spell.spellID)
            local spellName = (spellInfo and spellInfo.name) or spell.name or ("Spell " .. (spell.spellID or "?"))
            local spellIcon = (spellInfo and spellInfo.iconID) or spell.iconID or 136243
            row.icon:SetTexture(spellIcon)
            row.nameText:SetText(spellName)

            -- Amount
            row.amtText:SetFormattedText("%s", AbbreviateNumbers(spell.totalAmount, ABBREVIATE_OPTS_TOTAL))

            -- DPS
            if isPerSecond then
                row.dpsText:SetFormattedText("%s", AbbreviateNumbers(spell.amountPerSecond, ABBREVIATE_OPTS_PS))
            else
                row.dpsText:SetText("")
            end

            -- Percent
            local pctOk, pctVal = pcall(function()
                local total = spellData.totalAmount or 0
                if total > 0 then
                    return string.format("%.1f%%", spell.totalAmount / total * 100)
                end
                return ""
            end)
            row.pctText:SetText(pctOk and pctVal or "")

            row:Show()
        end
    end

    -- Size the tooltip to fit content
    local totalH = 36 + spellCount * (TOOLTIP_ROW_HEIGHT + 1) + 20
    tip:SetHeight(math.max(60, totalH))

    -- Position anchored to the bar
    tip:ClearAllPoints()
    tip:SetPoint("BOTTOMLEFT", bar, "TOPRIGHT", 4, -4)
    tip:Show()
end

function MeterProto:HideBarTooltip()
    if self.tooltipFrame then
        self.tooltipFrame:Hide()
    end
end

-- ============================================================================
-- Full Breakdown Window (Details!-style, opens on bar click)
-- ============================================================================

-- Helper: create a row used in both spell and target sections
local function CreateBreakdownRow(parent, index, rowHeight)
    local iconSize = rowHeight - 2

    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(rowHeight)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * (rowHeight + 1))
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.4)

    local icon = row:CreateTexture(nil, "OVERLAY")
    icon:SetSize(iconSize, iconSize)
    icon:SetPoint("LEFT", 1, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    -- Inner StatusBar (starts after icon)
    local sb = CreateFrame("StatusBar", nil, row)
    sb:SetPoint("TOPLEFT", icon, "TOPRIGHT", 1, 0)
    sb:SetPoint("BOTTOMRIGHT", 0, 0)
    sb:SetStatusBarTexture("Interface\\BUTTONS\\WHITE8X8")
    sb:SetStatusBarColor(0.3, 0.3, 0.3, 0.6)
    sb:SetMinMaxValues(0, 100)
    sb:SetValue(0)

    row.SetMinMaxValues = function(_, ...) sb:SetMinMaxValues(...) end
    row.SetValue = function(_, ...) sb:SetValue(...) end
    row.SetStatusBarColor = function(_, ...) sb:SetStatusBarColor(...) end

    local rankText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rankText:SetPoint("LEFT", 2, 0)
    rankText:SetWidth(16)
    rankText:SetJustifyH("RIGHT")
    rankText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    row.rankText = rankText

    local nameText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", rankText, "RIGHT", 4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetTextColor(1, 1, 1)
    row.nameText = nameText

    local pctText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pctText:SetPoint("RIGHT", -2, 0)
    pctText:SetWidth(40)
    pctText:SetJustifyH("RIGHT")
    pctText:SetTextColor(1, 0.82, 0)
    row.pctText = pctText

    local dpsText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dpsText:SetPoint("RIGHT", pctText, "LEFT", -4, 0)
    dpsText:SetWidth(40)
    dpsText:SetJustifyH("RIGHT")
    dpsText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    row.dpsText = dpsText

    local amtText = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    amtText:SetPoint("RIGHT", dpsText, "LEFT", -4, 0)
    amtText:SetWidth(48)
    amtText:SetJustifyH("RIGHT")
    amtText:SetTextColor(1, 1, 1)
    row.amtText = amtText

    nameText:SetPoint("RIGHT", amtText, "LEFT", -4, 0)

    row:EnableMouse(true)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(self, delta)
        local scroll = self:GetParent():GetParent()
        local handler = scroll and scroll:GetScript("OnMouseWheel")
        if handler then handler(scroll, delta) end
    end)
    row:SetScript("OnEnter", function(self)
        if self.spellID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(self.spellID)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

-- Helper: create a player row for the left sidebar
local function CreatePlayerRow(parent, index, rowHeight)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(rowHeight)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * (rowHeight + 1))
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.08, 0.08, 0.1, 0.6)
    row.bg = bg

    local icon = row:CreateTexture(nil, "OVERLAY")
    icon:SetSize(rowHeight - 2, rowHeight - 2)
    icon:SetPoint("LEFT", 2, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    nameText:SetPoint("RIGHT", -2, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetTextColor(1, 1, 1)
    row.nameText = nameText

    return row
end

function MeterProto:CreateBreakdownFrame()
    if self.breakdownFrame then return self.breakdownFrame end

    local meter = self
    local bw = 680  -- total width
    local leftW = 150
    local rowH = 18

    local bdName = "DPSReportBreakdown" .. (self.id > 1 and self.id or "")
    local frame = CreateFrame("Frame", bdName, UIParent, "BackdropTemplate")
    frame:SetSize(bw, 450)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(500, 300, 900, 700)
    end
    ApplyDRBackdrop(frame, {0.04, 0.04, 0.06, 0.95}, DR_COLORS.border)

    -- ============== TITLE BAR ==============
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(22)
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    titleBar:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    titleBar:SetBackdropColor(DR_COLORS.titleBar[1], DR_COLORS.titleBar[2], DR_COLORS.titleBar[3], 1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", 6, 0)
    titleText:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])
    frame.titleText = titleText

    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(14, 14)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -3, 0)
    local closeText = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    closeText:SetPoint("CENTER")
    closeText:SetText("X")
    closeText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    closeBtn:SetScript("OnEnter", function() closeText:SetTextColor(DR_COLORS.danger[1], DR_COLORS.danger[2], DR_COLORS.danger[3]) end)
    closeBtn:SetScript("OnLeave", function() closeText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3]) end)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- Mode dropdown in title bar
    local bdModeItems = {
        { text = "DPS",        value = "dps" },
        { text = "HPS",        value = "hps" },
        { text = "Damage",     value = "damage" },
        { text = "Healing",    value = "healing" },
        { text = "Absorbs",    value = "absorbs" },
        { text = "Interrupts", value = "interrupts" },
        { text = "Dispels",    value = "dispels" },
        { text = "Dmg Taken",  value = "taken" },
        { text = "Deaths",     value = "deaths" },
    }
    local bdModeDrop = CreateMeterDropdown(titleBar, 80, bdModeItems, self.mode, function(value)
        frame.bdMode = value
        meter:LoadBreakdownEntries()
        meter:PopulateSidebar()
        local selEntry
        for _, e in ipairs(frame.bdEntries) do
            if e.sourceGUID == meter.breakdownSelectedGUID then selEntry = e; break end
        end
        if selEntry then
            meter:PopulateSpells(selEntry)
            meter:PopulateTargets(selEntry)
        elseif frame.bdEntries[1] then
            meter.breakdownSelectedGUID = frame.bdEntries[1].sourceGUID
            meter:PopulateSidebar()
            meter:PopulateSpells(frame.bdEntries[1])
            meter:PopulateTargets(frame.bdEntries[1])
        else
            meter:PopulateSidebar()
            meter:PopulateSpells(nil)
            meter:PopulateTargets(nil)
        end
    end)
    bdModeDrop:SetPoint("RIGHT", closeBtn, "LEFT", -6, 0)
    frame.bdModeDrop = bdModeDrop

    local accentLine = titleBar:CreateTexture(nil, "OVERLAY")
    accentLine:SetHeight(1)
    accentLine:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    accentLine:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.3)

    -- ============== LEFT SIDEBAR (Player list) ==============
    local sidebar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    sidebar:SetWidth(leftW)
    sidebar:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 1, -1)
    sidebar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 2)
    sidebar:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    sidebar:SetBackdropColor(0.03, 0.03, 0.05, 0.8)
    frame.sidebar = sidebar

    -- "Name" column header
    local sideHeader = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sideHeader:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 4, -2)
    sideHeader:SetText("#    Name")
    sideHeader:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    -- Scrollable player list
    local sideScroll = CreateFrame("ScrollFrame", nil, sidebar, "UIPanelScrollFrameTemplate")
    sideScroll:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, -18)
    sideScroll:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 0, 124)
    local sideScrollBar = sideScroll.ScrollBar
    if sideScrollBar then
        sideScrollBar:ClearAllPoints()
        sideScrollBar:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 1000, 0)
        sideScrollBar:SetWidth(1)
        sideScrollBar:Hide()
        sideScrollBar:SetAlpha(0)
        if sideScrollBar.ScrollUpButton then sideScrollBar.ScrollUpButton:Hide() end
        if sideScrollBar.ScrollDownButton then sideScrollBar.ScrollDownButton:Hide() end
    end

    local sideContent = CreateFrame("Frame", nil, sideScroll)
    sideContent:SetWidth(leftW - 2)
    sideContent:SetHeight(1)
    sideScroll:SetScrollChild(sideContent)
    frame.sideContent = sideContent
    frame.sideScroll = sideScroll

    -- Mouse wheel for player list scroll
    sideScroll:EnableMouseWheel(true)
    sideScroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = sideContent:GetHeight() - self:GetHeight()
        self:SetVerticalScroll(math.max(0, math.min(cur - delta * 42, math.max(0, max))))
    end)
    frame.playerRows = {}

    -- Horizontal divider above segments
    local segDivider = sidebar:CreateTexture(nil, "OVERLAY")
    segDivider:SetHeight(1)
    segDivider:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMLEFT", 2, 120)
    segDivider:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -2, 120)
    segDivider:SetColorTexture(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.4)

    -- Segments header
    local segHeader = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    segHeader:SetPoint("TOPLEFT", segDivider, "BOTTOMLEFT", 2, -2)
    segHeader:SetText("Session")
    segHeader:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    -- Scrollable segment area
    local segScroll = CreateFrame("ScrollFrame", nil, sidebar, "UIPanelScrollFrameTemplate")
    segScroll:SetPoint("TOPLEFT", segHeader, "BOTTOMLEFT", -2, -2)
    segScroll:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 0, 0)
    local segSB = segScroll.ScrollBar
    if segSB then
        segSB:ClearAllPoints()
        segSB:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 1000, 0)
        segSB:SetWidth(1)
        segSB:Hide()
        segSB:SetAlpha(0)
        if segSB.ScrollUpButton then segSB.ScrollUpButton:Hide() end
        if segSB.ScrollDownButton then segSB.ScrollDownButton:Hide() end
    end

    local segContent = CreateFrame("Frame", nil, segScroll)
    segContent:SetWidth(leftW - 2)
    segContent:SetHeight(1)
    segScroll:SetScrollChild(segContent)
    frame.segContent = segContent
    frame.segScroll = segScroll
    frame.segmentRows = {}

    -- Mouse wheel for segment scroll
    segScroll:EnableMouseWheel(true)
    segScroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = segContent:GetHeight() - self:GetHeight()
        self:SetVerticalScroll(math.max(0, math.min(cur - delta * 42, math.max(0, max))))
    end)

    -- Divider line between sidebar and right pane
    local divider = frame:CreateTexture(nil, "OVERLAY")
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMRIGHT", 0, 0)
    divider:SetColorTexture(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.5)

    -- ============== RIGHT PANE (spell + target panels) ==============
    local rightPane = CreateFrame("Frame", nil, frame)
    rightPane:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 2, 0)
    rightPane:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    frame.rightPane = rightPane

    -- ---- SPELL SECTION (top half) ----
    local spellSection = CreateFrame("Frame", nil, rightPane)
    spellSection:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 0, 0)
    spellSection:SetPoint("RIGHT", rightPane, "RIGHT", 0, 0)
    spellSection:SetHeight(200) -- will be adjusted dynamically
    frame.spellSection = spellSection

    -- Spell header row
    local spellHdr = CreateFrame("Frame", nil, spellSection)
    spellHdr:SetHeight(16)
    spellHdr:SetPoint("TOPLEFT", spellSection, "TOPLEFT", 0, -2)
    spellHdr:SetPoint("TOPRIGHT", spellSection, "TOPRIGHT", 0, -2)

    local hSpell = spellHdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hSpell:SetPoint("LEFT", 22, 0)
    hSpell:SetText("Spell Name")
    hSpell:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    local hPct = spellHdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hPct:SetPoint("RIGHT", -2, 0)
    hPct:SetWidth(40)
    hPct:SetJustifyH("RIGHT")
    hPct:SetText("%")
    hPct:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    local hDPS = spellHdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hDPS:SetPoint("RIGHT", hPct, "LEFT", -4, 0)
    hDPS:SetWidth(40)
    hDPS:SetJustifyH("RIGHT")
    hDPS:SetText("DPS")
    hDPS:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
    frame.hdrDPS = hDPS

    local hAmt = spellHdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hAmt:SetPoint("RIGHT", hDPS, "LEFT", -4, 0)
    hAmt:SetWidth(48)
    hAmt:SetJustifyH("RIGHT")
    hAmt:SetText("Amount")
    hAmt:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    -- Spell scroll (plain ScrollFrame, no template scrollbar)
    local spellScroll = CreateFrame("ScrollFrame", nil, spellSection)
    spellScroll:SetPoint("TOPLEFT", spellHdr, "BOTTOMLEFT", 0, -2)
    spellScroll:SetPoint("BOTTOMRIGHT", spellSection, "BOTTOMRIGHT", 0, 0)

    local spellContent = CreateFrame("Frame", nil, spellScroll)
    spellContent:SetWidth(1)
    spellContent:SetHeight(1)
    spellScroll:SetScrollChild(spellContent)
    frame.spellContent = spellContent
    frame.spellRows = {}

    spellScroll:SetScript("OnSizeChanged", function(self, w)
        spellContent:SetWidth(w)
    end)
    spellScroll:EnableMouseWheel(true)
    spellScroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = math.max(0, spellContent:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(cur - delta * 54, max)))
    end)

    -- "No Data" overlay for spell section
    local spellNoData = spellSection:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    spellNoData:SetPoint("CENTER", spellSection, "CENTER", 0, 0)
    spellNoData:SetText("No Data")
    spellNoData:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3], 0.7)
    spellNoData:Hide()
    frame.spellNoData = spellNoData

    -- ---- Divider between spells and targets ----
    local midDivider = rightPane:CreateTexture(nil, "OVERLAY")
    midDivider:SetHeight(1)
    midDivider:SetPoint("TOPLEFT", spellSection, "BOTTOMLEFT", 0, -1)
    midDivider:SetPoint("TOPRIGHT", spellSection, "BOTTOMRIGHT", 0, -1)
    midDivider:SetColorTexture(DR_COLORS.border[1], DR_COLORS.border[2], DR_COLORS.border[3], 0.4)
    frame.midDivider = midDivider

    -- ---- TARGET SECTION (bottom half) ----
    local targetSection = CreateFrame("Frame", nil, rightPane)
    targetSection:SetPoint("TOPLEFT", spellSection, "BOTTOMLEFT", 0, -3)
    targetSection:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", 0, 0)
    frame.targetSection = targetSection

    -- Target header
    local targetHdr = CreateFrame("Frame", nil, targetSection)
    targetHdr:SetHeight(16)
    targetHdr:SetPoint("TOPLEFT", targetSection, "TOPLEFT", 0, -2)
    targetHdr:SetPoint("TOPRIGHT", targetSection, "TOPRIGHT", 0, -2)

    local tName = targetHdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tName:SetPoint("LEFT", 22, 0)
    tName:SetText("Target Name")
    tName:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    local tAmt = targetHdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tAmt:SetPoint("RIGHT", -(2 + 40 + 4 + 40 + 4), 0)
    tAmt:SetWidth(48)
    tAmt:SetJustifyH("RIGHT")
    tAmt:SetText("Amount")
    tAmt:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])

    -- Target scroll (plain ScrollFrame, no template scrollbar)
    local targetScroll = CreateFrame("ScrollFrame", nil, targetSection)
    targetScroll:SetPoint("TOPLEFT", targetHdr, "BOTTOMLEFT", 0, -2)
    targetScroll:SetPoint("BOTTOMRIGHT", targetSection, "BOTTOMRIGHT", 0, 0)

    local targetContent = CreateFrame("Frame", nil, targetScroll)
    targetContent:SetWidth(1)
    targetContent:SetHeight(1)
    targetScroll:SetScrollChild(targetContent)
    frame.targetContent = targetContent
    frame.targetRows = {}

    targetScroll:SetScript("OnSizeChanged", function(self, w)
        targetContent:SetWidth(w)
    end)
    targetScroll:EnableMouseWheel(true)
    targetScroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = math.max(0, targetContent:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(cur - delta * 54, max)))
    end)

    -- "No Data" overlay for target section
    local targetNoData = targetSection:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    targetNoData:SetPoint("CENTER", targetSection, "CENTER", 0, 0)
    targetNoData:SetText("No Data")
    targetNoData:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3], 0.7)
    targetNoData:Hide()
    frame.targetNoData = targetNoData

    -- Resize handle
    local resizer = CreateFrame("Button", nil, frame)
    resizer:SetSize(12, 12)
    resizer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizer:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    resizer:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        -- Recalculate section heights
        meter:LayoutBreakdownSections()
    end)

    frame:Hide()
    self.breakdownFrame = frame
    return frame
end

-- Adjust the spell/target section split (60/40)
function MeterProto:LayoutBreakdownSections()
    local frame = self.breakdownFrame
    if not frame then return end
    local rightH = frame.rightPane:GetHeight()
    local spellH = math.floor(rightH * 0.6)
    frame.spellSection:SetHeight(spellH)
end

-- Load entries for the breakdown window independently of the main meter
function MeterProto:LoadBreakdownEntries()
    local frame = self.breakdownFrame
    if not frame then return end
    local mode = frame.bdMode
    local session = frame.bdSession
    frame.bdEntries = {}

    -- M+ stored segment: load from snapshot
    if session and session:sub(1, 4) == "seg:" then
        local idx = tonumber(session:sub(5))
        local seg = idx and DPSMeter.segments[idx]
        if seg and seg.modes and seg.modes[mode] then
            for _, e in ipairs(seg.modes[mode].entries) do
                table.insert(frame.bdEntries, e)
            end
        end
        return
    end

    -- API-tracked expired session
    if session and session:sub(1, 4) == "sid:" then
        local id = tonumber(session:sub(5))
        for _, e in ipairs(BuildEntriesFromSessionID(id, mode, 40)) do
            table.insert(frame.bdEntries, e)
        end
        return
    end

    local meterType = METER_MODE_MAP[mode]
    if not meterType then return end

    local isAvailable = C_DamageMeter.IsDamageMeterAvailable()
    if not isAvailable then return end

    local apiSession = C_DamageMeter.GetCombatSessionFromType(
        session == "overall" and Enum.DamageMeterSessionType.Overall or Enum.DamageMeterSessionType.Current,
        meterType
    )
    if not apiSession then return end

    local sources = apiSession.combatSources
    if not sources or #sources == 0 then return end

    local isPerSecond = (mode == "dps" or mode == "hps")
    local count = math.min(40, #sources)
    for i = 1, count do
        local src = sources[i]
        local plainName = ResolveSourcePlainName(src)
        table.insert(frame.bdEntries, {
            name            = plainName or src.name,
            plainName       = plainName,
            apiName         = src.name,
            class           = src.classFilename,
            displayValue = isPerSecond and src.amountPerSecond or src.totalAmount,
            totalAmount  = src.totalAmount,
            amountPerSecond = src.amountPerSecond,
            isPlayer     = src.isLocalPlayer,
            sourceGUID   = src.sourceGUID ~= nil and SafeStr(src.sourceGUID) or nil,
            specIconID   = src.specIconID,
        })
    end
end

-- Get or create a spell row
function MeterProto:GetSpellRow(index)
    local frame = self.breakdownFrame
    if frame.spellRows[index] then return frame.spellRows[index] end
    local row = CreateBreakdownRow(frame.spellContent, index, 18)
    frame.spellRows[index] = row
    return row
end

-- Get or create a target row
function MeterProto:GetTargetRow(index)
    local frame = self.breakdownFrame
    if frame.targetRows[index] then return frame.targetRows[index] end
    local row = CreateBreakdownRow(frame.targetContent, index, 18)
    -- Targets don't have spellID tooltips; clear the handler
    row:SetScript("OnEnter", nil)
    row:SetScript("OnLeave", nil)
    frame.targetRows[index] = row
    return row
end

-- Get or create a player sidebar row
function MeterProto:GetPlayerRow(index)
    local frame = self.breakdownFrame
    if frame.playerRows[index] then return frame.playerRows[index] end
    local row = CreatePlayerRow(frame.sideContent, index, 20)
    frame.playerRows[index] = row
    return row
end

-- Populate the left sidebar with all meter entries
function MeterProto:PopulateSidebar()
    local frame = self.breakdownFrame
    local entries = frame.bdEntries or {}

    for i = 1, math.max(#entries, #frame.playerRows) do
        local entry = entries[i]
        if entry then
            local row = self:GetPlayerRow(i)

            -- Icon
            if entry.specIconID then
                row.icon:SetTexture(entry.specIconID)
                row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            elseif entry.class and CLASS_ICON_TCOORDS[entry.class] then
                row.icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
                local coords = CLASS_ICON_TCOORDS[entry.class]
                row.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
            else
                row.icon:SetTexture(136243)
                row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            end

            row.nameText:SetText(EntryDisplayName(entry))

            -- Class color on name
            if entry.class and CLASS_COLORS[entry.class] then
                local cc = CLASS_COLORS[entry.class]
                row.nameText:SetTextColor(cc.r, cc.g, cc.b)
            else
                row.nameText:SetTextColor(1, 1, 1)
            end

            -- Highlight selected
            local isSelected = (entry.sourceGUID == self.breakdownSelectedGUID)
            if isSelected then
                row.bg:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.25)
            else
                row.bg:SetColorTexture(0.08, 0.08, 0.1, 0.6)
            end

            -- Click to select
            row:SetScript("OnClick", function()
                self.breakdownSelectedGUID = entry.sourceGUID
                self:PopulateSidebar()
                self:PopulateSpells(entry)
                self:PopulateTargets(entry)
            end)

            -- Hover highlight
            row:SetScript("OnEnter", function(self)
                if not isSelected then
                    self.bg:SetColorTexture(0.15, 0.15, 0.2, 0.8)
                end
            end)
            row:SetScript("OnLeave", function(self)
                if not isSelected then
                    self.bg:SetColorTexture(0.08, 0.08, 0.1, 0.6)
                end
            end)

            row:Show()
        elseif frame.playerRows[i] then
            frame.playerRows[i]:Hide()
        end
    end

    frame.sideContent:SetHeight(math.max(1, #entries) * 21)
end

-- Populate the spell breakdown for a given entry
function MeterProto:PopulateSpells(entry)
    local frame = self.breakdownFrame

    -- Hide all existing rows first
    for _, row in pairs(frame.spellRows) do row:Hide() end

    if not entry or not entry.sourceGUID then
        frame.spellContent:SetHeight(1)
        frame.spellNoData:Show()
        return
    end

    local bdMode = frame.bdMode or self.mode
    local bdSession = frame.bdSession or self.session

    -- Update title: character name in class color
    if entry.class and CLASS_COLORS[entry.class] then
        local cc = CLASS_COLORS[entry.class]
        frame.titleText:SetText(EntryDisplayName(entry))
        frame.titleText:SetTextColor(cc.r, cc.g, cc.b)
    else
        frame.titleText:SetText(EntryDisplayName(entry))
        frame.titleText:SetTextColor(DR_COLORS.text[1], DR_COLORS.text[2], DR_COLORS.text[3])
    end

    local isPerSecond = (bdMode == "dps" or bdMode == "hps")
    if frame.hdrDPS then
        frame.hdrDPS:SetText(isPerSecond and "DPS" or "")
    end

    -- Fetch spell data.
    -- seg:  M+ stored snapshot  (entry.spells)
    -- sid:  API expired session  (GetCombatSessionSourceFromID)
    -- live: current/overall      (GetCombatSessionSourceFromType)
    local meterType = METER_MODE_MAP[bdMode] or Enum.DamageMeterType.Dps
    local isSavedSeg = bdSession and bdSession:sub(1, 4) == "seg:"
    local isAPISession = bdSession and bdSession:sub(1, 4) == "sid:"

    local ok, spellData
    if isSavedSeg then
        if entry.spells and #entry.spells > 0 then
            ok = true
            spellData = { combatSpells = entry.spells, totalAmount = entry.totalAmount }
        end
    elseif isAPISession then
        local id = tonumber(bdSession:sub(5))
        ok, spellData = pcall(C_DamageMeter.GetCombatSessionSourceFromID,
            id, meterType, entry.sourceGUID)
    else
        local sessionEnum = bdSession == "overall"
            and Enum.DamageMeterSessionType.Overall
            or Enum.DamageMeterSessionType.Current
        ok, spellData = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
            sessionEnum, meterType, entry.sourceGUID)
    end

    if not ok or not spellData or not spellData.combatSpells then
        frame.spellContent:SetHeight(1)
        frame.spellNoData:Show()
        return
    end

    frame.spellNoData:Hide()

    local spells = spellData.combatSpells
    local topSpell = spells[1]

    for i = 1, #spells do
        local spell = spells[i]
        local row = self:GetSpellRow(i)

        if topSpell then
            row:SetMinMaxValues(0, topSpell.totalAmount)
        end
        row:SetValue(spell.totalAmount)

        -- Fall back to stored name/iconID for snapshot entries
        local spellInfo = spell.spellID and C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spell.spellID)
        local spellName = (spellInfo and spellInfo.name) or spell.name or ("Spell " .. (spell.spellID or "?"))
        local spellIcon = (spellInfo and spellInfo.iconID) or spell.iconID or 136243

        row.icon:SetTexture(spellIcon)
        row.rankText:SetText(i)
        row.nameText:SetText(spellName)
        row.amtText:SetFormattedText("%s", AbbreviateNumbers(spell.totalAmount, ABBREVIATE_OPTS_TOTAL))

        if isPerSecond then
            row.dpsText:SetFormattedText("%s", AbbreviateNumbers(spell.amountPerSecond, ABBREVIATE_OPTS_PS))
        else
            row.dpsText:SetText("")
        end

        local pctOk, pctVal = pcall(function()
            local total = spellData.totalAmount or 0
            if total > 0 then
                return string.format("%.1f%%", spell.totalAmount / total * 100)
            end
            return ""
        end)
        row.pctText:SetText(pctOk and pctVal or "")

        -- Class-tinted bar color
        local r, g, b = 0.4, 0.4, 0.5
        if entry.class and CLASS_COLORS[entry.class] then
            local cc = CLASS_COLORS[entry.class]
            r, g, b = cc.r * 0.7, cc.g * 0.7, cc.b * 0.7
        end
        row:SetStatusBarColor(r, g, b, 0.6)
        row.spellID = spell.spellID
        row:Show()
    end

    frame.spellContent:SetHeight(math.max(1, #spells) * 19)
end

-- Populate the target breakdown using EnemyDamageTaken sources
function MeterProto:PopulateTargets(entry)
    local frame = self.breakdownFrame

    -- Hide all existing target rows
    for _, row in pairs(frame.targetRows) do row:Hide() end

    if not entry then
        frame.targetContent:SetHeight(1)
        frame.targetNoData:Show()
        return
    end

    local bdSession = frame.bdSession or self.session
    local isSavedSeg = bdSession and bdSession:sub(1, 4) == "seg:"
    local isAPISession = bdSession and bdSession:sub(1, 4) == "sid:"

    local enemies
    if isSavedSeg then
        -- Use targets stored in the M+ snapshot
        local idx = tonumber(bdSession:sub(5))
        local seg = idx and DPSMeter.segments[idx]
        enemies = seg and seg.targets
    elseif isAPISession then
        local id = tonumber(bdSession:sub(5))
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromID,
            id, Enum.DamageMeterType.EnemyDamageTaken)
        if ok and session and session.combatSources and #session.combatSources > 0 then
            enemies = session.combatSources
        end
    else
        local sessionEnum = bdSession == "overall"
            and Enum.DamageMeterSessionType.Overall
            or Enum.DamageMeterSessionType.Current
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            sessionEnum, Enum.DamageMeterType.EnemyDamageTaken)
        if ok and session and session.combatSources and #session.combatSources > 0 then
            enemies = session.combatSources
        end
    end

    if not enemies or #enemies == 0 then
        frame.targetContent:SetHeight(1)
        frame.targetNoData:Show()
        return
    end

    frame.targetNoData:Hide()

    local topEnemy = enemies[1]

    for i = 1, #enemies do
        local enemy = enemies[i]
        local row = self:GetTargetRow(i)

        if topEnemy then
            row:SetMinMaxValues(0, topEnemy.totalAmount)
        end
        row:SetValue(enemy.totalAmount)

        -- Icon
        if enemy.specIconID then
            row.icon:SetTexture(enemy.specIconID)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        elseif enemy.classFilename and CLASS_ICON_TCOORDS[enemy.classFilename] then
            row.icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
            local coords = CLASS_ICON_TCOORDS[enemy.classFilename]
            row.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        else
            row.icon:SetTexture(136243)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end

        row.rankText:SetText(i)
        row.nameText:SetText(DisplayName(enemy.name))
        row.amtText:SetFormattedText("%s", AbbreviateNumbers(enemy.totalAmount, ABBREVIATE_OPTS_TOTAL))
        row.dpsText:SetText("")
        row.pctText:SetText("")

        row:SetStatusBarColor(0.5, 0.3, 0.3, 0.5)
        row.spellID = nil
        row:Show()
    end

    frame.targetContent:SetHeight(math.max(1, #enemies) * 19)
end

-- Get or create a segment row in the bottom-left
function MeterProto:GetSegmentRow(index)
    local frame = self.breakdownFrame
    if frame.segmentRows[index] then return frame.segmentRows[index] end
    local row = CreatePlayerRow(frame.segContent, index, 18)
    row.icon:SetSize(1, 1)
    row.icon:SetTexture(nil)
    frame.segmentRows[index] = row
    return row
end

-- Populate the segment selector in the bottom-left sidebar
function MeterProto:PopulateSegments()
    local frame = self.breakdownFrame

    -- Build session list: Current, Overall, API sessions (newest first), then M+ stored
    local sessions = {
        { key = "current",  label = "Current" },
        { key = "overall",  label = "Overall" },
    }
    local apiSessions = GetAvailableAPISessions()
    for i = #apiSessions, 1, -1 do
        local s = apiSessions[i]
        local dur = (s.durationSeconds and s.durationSeconds > 0)
            and (" (" .. FormatDuration(s.durationSeconds) .. ")") or ""
        table.insert(sessions, { key = "sid:" .. s.sessionID, label = (s.name or "Combat") .. dur })
    end
    if DPSMeter.segments then
        for i = #DPSMeter.segments, 1, -1 do
            local seg = DPSMeter.segments[i]
            local label = (seg.name or "Combat")
            if seg.duration and seg.duration > 0 then
                label = label .. " (" .. FormatDuration(seg.duration) .. ")"
            end
            table.insert(sessions, { key = "seg:" .. i, label = label })
        end
    end

    -- Hide all existing rows first
    for _, row in pairs(frame.segmentRows) do row:Hide() end

    local bdSession = frame.bdSession or self.session
    local ROW_H = 19
    for i, seg in ipairs(sessions) do
        local row = self:GetSegmentRow(i)
        local isSelected = (bdSession == seg.key)

        row.nameText:SetText(seg.label)
        if isSelected then
            row.bg:SetColorTexture(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3], 0.25)
            row.nameText:SetTextColor(DR_COLORS.accent[1], DR_COLORS.accent[2], DR_COLORS.accent[3])
        else
            row.bg:SetColorTexture(0.08, 0.08, 0.1, 0.6)
            row.nameText:SetTextColor(DR_COLORS.textDim[1], DR_COLORS.textDim[2], DR_COLORS.textDim[3])
        end

        row:SetScript("OnClick", function()
            frame.bdSession = seg.key
            self:LoadBreakdownEntries()
            self:PopulateSegments()
            -- Select first entry after session change
            local entries = frame.bdEntries or {}
            if entries[1] then
                self.breakdownSelectedGUID = entries[1].sourceGUID
                self:PopulateSidebar()
                self:PopulateSpells(entries[1])
                self:PopulateTargets(entries[1])
            else
                self:PopulateSidebar()
                self:PopulateSpells(nil)
                self:PopulateTargets(nil)
            end
        end)

        row:SetScript("OnEnter", function(r)
            if not isSelected then
                r.bg:SetColorTexture(0.15, 0.15, 0.2, 0.8)
            end
        end)
        row:SetScript("OnLeave", function(r)
            if not isSelected then
                r.bg:SetColorTexture(0.08, 0.08, 0.1, 0.6)
            end
        end)

        row:Show()
    end

    frame.segContent:SetHeight(math.max(1, #sessions) * ROW_H)
end

-- Main entry point: open breakdown for a clicked bar
function MeterProto:ShowBreakdown(entry)
    if not entry or not entry.sourceGUID then return end

    local frame = self:CreateBreakdownFrame()

    -- Center on screen on first show
    if not frame.hasBeenPositioned then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        frame.hasBeenPositioned = true
    end

    -- Initialize breakdown state from current meter state
    frame.bdMode = self.mode
    frame.bdSession = self.session

    -- Sync mode dropdown to current meter mode
    if frame.bdModeDrop then
        frame.bdModeDrop:SetSelectedValue(self.mode)
    end

    -- Load breakdown entries independently
    self:LoadBreakdownEntries()

    self.breakdownSelectedGUID = entry.sourceGUID
    self:LayoutBreakdownSections()
    self:PopulateSidebar()
    self:PopulateSegments()
    self:PopulateSpells(entry)
    self:PopulateTargets(entry)
    frame:Show()
end

-- ============================================================================
-- Report current meter to chat
-- ============================================================================

function MeterProto:ReportToChat()
    self:ReportToChannel(nil)
end

function MeterProto:ReportToChannel(channelOverride)
    if UnitAffectingCombat("player") then
        print("|cff00ccff[DPSReport]|r Cannot report while in combat.")
        return
    end
    local topCount = settings and settings.defaultTopCount or 10
    local channel, target
    if channelOverride then
        channel = channelOverride
        target = nil
    else
        local chanOverride = settings and settings.defaultChannel ~= "auto" and settings.defaultChannel or nil
        channel, target = GetChatChannel(chanOverride, nil)
    end

    local lines, err
    if self.session and self.session:sub(1, 4) == "seg:" then
        -- M+ stored segment
        local idx = tonumber(self.session:sub(5))
        lines, err = BuildSegmentReport(self.mode, idx, topCount)
    elseif self.session and self.session:sub(1, 4) == "sid:" then
        -- API expired session: report from live data
        local id = tonumber(self.session:sub(5))
        local meterType = METER_MODE_MAP[self.mode] or Enum.DamageMeterType.Dps
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromID, id, meterType)
        if ok and session and session.combatSources and #session.combatSources > 0 then
            local s = FindAPISession(id)
            local sessionName = s and s.name or "Combat"
            local duration = s and s.durationSeconds or 0
            local isPerSecond = (self.mode == "dps" or self.mode == "hps")
            local label = TYPE_LABELS[meterType] or self.mode:upper()
            local headerExtra = sessionName .. (duration > 0 and (" " .. FormatDuration(duration)) or "")
            lines = {}
            if settings and settings.showTotalInHeader ~= false then
                table.insert(lines, string.format("--- %s Report (%s) - Total: %s ---",
                    label, headerExtra, FormatNumber(LaunderNumber(session.totalAmount))))
            else
                table.insert(lines, string.format("--- %s Report (%s) ---", label, headerExtra))
            end
            local count = math.min(topCount, #session.combatSources)
            for i = 1, count do
                local src = session.combatSources[i]
                local value = isPerSecond
                    and FormatNumber(LaunderNumber(src.amountPerSecond))
                    or  FormatNumber(LaunderNumber(src.totalAmount))
                local total = LaunderNumber(session.totalAmount)
                local pct = ""
                if settings and settings.showPercentages ~= false and total > 0 then
                    pct = string.format(", %.1f%%", LaunderNumber(src.totalAmount) / total * 100)
                end
                local marker = (settings and settings.showSelfMarker ~= false) and src.isLocalPlayer and " (*)" or ""
                local plainName = ResolveSourcePlainName(src)
                table.insert(lines, string.format("%d. %s%s - %s (%s%s)",
                    i, DisplayName(plainName or SafeStr(src.name)), marker,
                    value, FormatNumber(LaunderNumber(src.totalAmount)), pct))
            end
        else
            err = "No data for this session."
        end
    else
        local meterType = METER_MODE_MAP[self.mode] or Enum.DamageMeterType.Dps
        local sessionType = self.session == "overall" and Enum.DamageMeterSessionType.Overall or Enum.DamageMeterSessionType.Current
        lines, err = BuildReport(meterType, sessionType, topCount)
    end

    if err then
        print("|cff00ccff[DPSReport]|r " .. err)
    elseif lines then
        SendLines(lines, channel, target)
    end
end

-- ============================================================================
-- Position Save/Load
-- ============================================================================

function MeterProto:SavePosition()
    if not self.frame or not DPSReportDB then return end
    DPSMeter:SaveAllMeters()
end

function MeterProto:LoadPosition()
    if not self.frame or not DPSReportDB or not charKey then return end
    local charData = DPSReportDB.charData and DPSReportDB.charData[charKey]
    if not charData or not charData.meters then return end
    -- Find saved entry by id (array may not be sequential after removals)
    local saved
    for _, entry in ipairs(charData.meters) do
        if entry.id == self.id then saved = entry; break end
    end
    if not saved or not saved.pos then return end
    local pos = saved.pos
    -- Guard: only apply absolute SetPoint if pos has a point field.
    -- Snapped frames only save width/height (no point), so this prevents
    -- them being incorrectly anchored to UIParent even if snapTo was lost.
    if pos.point then
        self.frame:ClearAllPoints()
        self.frame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    end
    if pos.width then
        self.frame:SetWidth(pos.width)
        if self.barContainer then
            self.barContainer:SetWidth(pos.width - 2)
        end
    end
    if pos.height then
        self.frame:SetHeight(pos.height)
    end
end

-- ============================================================================
-- Save/Load All Meters
-- ============================================================================

function DPSMeter:SaveAllMeters()
    if not DPSReportDB or not charKey then return end
    -- Never persist before the saved meters have been read back in: the list is
    -- empty until then, and writing it destroys the saved layout. See the note
    -- on DPSMeter.metersLoaded.
    if not self.metersLoaded then return end
    if not DPSReportDB.charData then DPSReportDB.charData = {} end
    local saved = {}
    for _, meter in ipairs(self.meters) do
        local entry = {
            id      = meter.id,
            mode    = meter.mode,
            session = meter.session,
            snapTo  = (meter.snapTo and next(meter.snapTo)) and CopyTable(meter.snapTo) or nil,
        }
        -- Persist the last resolved display entries so names survive a reload.
        -- Numbers are laundered to plain values so they are safe to store.
        if meter.entries and #meter.entries > 0 then
            local savedEntries = {}
            for _, e in ipairs(meter.entries) do
                -- LoadFromAPI stores the raw API name when GUID resolution
                -- fails, so in combat e.name can be a secret value. Numbers go
                -- through LaunderNumber, but the name never did -- and a
                -- PLAYER_LOGOUT mid-fight (any /reload in combat) writes it
                -- straight into SavedVariables. Persist only plain names; a
                -- dropped cosmetic name is repopulated by the next LoadFromAPI.
                local plain = e.name
                if plain ~= nil and issecretvalue(plain) then plain = nil end
                if plain ~= nil then
                    table.insert(savedEntries, {
                        name            = plain,
                        plainName       = (e.plainName ~= nil
                            and not issecretvalue(e.plainName)) and e.plainName or nil,
                        class           = (e.class ~= nil
                            and not issecretvalue(e.class)) and e.class or nil,
                        displayValue    = LaunderNumber(e.displayValue),
                        totalAmount     = LaunderNumber(e.totalAmount),
                        amountPerSecond = LaunderNumber(e.amountPerSecond),
                        isPlayer        = e.isPlayer,
                        specIconID      = (e.specIconID ~= nil
                            and not issecretvalue(e.specIconID)) and e.specIconID or nil,
                    })
                end
            end
            if #savedEntries > 0 then
                entry.entries = savedEntries
            end
        end
        if meter.frame then
            -- Only save absolute position for free (non-snapped) frames.
            -- Snapped frames are re-anchored by RestoreAnchors() on load;
            -- saving their parent-relative GetPoint() coordinates would mislead LoadPosition.
            local isSnapped = meter.snapTo and meter.snapTo._parent
            if not isSnapped then
                local point, _, relativePoint, xOfs, yOfs = meter.frame:GetPoint()
                entry.pos = {
                    point = point,
                    relativePoint = relativePoint,
                    x = xOfs,
                    y = yOfs,
                    width  = meter.frame:GetWidth(),
                    height = meter.frame:GetHeight(),
                }
            else
                -- Save size only so the frame dimensions are preserved
                entry.pos = {
                    width  = meter.frame:GetWidth(),
                    height = meter.frame:GetHeight(),
                }
            end
        end
        table.insert(saved, entry)
    end
    -- Preserve existing per-character fields (e.g. activeProfile) when saving
    if not DPSReportDB.charData[charKey] then DPSReportDB.charData[charKey] = {} end
    local cd = DPSReportDB.charData[charKey]
    cd.meters = saved
    cd.segments = self.segments
end

function DPSMeter:LoadAllMeters()
    -- Set before anything else: the migrations at the end of this function, and
    -- the LoadFromAPI calls below, both save, and they must be allowed through.
    self.metersLoaded = true
    local charData = DPSReportDB and DPSReportDB.charData and DPSReportDB.charData[charKey]
    -- Restore M+ stored segments
    if charData and charData.segments then
        self.segments = charData.segments
    end
    local saved = charData and charData.meters
    if saved and #saved > 0 then
        for _, cfg in ipairs(saved) do
            local meter = self:NewMeter(cfg)
            meter.snapTo = cfg.snapTo and CopyTable(cfg.snapTo) or {}  -- restore before LoadPosition is called
            meter:CreateMeterFrame()
            meter:LoadPosition()
            -- Restore persisted entries so names are correct before caches are warm.
            -- LoadFromAPI will overwrite these once combat starts and caches are populated.
            if cfg.entries and #cfg.entries > 0 then
                meter.entries = cfg.entries
                meter:RefreshDisplay()
            else
                meter:LoadFromAPI()
                meter:RefreshDisplay()
            end
        end
        -- Re-apply snap anchors now that all meter frames exist
        MeterSnapSystem.RestoreAnchors()
    else
        -- First run: create default primary meter
        local meter = self:NewMeter({ id = 1, mode = "dps", session = "current" })
        meter:CreateMeterFrame()
        meter:LoadFromAPI()
        meter:RefreshDisplay()
    end
    -- Migrate legacy single meterPosition if present
    if DPSReportDB and DPSReportDB.meterPosition then
        local primary = self.meters[1]
        if primary and primary.frame then
            local pos = DPSReportDB.meterPosition
            primary.frame:ClearAllPoints()
            primary.frame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
            if pos.width then primary.frame:SetWidth(pos.width) end
            if pos.height then primary.frame:SetHeight(pos.height) end
        end
        DPSReportDB.meterPosition = nil
        self:SaveAllMeters()
    end
    -- Migrate legacy global meters/segments to per-character
    if DPSReportDB and charKey and DPSReportDB.meters and not DPSReportDB.charData then
        DPSReportDB.charData = {}
        DPSReportDB.charData[charKey] = {
            meters = DPSReportDB.meters,
            segments = DPSReportDB.segments or {},
        }
        DPSReportDB.meters = nil
        DPSReportDB.segments = nil
    end
end

-- ============================================================================
-- Toggle Meter
-- ============================================================================

-- Toggle function (toggles primary meter)
function DPSReport_ToggleMeter()
    local primary = DPSMeter.meters[1]
    if not primary then
        primary = DPSMeter:NewMeter({ id = 1, mode = "dps", session = "current" })
        primary:CreateMeterFrame()
        primary:LoadFromAPI()
        primary:RefreshDisplay()
        return
    end
    if not primary.frame then
        primary:CreateMeterFrame()
    end
    if primary.frame:IsShown() then
        primary.frame:Hide()
        if settings then settings.meterShown = false end
        print("|cff00ccff[DPSReport]|r Meter hidden.")
    else
        primary.frame:Show()
        if settings then settings.meterShown = true end
        print("|cff00ccff[DPSReport]|r Meter shown.")
    end
end

-- DPSReport_Threat.lua -- the threat meter (2026-10-22).
--
-- MEASURED FIRST (/dpsprobe, 2026-10-21): every UnitDetailedThreatSituation
-- return, for players AND pets, came back plain in open-world combat, a
-- dungeon boss (Encounter restriction) and a Mythic+ key (ChallengeMode). So
-- the rows are ranked in Lua. Raids were not measured; if a value ever comes
-- back secret, the bars still draw it (StatusBar:SetValue and SetFormattedText
-- take secrets) and the rows simply stay in group order instead of ranked.
--
-- Pets are their own entries on a mob's threat list (separate from the owner),
-- so each is a row of its own, named "Owner's pet".
--
-- Opened from the T on a meter's title bar or /dpsthreat. Right-click the
-- title: target or focus, hide out of combat, lock. State in DPSReportDB.threat.

local _, ns = ...
local C = ns.colors

local MAX_ROWS = 10
local ROW_H = 18
local UPDATE_INTERVAL = 0.3

local function IsSecret(v)
    if issecretvalue and issecretvalue(v) then return true end
    if issecrettable and issecrettable(v) then return true end
    return false
end

local function Plain(v)
    if IsSecret(v) then return nil end
    return v
end

local function DB()
    if type(DPSReportDB) ~= "table" then return {} end
    DPSReportDB.threat = DPSReportDB.threat or {}
    local db = DPSReportDB.threat
    if db.hideOOC == nil then db.hideOOC = true end
    return db
end

local function Rgb(t) return t[1], t[2], t[3] end

-----------------------------------------------------------------------
-- Reading threat
-----------------------------------------------------------------------

-- Every group member and pet, as {unit, owner (pets), isPet}.
local function Units()
    local list = {}
    local function Add(unit, owner)
        if UnitExists(unit) then list[#list + 1] = { unit = unit, owner = owner, isPet = owner ~= nil } end
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            Add("raid" .. i)
            Add("raidpet" .. i, "raid" .. i)
        end
    else
        Add("player")
        Add("pet", "player")
        for i = 1, GetNumSubgroupMembers() do
            Add("party" .. i)
            Add("partypet" .. i, "party" .. i)
        end
    end
    return list
end

local function MobUnit()
    return DB().unit == "focus" and "focus" or "target"
end

-- Rows on the mob's threat list, ranked when the values are readable.
local function Read(mob)
    local rows, ranked = {}, true
    for _, u in ipairs(Units()) do
        local ok, tanking, status, scaled = pcall(UnitDetailedThreatSituation, u.unit, mob)
        if ok and (IsSecret(scaled) or scaled ~= nil) then
            local row = { unit = u.unit, owner = u.owner, isPet = u.isPet, tanking = tanking,
                          status = status, percent = scaled, order = #rows + 1,
                          -- Plain copies to sort on; secret ones leave them nil.
                          sortTank = Plain(tanking) == true, sortPercent = Plain(scaled) }
            if IsSecret(tanking) or IsSecret(scaled) then ranked = false end
            rows[#rows + 1] = row
        end
    end
    if ranked then
        table.sort(rows, function(a, b)
            if a.sortTank ~= b.sortTank then return a.sortTank end
            local ap, bp = a.sortPercent or -1, b.sortPercent or -1
            if ap ~= bp then return ap > bp end
            return a.order < b.order
        end)
    end
    return rows, ranked
end

-----------------------------------------------------------------------
-- Window
-----------------------------------------------------------------------

local win, title, rowsHost, emptyText
local bars = {}
local elapsedSince = 0

local function ClassColor(unit)
    local ok, _, class = pcall(UnitClass, unit)
    class = ok and Plain(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 0.6, 0.6, 0.6
end

local function NewRow(i)
    local bar = CreateFrame("StatusBar", nil, rowsHost)
    bar:SetHeight(ROW_H - 2)
    bar:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    bar:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_H)
    bar:SetStatusBarTexture("Interface\\BUTTONS\\WHITE8X8")
    bar:SetMinMaxValues(0, 100)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.35)
    bar.name = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.name:SetPoint("LEFT", 4, 0)
    bar.name:SetPoint("RIGHT", -52, 0)
    bar.name:SetJustifyH("LEFT")
    bar.name:SetWordWrap(false)
    bar.value = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.value:SetPoint("RIGHT", -4, 0)
    -- A border that lights up on the unit holding aggro.
    bar.edge = bar:CreateTexture(nil, "OVERLAY")
    bar.edge:SetPoint("TOPLEFT", -1, 1)
    bar.edge:SetPoint("BOTTOMLEFT", -1, -1)
    bar.edge:SetWidth(3)
    bar.edge:SetColorTexture(1, 0.25, 0.2, 1)
    return bar
end

-- Placing: just switched on out of combat with "hide out of combat" set, the
-- window stays up (with a placeholder) until combat starts or it is moved,
-- so it can be put where it belongs. Otherwise it would vanish at once.
local placing = false

local function Visible()
    local db = DB()
    if not db.shown then return false end
    if db.hideOOC and not InCombatLockdown() and not placing then return false end
    return true
end

local function Refresh()
    if not win then return end
    if not Visible() then
        win:Hide()
        return
    end
    win:Show()
    if placing then
        if InCombatLockdown() then
            placing = false
        else
            title:SetText("Threat (shown in combat)")
            emptyText:SetText("Drag me into place. Right-click the title for options.")
            emptyText:Show()
            for _, b in ipairs(bars) do b:Hide() end
            return
        end
    end

    local mob = MobUnit()
    if not (UnitExists(mob) and UnitCanAttack("player", mob)) then
        title:SetText("Threat")
        emptyText:SetText(mob == "focus" and "Focus an enemy to see threat." or "Target an enemy to see threat.")
        emptyText:Show()
        for _, b in ipairs(bars) do b:Hide() end
        return
    end
    title:SetFormattedText("Threat: %s", UnitName(mob))

    local rows, ranked = Read(mob)
    emptyText:SetShown(#rows == 0)
    emptyText:SetText("Nobody is on its threat list yet.")
    local maxRows = math.min(MAX_ROWS, math.max(1, math.floor((rowsHost:GetHeight() + 2) / ROW_H)))

    for i = 1, math.max(#bars, maxRows) do
        local row, bar = rows[i], bars[i]
        if row and i <= maxRows then
            bar = bar or NewRow(i)
            bars[i] = bar
            local r, g, b = ClassColor(row.owner or row.unit)
            if row.isPet then r, g, b = r * 0.65, g * 0.65, b * 0.65 end
            -- Your own row warns: orange when close to pulling, red with aggro.
            local status = Plain(row.status)
            local me = row.unit == "player"
            if not me and not row.isPet and IsInRaid() then
                -- UnitIsUnit can be secret (rated PvP maps), so guarded.
                local ok, same = pcall(UnitIsUnit, row.unit, "player")
                me = ok and Plain(same) == true
            end
            if me then
                if status == 3 then r, g, b = 1, 0.2, 0.15 elseif status == 2 then r, g, b = 1, 0.55, 0.1 end
            end
            bar:SetStatusBarColor(r, g, b, 0.85)
            bar:SetValue(row.percent)
            if row.isPet then
                bar.name:SetFormattedText("%s's pet", UnitName(row.owner))
            else
                bar.name:SetText(UnitName(row.unit))
            end
            bar.value:SetFormattedText("%.0f%%", row.percent)
            bar.edge:SetShown(Plain(row.tanking) == true)
            bar:Show()
        elseif bar then
            bar:Hide()
        end
    end
    if not ranked then emptyText:SetText("") end
end

local function SavePlace()
    local db = DB()
    local point, _, rel, x, y = win:GetPoint(1)
    db.point, db.rel, db.x, db.y = point, rel, x, y
    db.w, db.h = win:GetWidth(), win:GetHeight()
end

local function OpenMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    local db = DB()
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Threat meter")
        root:CreateRadio("Threat on my target", function() return db.unit ~= "focus" end,
            function() db.unit = "target" Refresh() end)
        root:CreateRadio("Threat on my focus", function() return db.unit == "focus" end,
            function() db.unit = "focus" Refresh() end)
        root:CreateCheckbox("Hide out of combat", function() return db.hideOOC end,
            function() db.hideOOC = not db.hideOOC Refresh() end)
        root:CreateCheckbox("Lock position", function() return db.locked end,
            function() db.locked = not db.locked end)
        root:CreateButton("Close", function() DPSReport_ToggleThreat() end)
    end)
end

local function Build()
    if win then return end
    local db = DB()
    win = CreateFrame("Frame", "DPSReportThreatFrame", UIParent, "BackdropTemplate")
    win:SetSize(db.w or 220, db.h or 150)
    if db.point then
        win:SetPoint(db.point, UIParent, db.rel or db.point, db.x or 0, db.y or 0)
    else
        win:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    end
    win:SetFrameStrata("MEDIUM")
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:SetResizable(true)
    if win.SetResizeBounds then win:SetResizeBounds(150, 60, 600, 600) end
    ns.ApplyBackdrop(win)

    local bar = CreateFrame("Frame", nil, win, "BackdropTemplate")
    bar:SetHeight(18)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
    bar:SetBackdropColor(C.titleBar[1], C.titleBar[2], C.titleBar[3], C.titleBar[4] or 1)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() if not DB().locked then win:StartMoving() end end)
    bar:SetScript("OnDragStop", function()
        win:StopMovingOrSizing()
        SavePlace()
        placing = false
        Refresh()
    end)
    bar:SetScript("OnMouseUp", function(self, button) if button == "RightButton" then OpenMenu(self) end end)

    title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("LEFT", 6, 0)
    title:SetPoint("RIGHT", -18, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetTextColor(Rgb(C.accent))

    local close = CreateFrame("Button", nil, bar)
    close:SetSize(16, 16)
    close:SetPoint("RIGHT", -2, 0)
    local x = close:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    x:SetPoint("CENTER")
    x:SetText("X")
    x:SetTextColor(Rgb(C.textDim))
    close:SetScript("OnClick", function() DPSReport_ToggleThreat() end)

    rowsHost = CreateFrame("Frame", nil, win)
    rowsHost:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 3, -3)
    rowsHost:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -3, 3)
    rowsHost:SetScript("OnSizeChanged", Refresh)

    emptyText = rowsHost:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyText:SetPoint("TOPLEFT", 2, -4)
    emptyText:SetPoint("RIGHT", -2, 0)
    emptyText:SetJustifyH("LEFT")

    local grip = CreateFrame("Button", nil, win)
    grip:SetSize(12, 12)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel(rowsHost:GetFrameLevel() + 5)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetScript("OnMouseDown", function() if not DB().locked then win:StartSizing("BOTTOMRIGHT") end end)
    grip:SetScript("OnMouseUp", function() win:StopMovingOrSizing() SavePlace() Refresh() end)

    -- Threat moves continuously; events alone miss most of it.
    win:SetScript("OnUpdate", function(_, elapsed)
        elapsedSince = elapsedSince + elapsed
        if elapsedSince < UPDATE_INTERVAL then return end
        elapsedSince = 0
        Refresh()
    end)
    win:Hide()
end

-- The window itself only updates while shown, so combat start/end and
-- target changes have to bring it back.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("PLAYER_FOCUS_CHANGED")
ev:SetScript("OnEvent", function()
    if not DB().shown then return end
    Build()
    Refresh()
end)

function DPSReport_ToggleThreat()
    local db = DB()
    db.shown = not db.shown
    Build()
    placing = db.shown and db.hideOOC and not InCombatLockdown()
    if placing then
        print("|cff00ccff[DPSReport]|r Threat meter on -- it appears in combat. Drag it into place now; "
            .. "right-click its title for options.")
    end
    Refresh()
end

SLASH_DPSREPORTTHREAT1 = "/dpsthreat"
SlashCmdList.DPSREPORTTHREAT = DPSReport_ToggleThreat

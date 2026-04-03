-------------------------------------------------------------------------------
-- EbonholdEchoBuddy  v3.0
--
-- Three features:
--
--   1. BUILD ADVISOR  (/eb)
--      Browse the full echo database filtered by class + role.
--
--   2. AUTO-SELECT
--      Hooks PerkUI.Show so echoes are automatically picked.
--
--   3. AI LEARNING ENGINE
--      Observes every echo comparison and every run outcome, building a
--      per-role performance model that improves with each pick made.
--
--      Algorithm:
--        • ELO comparative learning — whenever echoes are offered together,
--          the chosen echo "beats" the unchosen ones. ELO ratings update
--          per match-up (K=32 → K=16 after 10 games, like chess).
--        • Run EMA — on player death, every echo in that run's build gets its
--          run-level-average updated: avg = 0.7*old + 0.3*new_level.
--        • UCB1 exploration bonus — echoes rarely seen get a small score
--          boost so the model doesn't permanently ignore uncommon picks.
--        • Confidence blending — combined score starts at 100% static
--          quality/family scoring and smoothly shifts toward AI scores as
--          data accumulates (full confidence at 30 comparisons).
--
-- Slash commands: /eb  /echobuild  /ebauto  /ebstats  /ebreset
-------------------------------------------------------------------------------

local ADDON = "EbonholdEchoBuddy"

-------------------------------------------------------------------------------
-- 1. CONSTANTS
-------------------------------------------------------------------------------

local DB_DEFAULTS = {
    autoSelect   = false,
    selectedRole = "Melee DPS",
    selectDelay  = 0.6,
    useAIScores  = true,    -- blend AI scores into advisor + auto-select
}

local CLASS_MASK = {
    WARRIOR=1, PALADIN=2, HUNTER=4, ROGUE=8, PRIEST=16,
    DEATHKNIGHT=32, SHAMAN=64, MAGE=128, WARLOCK=256, DRUID=1024,
}
local CLASS_DISPLAY  = {"Warrior","Paladin","Hunter","Rogue","Priest","Death Knight","Shaman","Mage","Warlock","Druid"}
local CLASS_INTERNAL = {"WARRIOR","PALADIN","HUNTER","ROGUE","PRIEST","DEATHKNIGHT","SHAMAN","MAGE","WARLOCK","DRUID"}
local ROLES          = {"Tank","Healer","Melee DPS","Ranged DPS","Caster DPS"}

-------------------------------------------------------------------------------
-- 2. STATIC SCORING WEIGHTS
-------------------------------------------------------------------------------

local QUALITY_BASE = {[0]=10,[1]=20,[2]=30,[3]=40,[4]=50}

local ROLE_CONFIG = {
    ["Tank"]      = {primaryFamilies={"Tank"},        secondaryFamilies={"Survivability"}, primaryBonus=40, secondaryBonus=20},
    ["Healer"]    = {primaryFamilies={"Healer"},       secondaryFamilies={"Survivability"}, primaryBonus=40, secondaryBonus=15},
    ["Melee DPS"] = {primaryFamilies={"Melee DPS"},    secondaryFamilies={"Survivability"}, primaryBonus=40, secondaryBonus=5},
    ["Ranged DPS"]= {primaryFamilies={"Ranged DPS"},   secondaryFamilies={"Survivability"}, primaryBonus=40, secondaryBonus=5},
    ["Caster DPS"]= {primaryFamilies={"Caster DPS"},   secondaryFamilies={"Survivability"}, primaryBonus=40, secondaryBonus=5},
}

local QUALITY_COLOR = {
    [0]={1,1,1}, [1]={0.12,1,0.12}, [2]={0,0.44,1}, [3]={0.78,0.40,1}, [4]={1,0.50,0},
}
local QUALITY_NAME = {[0]="Common",[1]="Uncommon",[2]="Rare",[3]="Epic",[4]="Legendary"}

local CLASS_COLOR = {
    WARRIOR={0.78,0.61,0.43}, PALADIN={0.96,0.55,0.73}, HUNTER={0.67,0.83,0.45},
    ROGUE={1,0.96,0.41},      PRIEST={1,1,1},            DEATHKNIGHT={0.77,0.12,0.23},
    SHAMAN={0,0.44,0.87},     MAGE={0.41,0.80,0.94},     WARLOCK={0.58,0.51,0.79},
    DRUID={1,0.49,0.04},
}

-- Confidence dot colours (matches thresholds below)
local CONF_COLORS = {
    {0.4,0.4,0.4},  -- 0: no data
    {1,0.85,0},     -- 1: learning
    {1,0.55,0},     -- 2: building
    {0.1,0.9,0.1},  -- 3: confident
}

-------------------------------------------------------------------------------
-- 3. SAVED-VARIABLE HELPERS
-------------------------------------------------------------------------------

local function GetDB()
    EchoBuddyDB = EchoBuddyDB or {}
    for k,v in pairs(DB_DEFAULTS) do
        if EchoBuddyDB[k] == nil then EchoBuddyDB[k] = v end
    end
    return EchoBuddyDB
end
local function SaveRole(r)    GetDB().selectedRole = r end
local function SaveAuto(v)    GetDB().autoSelect   = v end

-------------------------------------------------------------------------------
-- 4. LEARNING ENGINE
-------------------------------------------------------------------------------
-- Data layout (per role, per spellId):
--   elo          number  1200      ELO rating
--   comparisons  number  0         total times offered alongside another echo
--   wins         number  0         times chosen
--   losses       number  0         times not chosen when another was
--   runCount     number  0         runs tracked that included this echo
--   runLevelAvg  number  0         exponential moving average of level reached
--   lastSeen     number  0         GetTime() when last offered
-------------------------------------------------------------------------------

local ELO_START  = 1200
local ELO_K_NEW  = 32    -- K-factor first 10 comparisons
local ELO_K_EST  = 16    -- K-factor thereafter
local RUN_ALPHA  = 0.30  -- EMA weight for new run data
local CONF_FULL  = 30    -- comparisons needed for full AI confidence
local UCB_C      = 8     -- exploration coefficient

local function GetLearnDB()
    EchoBuddyLearnDB = EchoBuddyLearnDB or {}
    return EchoBuddyLearnDB
end

local function GetLearnData(role, spellId)
    local ldb = GetLearnDB()
    ldb[role] = ldb[role] or {}
    local d = ldb[role][spellId]
    if not d then
        d = {elo=ELO_START, comparisons=0, wins=0, losses=0,
             runCount=0, runLevelAvg=0, lastSeen=0}
        ldb[role][spellId] = d
    end
    return d
end

-- ELO update: winnerSpellId beat every id in loserIds table
local function RecordComparison(winnerId, loserIds, role)
    if not winnerId or not loserIds or #loserIds == 0 then return end
    local winner = GetLearnData(role, winnerId)
    local K_w    = (winner.comparisons < 10) and ELO_K_NEW or ELO_K_EST
    local totalDelta = 0

    for _, lid in ipairs(loserIds) do
        local loser = GetLearnData(role, lid)
        local K_l   = (loser.comparisons < 10) and ELO_K_NEW or ELO_K_EST
        -- Expected probability winner beats loser
        local expected = 1 / (1 + 10^((loser.elo - winner.elo) / 400))
        totalDelta       = totalDelta + K_w * (1 - expected)
        loser.elo        = loser.elo + K_l * (0 - (1 - expected))
        loser.losses     = loser.losses  + 1
        loser.comparisons= loser.comparisons + 1
    end

    -- Average the winner delta across all opponents (prevents inflation with 3-way)
    winner.elo        = winner.elo + totalDelta / math.max(1, #loserIds)
    winner.wins       = winner.wins + 1
    winner.comparisons= winner.comparisons + 1
end

-- EMA update: echo appeared in a run that ended at `levelReached`
local function RecordRunOutcome(echoSpellIds, levelReached, role)
    if not echoSpellIds or #echoSpellIds == 0 then return end
    local lvl = math.max(1, math.min(80, levelReached or 1))
    for _, sid in ipairs(echoSpellIds) do
        local d = GetLearnData(role, sid)
        if d.runCount == 0 then
            d.runLevelAvg = lvl
        else
            d.runLevelAvg = (1 - RUN_ALPHA) * d.runLevelAvg + RUN_ALPHA * lvl
        end
        d.runCount = d.runCount + 1
    end
end

-- Pure static score from quality + role family matching (no AI)
local band = bit and bit.band or function(a, b)
    local r,bv = 0,1
    while a>0 and b>0 do
        if a%2==1 and b%2==1 then r=r+bv end
        a=math.floor(a/2); b=math.floor(b/2); bv=bv*2
    end
    return r
end

local function StaticScore(spellId, quality, config)
    local score = QUALITY_BASE[quality] or 10
    local db    = ProjectEbonhold and ProjectEbonhold.PerkDatabase
    local fams  = (db and db[spellId] and db[spellId].families) or {}
    for _, fam in ipairs(fams) do
        for _, pf in ipairs(config.primaryFamilies) do
            if fam == pf then score = score + config.primaryBonus; break end
        end
        for _, sf in ipairs(config.secondaryFamilies) do
            if fam == sf then score = score + config.secondaryBonus; break end
        end
    end
    return score, fams
end

-- Total comparisons across all roles (for UCB1 denominator)
local function TotalComparisons()
    local n = 0
    local ldb = GetLearnDB()
    for _, roleData in pairs(ldb) do
        for _, d in pairs(roleData) do
            n = n + (d.comparisons or 0)
        end
    end
    return math.max(1, n)
end

-- Confidence level index for display (0–3)
local function ConfidenceLevel(comparisons)
    if comparisons < 3  then return 0 end
    if comparisons < 10 then return 1 end
    if comparisons < 30 then return 2 end
    return 3
end

-- Final blended score (static + AI adjustments).
-- Returns: finalScore, staticBase, eloAdj, runAdj, confidence (0-1), confLevel (0-3)
local function BlendedScore(spellId, quality, config, role)
    local base, _   = StaticScore(spellId, quality, config)
    local d         = GetLearnData(role, spellId)
    local comps     = d.comparisons or 0
    local confidence= math.min(1.0, comps / CONF_FULL)
    local confLevel = ConfidenceLevel(comps)

    if confidence < 0.05 or not GetDB().useAIScores then
        return base, base, 0, 0, confidence, confLevel
    end

    -- ELO adjustment: ±25 pts (ELO 800 = -25, 1200 = 0, 1600 = +25)
    local eloAdj = math.max(-25, math.min(25, (d.elo - ELO_START) / 400 * 25))

    -- Run adjustment: ±15 pts centred around level 40 (mid-run)
    local runAdj = 0
    if (d.runCount or 0) > 0 then
        runAdj = math.max(-15, math.min(15, (d.runLevelAvg / 80 - 0.5) * 30))
    end

    -- UCB1 exploration bonus: small boost for rarely-seen echoes
    local ucbBonus = UCB_C * math.sqrt(math.log(TotalComparisons()) / math.max(1, comps))
    ucbBonus = math.min(ucbBonus, 10) -- cap at 10 pts

    local aiBonus = (eloAdj + runAdj) * confidence + ucbBonus * (1 - confidence)
    return base + aiBonus, base, eloAdj, runAdj, confidence, confLevel
end

-- Stats summary for a given role
local function LearnStats(role)
    local ldb = GetLearnDB()
    local rd  = ldb[role] or {}
    local totalComps, totalRuns, tracked = 0, 0, 0
    for _, d in pairs(rd) do
        totalComps = totalComps + (d.comparisons or 0)
        totalRuns  = totalRuns  + (d.runCount    or 0)
        tracked    = tracked + 1
    end
    return totalComps, totalRuns, tracked
end

-- Reset learning data for a role (or all roles)
local function ResetLearnData(role)
    if role then
        EchoBuddyLearnDB = EchoBuddyLearnDB or {}
        EchoBuddyLearnDB[role] = {}
    else
        EchoBuddyLearnDB = {}
    end
end

-------------------------------------------------------------------------------
-- 5. RUN TRACKING STATE
-------------------------------------------------------------------------------
-- These are populated by the hooks and consumed by the learning engine.

local currentOfferedChoices = nil   -- table of {spellId, quality} for current offer
local currentRunEchoes      = {}    -- spellIds picked so far this run
local lastTrackedLevel      = 0     -- to detect new-run resets

-------------------------------------------------------------------------------
-- 6. AUTO-SELECT ENGINE
-------------------------------------------------------------------------------

local function After(sec, fn)
    local t = 0
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function(self, dt)
        t = t + dt
        if t >= sec then self:SetScript("OnUpdate",nil); self:Hide(); fn() end
    end)
    f:Show()
end

-- Toast notification
local toastFrame
local function ShowToast(name, score, line2)
    if not toastFrame then
        toastFrame = CreateFrame("Frame","EBBToastFrame",UIParent)
        toastFrame:SetSize(360,56)
        toastFrame:SetPoint("TOP",UIParent,"TOP",0,-175)
        toastFrame:SetFrameStrata("DIALOG")
        toastFrame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true,tileSize=32,edgeSize=22,
            insets={left=7,right=8,top=7,bottom=7}})
        toastFrame:SetBackdropColor(0.04,0.04,0.12,0.96)
        local t1=toastFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        t1:SetPoint("TOP",toastFrame,"TOP",0,-11); t1:SetTextColor(0.5,0.5,0.5)
        t1:SetText("Echo Buddy — Auto Selected"); toastFrame._t1=t1
        local t2=toastFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
        t2:SetPoint("CENTER",toastFrame,"CENTER",0,-3); toastFrame._t2=t2
        local t3=toastFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        t3:SetPoint("BOTTOM",toastFrame,"BOTTOM",0,9); toastFrame._t3=t3
    end
    toastFrame._t2:SetText("|cff00CCFF"..name.."|r")
    toastFrame._t3:SetText(line2 or "")
    toastFrame:SetAlpha(1); toastFrame:Show()
    local e=0
    toastFrame:SetScript("OnUpdate",function(self,dt)
        e=e+dt
        if e>3.0 then
            local a=1-((e-3.0)/0.7)
            if a<=0 then self:SetAlpha(0);self:Hide();self:SetScript("OnUpdate",nil)
            else self:SetAlpha(a) end
        end
    end)
end

local function DoAutoSelect(choices)
    local db     = GetDB()
    local role   = db.selectedRole or "Melee DPS"
    local config = ROLE_CONFIG[role]
    if not config then return end

    local best = {spellId=nil, score=-math.huge, name="", quality=0}

    for _, choice in ipairs(choices) do
        local perkDB = ProjectEbonhold and ProjectEbonhold.PerkDatabase
        local quality = choice.quality or (perkDB and perkDB[choice.spellId] and perkDB[choice.spellId].quality) or 0
        local score   = (BlendedScore(choice.spellId, quality, config, role))
        if score > best.score then
            best.spellId = choice.spellId
            best.score   = score
            best.name    = GetSpellInfo(choice.spellId) or ("Echo #"..choice.spellId)
            best.quality = quality
        end
    end

    if not best.spellId then return end

    local comps   = GetLearnData(role, best.spellId).comparisons or 0
    local confPct = math.floor(math.min(100, comps / CONF_FULL * 100))
    local srcTag  = confPct >= 10 and ("AI " .. confPct .. "% conf") or "Static"
    local line2   = "Score: " .. math.floor(best.score) .. "  ·  " .. role .. "  ·  " .. srcTag

    After(db.selectDelay or 0.6, function()
        local svc = ProjectEbonhold.PerkService
        if svc and svc.SelectPerk then
            svc.SelectPerk(best.spellId)
            ShowToast(best.name, best.score, line2)
        end
    end)
end

-------------------------------------------------------------------------------
-- 7. HOOK INSTALLATION
-------------------------------------------------------------------------------

local function InstallHook()
    -- ── 7a. PerkUI.Show hook ───────────────────────────────────────────────
    if not (ProjectEbonhold and ProjectEbonhold.PerkUI and ProjectEbonhold.PerkUI.Show) then
        print("|cffFF4444[Echo Buddy]|r PerkUI.Show not found — auto-select disabled.")
        return
    end

    local origShow = ProjectEbonhold.PerkUI.Show
    ProjectEbonhold.PerkUI.Show = function(choices)
        origShow(choices)
        -- Store what was offered so SelectPerk hook can identify losers
        if choices and #choices > 0 then
            currentOfferedChoices = choices
        end
        if GetDB().autoSelect and choices and #choices > 0 then
            DoAutoSelect(choices)
        end
    end

    -- ── 7b. PerkService.SelectPerk hook ────────────────────────────────────
    -- Captures both manual and auto-select picks to feed the learning engine.
    if not (ProjectEbonhold.PerkService and ProjectEbonhold.PerkService.SelectPerk) then return end

    local origSelect = ProjectEbonhold.PerkService.SelectPerk
    ProjectEbonhold.PerkService.SelectPerk = function(spellId)
        local result = origSelect(spellId)   -- always call original first

        -- Record learning data whenever a pick happens, regardless of return value
        -- (origSelect is a void function; gating on result would silently drop all data)
        if currentOfferedChoices then
            local role   = GetDB().selectedRole or "Melee DPS"
            local losers = {}
            for _, c in ipairs(currentOfferedChoices) do
                if c.spellId ~= spellId then
                    table.insert(losers, c.spellId)
                end
            end
            -- Record ELO comparison (core learning signal)
            if #losers > 0 then
                RecordComparison(spellId, losers, role)
            end
            -- Track echo in current run for run-outcome learning
            table.insert(currentRunEchoes, spellId)
            -- Mark this echo as recently seen
            GetLearnData(role, spellId).lastSeen = GetTime()
            currentOfferedChoices = nil
        end

        return result
    end
end

-------------------------------------------------------------------------------
-- 8. DEATH / RUN-END EVENT
-------------------------------------------------------------------------------

local runEventFrame = CreateFrame("Frame")
runEventFrame:RegisterEvent("PLAYER_DEAD")
runEventFrame:RegisterEvent("PLAYER_LEVEL_UP")
runEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

runEventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_DEAD" then
        -- Record run outcome for every echo picked this run
        local level = UnitLevel and UnitLevel("player") or 1
        local role  = GetDB().selectedRole or "Melee DPS"
        if #currentRunEchoes > 0 then
            RecordRunOutcome(currentRunEchoes, level, role)
        end
        currentRunEchoes = {}
        lastTrackedLevel = 0

    elseif event == "PLAYER_LEVEL_UP" then
        local newLevel = tonumber(arg1) or (UnitLevel and UnitLevel("player")) or 1
        -- Detect a run restart (level jumped down → we missed a death, reset)
        if newLevel <= 2 and lastTrackedLevel > 5 then
            currentRunEchoes = {}
        end
        lastTrackedLevel = newLevel

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- If we log in at level 1, treat as new run
        local lvl = UnitLevel and UnitLevel("player") or 1
        if lvl <= 1 then currentRunEchoes = {} end
        lastTrackedLevel = lvl
    end
end)

-------------------------------------------------------------------------------
-- 9. DATABASE SCORING (static + AI blend, used by Advisor)
-------------------------------------------------------------------------------

local function ScoreFullDatabase(classMask, role)
    local db = ProjectEbonhold and ProjectEbonhold.PerkDatabase
    if not db then return nil,"ProjectEbonhold.PerkDatabase not available." end
    local config = ROLE_CONFIG[role]
    if not config then return nil,"Unknown role: "..tostring(role) end

    -- Collect eligible perks
    local eligible = {}
    for spellId, perk in pairs(db) do
        if band(perk.classMask, classMask) ~= 0 then
            table.insert(eligible, {spellId=spellId, perk=perk})
        end
    end

    -- Dedup by groupId (keep highest quality per group)
    local bestByGroup, ungrouped = {}, {}
    for _, e in ipairs(eligible) do
        local gid = e.perk.groupId
        if gid and gid > 0 then
            if not bestByGroup[gid] or e.perk.quality > bestByGroup[gid].perk.quality then
                bestByGroup[gid] = e
            end
        else table.insert(ungrouped, e) end
    end
    local pool = {}
    for _, e in pairs(bestByGroup) do table.insert(pool, e) end
    for _, e in ipairs(ungrouped)   do table.insert(pool, e) end

    -- Score each perk with blended AI+static
    local scored = {}
    for _, e in ipairs(pool) do
        local final, base, eloAdj, runAdj, conf, confLevel =
            BlendedScore(e.spellId, e.perk.quality, config, role)
        table.insert(scored, {
            spellId  = e.spellId,
            perk     = e.perk,
            score    = final,
            base     = base,
            eloAdj   = eloAdj,
            runAdj   = runAdj,
            conf     = conf,
            confLevel= confLevel,
        })
    end

    table.sort(scored, function(a, b)
        if a.score ~= b.score       then return a.score > b.score end
        if a.perk.quality ~= b.perk.quality then return a.perk.quality > b.perk.quality end
        return (GetSpellInfo(a.spellId) or "") < (GetSpellInfo(b.spellId) or "")
    end)
    return scored, nil
end

-------------------------------------------------------------------------------
-- 10. GUI
-------------------------------------------------------------------------------

local mainFrame      = nil
local resultRows     = {}
local scrollChild    = nil
local infoText       = nil
local aiStatsText    = nil
local autoCheckbox   = nil

local selectedClassIdx = 1
local selectedRoleIdx  = 1

local MAX_RESULTS = 50
local ROW_H       = 30

-- Confidence dot texture helper (coloured ● drawn into a row)
local CONF_CHAR = "|cff%02x%02x%02x●|r"
local function ConfDot(level)
    local c = CONF_COLORS[level+1] or CONF_COLORS[1]
    return CONF_CHAR:format(c[1]*255, c[2]*255, c[3]*255)
end

local function GetOrCreateRow(index)
    if resultRows[index] then return resultRows[index] end
    local row = CreateFrame("Frame", nil, scrollChild)
    row:SetSize(580, ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); row._bg = bg

    local rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rank:SetSize(26, ROW_H); rank:SetPoint("LEFT", row, "LEFT", 4, 0)
    rank:SetJustifyH("RIGHT"); row._rank = rank

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22); icon:SetPoint("LEFT", row, "LEFT", 33, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92); row._icon = icon

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetSize(210, ROW_H); nameText:SetPoint("LEFT", row, "LEFT", 59, 0)
    nameText:SetJustifyH("LEFT"); row._name = nameText

    local qualText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    qualText:SetSize(75, ROW_H); qualText:SetPoint("LEFT", row, "LEFT", 275, 0)
    qualText:SetJustifyH("LEFT"); row._qual = qualText

    local famText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    famText:SetSize(160, ROW_H); famText:SetPoint("LEFT", row, "LEFT", 355, 0)
    famText:SetJustifyH("LEFT"); famText:SetTextColor(0.60, 0.55, 0.75); row._fam = famText

    local dotText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dotText:SetSize(14, ROW_H); dotText:SetPoint("LEFT", row, "LEFT", 520, 0); row._dot = dotText

    local scoreText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scoreText:SetSize(40, ROW_H); scoreText:SetPoint("LEFT", row, "LEFT", 535, 0)
    scoreText:SetJustifyH("RIGHT"); row._score = scoreText

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        self._bg:SetTexture(0.18, 0.12, 0.36, 0.65)
        if self._spellId then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("spell:" .. self._spellId)
            GameTooltip:AddLine(" ")
            local conf  = self._conf or 0
            local pct   = math.floor(conf * 100)
            local baseS = self._base or self._scoreVal or 0
            local eloA  = self._eloAdj or 0
            local runA  = self._runAdj or 0
            GameTooltip:AddLine(string.format(
                "|cffFFD700Score: %d|r  (Base %d  ELO%+.0f  Run%+.0f  Conf %d%%)",
                math.floor(self._scoreVal or 0), math.floor(baseS), eloA, runA, pct))
            local d = self._role and GetLearnData(self._role, self._spellId)
            if d then
                GameTooltip:AddLine(string.format(
                    "|cff888888Picks: %d W / %d L  ·  Runs: %d  ·  Avg lvl: %.0f|r",
                    d.wins or 0, d.losses or 0, d.runCount or 0, d.runLevelAvg or 0))
                GameTooltip:AddLine(string.format("|cff888888ELO: %.0f|r", d.elo or ELO_START))
            end
            if self._families and #self._families > 0 then
                GameTooltip:AddLine("|cff888888" .. table.concat(self._families, "  •  ") .. "|r")
            end
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        if self._isEven then
            self._bg:SetTexture(0.06, 0.04, 0.18, 0.45)
        else
            self._bg:SetTexture(0, 0, 0, 0)
        end
        GameTooltip:Hide()
    end)

    resultRows[index] = row
    return row
end

local function DisplayResults(results, className, role)
    local shown=math.min(#results,MAX_RESULTS)
    for i=shown+1,#resultRows do resultRows[i]:Hide() end

    for i=1,shown do
        local e       =results[i]
        local perk    =e.perk
        local quality =perk.quality
        local families=(perk.families or {})
        local sn,_,si =GetSpellInfo(e.spellId)
        sn=sn or perk.comment or ("Echo #"..e.spellId)
        si=si or "Interface\\Icons\\inv_misc_questionmark"
        local qc      =QUALITY_COLOR[quality] or QUALITY_COLOR[0]
        local isEven  =(i%2==0)

        local row=GetOrCreateRow(i)
        row:SetPoint("TOPLEFT",scrollChild,"TOPLEFT",0,-(i-1)*ROW_H)
        row._spellId =e.spellId
        row._quality =quality
        row._scoreVal=e.score
        row._base    =e.base
        row._eloAdj  =e.eloAdj
        row._runAdj  =e.runAdj
        row._conf    =e.conf
        row._families=families
        row._isEven  =isEven
        row._role    =role

        if isEven then row._bg:SetTexture(0.06, 0.04, 0.18, 0.45)
        else           row._bg:SetTexture(0, 0, 0, 0) end

        row._rank:SetText("|cff555577#" .. i .. "|r")
        row._icon:SetTexture(si)
        row._name:SetTextColor(qc[1], qc[2], qc[3]); row._name:SetText(sn)
        row._qual:SetTextColor(qc[1], qc[2], qc[3]); row._qual:SetText(QUALITY_NAME[quality] or "?")
        row._fam:SetText(table.concat(families, " • "))
        row._dot:SetText(ConfDot(e.confLevel or 0))
        local ratio = math.min(1, e.score / 80)
        row._score:SetTextColor(1 - ratio * 0.5, 0.7 + ratio * 0.3, 0)
        row._score:SetText(math.floor(e.score))
        row:SetSize(580, ROW_H); row:Show()
    end

    scrollChild:SetHeight(math.max(1,shown*ROW_H))

    -- Info bar
    if infoText then
        local ci=CLASS_INTERNAL[selectedClassIdx]
        local cc=CLASS_COLOR[ci] or {1,1,1}
        infoText:SetText(string.format(
            "Showing |cffFFD700%d|r echoes  ·  |cff%02x%02x%02x%s|r  |cff888888›|r  |cff00CCFF%s|r",
            shown,cc[1]*255,cc[2]*255,cc[3]*255,className,role))
    end
    -- AI stats bar
    if aiStatsText then
        local tc,tr,te=LearnStats(role)
        aiStatsText:SetText(string.format(
            "|cff888888🧠 AI: %d comparisons · %d runs · %d echoes tracked  (role: %s)|r",
            tc,tr,te,role))
    end
end

local function RunRecommendation()
    local classKey =CLASS_INTERNAL[selectedClassIdx]
    local className=CLASS_DISPLAY[selectedClassIdx]
    local role     =ROLES[selectedRoleIdx]
    local mask     =CLASS_MASK[classKey] or 0
    local results,err=ScoreFullDatabase(mask,role)
    if not results then
        if infoText then infoText:SetText("|cffFF4444"..(err or "Error").."|r") end
        return
    end
    DisplayResults(results,className,role)
end

-- Dropdown helpers
local function InitClassDD(frame)
    UIDropDownMenu_SetWidth(frame,148)
    UIDropDownMenu_SetText(frame,CLASS_DISPLAY[selectedClassIdx])
    UIDropDownMenu_Initialize(frame,function()
        for i,label in ipairs(CLASS_DISPLAY) do
            local info=UIDropDownMenu_CreateInfo()
            info.text=label; info.value=i
            info.func=function()
                selectedClassIdx=i
                UIDropDownMenu_SetText(frame,label)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
end

local function OnRoleChanged(label)
    SaveRole(label)
    -- Sync all role dropdowns and refresh AI stats bar
    for _, ddname in ipairs({"EBBAutoRoleDD","EBBAdvRoleDD"}) do
        local dd=_G[ddname]
        if dd then UIDropDownMenu_SetText(dd,label) end
    end
    if aiStatsText then
        local tc,tr,te=LearnStats(label)
        aiStatsText:SetText(string.format(
            "|cff888888🧠 AI: %d comparisons · %d runs · %d echoes tracked  (role: %s)|r",
            tc,tr,te,label))
    end
end

local function MakeRoleDD(frameName, parent, pointArgs)
    local dd=CreateFrame("Frame",frameName,parent,"UIDropDownMenuTemplate")
    dd:SetPoint(unpack(pointArgs))
    UIDropDownMenu_SetWidth(dd,118)
    UIDropDownMenu_SetText(dd,ROLES[selectedRoleIdx])
    UIDropDownMenu_Initialize(dd,function()
        for i,label in ipairs(ROLES) do
            local info=UIDropDownMenu_CreateInfo()
            info.text=label; info.value=i
            info.func=function()
                selectedRoleIdx=i
                OnRoleChanged(label)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    return dd
end

-- ── Confirmation popup (used for Reset AI) ───────────────────────────────────
local function ShowConfirm(msg, onYes)
    StaticPopupDialogs["EBB_CONFIRM"] = {
        text         = msg,
        button1      = "Yes",
        button2      = "No",
        OnAccept     = onYes,
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("EBB_CONFIRM")
end

-- ── Build the main frame ──────────────────────────────────────────────────────
local function BuildMainFrame()
    local W, H = 660, 620

    mainFrame = CreateFrame("Frame", "EbonholdEchoBuddyFrame", UIParent)
    mainFrame:SetSize(W, H)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop",  mainFrame.StopMovingOrSizing)
    mainFrame:SetFrameStrata("HIGH")

    -- Dark stone base with purple-tinted border
    mainFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = {left=11, right=12, top=12, bottom=11},
    })
    mainFrame:SetBackdropColor(0.03, 0.02, 0.12, 0.98)
    mainFrame:SetBackdropBorderColor(0.40, 0.25, 0.70, 1.0)

    ---------------------------------------------------------------------------
    -- VISUAL LAYERS
    ---------------------------------------------------------------------------

    -- Deep purple header gradient band
    local hdrBand = mainFrame:CreateTexture(nil, "BORDER")
    hdrBand:SetTexture("Interface\\Buttons\\WHITE8X8")
    hdrBand:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  12, -12)
    hdrBand:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -12, -12)
    hdrBand:SetHeight(54)
    hdrBand:SetGradientAlpha("VERTICAL", 0.14, 0.08, 0.36, 0.95, 0.03, 0.02, 0.12, 0)

    -- Thin gold rule beneath the header band
    local hdrLine = mainFrame:CreateTexture(nil, "ARTWORK")
    hdrLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    hdrLine:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  15, -64)
    hdrLine:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -15, -64)
    hdrLine:SetHeight(1)
    hdrLine:SetVertexColor(0.88, 0.72, 0.18, 1.0)

    -- Soft golden glow bleeding downward from the rule
    local hdrGlow = mainFrame:CreateTexture(nil, "ARTWORK")
    hdrGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    hdrGlow:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  15, -65)
    hdrGlow:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -15, -65)
    hdrGlow:SetHeight(8)
    hdrGlow:SetGradientAlpha("VERTICAL", 0.88, 0.72, 0.18, 0.22, 0.88, 0.72, 0.18, 0)
    hdrGlow:SetBlendMode("ADD")

    -- Gold L-corner accents (top-left and top-right)
    local function Corner(point, ox, oy, w, h)
        local t = mainFrame:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        t:SetPoint(point, mainFrame, point, ox, oy)
        t:SetSize(w, h)
        t:SetVertexColor(0.90, 0.75, 0.20, 0.90)
    end
    Corner("TOPLEFT",  15, -14, 30, 2);  Corner("TOPLEFT",  15, -14, 2, 24)
    Corner("TOPRIGHT", -45, -14, 30, 2); Corner("TOPRIGHT", -17, -14, 2, 24)

    -- Bottom fade to ground the frame visually
    local botFade = mainFrame:CreateTexture(nil, "BORDER")
    botFade:SetTexture("Interface\\Buttons\\WHITE8X8")
    botFade:SetPoint("BOTTOMLEFT",  mainFrame, "BOTTOMLEFT",  12, 12)
    botFade:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -12, 12)
    botFade:SetHeight(30)
    botFade:SetGradientAlpha("VERTICAL", 0.03, 0.02, 0.10, 0, 0.03, 0.02, 0.10, 0.60)

    ---------------------------------------------------------------------------
    -- TITLE
    ---------------------------------------------------------------------------

    local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", mainFrame, "TOP", 0, -22)
    title:SetText("|cffFFD700Echo Buddy|r  |cff554477v3|r")

    local sub = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -3)
    sub:SetTextColor(0.55, 0.45, 0.78)
    sub:SetText("Build Advisor  ·  Auto-Select  ·  AI Learning")

    local closeBtn = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() mainFrame:Hide() end)

    ---------------------------------------------------------------------------
    -- HELPERS: GOLD DIVIDER + SECTION PANEL
    ---------------------------------------------------------------------------

    local function GoldDivider(yOff)
        -- Upward glow
        local glowA = mainFrame:CreateTexture(nil, "ARTWORK")
        glowA:SetTexture("Interface\\Buttons\\WHITE8X8")
        glowA:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  15, yOff + 5)
        glowA:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -15, yOff + 5)
        glowA:SetHeight(5)
        glowA:SetGradientAlpha("VERTICAL", 0.88, 0.72, 0.18, 0, 0.88, 0.72, 0.18, 0.20)
        glowA:SetBlendMode("ADD")
        -- Sharp line
        local line = mainFrame:CreateTexture(nil, "ARTWORK")
        line:SetTexture("Interface\\Buttons\\WHITE8X8")
        line:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  15, yOff)
        line:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -15, yOff)
        line:SetHeight(1)
        line:SetVertexColor(0.88, 0.72, 0.18, 0.85)
        -- Downward glow
        local glowB = mainFrame:CreateTexture(nil, "ARTWORK")
        glowB:SetTexture("Interface\\Buttons\\WHITE8X8")
        glowB:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  15, yOff - 1)
        glowB:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -15, yOff - 1)
        glowB:SetHeight(6)
        glowB:SetGradientAlpha("VERTICAL", 0.88, 0.72, 0.18, 0.20, 0.88, 0.72, 0.18, 0)
        glowB:SetBlendMode("ADD")
    end

    local function SectionPanel(yTop, panelH)
        local p = CreateFrame("Frame", nil, mainFrame)
        p:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  14, yTop)
        p:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -14, yTop)
        p:SetHeight(panelH)
        p:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = {left=3, right=3, top=3, bottom=3},
        })
        p:SetBackdropColor(0.07, 0.04, 0.20, 0.50)
        p:SetBackdropBorderColor(0.38, 0.26, 0.62, 0.45)
        return p
    end

    GoldDivider(-66)

    ---------------------------------------------------------------------------
    -- AUTO-SELECT PANEL  (y -70 … -122)
    ---------------------------------------------------------------------------
    SectionPanel(-70, 56)

    local asLbl = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    asLbl:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 24, -82)
    asLbl:SetText("|cffBB88FFAuto-Select|r")

    local cb = CreateFrame("CheckButton", "EBBAutoCheck", mainFrame, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 132, -78)
    cb:SetSize(26, 26)
    _G["EBBAutoCheckText"]:SetText("|cffDDDDDDEnable|r")
    cb:SetChecked(GetDB().autoSelect)
    autoCheckbox = cb

    local aiCB = CreateFrame("CheckButton", "EBBAICheck", mainFrame, "UICheckButtonTemplate")
    aiCB:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 248, -78)
    aiCB:SetSize(26, 26)
    _G["EBBAICheckText"]:SetText("|cffDDDDDDUse AI|r")
    aiCB:SetChecked(GetDB().useAIScores)
    aiCB:SetScript("OnClick", function(self)
        GetDB().useAIScores = self:GetChecked() and true or false
    end)
    aiCB:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Blend learned AI scores with static\nquality/family scoring.\nDisable to use only static weights.", nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    aiCB:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Role selector — anchored at x=488 so rightmost edge ≈631 < 646 (W-14)
    local autoRoleLbl = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoRoleLbl:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 468, -84)
    autoRoleLbl:SetTextColor(0.65, 0.50, 0.90)
    autoRoleLbl:SetText("Role:")
    MakeRoleDD("EBBAutoRoleDD", mainFrame, {"TOPLEFT", mainFrame, "TOPLEFT", 488, -72})

    -- Status line
    local statusText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 24, -108)
    statusText:SetTextColor(0.50, 0.42, 0.65)

    local function RefreshStatus()
        local db = GetDB()
        if db.autoSelect then
            statusText:SetText("|cff44FF44● Active|r — auto-picking best echo for |cff00CCFF" .. (db.selectedRole or "?") .. "|r")
        else
            statusText:SetText("|cffFF6666● Inactive|r — enable above to auto-pick echoes.")
        end
    end

    cb:SetScript("OnClick", function(self)
        local en = self:GetChecked() and true or false
        SaveAuto(en); RefreshStatus()
        if en then
            print("|cffFFD700[Echo Buddy]|r Auto-select |cff00FF00ON|r · |cff00CCFF" .. (GetDB().selectedRole or "?") .. "|r")
        else
            print("|cffFFD700[Echo Buddy]|r Auto-select |cffFF4444OFF|r")
        end
    end)

    GoldDivider(-122)

    ---------------------------------------------------------------------------
    -- BUILD ADVISOR PANEL  (y -126 … -212)
    ---------------------------------------------------------------------------
    SectionPanel(-126, 88)

    local advLbl = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    advLbl:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 24, -137)
    advLbl:SetText("|cffBB88FFBuild Advisor|r")

    -- Class dropdown
    local classLbl = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    classLbl:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 26, -160)
    classLbl:SetTextColor(0.65, 0.50, 0.88)
    classLbl:SetText("Class:")
    local classDD = CreateFrame("Frame", "EBBClassDropdown", mainFrame, "UIDropDownMenuTemplate")
    classDD:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 56, -148)

    -- Role dropdown (advisor)
    local advRoleLbl = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    advRoleLbl:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 272, -160)
    advRoleLbl:SetTextColor(0.65, 0.50, 0.88)
    advRoleLbl:SetText("Role:")
    MakeRoleDD("EBBAdvRoleDD", mainFrame, {"TOPLEFT", mainFrame, "TOPLEFT", 300, -148})

    -- Use My Character button
    local selfBtn = CreateFrame("Button", nil, mainFrame, "GameMenuButtonTemplate")
    selfBtn:SetSize(140, 24)
    selfBtn:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 466, -154)
    selfBtn:SetText("Use My Character")
    selfBtn:SetScript("OnClick", function()
        local _, pc = UnitClass("player")
        if pc then
            for i, c in ipairs(CLASS_INTERNAL) do
                if c == pc then
                    selectedClassIdx = i
                    UIDropDownMenu_SetText(classDD, CLASS_DISPLAY[i])
                    break
                end
            end
        end
    end)

    -- Recommend button
    local recBtn = CreateFrame("Button", nil, mainFrame, "GameMenuButtonTemplate")
    recBtn:SetSize(172, 28)
    recBtn:SetPoint("TOP", mainFrame, "TOP", -50, -190)
    recBtn:SetText("▶  Recommend Echoes")
    recBtn:SetScript("OnClick", RunRecommendation)

    -- Reset AI Data button
    local resetBtn = CreateFrame("Button", nil, mainFrame, "GameMenuButtonTemplate")
    resetBtn:SetSize(120, 24)
    resetBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -20, -191)
    resetBtn:SetText("Reset AI Data")
    resetBtn:SetScript("OnClick", function()
        local role = ROLES[selectedRoleIdx]
        ShowConfirm(
            "Reset all AI learning data for |cff00CCFF" .. role .. "|r?\nThis cannot be undone.",
            function()
                ResetLearnData(role)
                print("|cffFFD700[Echo Buddy]|r AI data reset for " .. role)
                RunRecommendation()
            end
        )
    end)
    resetBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Wipe learned ELO and run data\nfor the currently selected role.", nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    GoldDivider(-220)

    ---------------------------------------------------------------------------
    -- COLUMN HEADERS
    ---------------------------------------------------------------------------
    local function Hdr(text, x)
        local h = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", x, -230)
        h:SetText("|cffAA8833" .. text .. "|r")
    end
    Hdr("#",          20)
    Hdr("Echo Name",  64)
    Hdr("Quality",   279)
    Hdr("Families",  359)
    Hdr("AI",        522)
    Hdr("Score",     538)

    -- Thin rule under headers
    local rule = mainFrame:CreateTexture(nil, "ARTWORK")
    rule:SetTexture("Interface\\Buttons\\WHITE8X8")
    rule:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  16, -244)
    rule:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -34, -244)
    rule:SetHeight(1)
    rule:SetVertexColor(0.35, 0.22, 0.55, 0.70)

    -- AI stats bar (bottom)
    aiStatsText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    aiStatsText:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 20, 28)
    aiStatsText:SetText("|cff665599AI: no data yet — play runs to build the model.|r")

    -- Info bar
    infoText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    infoText:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 20, 14)
    infoText:SetText("|cff665599Choose a class and role, then click Recommend.|r")

    -- Scroll frame
    local sf = CreateFrame("ScrollFrame", "EBBScrollFrame", mainFrame, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",  16, -247)
    sf:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -34, 42)
    scrollChild = CreateFrame("Frame", "EBBScrollChild", sf)
    scrollChild:SetSize(580, 1)
    sf:SetScrollChild(scrollChild)

    -- Wire class dropdown
    InitClassDD(classDD)

    -- Auto-detect player class
    local _, pc = UnitClass("player")
    if pc then
        for i, c in ipairs(CLASS_INTERNAL) do
            if c == pc then
                selectedClassIdx = i
                UIDropDownMenu_SetText(classDD, CLASS_DISPLAY[i])
                break
            end
        end
    end

    RefreshStatus()
    mainFrame:Show()
end

local function OpenAddon()
    if not mainFrame then
        BuildMainFrame()
    else
        if mainFrame:IsShown() then mainFrame:Hide() else mainFrame:Show() end
    end
end

-------------------------------------------------------------------------------
-- 11. SLASH COMMANDS
-------------------------------------------------------------------------------

SLASH_ECHOBUILD1="/echobuild"; SLASH_ECHOBUILD2="/eb"
SlashCmdList["ECHOBUILD"]=function(msg)
    local cmd=(msg or ""):lower():match("^%s*(%S*)")
    if cmd=="help" then
        print("|cffFFD700Echo Buddy commands:|r")
        print("  |cff00CCFF/eb|r               Open / close the window")
        print("  |cff00CCFF/ebauto|r            Toggle auto-select on/off")
        print("  |cff00CCFF/ebstats|r           Print AI learning stats to chat")
        print("  |cff00CCFF/ebreset [role]|r    Wipe AI data for a role (or all)")
    else OpenAddon() end
end

SLASH_EBAUTO1="/ebauto"
SlashCmdList["EBAUTO"]=function()
    local db=GetDB(); local v=not db.autoSelect; SaveAuto(v)
    if autoCheckbox then autoCheckbox:SetChecked(v) end
    if v then print("|cffFFD700[Echo Buddy]|r Auto-select |cff00FF00ON|r · |cff00CCFF"..(db.selectedRole or "?").."|r")
    else      print("|cffFFD700[Echo Buddy]|r Auto-select |cffFF4444OFF|r") end
end

SLASH_EBSTATS1="/ebstats"
SlashCmdList["EBSTATS"]=function()
    print("|cffFFD700[Echo Buddy] AI Learning Stats:|r")
    for _,role in ipairs(ROLES) do
        local tc,tr,te=LearnStats(role)
        if tc>0 or tr>0 then
            print(string.format("  |cff00CCFF%-12s|r  %d comparisons · %d runs · %d echoes",
                role, tc, tr, te))
        end
    end
end

SLASH_EBRESET1="/ebreset"
SlashCmdList["EBRESET"]=function(msg)
    local role=(msg or ""):match("^%s*(.-)%s*$")
    if role=="" then
        ShowConfirm("Reset ALL AI learning data for every role?\nThis cannot be undone.",
            function()
                ResetLearnData(nil)
                print("|cffFFD700[Echo Buddy]|r All AI data wiped.")
            end)
    else
        -- Try to match partial role name
        local matched=nil
        for _,r in ipairs(ROLES) do
            if r:lower():find(role:lower(),1,true) then matched=r; break end
        end
        if matched then
            ResetLearnData(matched)
            print("|cffFFD700[Echo Buddy]|r AI data wiped for "..matched)
        else
            print("|cffFF4444[Echo Buddy]|r Unknown role: '"..role.."'  Valid: "..table.concat(ROLES,", "))
        end
    end
end

-------------------------------------------------------------------------------
-- 12. INITIALISATION
-------------------------------------------------------------------------------

local initFrame=CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("ADDON_LOADED")

initFrame:SetScript("OnEvent",function(self,event,arg1)
    if event=="ADDON_LOADED" and arg1==ADDON then
        GetDB()
        local savedRole=EchoBuddyDB.selectedRole
        if savedRole then
            for i,r in ipairs(ROLES) do
                if r==savedRole then selectedRoleIdx=i; break end
            end
        end

    elseif event=="PLAYER_LOGIN" then
        local _,pc=UnitClass("player")
        if pc then
            for i,c in ipairs(CLASS_INTERNAL) do
                if c==pc then selectedClassIdx=i; break end
            end
        end

        InstallHook()

        print("|cffFFD700[Echo Buddy]|r Ready — |cff00CCFF/eb|r to open · |cff00CCFF/ebauto|r to toggle · |cff00CCFF/ebstats|r for AI data")
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

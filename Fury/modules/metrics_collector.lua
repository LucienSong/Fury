local _, ns = ...

local CollectorModule = {
    name = "MetricsCollector",
}

local BATTLE_STANCE_ID = 2457
local OVERPOWER_TRIGGER_TOKENS = {
    BLOODTHIRST = true,
    WHIRLWIND = true,
    EXECUTE = true,
    OVERPOWER = true,
    SUNDER_ARMOR = true,
    HEROIC_STRIKE = true,
    CLEAVE = true,
    HAMSTRING = true,
    REVENGE = true,
    SHIELD_SLAM = true,
    MOCKING_BLOW = true,
}

local function IsBattleStanceActive()
    local forms = GetNumShapeshiftForms and (GetNumShapeshiftForms() or 0) or 0
    local activeForm = GetShapeshiftForm and (GetShapeshiftForm() or 0) or 0
    if activeForm and activeForm > 0 and activeForm <= forms then
        local _, _, active, _, spellId = GetShapeshiftFormInfo(activeForm)
        if active and spellId == BATTLE_STANCE_ID then
            return true
        end
    end
    for i = 1, forms do
        local _, _, active, _, spellId = GetShapeshiftFormInfo(i)
        if active and spellId == BATTLE_STANCE_ID then
            return true
        end
    end
    return false
end

local function EnsureFightStarted()
    local metrics = ns.metrics
    if not metrics then
        return nil
    end
    local fight = metrics.GetActiveFight()
    if fight then
        return fight
    end
    if UnitAffectingCombat("player") then
        return metrics.StartFight(UnitGUID("target"))
    end
    return nil
end

local function IsOverpowerTriggerSpell(spellId, spellName)
    local decision = ns.decision
    if not decision then
        return false
    end
    local token = decision.GetTokenForSpellId and spellId and decision.GetTokenForSpellId(spellId) or nil
    if (not token) and decision.GetTokenForSpellName and spellName then
        token = decision.GetTokenForSpellName(spellName)
    end
    return token and OVERPOWER_TRIGGER_TOKENS[token] or false
end

local function HandleCombatLog()
    local metrics = ns.metrics
    if not metrics then
        return
    end

    local data = { CombatLogGetCurrentEventInfo() }
    local subEvent = data[2]
    -- B7 fix: guard against nil/empty fields from non-standard combat log events.
    if not subEvent then
        return
    end
    local sourceGUID = data[4]
    local destGUID = data[8]
    local spellId = data[12]
    local spellName = data[13]
    local playerGUID = UnitGUID("player")
    if not playerGUID then
        return
    end
    local playerInvolved = sourceGUID == playerGUID or destGUID == playerGUID

    if not playerInvolved and sourceGUID ~= playerGUID then
        return
    end

    local fight = EnsureFightStarted()
    if not fight then
        return
    end

    if subEvent == "SWING_DAMAGE" and sourceGUID == playerGUID then
        local amount = data[12]
        local critical = data[18]
        local glancing = data[19]
        local isOffHand = data[21]
        metrics.RecordSwingDamage(amount, critical, glancing, isOffHand)
        metrics.MarkHostile(destGUID, GetTime())
        return
    end

    if subEvent == "SWING_MISSED" and sourceGUID == playerGUID then
        local missType = data[12]
        local isOffHand = data[16]
        metrics.RecordSwingMiss(missType, isOffHand, GetTime())
        if missType == "DODGE" and destGUID and IsBattleStanceActive() then
            metrics.RecordTargetDodged(destGUID, GetTime())
        end
        metrics.MarkHostile(destGUID, GetTime())
        return
    end

    if subEvent == "SPELL_DAMAGE" and sourceGUID == playerGUID then
        local amount = data[15]
        local critical = data[21]
        metrics.RecordSpellDamage(spellName, spellId, amount, critical)
        metrics.MarkHostile(destGUID, GetTime())
        return
    end

    if subEvent == "SPELL_MISSED" and sourceGUID == playerGUID then
        local missType = data[15]
        metrics.RecordSpellMiss(missType)
        if missType == "DODGE" and destGUID and IsBattleStanceActive() and IsOverpowerTriggerSpell(spellId, spellName) then
            metrics.RecordTargetDodged(destGUID, GetTime())
        end
        metrics.MarkHostile(destGUID, GetTime())
        return
    end

    if subEvent == "UNIT_DIED" or subEvent == "UNIT_DESTROYED" or subEvent == "PARTY_KILL" then
        metrics.UnmarkHostile(destGUID)
        return
    end

    if subEvent == "SPELL_CAST_SUCCESS" and sourceGUID == playerGUID then
        metrics.RecordCast(spellName, spellId, GetTime())
        return
    end

    if (subEvent == "SPELL_AURA_APPLIED" or subEvent == "SPELL_AURA_REFRESH" or subEvent == "SPELL_AURA_REMOVED") and destGUID == playerGUID then
        metrics.RecordAuraEvent(spellName, spellId, subEvent, GetTime())
    end
end

function CollectorModule:Init()
    local frame = CreateFrame("Frame")
    self.frame = frame

    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    frame:RegisterEvent("UNIT_POWER_UPDATE")
    frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

    frame:SetScript("OnEvent", function(_, event, arg1, arg2)
        local metrics = ns.metrics
        if not metrics then
            return
        end

        if event == "PLAYER_REGEN_DISABLED" then
            metrics.StartFight(UnitGUID("target"))
            metrics.UpdateRage(UnitPower("player", 1) or 0, GetTime())
            metrics.NotifyChanged()
            return
        end

        if event == "PLAYER_REGEN_ENABLED" then
            metrics.EndFight()
            return
        end

        if event == "PLAYER_TARGET_CHANGED" then
            local fight = metrics.GetActiveFight()
            if fight and not fight.targetGuidMain then
                fight.targetGuidMain = UnitGUID("target")
            end
            return
        end

        if event == "UNIT_POWER_UPDATE" then
            local unit = arg1
            local powerType = arg2
            if unit == "player" and (powerType == "RAGE" or powerType == "Rage") then
                if EnsureFightStarted() then
                    metrics.UpdateRage(UnitPower("player", 1) or 0, GetTime())
                end
            end
            return
        end

        if event == "COMBAT_LOG_EVENT_UNFILTERED" then
            HandleCombatLog()
            return
        end
    end)

    frame:SetScript("OnUpdate", function(_, elapsed)
        self._tick = (self._tick or 0) + elapsed
        -- P2 fix: use longer tick interval when out of combat to reduce idle CPU.
        local inCombat = UnitAffectingCombat("player")
        local tickInterval = inCombat and 0.2 or 0.5
        if self._tick < tickInterval then
            return
        end
        self._tick = 0

        local metrics = ns.metrics
        if not metrics or not metrics.GetActiveFight() then
            return
        end

        local rage = UnitPower("player", 1) or 0
        local ts = GetTime()
        metrics.UpdateRage(rage, ts)
        metrics.UpdateStarvedWindow(rage, ts)
        if ns.decision and ns.decision.GetRecommendation then
            metrics.TrackRecommendation(ns.decision.GetRecommendation(), ts)
        end
        metrics.NotifyChanged()
    end)
end

ns.RegisterModule(CollectorModule)

local _, ns = ...

local MetricsModule = {
    name = "Metrics",
}

local Metrics = {
    state = {
        activeFight = nil,
        lastFight = nil,
        history = {},
        maxHistory = 20,
        recentHostiles = {},
        hostileCountCache = {
            window = 0,
            value = 0,
            expireAt = 0,
        },
        swingClock = {
            lastMainSwingAt = 0,
            lastOffSwingAt = 0,
        },
    },
    listeners = {},
}

ns.metrics = Metrics

local SPELL = {
    BLOODTHIRST = GetSpellInfo(23881) or "Bloodthirst",
    WHIRLWIND = GetSpellInfo(1680) or "Whirlwind",
    EXECUTE = GetSpellInfo(5308) or "Execute",
    HEROIC_STRIKE = GetSpellInfo(78) or "Heroic Strike",
    CLEAVE = GetSpellInfo(845) or "Cleave",
    SUNDER_ARMOR = GetSpellInfo(7386) or "Sunder Armor",
    FLURRY = GetSpellInfo(12319) or "Flurry",
    DEATH_WISH = GetSpellInfo(12328) or "Death Wish",
    RECKLESSNESS = GetSpellInfo(1719) or "Recklessness",
}

local SPELL_ID = {
    BLOODTHIRST = 23881,
    WHIRLWIND = 1680,
    EXECUTE = 5308,
    HEROIC_STRIKE = 78,
    CLEAVE = 845,
    SUNDER_ARMOR = 7386,
    FLURRY = 12319,
    DEATH_WISH = 12328,
    RECKLESSNESS = 1719,
}

local TRACKED_BUFFS = {
    [SPELL_ID.FLURRY] = "flurry",
    [SPELL_ID.DEATH_WISH] = "deathWish",
    [SPELL_ID.RECKLESSNESS] = "recklessness",
}

local function Now()
    return GetTime()
end

local function SafeDiv(a, b)
    if not b or b == 0 then
        return 0
    end
    return a / b
end

local function NewFight(targetGuid)
    local ts = Now()
    return {
        fightId = tostring(math.floor(ts * 1000)),
        startTime = ts,
        endTime = nil,
        duration = 0,
        targetGuidMain = targetGuid,
        isBossLike = false,
        confidence = 0.9,

        totalDamage = 0,
        whiteDamageMainHand = 0,
        whiteDamageOffHand = 0,
        yellowDamage = 0,
        executeDamage = 0,

        missCountWhite = 0,
        missCountYellow = 0,
        dodgeCount = 0,
        parryCount = 0,
        glancingCount = 0,
        critCountWhite = 0,
        critCountYellow = 0,
        hitCountWhite = 0,
        hitCountYellow = 0,

        rageGainTotal = 0,
        rageGainFromDamageDone = 0,
        rageGainFromDamageTaken = 0,
        rageSpendTotal = 0,
        rageWastedOverflow = 0,
        rageStarvedWindow = 0,
        rageCapTime = 0,
        lastRage = UnitPower("player", 1) or 0,
        rageCapStartedAt = nil,
        starvedLastCheckAt = ts,

        castsBloodthirst = 0,
        castsWhirlwind = 0,
        castsExecute = 0,
        castsHeroicStrike = 0,
        castsCleave = 0,
        castsSunderArmor = 0,
        bloodthirstReadyTime = 0,
        whirlwindReadyTime = 0,
        bloodthirstDelaySum = 0,
        whirlwindDelaySum = 0,
        abilityState = {
            bloodthirst = { cost = 30, cd = 6, readyAt = ts, casts = 0, delaySum = 0 },
            whirlwind = { cost = 25, cd = 10, readyAt = ts, casts = 0, delaySum = 0 },
        },

        uptimeFlurry = 0,
        uptimeDeathWish = 0,
        uptimeRecklessness = 0,
        buffActiveSince = {
            flurry = nil,
            deathWish = nil,
            recklessness = nil,
        },
        recommendation = {
            total = 0,
            matched = 0,
            pending = nil,
            byToken = {},
            lastTrackedAt = 0,
            lastToken = nil,
        },
    }
end

function Metrics.RegisterListener(key, callback)
    if type(key) ~= "string" or type(callback) ~= "function" then
        return
    end
    Metrics.listeners[key] = callback
end

function Metrics.UnregisterListener(key)
    Metrics.listeners[key] = nil
end

function Metrics.NotifyChanged()
    for _, callback in pairs(Metrics.listeners) do
        pcall(callback, Metrics.state.activeFight, Metrics.state.lastFight)
    end
end

function Metrics.StartFight(targetGuid)
    if Metrics.state.activeFight then
        return Metrics.state.activeFight
    end
    Metrics.state.activeFight = NewFight(targetGuid)
    Metrics.NotifyChanged()
    return Metrics.state.activeFight
end

local function CloseBuffUptime(fight, nowTs)
    for key, startedAt in pairs(fight.buffActiveSince) do
        if startedAt then
            local field = "uptime" .. key:sub(1, 1):upper() .. key:sub(2)
            fight[field] = (fight[field] or 0) + (nowTs - startedAt)
            fight.buffActiveSince[key] = nil
        end
    end
end

function Metrics.BuildSummary(fight, nowTs)
    local summary = {}
    local endTs = nowTs or fight.endTime or Now()
    local duration = math.max(endTs - fight.startTime, 0.001)
    local whiteTotal = fight.whiteDamageMainHand + fight.whiteDamageOffHand
    local whiteDen = fight.missCountWhite + fight.hitCountWhite + fight.critCountWhite + fight.glancingCount + fight.dodgeCount
    local yellowDen = fight.missCountYellow + fight.hitCountYellow + fight.critCountYellow + fight.dodgeCount

    summary.fightId = fight.fightId
    summary.duration = duration
    summary.dps = fight.totalDamage / duration
    summary.totalDamage = fight.totalDamage

    summary.rage = {
        rps = fight.rageGainTotal / duration,
        gain = fight.rageGainTotal,
        spend = fight.rageSpendTotal,
        wastePct = SafeDiv(fight.rageWastedOverflow, math.max(fight.rageGainTotal, 1)),
        starvedPct = SafeDiv(fight.rageStarvedWindow, duration),
        capPct = SafeDiv(fight.rageCapTime, duration),
    }

    summary.rotation = {
        bloodthirstCasts = fight.castsBloodthirst,
        whirlwindCasts = fight.castsWhirlwind,
        executeCasts = fight.castsExecute,
        bloodthirstDelayAvg = SafeDiv(fight.bloodthirstDelaySum, math.max(fight.castsBloodthirst, 1)),
        whirlwindDelayAvg = SafeDiv(fight.whirlwindDelaySum, math.max(fight.castsWhirlwind, 1)),
        flurryUptimePct = SafeDiv(fight.uptimeFlurry, duration),
    }

    summary.hitTable = {
        whiteMissRate = SafeDiv(fight.missCountWhite, math.max(whiteDen, 1)),
        yellowMissRate = SafeDiv(fight.missCountYellow, math.max(yellowDen, 1)),
        glancingRate = SafeDiv(fight.glancingCount, math.max(whiteDen, 1)),
        whiteCritEff = SafeDiv(fight.critCountWhite, math.max(fight.hitCountWhite + fight.critCountWhite, 1)),
    }

    summary.mix = {
        whiteRatio = SafeDiv(whiteTotal, math.max(fight.totalDamage, 1)),
        yellowRatio = SafeDiv(fight.yellowDamage, math.max(fight.totalDamage, 1)),
        executeRatio = SafeDiv(fight.executeDamage, math.max(fight.totalDamage, 1)),
    }

    local rec = fight.recommendation or { total = 0, matched = 0 }
    summary.advisory = {
        total = rec.total or 0,
        matched = rec.matched or 0,
        hitRate = SafeDiv(rec.matched or 0, math.max(rec.total or 0, 1)),
    }

    summary.confidence = fight.confidence
    summary.inProgress = not fight.endTime
    return summary
end

function Metrics.EndFight()
    local fight = Metrics.state.activeFight
    if not fight then
        return nil
    end

    fight.endTime = Now()
    if fight.rageCapStartedAt then
        fight.rageCapTime = fight.rageCapTime + (fight.endTime - fight.rageCapStartedAt)
        fight.rageCapStartedAt = nil
    end
    CloseBuffUptime(fight, fight.endTime)
    fight.duration = fight.endTime - fight.startTime

    local summary = Metrics.BuildSummary(fight, fight.endTime)
    Metrics.state.lastFight = summary
    table.insert(Metrics.state.history, 1, summary)
    if #Metrics.state.history > Metrics.state.maxHistory then
        table.remove(Metrics.state.history)
    end

    Metrics.state.activeFight = nil
    Metrics.NotifyChanged()
    return summary
end

function Metrics.GetSnapshot()
    local activeFight = Metrics.state.activeFight
    if activeFight then
        return Metrics.BuildSummary(activeFight, Now())
    end
    return Metrics.state.lastFight
end

function Metrics.GetActiveFight()
    return Metrics.state.activeFight
end

function Metrics.MarkHostile(guid, ts)
    if not guid then
        return
    end
    Metrics.state.recentHostiles[guid] = ts or Now()
    Metrics.state.hostileCountCache.expireAt = 0
end

function Metrics.UnmarkHostile(guid)
    if not guid then
        return
    end
    if Metrics.state.recentHostiles[guid] ~= nil then
        Metrics.state.recentHostiles[guid] = nil
        Metrics.state.hostileCountCache.expireAt = 0
    end
end

function Metrics.GetRecentHostileCount(windowSeconds)
    local window = windowSeconds or 6
    local nowTs = Now()
    local cache = Metrics.state.hostileCountCache
    if cache and cache.window == window and nowTs <= (cache.expireAt or 0) then
        return cache.value or 0
    end
    local count = 0
    for guid, seenAt in pairs(Metrics.state.recentHostiles) do
        if nowTs - seenAt <= window then
            count = count + 1
        else
            Metrics.state.recentHostiles[guid] = nil
        end
    end
    cache.window = window
    cache.value = count
    cache.expireAt = nowTs + 0.25
    return count
end

function Metrics.TrackRecommendation(rec, ts)
    local fight = Metrics.state.activeFight
    if not fight or not rec then
        return
    end

    local token = rec.nextGcdSkill or rec.nextSkill
    local decision = ns.decision
    local actionable = decision and decision.GetActionableTokens and decision.GetActionableTokens() or nil
    if not actionable or not actionable[token] then
        return
    end

    local nowTs = ts or Now()
    local horizonSec = ((rec.horizonMs or 400) / 1000)
    local bucket = fight.recommendation

    if bucket.pending and nowTs > bucket.pending.expireAt then
        bucket.pending = nil
    end

    if bucket.pending and bucket.pending.token == token and nowTs - bucket.pending.issuedAt < horizonSec * 0.8 then
        return
    end
    if bucket.lastToken == token and nowTs - (bucket.lastTrackedAt or 0) < horizonSec then
        return
    end

    bucket.total = bucket.total + 1
    bucket.lastToken = token
    bucket.lastTrackedAt = nowTs
    bucket.pending = {
        token = token,
        issuedAt = nowTs,
        expireAt = nowTs + horizonSec + 0.15,
    }

    bucket.byToken[token] = bucket.byToken[token] or { total = 0, matched = 0 }
    bucket.byToken[token].total = bucket.byToken[token].total + 1
end

function Metrics.UpdateRage(currentRage, ts)
    local fight = Metrics.state.activeFight
    if not fight then
        return
    end

    local nowTs = ts or Now()
    local prev = fight.lastRage or currentRage
    local delta = currentRage - prev
    if delta > 0 then
        fight.rageGainTotal = fight.rageGainTotal + delta
        if prev >= 100 then
            fight.rageWastedOverflow = fight.rageWastedOverflow + delta
        end
    elseif delta < 0 then
        fight.rageSpendTotal = fight.rageSpendTotal + (-delta)
    end

    if currentRage >= 100 and not fight.rageCapStartedAt then
        fight.rageCapStartedAt = nowTs
    elseif currentRage < 100 and fight.rageCapStartedAt then
        fight.rageCapTime = fight.rageCapTime + (nowTs - fight.rageCapStartedAt)
        fight.rageCapStartedAt = nil
    end

    fight.lastRage = currentRage
end

function Metrics.UpdateStarvedWindow(currentRage, ts)
    local fight = Metrics.state.activeFight
    if not fight then
        return
    end

    local nowTs = ts or Now()
    local dt = nowTs - (fight.starvedLastCheckAt or nowTs)
    if dt <= 0 then
        return
    end
    fight.starvedLastCheckAt = nowTs

    local starved = false
    local bt = fight.abilityState.bloodthirst
    local ww = fight.abilityState.whirlwind
    if nowTs >= bt.readyAt and currentRage < bt.cost then
        starved = true
    elseif nowTs >= ww.readyAt and currentRage < ww.cost then
        starved = true
    end

    if starved then
        fight.rageStarvedWindow = fight.rageStarvedWindow + dt
    end
end

local function UpdateSwingClock(isOffHand, ts)
    local nowTs = ts or Now()
    if isOffHand then
        Metrics.state.swingClock.lastOffSwingAt = nowTs
    else
        Metrics.state.swingClock.lastMainSwingAt = nowTs
    end
end

function Metrics.GetSwingState(nowTs)
    local nowValue = nowTs or Now()
    local speedMain, speedOff = UnitAttackSpeed("player")
    local swing = Metrics.state.swingClock or {}
    local lastMain = tonumber(swing.lastMainSwingAt) or 0
    local lastOff = tonumber(swing.lastOffSwingAt) or 0
    local hasOff = (speedOff or 0) > 0

    local nextMain = (speedMain and speedMain > 0)
        and ((lastMain > 0) and (lastMain + speedMain) or (nowValue + speedMain))
        or nowValue
    local nextOff = (hasOff and speedOff and speedOff > 0)
        and ((lastOff > 0) and (lastOff + speedOff) or (nowValue + speedOff))
        or nowValue

    return {
        now = nowValue,
        speedMain = speedMain or 0,
        speedOff = speedOff or 0,
        hasOffHand = hasOff,
        lastMainSwingAt = lastMain,
        lastOffSwingAt = lastOff,
        nextMainSwingAt = nextMain,
        nextOffSwingAt = nextOff,
        timeToMain = math.max((nextMain or nowValue) - nowValue, 0),
        timeToOff = hasOff and math.max((nextOff or nowValue) - nowValue, 0) or 0,
    }
end

function Metrics.RecordSwingDamage(amount, critical, glancing, isOffHand)
    local fight = Metrics.state.activeFight
    if not fight then
        return
    end

    local dmg = amount or 0
    fight.totalDamage = fight.totalDamage + dmg
    if isOffHand then
        fight.whiteDamageOffHand = fight.whiteDamageOffHand + dmg
    else
        fight.whiteDamageMainHand = fight.whiteDamageMainHand + dmg
    end

    if glancing then
        fight.glancingCount = fight.glancingCount + 1
    elseif critical then
        fight.critCountWhite = fight.critCountWhite + 1
    else
        fight.hitCountWhite = fight.hitCountWhite + 1
    end
    UpdateSwingClock(isOffHand, Now())
end

function Metrics.RecordSwingMiss(missType, isOffHand, ts)
    local fight = Metrics.state.activeFight
    if not fight then
        return
    end

    if missType == "MISS" then
        fight.missCountWhite = fight.missCountWhite + 1
    elseif missType == "DODGE" then
        fight.dodgeCount = fight.dodgeCount + 1
    elseif missType == "PARRY" then
        fight.parryCount = fight.parryCount + 1
    end
    UpdateSwingClock(isOffHand, ts or Now())
end

function Metrics.RecordSpellDamage(spellName, spellId, amount, critical)
    local fight = Metrics.state.activeFight
    if not fight then
        return
    end

    local dmg = amount or 0
    fight.totalDamage = fight.totalDamage + dmg
    fight.yellowDamage = fight.yellowDamage + dmg

    if spellId == SPELL_ID.EXECUTE or spellName == SPELL.EXECUTE then
        fight.executeDamage = fight.executeDamage + dmg
    end

    if critical then
        fight.critCountYellow = fight.critCountYellow + 1
    else
        fight.hitCountYellow = fight.hitCountYellow + 1
    end
end

function Metrics.RecordSpellMiss(missType)
    local fight = Metrics.state.activeFight
    if not fight then
        return
    end

    if missType == "MISS" then
        fight.missCountYellow = fight.missCountYellow + 1
    elseif missType == "DODGE" then
        fight.dodgeCount = fight.dodgeCount + 1
    elseif missType == "PARRY" then
        fight.parryCount = fight.parryCount + 1
    end
end

function Metrics.RecordCast(spellName, spellId, ts)
    local fight = Metrics.state.activeFight
    if not fight then
        return
    end

    local nowTs = ts or Now()
    local decision = ns.decision
    local token = nil
    if decision and decision.GetTokenForSpellId and spellId then
        token = decision.GetTokenForSpellId(spellId)
    end
    if not token and decision and decision.GetTokenForSpellName then
        token = decision.GetTokenForSpellName(spellName)
    end
    local rec = fight.recommendation
    if rec and rec.pending and nowTs > rec.pending.expireAt then
        rec.pending = nil
    end
    if token and rec and rec.pending and rec.pending.token == token and nowTs <= rec.pending.expireAt then
        rec.matched = rec.matched + 1
        rec.byToken[token] = rec.byToken[token] or { total = 0, matched = 0 }
        rec.byToken[token].matched = rec.byToken[token].matched + 1
        rec.pending = nil
    end

    if spellId == SPELL_ID.BLOODTHIRST or spellName == SPELL.BLOODTHIRST then
        local state = fight.abilityState.bloodthirst
        fight.castsBloodthirst = fight.castsBloodthirst + 1
        state.casts = state.casts + 1
        if nowTs > state.readyAt then
            local delay = nowTs - state.readyAt
            fight.bloodthirstDelaySum = fight.bloodthirstDelaySum + delay
            state.delaySum = state.delaySum + delay
        end
        state.readyAt = nowTs + state.cd
    elseif spellId == SPELL_ID.WHIRLWIND or spellName == SPELL.WHIRLWIND then
        local state = fight.abilityState.whirlwind
        fight.castsWhirlwind = fight.castsWhirlwind + 1
        state.casts = state.casts + 1
        if nowTs > state.readyAt then
            local delay = nowTs - state.readyAt
            fight.whirlwindDelaySum = fight.whirlwindDelaySum + delay
            state.delaySum = state.delaySum + delay
        end
        state.readyAt = nowTs + state.cd
    elseif spellId == SPELL_ID.EXECUTE or spellName == SPELL.EXECUTE then
        fight.castsExecute = fight.castsExecute + 1
    elseif spellId == SPELL_ID.HEROIC_STRIKE or spellName == SPELL.HEROIC_STRIKE then
        fight.castsHeroicStrike = fight.castsHeroicStrike + 1
    elseif spellId == SPELL_ID.CLEAVE or spellName == SPELL.CLEAVE then
        fight.castsCleave = fight.castsCleave + 1
    elseif spellId == SPELL_ID.SUNDER_ARMOR or spellName == SPELL.SUNDER_ARMOR then
        fight.castsSunderArmor = fight.castsSunderArmor + 1
    end
end

function Metrics.RecordAuraEvent(spellName, spellId, eventType, ts)
    local fight = Metrics.state.activeFight
    if not fight then
        return
    end

    local buffKey = TRACKED_BUFFS[spellId]
    if not buffKey and spellName then
        if spellName == SPELL.FLURRY then
            buffKey = "flurry"
        elseif spellName == SPELL.DEATH_WISH then
            buffKey = "deathWish"
        elseif spellName == SPELL.RECKLESSNESS then
            buffKey = "recklessness"
        end
    end
    if not buffKey then
        return
    end
    local nowTs = ts or Now()
    local activeSince = fight.buffActiveSince[buffKey]

    if eventType == "SPELL_AURA_APPLIED" or eventType == "SPELL_AURA_REFRESH" then
        if not activeSince then
            fight.buffActiveSince[buffKey] = nowTs
        end
        return
    end

    if eventType == "SPELL_AURA_REMOVED" and activeSince then
        local field = "uptime" .. buffKey:sub(1, 1):upper() .. buffKey:sub(2)
        fight[field] = (fight[field] or 0) + (nowTs - activeSince)
        fight.buffActiveSince[buffKey] = nil
    end
end

function MetricsModule:Init()
    -- Metrics 数据模块本身无需事件，供采集器与面板调用。
end

ns.RegisterModule(MetricsModule)

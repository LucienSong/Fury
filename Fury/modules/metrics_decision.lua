local _, ns = ...

local DecisionModule = {
    name = "MetricsDecision",
}

local Decision = {}
ns.decision = Decision
local HabitState = {
    lockedSkill = nil,
    lockedAt = 0,
    lastSwitchAt = 0,
    candidateSkill = nil,
    candidateSince = 0,
    mode = nil,
    inCombat = nil,
}

local TOKENS = {
    NONE = "NONE",
    WAIT = "WAIT",
    HOLD = "HOLD",
    RAGE_DUMP = "RAGE_DUMP",
    BLOODRAGE = "BLOODRAGE",
    BLOODTHIRST = "BLOODTHIRST",
    WHIRLWIND = "WHIRLWIND",
    EXECUTE = "EXECUTE",
    HAMSTRING = "HAMSTRING",
    HEROIC_STRIKE = "HEROIC_STRIKE",
    CLEAVE = "CLEAVE",
    BATTLE_SHOUT = "BATTLE_SHOUT",
    SUNDER_ARMOR = "SUNDER_ARMOR",
    REVENGE = "REVENGE",
    SHIELD_BLOCK = "SHIELD_BLOCK",
    SHIELD_SLAM = "SHIELD_SLAM",
    LAST_STAND = "LAST_STAND",
    TAUNT = "TAUNT",
    MOCKING_BLOW = "MOCKING_BLOW",
}

local SPELL = {
    BATTLE_STANCE = GetSpellInfo(2457) or "Battle Stance",
    DEFENSIVE_STANCE = GetSpellInfo(71) or "Defensive Stance",
    BERSERKER_STANCE = GetSpellInfo(2458) or "Berserker Stance",
}

local ReadThreatState
local IsOffGcdToken

local SPELL_ID = {
    BATTLE_STANCE = 2457,
    DEFENSIVE_STANCE = 71,
    BERSERKER_STANCE = 2458,
    BLOODRAGE = 2687,
    BATTLE_SHOUT = 6673,
    SUNDER_ARMOR = 7386,
    FLURRY_BUFF = 12319,
    DEATH_WISH_BUFF = 12328,
    RECKLESSNESS_BUFF = 1719,
    BLOODRAGE_BUFF = 2687,
    BERSERKER_RAGE_BUFF = 18499,
    HAMSTRING = 1715,
    MOCKING_BLOW = 694,
}

local EXECUTE_RANK_IDS = { 5308, 20658, 20660, 20661, 20662 }
local HAMSTRING_RANK_IDS = { 1715, 7372, 7373 }
local SUNDER_RANK_IDS = { 7386, 7405, 8380, 11596, 11597 }
local HS_RANK_IDS = { 78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286 }
local CLEAVE_RANK_IDS = { 845, 7369, 11608, 11609, 20569 }
local BATTLE_SHOUT_RANK_IDS = { 6673, 5242, 6192, 11549, 11550, 11551, 25289 }
local MOCKING_BLOW_RANK_IDS = { 694, 7400, 7402, 20559, 20560 }
local EXECUTE_MODEL_CACHE = nil

-- 白名单精细化：setId -> bonus profile（可持续扩展）
local SET_BONUS_PROFILES = {
    -- 示例（请按实测 setId 继续补充）：
    -- [209] = Battlegear of Might, [210] = Battlegear of Wrath
    [209] = {
        name = "Battlegear of Might",
        pieces = {
            [3] = { threat = 6, tps = 5, sunder = 4, survival = 2 },
            [5] = { threat = 10, tps = 8, sunder = 6, survival = 3 },
        },
    },
    [210] = {
        name = "Battlegear of Wrath",
        pieces = {
            [3] = { threat = 8, tps = 7, sunder = 6, survival = 4 },
            [5] = { threat = 12, tps = 10, sunder = 8, survival = 6 },
        },
    },
}

-- 若 setId 未命中，可按套装名关键词做弱匹配兜底。
local SET_NAME_PROFILE_HINTS = {
    { pattern = "Might", pieces = { [3] = { threat = 6, tps = 5 }, [5] = { threat = 10, tps = 8, sunder = 5 } } },
    { pattern = "Wrath", pieces = { [3] = { threat = 8, tps = 7 }, [5] = { threat = 12, tps = 10, survival = 4 } } },
    { pattern = "Conqueror", pieces = { [3] = { dps = 6, whirlwind = 4 }, [5] = { dps = 10, whirlwind = 8, dump = 4 } } },
    { pattern = "Dreadnaught", pieces = { [3] = { threat = 10, tps = 9 }, [5] = { threat = 14, tps = 12, survival = 6 } } },
}

-- trinket/buff spellId -> AP/crit/haste/threat 权重映射（白名单，可持续补充）。
local BUFF_TRINKET_WEIGHT_PROFILES = {
    [SPELL_ID.FLURRY_BUFF] = { name = "Flurry", weights = { haste = 20, dps = 6, dump = 3 } },
    [SPELL_ID.DEATH_WISH_BUFF] = { name = "Death Wish", weights = { dps = 14, threat = 8, bloodthirst = 5, execute = 5 } },
    [SPELL_ID.RECKLESSNESS_BUFF] = { name = "Recklessness", weights = { crit = 30, dps = 16, execute = 8, bloodthirst = 6 } },
    [SPELL_ID.BLOODRAGE_BUFF] = { name = "Bloodrage", weights = { threat = 4, tps = 3, sunder = 2 } },
    [SPELL_ID.BERSERKER_RAGE_BUFF] = { name = "Berserker Rage", weights = { threat = 3, tps = 2 } },
    -- 常见世界 Buff / 饰品触发（具体 spellId 可按你实测继续扩展）
    [22888] = { name = "Rallying Cry", weights = { ap = 140, crit = 5, dps = 10, threat = 6 } },
    [16609] = { name = "Warchief Blessing", weights = { haste = 15, dps = 7, dump = 3 } },
    [15366] = { name = "Songflower", weights = { crit = 5, dps = 6, threat = 3 } },
}

local function GetUnifiedProfile()
    if ns.GetDecisionProfile then
        return ns.GetDecisionProfile()
    end
    return nil
end

local function GetPolicyParam(key, defaultValue)
    local profile = GetUnifiedProfile()
    local policy = profile and profile.policyParams
    if type(policy) == "table" then
        local raw = policy[key]
        if type(raw) == "number" then
            return raw
        end
    end
    return defaultValue
end

local function GetSetBonusProfiles()
    local profile = GetUnifiedProfile()
    if profile and type(profile.setBonusProfiles) == "table" then
        return profile.setBonusProfiles
    end
    return SET_BONUS_PROFILES
end

local function GetSetNameProfileHints()
    local profile = GetUnifiedProfile()
    if profile and type(profile.setNameProfileHints) == "table" then
        return profile.setNameProfileHints
    end
    return SET_NAME_PROFILE_HINTS
end

local function GetBuffTrinketWeightProfiles()
    local profile = GetUnifiedProfile()
    if profile and type(profile.buffTrinketWeightProfiles) == "table" then
        return profile.buffTrinketWeightProfiles
    end
    return BUFF_TRINKET_WEIGHT_PROFILES
end

local ABILITIES = {
    [TOKENS.BLOODRAGE] = { id = SPELL_ID.BLOODRAGE, name = GetSpellInfo(SPELL_ID.BLOODRAGE) or "Bloodrage", rage = 0 },
    [TOKENS.BLOODTHIRST] = { id = 23881, name = GetSpellInfo(23881) or "Bloodthirst", rage = 30 },
    [TOKENS.WHIRLWIND] = { id = 1680, name = GetSpellInfo(1680) or "Whirlwind", rage = 25 },
    [TOKENS.EXECUTE] = { id = 5308, name = GetSpellInfo(5308) or "Execute", rage = 15 },
    [TOKENS.HAMSTRING] = { id = 1715, name = GetSpellInfo(1715) or "Hamstring", rage = 10 },
    [TOKENS.HEROIC_STRIKE] = { id = 78, name = GetSpellInfo(78) or "Heroic Strike", rage = 15 },
    [TOKENS.CLEAVE] = { id = 845, name = GetSpellInfo(845) or "Cleave", rage = 20 },
    [TOKENS.BATTLE_SHOUT] = { id = SPELL_ID.BATTLE_SHOUT, name = GetSpellInfo(SPELL_ID.BATTLE_SHOUT) or "Battle Shout", rage = 10 },
    [TOKENS.SUNDER_ARMOR] = { id = 7386, name = GetSpellInfo(7386) or "Sunder Armor", rage = 15 },
    [TOKENS.REVENGE] = { id = 6572, name = GetSpellInfo(6572) or "Revenge", rage = 5 },
    [TOKENS.SHIELD_BLOCK] = { id = 2565, name = GetSpellInfo(2565) or "Shield Block", rage = 10 },
    [TOKENS.SHIELD_SLAM] = { id = 23922, name = GetSpellInfo(23922) or "Shield Slam", rage = 20 },
    [TOKENS.LAST_STAND] = { id = 12975, name = GetSpellInfo(12975) or "Last Stand", rage = 0 },
    [TOKENS.TAUNT] = { id = 355, name = GetSpellInfo(355) or "Taunt", rage = 0 },
    [TOKENS.MOCKING_BLOW] = { id = SPELL_ID.MOCKING_BLOW, name = GetSpellInfo(SPELL_ID.MOCKING_BLOW) or "Mocking Blow", rage = 10 },
}

local TOKEN_BY_RANK_SPELL_ID = {
    -- Execute
    [5308] = TOKENS.EXECUTE, [20658] = TOKENS.EXECUTE, [20660] = TOKENS.EXECUTE,
    [20661] = TOKENS.EXECUTE, [20662] = TOKENS.EXECUTE,
    -- Hamstring
    [1715] = TOKENS.HAMSTRING, [7372] = TOKENS.HAMSTRING, [7373] = TOKENS.HAMSTRING,
    -- Heroic Strike
    [78] = TOKENS.HEROIC_STRIKE, [284] = TOKENS.HEROIC_STRIKE, [285] = TOKENS.HEROIC_STRIKE,
    [1608] = TOKENS.HEROIC_STRIKE, [11564] = TOKENS.HEROIC_STRIKE, [11565] = TOKENS.HEROIC_STRIKE,
    [11566] = TOKENS.HEROIC_STRIKE, [11567] = TOKENS.HEROIC_STRIKE, [25286] = TOKENS.HEROIC_STRIKE,
    -- Cleave
    [845] = TOKENS.CLEAVE, [7369] = TOKENS.CLEAVE, [11608] = TOKENS.CLEAVE,
    [11609] = TOKENS.CLEAVE, [20569] = TOKENS.CLEAVE,
    -- Battle Shout
    [6673] = TOKENS.BATTLE_SHOUT, [5242] = TOKENS.BATTLE_SHOUT, [6192] = TOKENS.BATTLE_SHOUT,
    [11549] = TOKENS.BATTLE_SHOUT, [11550] = TOKENS.BATTLE_SHOUT, [11551] = TOKENS.BATTLE_SHOUT,
    [25289] = TOKENS.BATTLE_SHOUT,
    -- Sunder Armor
    [7386] = TOKENS.SUNDER_ARMOR, [7405] = TOKENS.SUNDER_ARMOR, [8380] = TOKENS.SUNDER_ARMOR,
    [11596] = TOKENS.SUNDER_ARMOR, [11597] = TOKENS.SUNDER_ARMOR,
    -- Mocking Blow
    [694] = TOKENS.MOCKING_BLOW, [7400] = TOKENS.MOCKING_BLOW, [7402] = TOKENS.MOCKING_BLOW,
    [20559] = TOKENS.MOCKING_BLOW, [20560] = TOKENS.MOCKING_BLOW,
}

local TOKEN_COOLDOWN_KEY = {
    [TOKENS.BLOODRAGE] = "br",
    [TOKENS.BLOODTHIRST] = "bt",
    [TOKENS.WHIRLWIND] = "ww",
    [TOKENS.EXECUTE] = "ex",
    [TOKENS.HAMSTRING] = nil,
    [TOKENS.REVENGE] = "rev",
    [TOKENS.SHIELD_BLOCK] = "sb",
    [TOKENS.SHIELD_SLAM] = "ss",
    [TOKENS.LAST_STAND] = "ls",
    [TOKENS.TAUNT] = "taunt",
    [TOKENS.MOCKING_BLOW] = "mb",
    [TOKENS.SUNDER_ARMOR] = nil,
}

local GCD_ACTIONABLE_TOKENS = {
    [TOKENS.BLOODTHIRST] = true,
    [TOKENS.WHIRLWIND] = true,
    [TOKENS.EXECUTE] = true,
    [TOKENS.HAMSTRING] = true,
    [TOKENS.BATTLE_SHOUT] = true,
    [TOKENS.SUNDER_ARMOR] = true,
    [TOKENS.REVENGE] = true,
    [TOKENS.SHIELD_SLAM] = true,
    [TOKENS.TAUNT] = true,
    [TOKENS.MOCKING_BLOW] = true,
}

local OFF_GCD_ACTIONABLE_TOKENS = {
    [TOKENS.BLOODRAGE] = true,
    [TOKENS.SHIELD_BLOCK] = true,
    [TOKENS.LAST_STAND] = true,
}

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function NewWeightBag()
    return {
        ap = 0,
        crit = 0,
        haste = 0,
        threat = 0,
        dps = 0,
        tps = 0,
        execute = 0,
        bloodthirst = 0,
        whirlwind = 0,
        hamstring = 0,
        sunder = 0,
        dump = 0,
        survival = 0,
    }
end

local function AddWeightBag(dst, src, scale)
    if type(dst) ~= "table" or type(src) ~= "table" then
        return
    end
    local m = scale or 1
    for k, v in pairs(src) do
        if type(v) == "number" then
            dst[k] = (dst[k] or 0) + v * m
        end
    end
end

local function PickPieceWeights(pieceMap, pieceCount)
    if type(pieceMap) ~= "table" then
        return nil, nil
    end
    local bestKey = nil
    for k, _ in pairs(pieceMap) do
        if type(k) == "number" and pieceCount >= k then
            if not bestKey or k > bestKey then
                bestKey = k
            end
        end
    end
    if bestKey then
        return pieceMap[bestKey], bestKey
    end
    return nil, nil
end

function Decision.GetActionableTokens()
    return GCD_ACTIONABLE_TOKENS
end

function Decision.GetOffGcdActionableTokens()
    return OFF_GCD_ACTIONABLE_TOKENS
end

function Decision.GetTokenForSpellName(spellName)
    if not spellName then
        return nil
    end
    for token, info in pairs(ABILITIES) do
        if info.name == spellName then
            return token
        end
    end
    return nil
end

function Decision.GetTokenForSpellId(spellId)
    if not spellId then
        return nil
    end
    local byRank = TOKEN_BY_RANK_SPELL_ID[spellId]
    if byRank then
        return byRank
    end
    for token, info in pairs(ABILITIES) do
        if info.id == spellId then
            return token
        end
    end
    return nil
end

function Decision.GetTokenTexture(token)
    local info = ABILITIES[token]
    if info and info.id then
        return GetSpellTexture(info.id)
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function GetTokenRageCost(token)
    local info = ABILITIES[token]
    return (info and info.rage) or 0
end

local function GetTokenCooldownRemaining(token, context)
    local key = TOKEN_COOLDOWN_KEY[token]
    if not key then
        return 0
    end
    if context and context.cooldown and type(context.cooldown[key]) == "number" then
        return math.max(context.cooldown[key], 0)
    end
    return 0
end

local function CalcThreatUrgency(threat)
    local scaledPct = (threat and tonumber(threat.scaledPct)) or 0
    return math.max(0, 100 - scaledPct) * GetPolicyParam("threat_urgency_base", 0.3)
end

local function CalcSurvivalUrgency(playerHealthPct)
    local hpPct = tonumber(playerHealthPct) or 100
    return math.max(0, 40 - hpPct) * GetPolicyParam("survival_urgency_base", 0.35)
end

local function CalcTpsThreatBias(threat)
    local scaledPct = (threat and tonumber(threat.scaledPct)) or 0
    return math.max(0, 95 - scaledPct) * GetPolicyParam("tps_threat_bias_coeff", 0.2)
end

local SUNDER_DUTY_MODES = {
    "self_stack",
    "maintain_only",
    "external_armor",
}

local SUNDER_DUTY_LABELS = {
    self_stack = "自动分工(Boss补层/Tank刷新)",
    maintain_only = "仅跟进/维持已有破甲",
    external_armor = "团队外部减甲职责",
}

local function NormalizeSunderDutyMode(raw)
    local mode = strlower(tostring(raw or "self_stack"))
    for i = 1, #SUNDER_DUTY_MODES do
        if SUNDER_DUTY_MODES[i] == mode then
            return mode
        end
    end
    return "self_stack"
end

function Decision.GetSunderDutyModeLabel(mode)
    local normalized = NormalizeSunderDutyMode(mode)
    return SUNDER_DUTY_LABELS[normalized] or normalized
end

function Decision.GetSunderDutyModes()
    local out = {}
    for i = 1, #SUNDER_DUTY_MODES do
        out[i] = SUNDER_DUTY_MODES[i]
    end
    return out
end

ns.GetSunderDutyModeLabel = Decision.GetSunderDutyModeLabel
ns.GetSunderDutyModes = Decision.GetSunderDutyModes

function Decision.GetHorizonMs()
    local profile = GetUnifiedProfile()
    if profile and tonumber(profile.decisionHorizonMs) then
        return Clamp(math.floor(tonumber(profile.decisionHorizonMs) + 0.5), 50, 2000)
    end
    return (ns.db and ns.db.metrics and ns.db.metrics.decisionHorizonMs) or 400
end

function Decision.GetConfig()
    local profile = GetUnifiedProfile()
    local cfg = (profile and profile.decisionConfig) or (ns.db and ns.db.metrics and ns.db.metrics.decisionConfig) or {}
    local targetStacks = Clamp(tonumber(cfg.sunderTargetStacks) or 5, 1, 5)
    return {
        sunderHpThreshold = Clamp(math.floor((tonumber(cfg.sunderHpThreshold) or 100000) + 0.5), 10000, 5000000),
        sunderRefreshSeconds = Clamp(tonumber(cfg.sunderRefreshSeconds) or 10, 1, 30),
        sunderTargetStacks = targetStacks,
        sunderDutyMode = NormalizeSunderDutyMode(cfg.sunderDutyMode),
        sunderMinTtdSeconds = Clamp(tonumber(cfg.sunderMinTtdSeconds) or 9, 2, 60),
        battleShoutRefreshSeconds = Clamp(tonumber(cfg.battleShoutRefreshSeconds) or 12, 3, 60),
        battleShoutOocMinRage = Clamp(math.floor((tonumber(cfg.battleShoutOocMinRage) or 10) + 0.5), 0, 100),
    }
end

function Decision.GetHsQueueConfig()
    local profile = GetUnifiedProfile()
    local cfg = (profile and profile.hsQueueConfig) or {}
    return {
        enabled = (cfg.enabled == nil) and true or (cfg.enabled and true or false),
        queueWindowMs = Clamp(math.floor((tonumber(cfg.queueWindowMs) or 380) + 0.5), 120, 1000),
        safetyRage = Clamp(math.floor((tonumber(cfg.safetyRage) or 8) + 0.5), 0, 40),
        btProtectMs = Clamp(math.floor((tonumber(cfg.btProtectMs) or 450) + 0.5), 0, 3000),
        wwProtectMs = Clamp(math.floor((tonumber(cfg.wwProtectMs) or 550) + 0.5), 0, 3000),
        exProtectMs = Clamp(math.floor((tonumber(cfg.exProtectMs) or 350) + 0.5), 0, 3000),
        singleTargetOnly = (cfg.singleTargetOnly == nil) and true or (cfg.singleTargetOnly and true or false),
    }
end

function Decision.GetHamstringConfig()
    local profile = GetUnifiedProfile()
    local cfg = (profile and profile.hamstringConfig) or {}
    local baseBias = tonumber(cfg.baseBias)
    if baseBias == nil then
        local legacyBonus = tonumber(cfg.flurryBaitBonus)
        if legacyBonus ~= nil then
            baseBias = legacyBonus * 0.25
        else
            baseBias = 1
        end
    end
    return {
        enabled = (cfg.enabled == nil) and true or (cfg.enabled and true or false),
        mode = (cfg.mode == "legacy") and "legacy" or "flurry_ev",
        singleTargetOnly = (cfg.singleTargetOnly == nil) and true or (cfg.singleTargetOnly and true or false),
        refreshSeconds = Clamp(tonumber(cfg.refreshSeconds) or 8, 2, 20),
        flurryBaitBonus = Clamp(tonumber(cfg.flurryBaitBonus) or 8, 0, 30),
        minTargetTtdSeconds = Clamp(tonumber(cfg.minTargetTtdSeconds) or 10, 2, 60),
        lookaheadSeconds = Clamp(tonumber(cfg.lookaheadSeconds) or 3.2, 0.5, 10),
        minEvScore = Clamp(tonumber(cfg.minEvScore) or 4, -20, 60),
        evScale = Clamp(tonumber(cfg.evScale) or 18, 1, 80),
        baseBias = Clamp(baseBias or 1, -10, 20),
        yellowLandChance = Clamp(tonumber(cfg.yellowLandChance) or 0.90, 0.50, 0.99),
        naturalProcWindowMaxEvents = Clamp(math.floor((tonumber(cfg.naturalProcWindowMaxEvents) or 4) + 0.5), 1, 8),
        mainSwingValue = Clamp(tonumber(cfg.mainSwingValue) or 1.0, 0.1, 3.0),
        offSwingValue = Clamp(tonumber(cfg.offSwingValue) or 0.65, 0.05, 3.0),
        gcdPenalty = Clamp(tonumber(cfg.gcdPenalty) or 1.0, 0, 20),
        ragePenaltyScale = Clamp(tonumber(cfg.ragePenaltyScale) or 0.8, 0, 10),
        keepDebuffBias = Clamp(tonumber(cfg.keepDebuffBias) or 0, -5, 15),
        rageSafetyReserve = Clamp(math.floor((tonumber(cfg.rageSafetyReserve) or 12) + 0.5), 0, 40),
        btProtectMs = Clamp(math.floor((tonumber(cfg.btProtectMs) or 450) + 0.5), 0, 3000),
        wwProtectMs = Clamp(math.floor((tonumber(cfg.wwProtectMs) or 550) + 0.5), 0, 3000),
        exProtectMs = Clamp(math.floor((tonumber(cfg.exProtectMs) or 350) + 0.5), 0, 3000),
        allowExecutePhase = (cfg.allowExecutePhase == nil) and false or (cfg.allowExecutePhase and true or false),
    }
end

function Decision.GetHabitConfig()
    local profile = GetUnifiedProfile()
    local cfg = (profile and profile.habitConfig) or {}
    local enabledByProfile = cfg.enabled
    if enabledByProfile == nil then
        enabledByProfile = true
    end
    local enabledByDb = ns.db and ns.db.metrics and ns.db.metrics.habitEnabled
    local enabled = (enabledByDb == nil) and enabledByProfile or (enabledByDb and true or false)
    return {
        enabled = enabled and true or false,
        minHoldMs = Clamp(math.floor((tonumber(cfg.minHoldMs) or 600) + 0.5), 100, 3000),
        switchDelta = Clamp(tonumber(cfg.switchDelta) or 10, 1, 80),
        baseLockedBonus = Clamp(tonumber(cfg.baseLockedBonus) or 8, 0, 40),
        bonusDecayMs = Clamp(math.floor((tonumber(cfg.bonusDecayMs) or 1200) + 0.5), 200, 5000),
        readySoonMs = Clamp(math.floor((tonumber(cfg.readySoonMs) or 350) + 0.5), 50, 2000),
        emergencyOverride = (cfg.emergencyOverride == nil) and true or (cfg.emergencyOverride and true or false),
    }
end

function ns.SetDecisionHabitEnabled(enabled)
    if not ns.db or not ns.db.metrics then
        return
    end
    local on = enabled and true or false
    ns.db.metrics.habitEnabled = on
    if ns.SetDecisionProfile then
        ns.SetDecisionProfile({ habitConfig = { enabled = on } })
    end
end

function ns.IsDecisionHabitEnabled()
    return Decision.GetHabitConfig().enabled
end

function Decision.GetModeOverride()
    local raw = ns.db and ns.db.metrics and ns.db.metrics.modeOverride
    if raw == "dps" or raw == "tps" then
        return raw
    end
    return "auto"
end

function ns.SetDecisionHorizonMs(ms)
    if not ns.db or not ns.db.metrics then
        return
    end
    local value = tonumber(ms)
    if not value then
        return
    end
    local normalized = Clamp(math.floor(value + 0.5), 50, 2000)
    ns.db.metrics.decisionHorizonMs = normalized
    if ns.SetDecisionProfile then
        ns.SetDecisionProfile({ decisionHorizonMs = normalized })
    end
end

function ns.GetDecisionHorizonMs()
    return Decision.GetHorizonMs()
end

function ns.SetDecisionConfig(partial)
    if not ns.db or not ns.db.metrics then
        return
    end
    ns.db.metrics.decisionConfig = ns.db.metrics.decisionConfig or {}
    for k, v in pairs(partial or {}) do
        ns.db.metrics.decisionConfig[k] = v
    end
    if ns.SetDecisionProfile then
        ns.SetDecisionProfile({ decisionConfig = partial or {} })
    end
end

function ns.GetDecisionConfig()
    return Decision.GetConfig()
end

function ns.SetDecisionModeOverride(mode)
    if not ns.db or not ns.db.metrics then
        return
    end
    local normalized = strlower(tostring(mode or "auto"))
    if normalized ~= "auto" and normalized ~= "dps" and normalized ~= "tps" then
        return
    end
    ns.db.metrics.modeOverride = normalized
end

function ns.GetDecisionModeOverride()
    return Decision.GetModeOverride()
end

local function GetCooldownRemaining(spellName)
    if not spellName then
        return 999
    end
    local start, duration = GetSpellCooldown(spellName)
    if not start or start == 0 then
        return 0
    end
    local remain = start + (duration or 0) - GetTime()
    if remain < 0 then
        return 0
    end
    return remain
end

local function GetGcdRemaining()
    local start, duration = GetSpellCooldown(61304)
    if not start or start == 0 then
        return 0
    end
    local remain = start + (duration or 0) - GetTime()
    if remain < 0 then
        return 0
    end
    return remain
end

local function MatchStanceBySpellId(spellId)
    if spellId == SPELL_ID.DEFENSIVE_STANCE then
        return "Defensive"
    elseif spellId == SPELL_ID.BERSERKER_STANCE then
        return "Berserker"
    elseif spellId == SPELL_ID.BATTLE_STANCE then
        return "Battle"
    end
    return nil
end

local function MatchStanceByIcon(texture)
    if not texture then
        return nil
    end
    local defTex = GetSpellTexture(SPELL_ID.DEFENSIVE_STANCE)
    local zerkTex = GetSpellTexture(SPELL_ID.BERSERKER_STANCE)
    local battleTex = GetSpellTexture(SPELL_ID.BATTLE_STANCE)
    if defTex and texture == defTex then
        return "Defensive"
    elseif zerkTex and texture == zerkTex then
        return "Berserker"
    elseif battleTex and texture == battleTex then
        return "Battle"
    end
    return nil
end

local function GetStance()
    -- 0) 直接用 spellId 判断当前姿态（跨语言最稳定）。
    if IsCurrentSpell and IsCurrentSpell(SPELL_ID.DEFENSIVE_STANCE) then
        return "Defensive", "current-spell:71"
    end
    if IsCurrentSpell and IsCurrentSpell(SPELL_ID.BERSERKER_STANCE) then
        return "Berserker", "current-spell:2458"
    end
    if IsCurrentSpell and IsCurrentSpell(SPELL_ID.BATTLE_STANCE) then
        return "Battle", "current-spell:2457"
    end

    -- 1) 优先按 spellId 扫描玩家 Buff（规避多语言差异）。
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, auraSpellId = UnitBuff("player", i)
        if not name then
            break
        end
        local byId = MatchStanceBySpellId(auraSpellId)
        if byId then
            return byId, "buff-id:" .. tostring(auraSpellId)
        end
    end

    local activeForm = GetShapeshiftForm and GetShapeshiftForm() or 0
    local forms = GetNumShapeshiftForms() or 0

    -- 2) 逐个扫描姿态栏，优先 active，然后按 spellId/icon/name。
    for i = 1, forms do
        local icon, name, active, _, spellId = GetShapeshiftFormInfo(i)
        local byId = MatchStanceBySpellId(spellId)
        local byIcon = MatchStanceByIcon(icon)
        local byName
        if name == SPELL.DEFENSIVE_STANCE then
            byName = "Defensive"
        elseif name == SPELL.BERSERKER_STANCE then
            byName = "Berserker"
        elseif name == SPELL.BATTLE_STANCE then
            byName = "Battle"
        end
        local guessed = byId or byIcon or byName
        if active and guessed then
            return guessed, "form-active:" .. tostring(i)
        end
    end

    -- 3) 按当前 form index 读取条目并匹配（有些环境 active 不可靠）。
    if activeForm and activeForm > 0 and activeForm <= forms then
        local icon, name, _, _, spellId = GetShapeshiftFormInfo(activeForm)
        local guessed = MatchStanceBySpellId(spellId) or MatchStanceByIcon(icon)
        if not guessed then
            if name == SPELL.DEFENSIVE_STANCE then
                guessed = "Defensive"
            elseif name == SPELL.BERSERKER_STANCE then
                guessed = "Berserker"
            elseif name == SPELL.BATTLE_STANCE then
                guessed = "Battle"
            end
        end
        if guessed then
            return guessed, "form-index:" .. tostring(activeForm)
        end
    end

    -- 4) 最后按经典战士默认槽位映射兜底（1/2/3）。
    if activeForm == 2 then
        return "Defensive", "fallback-index:2"
    elseif activeForm == 3 then
        return "Berserker", "fallback-index:3"
    elseif activeForm == 1 then
        return "Battle", "fallback-index:1"
    end

    return "None", "unknown"
end

local function IsUsable(spellName)
    local usable, noMana = IsUsableSpell(spellName)
    return usable and not noMana
end

local RANK_IDS_BY_TOKEN = {
    [TOKENS.EXECUTE] = EXECUTE_RANK_IDS,
    [TOKENS.HAMSTRING] = HAMSTRING_RANK_IDS,
    [TOKENS.BATTLE_SHOUT] = BATTLE_SHOUT_RANK_IDS,
    [TOKENS.SUNDER_ARMOR] = SUNDER_RANK_IDS,
    [TOKENS.HEROIC_STRIKE] = HS_RANK_IDS,
    [TOKENS.CLEAVE] = CLEAVE_RANK_IDS,
    [TOKENS.MOCKING_BLOW] = MOCKING_BLOW_RANK_IDS,
}

-- 真实 rank 数据驱动的收益锚点（Classic Era）。
-- 说明：这里只做“相对满级收益”归一化，用于低等级/低rank阶段的评分缩放。
local TOKEN_RANK_UTILITY_MODEL = {
    [TOKENS.EXECUTE] = {
        floorScale = 0.35,
        ranks = {
            { id = 5308, value = 125 },
            { id = 20658, value = 325 },
            { id = 20660, value = 450 },
            { id = 20661, value = 600 },
            { id = 20662, value = 800 },
        },
    },
    [TOKENS.HAMSTRING] = {
        floorScale = 0.45,
        ranks = {
            { id = 1715, value = 45 },
            { id = 7372, value = 63 },
            { id = 7373, value = 81 },
        },
    },
    [TOKENS.SUNDER_ARMOR] = {
        floorScale = 0.40,
        ranks = {
            { id = 7386, value = 450 },
            { id = 7405, value = 900 },
            { id = 8380, value = 1350 },
            { id = 11596, value = 1800 },
            { id = 11597, value = 2250 },
        },
    },
    -- 这两个技能在 Classic 里实质为单 rank；保留在模型中用于统一逻辑。
    [TOKENS.BLOODTHIRST] = {
        floorScale = 1,
        ranks = {
            { id = 23881, value = 100 },
        },
    },
    [TOKENS.WHIRLWIND] = {
        floorScale = 1,
        ranks = {
            { id = 1680, value = 100 },
        },
    },
}

local function ResolveHighestKnownSpellId(token)
    local info = ABILITIES[token]
    if not info then
        return nil
    end
    local ranks = RANK_IDS_BY_TOKEN[token]
    if type(ranks) == "table" and #ranks > 0 then
        for i = #ranks, 1, -1 do
            local id = ranks[i]
            if IsPlayerSpell and IsPlayerSpell(id) then
                return id
            end
        end
        return ranks[1]
    end
    return info.id
end

local function IsTokenKnown(token)
    local id = ResolveHighestKnownSpellId(token)
    if not id then
        return nil
    end
    if IsPlayerSpell then
        return IsPlayerSpell(id) and true or false
    end
    return nil
end

local function GetSpellNameByToken(token)
    local id = ResolveHighestKnownSpellId(token)
    if id then
        local name = GetSpellInfo(id)
        if name and name ~= "" then
            return name
        end
    end
    return ABILITIES[token] and ABILITIES[token].name or nil
end

local function GetTokenRankUtilityScale(token)
    local model = TOKEN_RANK_UTILITY_MODEL[token]
    if not model or type(model.ranks) ~= "table" or #model.ranks == 0 then
        return nil
    end

    local maxValue = 0
    local knownValue = nil
    local knownId = nil
    for i = 1, #model.ranks do
        local row = model.ranks[i]
        local value = tonumber(row.value) or 0
        if value > maxValue then
            maxValue = value
        end
        if IsPlayerSpell and IsPlayerSpell(row.id) then
            knownValue = value
            knownId = row.id
        end
    end

    if not knownValue then
        if IsPlayerSpell then
            return 0, 0, maxValue, nil
        end
        knownValue = tonumber(model.ranks[1].value) or 0
        knownId = model.ranks[1].id
    end

    if maxValue <= 0 then
        return 1, knownValue, 1, knownId
    end
    local floorScale = Clamp(tonumber(model.floorScale) or 0.35, 0, 1)
    local scale = Clamp(knownValue / maxValue, floorScale, 1)
    return scale, knownValue, maxValue, knownId
end

local function IsDumpQueuedToken(token)
    if not IsCurrentSpell then
        return false
    end
    if token == TOKENS.HEROIC_STRIKE then
        local hsName = GetSpellNameByToken(TOKENS.HEROIC_STRIKE)
        if hsName and IsCurrentSpell(hsName) then
            return true
        end
        for i = 1, #HS_RANK_IDS do
            if IsCurrentSpell(HS_RANK_IDS[i]) then
                return true
            end
        end
    elseif token == TOKENS.CLEAVE then
        local clName = GetSpellNameByToken(TOKENS.CLEAVE)
        if clName and IsCurrentSpell(clName) then
            return true
        end
        for i = 1, #CLEAVE_RANK_IDS do
            if IsCurrentSpell(CLEAVE_RANK_IDS[i]) then
                return true
            end
        end
    end
    return false
end

local function GetQueuedDumpToken()
    if IsDumpQueuedToken(TOKENS.CLEAVE) then
        return TOKENS.CLEAVE
    end
    if IsDumpQueuedToken(TOKENS.HEROIC_STRIKE) then
        return TOKENS.HEROIC_STRIKE
    end
    return TOKENS.HOLD
end

local function InRangeOrNil(spellName, unit)
    local ok = IsSpellInRange(spellName, unit)
    if ok == nil then
        return true
    end
    return ok == 1
end

local function GetTargetHealthPct()
    if not UnitExists("target") then
        return nil
    end
    local hp = UnitHealth("target") or 0
    local maxHp = UnitHealthMax("target") or 0
    if maxHp <= 0 then
        return nil
    end
    return (hp / maxHp) * 100
end

local function HasUnitBuffBySpellId(unit, spellId)
    if not unit or not spellId then
        return false
    end
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, auraSpellId = UnitBuff(unit, i)
        if not name then
            break
        end
        if auraSpellId == spellId then
            return true
        end
    end
    return false
end

local function BuildSpellIdSet(ids)
    local out = {}
    for i = 1, #(ids or {}) do
        out[ids[i]] = true
    end
    return out
end

local BATTLE_SHOUT_RANK_ID_SET = BuildSpellIdSet(BATTLE_SHOUT_RANK_IDS)

local function GetUnitBuffInfoBySpellIds(unit, spellIdSet)
    if not unit or type(spellIdSet) ~= "table" then
        return false, 0, 0, nil
    end
    local now = GetTime()
    for i = 1, 40 do
        local name, _, _, _, _, v6, v7, v8, v9, v10 = UnitBuff(unit, i)
        if not name then
            break
        end
        local duration = 0
        local expirationTime = 0
        local auraSpellId = nil

        if type(v6) == "number" and type(v7) == "number" then
            duration = v6 or 0
            expirationTime = v7 or 0
            auraSpellId = v10
        elseif type(v6) == "number" and type(v7) == "string" then
            expirationTime = v6 or 0
            auraSpellId = v10
        else
            auraSpellId = v10 or v9 or v8
        end
        if auraSpellId and spellIdSet[auraSpellId] then
            local remaining = 0
            if type(expirationTime) == "number" and expirationTime > 0 then
                remaining = math.max(expirationTime - now, 0)
            end
            return true, remaining, duration or 0, auraSpellId
        end
    end
    return false, 0, 0, nil
end

local function ReadTalentState()
    local state = {
        armsPoints = 0,
        furyPoints = 0,
        protPoints = 0,
        hasBloodthirst = IsPlayerSpell and IsPlayerSpell(23881) or false,
        hasShieldSlam = IsPlayerSpell and IsPlayerSpell(23922) or false,
        hasDeathWish = IsPlayerSpell and IsPlayerSpell(12328) or false,
        hasRecklessness = IsPlayerSpell and IsPlayerSpell(1719) or false,
    }

    if GetNumTalentTabs and GetTalentTabInfo then
        local tabs = GetNumTalentTabs() or 0
        for i = 1, tabs do
            local _, _, points = GetTalentTabInfo(i)
            if i == 1 then
                state.armsPoints = points or 0
            elseif i == 2 then
                state.furyPoints = points or 0
            elseif i == 3 then
                state.protPoints = points or 0
            end
        end
    end
    return state
end

local function ReadEquipmentState()
    local mainLink = GetInventoryItemLink("player", 16)
    local offLink = GetInventoryItemLink("player", 17)
    local trinket1 = GetInventoryItemLink("player", 13)
    local trinket2 = GetInventoryItemLink("player", 14)
    local offEquipLoc = offLink and select(9, GetItemInfo(offLink)) or nil
    local hasShield = offEquipLoc == "INVTYPE_SHIELD"
    local hasOffhandWeapon = offLink ~= nil and (
        offEquipLoc == "INVTYPE_WEAPON"
        or offEquipLoc == "INVTYPE_WEAPONOFFHAND"
    )

    local speedMain, speedOff = UnitAttackSpeed("player")
    local state = {
        hasMainHand = mainLink ~= nil,
        hasOffHand = offLink ~= nil,
        hasOffHandItem = offLink ~= nil,
        hasShield = hasShield,
        hasOffhandWeapon = hasOffhandWeapon,
        dualWieldWeapon = hasOffhandWeapon,
        dualWield = hasOffhandWeapon,
        speedMain = speedMain or 0,
        speedOff = speedOff or 0,
        setPieceMax = 0,
        setCounts = {},
        setDetails = {},
        hasTrinket1 = trinket1 ~= nil,
        hasTrinket2 = trinket2 ~= nil,
    }

    local setCounts = {}
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local setId = select(16, GetItemInfo(link))
            if setId and setId > 0 then
                setCounts[setId] = (setCounts[setId] or 0) + 1
            end
        end
    end
    for _, count in pairs(setCounts) do
        if count > state.setPieceMax then
            state.setPieceMax = count
        end
    end
    state.setCounts = setCounts
    for setId, count in pairs(setCounts) do
        local setName = GetItemSetInfo and select(2, GetItemSetInfo(setId)) or ("set:" .. tostring(setId))
        table.insert(state.setDetails, {
            id = setId,
            name = setName or ("set:" .. tostring(setId)),
            count = count,
        })
    end
    return state
end

local function ReadTrinketState()
    local function slotState(slot)
        local start, duration, enabled = GetInventoryItemCooldown("player", slot)
        if not start then
            return { ready = false, active = false, remain = 0, duration = 0, enabled = false }
        end
        local remain = math.max((start + (duration or 0)) - GetTime(), 0)
        local ready = (enabled == 1) and (remain <= 0.05)
        local active = (duration or 0) > 0 and remain > 0.05
        return { ready = ready, active = active, remain = remain, duration = duration or 0, enabled = enabled == 1 }
    end

    local s13 = slotState(13)
    local s14 = slotState(14)
    return {
        slot13 = s13,
        slot14 = s14,
        anyReady = s13.ready or s14.ready,
        anyActive = s13.active or s14.active,
    }
end

local function ReadBuffState()
    local flurry = HasUnitBuffBySpellId("player", SPELL_ID.FLURRY_BUFF)
    local deathWish = HasUnitBuffBySpellId("player", SPELL_ID.DEATH_WISH_BUFF)
    local reck = HasUnitBuffBySpellId("player", SPELL_ID.RECKLESSNESS_BUFF)
    local bloodrage = HasUnitBuffBySpellId("player", SPELL_ID.BLOODRAGE_BUFF)
    local berserkerRage = HasUnitBuffBySpellId("player", SPELL_ID.BERSERKER_RAGE_BUFF)
    local battleShout, battleShoutRemaining = GetUnitBuffInfoBySpellIds("player", BATTLE_SHOUT_RANK_ID_SET)
    return {
        flurry = flurry,
        deathWish = deathWish,
        recklessness = reck,
        bloodrage = bloodrage,
        berserkerRage = berserkerRage,
        battleShout = battleShout,
        battleShoutRemaining = battleShoutRemaining,
        offensiveBurst = deathWish or reck,
    }
end

local function BuildSetWeightState(equipment)
    local weights = NewWeightBag()
    local active = {}
    local details = (equipment and equipment.setDetails) or {}

    local setBonusProfiles = GetSetBonusProfiles()
    local setNameHints = GetSetNameProfileHints()

    for _, info in ipairs(details) do
        local setId = info.id
        local setName = tostring(info.name or "")
        local pieceCount = info.count or 0
        local profile = setBonusProfiles[setId]

        if not profile then
            for _, hint in ipairs(setNameHints) do
                if setName ~= "" and setName:find(hint.pattern) then
                    profile = { name = setName, pieces = hint.pieces }
                    break
                end
            end
        end

        if profile and profile.pieces then
            local pieceWeight, pieceKey = PickPieceWeights(profile.pieces, pieceCount)
            if pieceWeight then
                AddWeightBag(weights, pieceWeight, 1)
                table.insert(active, string.format("%s[%d/%d]", profile.name or setName, pieceCount, pieceKey))
            end
        end
    end

    return weights, active
end

local function BuildProcWeightState()
    local weights = NewWeightBag()
    local active = {}

    local procProfiles = GetBuffTrinketWeightProfiles()
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, spellId = UnitBuff("player", i)
        if not name then
            break
        end
        local profile = procProfiles[spellId]
        if profile and profile.weights then
            AddWeightBag(weights, profile.weights, 1)
            table.insert(active, string.format("%s(%d)", profile.name or name, spellId or 0))
        end
    end

    return weights, active
end

local function IsInRaidGroup()
    if UnitInRaid then
        return UnitInRaid("player") ~= nil
    end
    if GetNumRaidMembers then
        return (GetNumRaidMembers() or 0) > 0
    end
    return false
end

local function ForEachGroupUnit(callback)
    if type(callback) ~= "function" then
        return
    end
    callback("player")
    for i = 1, 4 do
        local unit = "party" .. tostring(i)
        if UnitExists(unit) and (not UnitIsUnit(unit, "player")) then
            callback(unit)
        end
    end
end

local function IsUnitBattleShoutCandidate(unit)
    if not unit or not UnitExists(unit) then
        return false
    end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then
        return false
    end
    if UnitIsConnected and (not UnitIsConnected(unit)) then
        return false
    end
    return true
end

local function IsUnitBattleShoutRange(unit)
    if not unit or unit == "player" then
        return true
    end
    if UnitInRange then
        local inRange = UnitInRange(unit)
        if inRange ~= nil then
            return inRange and true or false
        end
    end
    if CheckInteractDistance then
        if CheckInteractDistance(unit, 4) or CheckInteractDistance(unit, 1) then
            return true
        end
    end
    return true
end

local function ReadBattleShoutState(cfg)
    local refreshSeconds = (cfg and cfg.battleShoutRefreshSeconds) or 12
    local state = {
        selfActive = false,
        selfRemaining = 0,
        inRangeUnits = 0,
        buffedUnits = 0,
        missingUnits = 0,
        refreshUnits = 0,
        effectUnits = 0,
        threatUnits = 0,
        refreshSeconds = refreshSeconds,
        shouldCast = false,
        selfNeedsCast = false,
    }

    ForEachGroupUnit(function(unit)
        if not IsUnitBattleShoutCandidate(unit) or not IsUnitBattleShoutRange(unit) then
            return
        end
        state.inRangeUnits = state.inRangeUnits + 1
        local active, remaining = GetUnitBuffInfoBySpellIds(unit, BATTLE_SHOUT_RANK_ID_SET)
        if unit == "player" then
            state.selfActive = active
            state.selfRemaining = remaining
        end
        if active then
            state.buffedUnits = state.buffedUnits + 1
        else
            state.missingUnits = state.missingUnits + 1
        end
        if active and remaining <= refreshSeconds then
            state.refreshUnits = state.refreshUnits + 1
        end
        if (not active) or remaining <= refreshSeconds then
            state.effectUnits = state.effectUnits + 1
            state.threatUnits = state.threatUnits + (active and 0.6 or 1.0)
        end
    end)

    state.selfNeedsCast = (not state.selfActive) or ((state.selfRemaining or 0) <= refreshSeconds)
    state.shouldCast = state.effectUnits > 0
    return state
end

local function EstimateTargetTtd(targetHealthAbs, hostileCount)
    if targetHealthAbs <= 0 or not ns.metrics or not ns.metrics.GetActiveFight or not ns.metrics.GetSnapshot then
        return nil, 0, nil
    end
    if not ns.metrics.GetActiveFight() then
        return nil, 0, nil
    end
    local snapshot = ns.metrics.GetSnapshot()
    if type(snapshot) ~= "table" then
        return nil, 0, nil
    end
    local duration = tonumber(snapshot.duration) or 0
    local totalDps = tonumber(snapshot.dps) or 0
    if duration < 2 or totalDps <= 0 then
        return nil, totalDps, snapshot
    end
    local splitFactor = Clamp(tonumber(hostileCount) or 1, 1, 4)
    local targetDps = totalDps / splitFactor
    if targetDps <= 0 then
        return nil, targetDps, snapshot
    end
    return targetHealthAbs / targetDps, targetDps, snapshot
end

-- 前置声明：BuildContext 会提前读取该函数。
local ReadHamstringState

local function BuildContext()
    local cfg = Decision.GetConfig()
    local rage = UnitPower("player", 1) or 0
    local stance, stanceSource = GetStance()
    local mode = stance == "Defensive" and "TPS_SURVIVAL" or "DPS"
    local modeOverride = Decision.GetModeOverride()
    if modeOverride == "tps" then
        mode = "TPS_SURVIVAL"
    elseif modeOverride == "dps" then
        mode = "DPS"
    end
    local horizonMs = Decision.GetHorizonMs()
    local horizonSec = horizonMs / 1000
    local healthPct = (UnitHealthMax("player") or 0) > 0 and ((UnitHealth("player") or 0) / UnitHealthMax("player")) * 100 or 100
    local baseAP, posAP, negAP = UnitAttackPower("player")
    local attackPower = (baseAP or 0) + (posAP or 0) - (negAP or 0)
    local playerLevel = UnitLevel and (UnitLevel("player") or 60) or 60
    local critChance = GetCritChance and (GetCritChance() or 0) or 0
    local hitModifier = GetHitModifier and (GetHitModifier() or 0) or 0
    local talents = ReadTalentState()
    local equipment = ReadEquipmentState()
    local trinket = ReadTrinketState()
    local buffs = ReadBuffState()
    local battleShoutState = ReadBattleShoutState(cfg)
    local hamstringState = ReadHamstringState()
    local threat = ReadThreatState()
    local setWeights, activeSetProfiles = BuildSetWeightState(equipment)
    local procWeights, activeProcProfiles = BuildProcWeightState()
    local combinedWeights = NewWeightBag()
    AddWeightBag(combinedWeights, setWeights, 1)
    AddWeightBag(combinedWeights, procWeights, 1)

    local hostileCount = 0
    if ns.metrics and ns.metrics.GetRecentHostileCount then
        hostileCount = ns.metrics.GetRecentHostileCount(6)
    end
    if hostileCount == 0 and UnitExists("target") and UnitCanAttack("player", "target") then
        hostileCount = 1
    end
    local hsQueueCfg = Decision.GetHsQueueConfig()
    local swing = ns.metrics and ns.metrics.GetSwingState and ns.metrics.GetSwingState(GetTime()) or nil
    local timeToMain = swing and swing.timeToMain or 99
    local queueWindowOpen = timeToMain <= (hsQueueCfg.queueWindowMs / 1000)
    local queuedDumpToken = GetQueuedDumpToken()
    local targetExists = UnitExists("target") and UnitCanAttack("player", "target")
    local inRaidGroup = IsInRaidGroup()
    local targetLevel = targetExists and (UnitLevel("target") or 0) or 0
    local targetClassification = targetExists and (UnitClassification("target") or "normal") or "normal"
    local targetEliteLike = targetLevel < 0
        or targetClassification == "elite"
        or targetClassification == "rareelite"
        or targetClassification == "worldboss"
    local targetBossLike = targetLevel < 0
        or targetClassification == "worldboss"
    local targetHealthAbs = targetExists and (UnitHealth("target") or 0) or 0
    local targetHealthMax = targetExists and (UnitHealthMax("target") or 0) or 0
    local targetTtd, targetDpsRef, fightSnapshot = EstimateTargetTtd(targetHealthAbs, hostileCount)
    local threatUrgency = CalcThreatUrgency(threat)
    local survivalUrgency = CalcSurvivalUrgency(healthPct)
    local tpsThreatBias = CalcTpsThreatBias(threat)

    return {
        now = GetTime(),
        mode = mode,
        stance = stance,
        stanceSource = stanceSource,
        modeOverride = modeOverride,
        horizonMs = horizonMs,
        horizonSec = horizonSec,
        rage = rage,
        attackPower = attackPower,
        playerLevel = playerLevel,
        critChance = critChance,
        hitModifier = hitModifier,
        playerHealthPct = healthPct,
        targetHealthPct = GetTargetHealthPct(),
        targetHealthAbs = targetHealthAbs,
        targetHealthMax = targetHealthMax,
        targetLevel = targetLevel,
        targetClassification = targetClassification,
        targetEliteLike = targetEliteLike,
        targetBossLike = targetBossLike,
        targetExists = targetExists,
        inRaidGroup = inRaidGroup,
        config = cfg,
        estimatedTargetTtd = targetTtd,
        estimatedTargetDps = targetDpsRef,
        fightSnapshot = fightSnapshot,
        hostileCount = hostileCount,
        threat = threat,
        threatUrgency = threatUrgency,
        survivalUrgency = survivalUrgency,
        tpsThreatBias = tpsThreatBias,
        swing = swing,
        queue = {
            queuedDumpToken = queuedDumpToken,
            hsQueued = queuedDumpToken == TOKENS.HEROIC_STRIKE,
            cleaveQueued = queuedDumpToken == TOKENS.CLEAVE,
            queueWindowOpen = queueWindowOpen,
            timeToMain = timeToMain,
            timeToOff = swing and swing.timeToOff or 0,
        },
        inCombat = UnitAffectingCombat("player"),
        talents = talents,
        equipment = equipment,
        trinket = trinket,
        buffs = buffs,
        battleShoutState = battleShoutState,
        hamstringState = hamstringState,
        known = {
            battleShout = IsTokenKnown(TOKENS.BATTLE_SHOUT),
            execute = IsTokenKnown(TOKENS.EXECUTE),
            bloodthirst = IsTokenKnown(TOKENS.BLOODTHIRST),
            whirlwind = IsTokenKnown(TOKENS.WHIRLWIND),
            hamstring = IsTokenKnown(TOKENS.HAMSTRING),
        },
        setWeights = setWeights,
        procWeights = procWeights,
        weights = combinedWeights,
        activeSetProfiles = activeSetProfiles,
        activeProcProfiles = activeProcProfiles,
        gcdRem = GetGcdRemaining(),
        cooldown = {
            br = GetCooldownRemaining(GetSpellNameByToken(TOKENS.BLOODRAGE)),
            bt = GetCooldownRemaining(GetSpellNameByToken(TOKENS.BLOODTHIRST)),
            ww = GetCooldownRemaining(GetSpellNameByToken(TOKENS.WHIRLWIND)),
            ex = GetCooldownRemaining(GetSpellNameByToken(TOKENS.EXECUTE)),
            rev = GetCooldownRemaining(GetSpellNameByToken(TOKENS.REVENGE)),
            sb = GetCooldownRemaining(GetSpellNameByToken(TOKENS.SHIELD_BLOCK)),
            ss = GetCooldownRemaining(GetSpellNameByToken(TOKENS.SHIELD_SLAM)),
            ls = GetCooldownRemaining(GetSpellNameByToken(TOKENS.LAST_STAND)),
            taunt = GetCooldownRemaining(GetSpellNameByToken(TOKENS.TAUNT)),
            mb = GetCooldownRemaining(GetSpellNameByToken(TOKENS.MOCKING_BLOW)),
        },
    }
end

local function EstimateBtDamage(ap)
    -- Classic: Bloodthirst 伤害约等于 AP 的 45%。
    local attackPower = ap or 0
    return math.max(attackPower * 0.45, 0)
end

local function ResolveExecuteSpellId()
    return ResolveHighestKnownSpellId(TOKENS.EXECUTE) or EXECUTE_RANK_IDS[1]
end

local function ParseExecuteModelFromDescription(desc)
    if type(desc) ~= "string" or desc == "" then
        return nil
    end
    local numbers = {}
    for n in desc:gmatch("(%d+)") do
        table.insert(numbers, tonumber(n))
    end
    if #numbers == 0 then
        return nil
    end

    local baseDamage
    local baseIndex = 0
    for i = 1, #numbers do
        if numbers[i] >= 100 then
            baseDamage = numbers[i]
            baseIndex = i
            break
        end
    end

    local perRage
    for i = math.max(baseIndex + 1, 1), #numbers do
        local v = numbers[i]
        if v >= 1 and v <= 40 then
            perRage = v
            break
        end
    end
    if not perRage then
        for i = 1, #numbers do
            local v = numbers[i]
            if v >= 1 and v <= 40 then
                perRage = v
                break
            end
        end
    end

    local maxExtraRage
    for i = #numbers, 1, -1 do
        local v = numbers[i]
        if v >= 5 and v <= 30 then
            maxExtraRage = v
            break
        end
    end

    if not baseDamage then
        baseDamage = 600
    end
    if not perRage then
        perRage = 21
    end
    if not maxExtraRage then
        maxExtraRage = 15
    end

    return {
        baseDamage = Clamp(baseDamage, 50, 5000),
        perRage = Clamp(perRage, 1, 100),
        maxExtraRage = Clamp(maxExtraRage, 5, 50),
    }
end

local function GetExecuteModel()
    if EXECUTE_MODEL_CACHE then
        return EXECUTE_MODEL_CACHE
    end

    local model = {
        baseDamage = 600,
        perRage = 21,
        maxExtraRage = 15,
        source = "fallback-default",
    }

    local spellId = ResolveExecuteSpellId()
    if spellId then
        local desc
        if C_Spell and C_Spell.GetSpellDescription then
            desc = C_Spell.GetSpellDescription(spellId)
        elseif GetSpellDescription then
            desc = GetSpellDescription(spellId)
        end
        local parsed = ParseExecuteModelFromDescription(desc)
        if parsed then
            model.baseDamage = parsed.baseDamage
            model.perRage = parsed.perRage
            model.maxExtraRage = parsed.maxExtraRage
            model.source = "spell-description:" .. tostring(spellId)
        else
            model.source = "fallback-default:" .. tostring(spellId)
        end
    end

    EXECUTE_MODEL_CACHE = model
    return model
end

local function EstimateExecuteDamage(rage)
    -- 自动模型（优先从技能描述解析），仅用于决策排序。
    local model = GetExecuteModel()
    local extraRage = Clamp((rage or 0) - 15, 0, model.maxExtraRage)
    return model.baseDamage + extraRage * model.perRage, extraRage, model
end

local function ReadSunderState()
    local result = {
        stacks = 0,
        remaining = 0,
        hasDebuff = false,
    }
    if not UnitExists("target") then
        return result
    end

    for i = 1, 40 do
        local name, _, count, _, _, expirationTime, _, _, _, spellId = UnitDebuff("target", i)
        if not name then
            break
        end
        if spellId == SPELL_ID.SUNDER_ARMOR or name == ABILITIES[TOKENS.SUNDER_ARMOR].name then
            result.hasDebuff = true
            result.stacks = count or 0
            if expirationTime and expirationTime > 0 then
                result.remaining = math.max(expirationTime - GetTime(), 0)
            end
            return result
        end
    end
    return result
end

ReadHamstringState = function()
    local result = {
        hasDebuff = false,
        remaining = 0,
    }
    if not UnitExists("target") then
        return result
    end
    local hamName = GetSpellNameByToken(TOKENS.HAMSTRING)
    for i = 1, 40 do
        local name, _, _, _, _, expirationTime, _, _, _, spellId = UnitDebuff("target", i)
        if not name then
            break
        end
        if TOKEN_BY_RANK_SPELL_ID[spellId] == TOKENS.HAMSTRING or (hamName and name == hamName) then
            result.hasDebuff = true
            if expirationTime and expirationTime > 0 then
                result.remaining = math.max(expirationTime - GetTime(), 0)
            end
            return result
        end
    end
    return result
end

ReadThreatState = function()
    local info = {
        isTanking = false,
        status = 0,
        scaledPct = 0,
        rawPct = 0,
        value = 0,
    }
    if not UnitExists("target") then
        return info
    end
    local isTanking, status, scaledPct, rawPct, value = UnitDetailedThreatSituation("player", "target")
    info.isTanking = isTanking and true or false
    info.status = status or 0
    info.scaledPct = scaledPct or 0
    info.rawPct = rawPct or 0
    info.value = value or 0
    return info
end

local function GetHamstringObservedWhiteCrit(context)
    local snapshot = context and context.fightSnapshot or nil
    local hitTable = snapshot and snapshot.hitTable or nil
    local observed = hitTable and tonumber(hitTable.whiteCritEff) or nil
    if observed and observed > 0 then
        return Clamp(observed, 0.01, 0.75)
    end
    return nil
end

local function GetHamstringObservedFlurryUptime(context)
    local snapshot = context and context.fightSnapshot or nil
    local rotation = snapshot and snapshot.rotation or nil
    local uptime = rotation and tonumber(rotation.flurryUptimePct) or nil
    if uptime and uptime > 0 then
        return Clamp(uptime, 0, 1)
    end
    return 0
end

local function EstimateHamstringLandedCritChance(context, hamCfg)
    local panelCrit = Clamp((tonumber(context and context.critChance) or 0) / 100, 0.05, 0.75)
    local observedCrit = GetHamstringObservedWhiteCrit(context)
    local critChance = observedCrit and Clamp(panelCrit * 0.55 + observedCrit * 0.45, 0.05, 0.75) or Clamp(panelCrit * 0.92, 0.05, 0.75)
    local landChance = tonumber(hamCfg and hamCfg.yellowLandChance) or 0.90
    local hitBonus = Clamp((tonumber(context and context.hitModifier) or 0) * 0.003, -0.08, 0.06)
    if context and (not context.targetBossLike) then
        landChance = landChance + 0.03
        if context.targetEliteLike then
            landChance = landChance + 0.01
        end
    end
    landChance = Clamp(landChance + hitBonus, 0.55, 0.99)
    return Clamp(critChance * landChance, 0.02, 0.95), landChance, critChance
end

local function EstimateNaturalFlurryProcChance(context, hamCfg)
    local maxEvents = tonumber(hamCfg and hamCfg.naturalProcWindowMaxEvents) or 4
    local lookahead = tonumber(hamCfg and hamCfg.lookaheadSeconds) or 3.2
    local queue = context and context.queue or {}
    local equipment = context and context.equipment or {}
    local pHamCrit, landChance, critChance = EstimateHamstringLandedCritChance(context, hamCfg)
    local whiteCrit = Clamp(critChance, 0.01, 0.95)
    local yellowCrit = Clamp(landChance * math.min(critChance * 1.02, 0.95), 0.01, 0.95)
    local events = {}

    local function pushEvent(probability)
        if #events >= maxEvents then
            return
        end
        probability = Clamp(tonumber(probability) or 0, 0, 0.95)
        if probability > 0 then
            table.insert(events, probability)
        end
    end

    if (tonumber(queue.timeToMain) or math.huge) <= lookahead then
        pushEvent(whiteCrit)
    end
    if equipment.hasOffhandWeapon and (tonumber(queue.timeToOff) or math.huge) <= lookahead then
        pushEvent(whiteCrit)
    end
    if (tonumber(context and context.cooldown and context.cooldown.bt) or math.huge) <= math.min(lookahead, 1.5)
        and (tonumber(context and context.rage) or 0) >= ABILITIES[TOKENS.BLOODTHIRST].rage then
        pushEvent(yellowCrit * 0.95)
    end
    if (tonumber(context and context.cooldown and context.cooldown.ww) or math.huge) <= lookahead
        and (tonumber(context and context.rage) or 0) >= ABILITIES[TOKENS.WHIRLWIND].rage then
        pushEvent(yellowCrit * 0.90)
    end
    if context and context.targetHealthPct and context.targetHealthPct <= 20
        and (tonumber(context.cooldown and context.cooldown.ex) or math.huge) <= math.min(lookahead, 1.0)
        and (tonumber(context.rage) or 0) >= ABILITIES[TOKENS.EXECUTE].rage then
        pushEvent(yellowCrit * 0.85)
    end

    local noProc = 1
    for i = 1, #events do
        noProc = noProc * (1 - events[i])
    end
    local naturalChance = 1 - noProc
    local flurryUptime = GetHamstringObservedFlurryUptime(context)
    if flurryUptime > 0 then
        naturalChance = Clamp(naturalChance + flurryUptime * 0.10, 0, 0.98)
    end
    return naturalChance, events, pHamCrit
end

local function EstimateFlurrySwingValue(context, hamCfg)
    local swing = context and context.swing or {}
    local queue = context and context.queue or {}
    local equipment = context and context.equipment or {}
    local ttd = tonumber(context and context.estimatedTargetTtd) or nil
    local window = (tonumber(hamCfg and hamCfg.lookaheadSeconds) or 3.2) + 1.0
    if ttd and ttd > 0 then
        window = math.min(window, math.max(ttd, 0.5))
    end
    window = Clamp(window, 0.5, 8)

    local nextMain = tonumber(queue.timeToMain) or math.huge
    local nextOff = equipment.hasOffhandWeapon and (tonumber(queue.timeToOff) or math.huge) or math.huge
    local speedMain = math.max(tonumber(swing.speedMain) or 0, 1.2)
    local speedOff = math.max(tonumber(swing.speedOff) or 0, 1.2)
    local value = 0
    local charges = 0

    while charges < 3 do
        local nextEvent = math.min(nextMain, nextOff)
        if nextEvent > window then
            break
        end
        if nextMain <= nextOff then
            value = value + (tonumber(hamCfg and hamCfg.mainSwingValue) or 1.0)
            nextMain = nextMain + speedMain
        else
            value = value + (tonumber(hamCfg and hamCfg.offSwingValue) or 0.65)
            nextOff = nextOff + speedOff
        end
        charges = charges + 1
    end

    if charges <= 0 then
        return 0, 0, window
    end

    local ttlScale = 1
    if ttd and ttd > 0 then
        ttlScale = Clamp(ttd / math.max(tonumber(hamCfg and hamCfg.minTargetTtdSeconds) or 10, 1), 0.35, 1.4)
    end
    return value * ttlScale, charges, window
end

local function CalcHamstringProtectReserve(context, hamCfg)
    local reserve = 0
    if (tonumber(context and context.cooldown and context.cooldown.bt) or math.huge) <= ((tonumber(hamCfg and hamCfg.btProtectMs) or 0) / 1000) then
        reserve = math.max(reserve, ABILITIES[TOKENS.BLOODTHIRST].rage)
    end
    if (tonumber(context and context.cooldown and context.cooldown.ww) or math.huge) <= ((tonumber(hamCfg and hamCfg.wwProtectMs) or 0) / 1000) then
        reserve = math.max(reserve, ABILITIES[TOKENS.WHIRLWIND].rage)
    end
    if context and context.targetHealthPct and context.targetHealthPct <= 20
        and (tonumber(context.cooldown and context.cooldown.ex) or math.huge) <= ((tonumber(hamCfg and hamCfg.exProtectMs) or 0) / 1000) then
        reserve = math.max(reserve, ABILITIES[TOKENS.EXECUTE].rage)
    end
    return reserve
end

local function CalcHamstringEvScore(context, hamCfg)
    if context and context.buffs and context.buffs.flurry then
        return -60, { reason = "Flurry已激活，断筋骗乱舞收益极低" }
    end
    local estTtd = tonumber(context and context.estimatedTargetTtd) or nil
    if estTtd and estTtd > 0 and estTtd <= (tonumber(hamCfg and hamCfg.minTargetTtdSeconds) or 10) then
        return -40, { reason = string.format("预计目标%.1fs内倒地，断筋骗乱舞难以回本", estTtd) }
    end
    if estTtd and estTtd > 0 and estTtd <= math.max((tonumber(hamCfg and hamCfg.minTargetTtdSeconds) or 10) * 2, 20)
        and (tonumber(context and context.rage) or 0) < 30 then
        return -36, { reason = string.format("预计目标%.1fs内结束且怒气不足，优先保主循环资源", estTtd) }
    end
    local naturalChance, _, pHamCrit = EstimateNaturalFlurryProcChance(context, hamCfg)
    local swingValue, chargeCount = EstimateFlurrySwingValue(context, hamCfg)
    if chargeCount <= 0 or swingValue <= 0 then
        return -40, { reason = "未来挥击窗口过短，断筋骗乱舞吃不满3层收益" }
    end
    local deltaProc = Clamp(pHamCrit * (1 - naturalChance), 0, 1)
    local reserve = CalcHamstringProtectReserve(context, hamCfg)
    local rageAfter = (tonumber(context and context.rage) or 0) - ABILITIES[TOKENS.HAMSTRING].rage
    local ragePenalty = math.max(0, reserve - rageAfter) * (tonumber(hamCfg and hamCfg.ragePenaltyScale) or 0.8)
    if context and context.queue and context.queue.queueWindowOpen and (context.equipment and context.equipment.hasOffhandWeapon) and rageAfter < 30 then
        ragePenalty = ragePenalty + 2
    end
    local score = (tonumber(hamCfg and hamCfg.baseBias) or 1)
        + deltaProc * swingValue * (tonumber(hamCfg and hamCfg.evScale) or 18)
        - (tonumber(hamCfg and hamCfg.gcdPenalty) or 1)
        - ragePenalty
    return score, {
        pHamCrit = pHamCrit,
        naturalChance = naturalChance,
        deltaProc = deltaProc,
        swingValue = swingValue,
        chargeCount = chargeCount,
        reserve = reserve,
        ragePenalty = ragePenalty,
    }
end

local function NewEval(token, baseScore)
    return {
        token = token,
        score = baseScore or 0,
        passed = true,
        reasons = {},
    }
end

local function AddReason(eval, delta, text)
    eval.score = eval.score + (delta or 0)
    local mark = delta and (delta >= 0 and "+" or "") .. tostring(math.floor(delta)) or ""
    table.insert(eval.reasons, (mark ~= "" and (mark .. " ") or "") .. text)
end

local function Reject(eval, text)
    eval.passed = false
    AddReason(eval, -200, text)
end

local function ApplyCommonChecks(eval, context, opts)
    if opts.requireTarget and not context.targetExists then
        Reject(eval, "无敌对目标")
        return
    end

    if opts.rangeToken then
        local spellName = GetSpellNameByToken(opts.rangeToken)
        if spellName and not InRangeOrNil(spellName, "target") then
            Reject(eval, "不在技能距离内")
            return
        end
    end

    if opts.usableToken then
        local known = IsTokenKnown(opts.usableToken)
        if known == false then
            Reject(eval, "技能未学习")
            return
        end
        local spellName = GetSpellNameByToken(opts.usableToken)
        if spellName and not IsUsable(spellName) then
            if opts.allowUnusable then
                AddReason(eval, opts.unusablePenalty or -24, opts.unusableReason or "技能当前不可直接施放")
            else
                Reject(eval, "技能不可用")
                return
            end
        end
    end

    if opts.rageCost and context.rage < opts.rageCost then
        Reject(eval, "怒气不足(" .. context.rage .. "/" .. opts.rageCost .. ")")
        return
    end

    if opts.cooldown and opts.cooldown > context.horizonSec then
        Reject(eval, "CD超出窗口(" .. string.format("%.2f", opts.cooldown) .. "s)")
        return
    end

    if opts.predicate and not opts.predicate(context) then
        Reject(eval, opts.predicateReason or "条件不满足")
        return
    end

    if not opts.ignoreGcd then
        if context.gcdRem > context.horizonSec then
            AddReason(eval, -20, "GCD超过预测窗口")
        else
            AddReason(eval, 8, "GCD可在窗口内结束")
        end
    else
        AddReason(eval, 6, "独立于主GCD评估")
    end
end

local function SortEvaluations(list)
    table.sort(list, function(a, b)
        if a.score == b.score then
            return a.token < b.token
        end
        return a.score > b.score
    end)
end

local function CalcSunderValueByTargetHp(targetHpPct, mode)
    -- 将目标血量映射到 [0,1]，血越高代表破甲持续收益期越长。
    local hp = Clamp((targetHpPct or 100) / 100, 0, 1)
    -- 使用二次曲线提升高血量区间的权重，降低低血量破甲倾向。
    local curve = hp * hp

    if mode == "TPS_SURVIVAL" then
        -- 防御姿态更看重稳定仇恨，基线略高，幅度更温和。
        local score = -10 + 22 * curve
        local note = string.format("目标血量%.0f%%，连续收益系数=%.2f(TPS)", hp * 100, curve)
        return score, note
    end

    -- DPS 模式对斩杀前破甲价值敏感，低血量显著降权。
    local score = -24 + 42 * curve
    local note = string.format("目标血量%.0f%%，连续收益系数=%.2f(DPS)", hp * 100, curve)
    return score, note
end

local function IsRaidTrashContext(context)
    return (context and context.inRaidGroup) and (not context.targetBossLike)
end

local function GetShortTtdRejectReason(context, cfg)
    if not context or context.targetBossLike then
        return nil
    end
    local minTtd = (cfg and cfg.sunderMinTtdSeconds) or 9
    local estTtd = tonumber(context.estimatedTargetTtd)
    if estTtd and estTtd > 0 and estTtd <= minTtd then
        return string.format("预计单人%.1fs内可击杀，破甲收益不划算", estTtd)
    end
    return nil
end

local function CalcSunderValue(context, mode, cfg)
    local estTtd = context and tonumber(context.estimatedTargetTtd) or nil
    if estTtd and estTtd > 0 then
        local minTtd = math.max((cfg and cfg.sunderMinTtdSeconds) or 9, 1)
        local curve = Clamp((estTtd - minTtd) / (minTtd * 3), 0, 1)
        if mode == "TPS_SURVIVAL" then
            local score = -10 + 24 * curve
            local note = string.format("预计单人击杀时间%.1fs，持续收益系数=%.2f(TPS)", estTtd, curve)
            return score, note
        end
        local score = -24 + 42 * curve
        local note = string.format("预计单人击杀时间%.1fs，持续收益系数=%.2f(DPS)", estTtd, curve)
        return score, note
    end
    return CalcSunderValueByTargetHp(context and context.targetHealthPct or nil, mode)
end

local function IsBattleShoutRefreshWindow(shoutState)
    return shoutState and shoutState.effectUnits and shoutState.effectUnits > 0
end

local function BuildBattleShoutEval(context, cfg, mode, threat)
    local shoutCfg = cfg or context.config or Decision.GetConfig()
    local shoutState = context.battleShoutState or ReadBattleShoutState(shoutCfg)
    local shout = NewEval(TOKENS.BATTLE_SHOUT, mode == "TPS_SURVIVAL" and 64 or 40)
    local oocMinRage = math.max(ABILITIES[TOKENS.BATTLE_SHOUT].rage, shoutCfg.battleShoutOocMinRage or 10)
    local needsCast = mode == "TPS_SURVIVAL"
        and IsBattleShoutRefreshWindow(shoutState)
        or (shoutState and shoutState.selfNeedsCast)
    ApplyCommonChecks(shout, context, {
        requireTarget = false,
        usableToken = TOKENS.BATTLE_SHOUT,
        rageCost = ABILITIES[TOKENS.BATTLE_SHOUT].rage,
        cooldown = 0,
        predicate = function(ctx)
            if not needsCast then
                return false
            end
            if ctx.inCombat and not ctx.targetExists then
                return false
            end
            if not ctx.inCombat then
                return ctx.rage >= oocMinRage
            end
            return true
        end,
        predicateReason = context.inCombat and "Battle Shout 当前无需补/续" or "脱战下 Battle Shout 不值得现在补",
    })
    if not shout.passed then
        return shout
    end

    if not context.inCombat then
        AddReason(shout, 18, "脱战窗口补 Battle Shout")
        if not shoutState.selfActive then
            AddReason(shout, 12, "自身未覆盖 Battle Shout")
        else
            AddReason(shout, 8, "Battle Shout 即将到期(" .. string.format("%.1f", shoutState.selfRemaining or 0) .. "s)")
        end
        if shoutState.effectUnits > 1 then
            AddReason(shout, math.floor((shoutState.effectUnits - 1) * 3), "顺手补到附近队友")
        end
        return shout
    end

    if mode == "DPS" then
        local sunderState = ReadSunderState()
        local sunderDuty = NormalizeSunderDutyMode(shoutCfg.sunderDutyMode)
        local sunderStackUrgent = false
        if sunderDuty ~= "external_armor" and (context.targetBossLike or IsRaidTrashContext(context)) then
            local targetStacks = shoutCfg.sunderTargetStacks or 5
            local stacks = sunderState and sunderState.stacks or 0
            if sunderDuty == "maintain_only" then
                sunderStackUrgent = stacks > 0 and stacks < targetStacks
            else
                sunderStackUrgent = stacks < targetStacks
            end
        end
        if sunderStackUrgent then
            Reject(shout, "DPS当前应先承担破甲补层，再补 Battle Shout")
            return shout
        end

        local protect = false
        local rageCost = ABILITIES[TOKENS.BATTLE_SHOUT].rage
        if context.cooldown.bt <= 0.45 and context.rage < (ABILITIES[TOKENS.BLOODTHIRST].rage + rageCost) then
            protect = true
        end
        if context.cooldown.ww <= 0.55 and context.rage < (ABILITIES[TOKENS.WHIRLWIND].rage + rageCost) then
            protect = true
        end
        if context.targetHealthPct and context.targetHealthPct <= 20 and context.cooldown.ex <= 0.35
            and context.rage < (ABILITIES[TOKENS.EXECUTE].rage + rageCost) then
            protect = true
        end
        if protect then
            Reject(shout, "主循环保护窗内，Battle Shout 让位 BT/WW/EX")
            return shout
        end

        AddReason(shout, 10, "Battle Shout 进入补/续窗口")
        if not shoutState.selfActive then
            AddReason(shout, 12, "自身未覆盖 Battle Shout")
        else
            AddReason(shout, 8, "Battle Shout 即将到期(" .. string.format("%.1f", shoutState.selfRemaining or 0) .. "s)")
        end
        if shoutState.effectUnits > 1 then
            AddReason(shout, math.floor((shoutState.effectUnits - 1) * 4), "兼顾队友覆盖收益")
        end
        if context.targetBossLike then
            AddReason(shout, 4, "Boss战中长期收益更稳定")
        end
        if context.targetHealthPct and context.targetHealthPct <= 20 then
            AddReason(shout, -10, "斩杀期优先直接伤害")
        end
        if context.trinket and context.trinket.anyActive then
            AddReason(shout, -4, "爆发窗口优先直接伤害技能")
        end
        if context.weights and context.weights.dps and context.weights.dps > 0 then
            AddReason(shout, math.floor(context.weights.dps * 0.25), "白名单权重: 团队Buff收益")
        end
        return shout
    end

    local curThreat = threat or context.threat or ReadThreatState()
    AddReason(shout, 8, "Battle Shout 提供近似 AoE 仇恨")
    AddReason(shout, math.floor((shoutState.threatUnits or 0) * 12), "按受益单位数估算 Battle Shout 仇恨")
    if curThreat.status <= 1 or curThreat.scaledPct < 90 then
        AddReason(shout, 6, "仇恨未稳时 shout threat 更有价值")
    end
    if context.threatUrgency and context.threatUrgency > 0 then
        AddReason(shout, math.floor(context.threatUrgency * 0.35), "威胁紧迫度抬高 shout 价值")
    end
    if shoutState.effectUnits <= 1 then
        AddReason(shout, -8, "仅覆盖很少目标，仇恨收益有限")
    end
    if context.cooldown.ss <= context.horizonSec and context.rage < (ABILITIES[TOKENS.SHIELD_SLAM].rage + ABILITIES[TOKENS.BATTLE_SHOUT].rage) then
        AddReason(shout, -8, "盾猛窗口将到，Battle Shout 略让位")
    end
    if context.cooldown.rev <= context.horizonSec and context.rage < (ABILITIES[TOKENS.REVENGE].rage + ABILITIES[TOKENS.BATTLE_SHOUT].rage) then
        AddReason(shout, -4, "复仇窗口将到，保留怒气更稳")
    end
    if context.targetBossLike and context.battleShoutState and context.battleShoutState.selfActive then
        AddReason(shout, 3, "Boss战中可顺手续上 Battle Shout")
    end
    if context.weights and context.weights.threat and context.weights.threat > 0 then
        AddReason(shout, math.floor(context.weights.threat * 0.2), "白名单权重: 仇恨")
    end
    return shout
end

local function ApplyDpsSunderDuty(eval, context, cfg, sunderState)
    local duty = NormalizeSunderDutyMode(cfg and cfg.sunderDutyMode)
    local stacks = sunderState and sunderState.stacks or 0
    local remaining = sunderState and sunderState.remaining or 0
    local targetStacks = cfg.sunderTargetStacks or 5
    local missingStacks = math.max(targetStacks - stacks, 0)
    local isRaidTrash = IsRaidTrashContext(context)
    local shortTtdReason = GetShortTtdRejectReason(context, cfg)

    if duty == "external_armor" then
        Reject(eval, "职责=external_armor，团队已有外部减甲职责")
        return
    end

    if shortTtdReason then
        Reject(eval, shortTtdReason)
        return
    end

    if duty == "maintain_only" and stacks <= 0 then
        Reject(eval, "职责=maintain_only，不负责抢首层")
        return
    end

    if duty == "self_stack" and (not context.targetBossLike) and (not context.estimatedTargetTtd)
        and context.targetHealthAbs <= cfg.sunderHpThreshold then
        Reject(eval, "职责=self_stack 且目标HP低于阈值(" .. cfg.sunderHpThreshold .. ")")
        return
    end

    if context.targetBossLike then
        if stacks < targetStacks then
            AddReason(eval, 24 + missingStacks * 2, "Boss战由 DPS 负责补满5层破甲")
        else
            Reject(eval, "Boss战5层后刷新交给 tank")
        end
        return
    end

    if isRaidTrash then
        if stacks < targetStacks then
            AddReason(eval, 18 + missingStacks * 2, "团本小怪由 DPS 起手补满5层")
        else
            Reject(eval, "团本小怪起手满层后不再由 DPS 刷新")
        end
        return
    end

    if duty == "maintain_only" then
        if (not context.estimatedTargetTtd) and context.targetHealthAbs <= cfg.sunderHpThreshold then
            AddReason(eval, -8, "目标剩余血量较低，仅保留低强度维持价值")
        end
        if stacks < targetStacks then
            AddReason(eval, 12 + missingStacks * 2, "职责=maintain_only，已有破甲后继续补层")
        elseif remaining < cfg.sunderRefreshSeconds then
            AddReason(eval, 14, "职责=maintain_only，负责维持已有破甲")
        else
            Reject(eval, "职责=maintain_only，当前无需补层/刷新")
        end
        return
    end

    if stacks < targetStacks then
        AddReason(
            eval,
            18 + missingStacks * 2,
            "职责=self_stack，破甲层数不足(" .. stacks .. "/" .. targetStacks .. ")"
        )
    elseif stacks == targetStacks then
        if remaining < cfg.sunderRefreshSeconds then
            AddReason(eval, 12, targetStacks .. "层且剩余<" .. cfg.sunderRefreshSeconds .. "s，建议刷新")
        else
            Reject(eval, targetStacks .. "层且剩余>=" .. cfg.sunderRefreshSeconds .. "s，无需补破甲")
        end
    else
        AddReason(eval, 4, "破甲状态未知，保守小幅加分")
    end
end

local function ApplyTpsSunderDuty(eval, context, cfg, sunderState)
    local duty = NormalizeSunderDutyMode(cfg and cfg.sunderDutyMode)
    local stacks = sunderState and sunderState.stacks or 0
    local remaining = sunderState and sunderState.remaining or 0
    local targetStacks = cfg.sunderTargetStacks or 5
    local missingStacks = math.max(targetStacks - stacks, 0)
    local isRaidTrash = IsRaidTrashContext(context)
    local shortTtdReason = GetShortTtdRejectReason(context, cfg)
    local threat = (context and context.threat) or { status = 0, scaledPct = 0 }

    if shortTtdReason then
        Reject(eval, shortTtdReason)
        return
    end

    if duty == "self_stack" then
        if context.targetBossLike then
            if stacks < targetStacks then
                AddReason(eval, -16, "Boss战补层职责交给 DPS")
            elseif remaining < cfg.sunderRefreshSeconds then
                AddReason(eval, 14, "Boss破甲将到期，由 tank 择机刷新")
                if remaining <= math.max(cfg.sunderRefreshSeconds * 0.4, 2.5) then
                    AddReason(eval, 8, "接近掉层，刷新优先级抬高")
                end
                if threat.status >= 2 and threat.scaledPct >= 95 then
                    AddReason(eval, 12, "仇恨稳定，适合用当前GCD刷新破甲")
                else
                    AddReason(eval, -8, "仇恨未完全站稳，刷新应再等等")
                end
                if context.cooldown.ss > context.horizonSec and context.cooldown.rev > context.horizonSec then
                    AddReason(eval, 6, "主威胁技能暂不在窗口，当前补刷新损失更小")
                else
                    AddReason(eval, -4, "高优先仇恨技能就绪，稍后刷新更优")
                end
            else
                Reject(eval, "Boss破甲刷新时机未到")
            end
            return
        end

        if isRaidTrash then
            if stacks < targetStacks then
                AddReason(eval, -10, "团本小怪起手补层主要由 DPS 负责")
            else
                AddReason(eval, -8, "团本小怪满层后通常不再由 tank 刷新")
            end
            return
        end

        if stacks < targetStacks then
            AddReason(
                eval,
                12 + missingStacks,
                "职责=self_stack，优先补满破甲层数"
            )
        elseif remaining < cfg.sunderRefreshSeconds then
            AddReason(eval, 8, "职责=self_stack，破甲将到期(<" .. cfg.sunderRefreshSeconds .. "s)，刷新维持TPS")
        else
            AddReason(eval, -4, "职责=self_stack，但破甲层数与持续时间充足")
        end
        return
    end

    if duty == "maintain_only" then
        if context.targetBossLike then
            if stacks <= 0 then
                AddReason(eval, -18, "Boss补层由 DPS 负责，tank 不抢首层")
            elseif stacks < targetStacks then
                AddReason(eval, -8 + missingStacks, "Boss补层阶段不建议由 tank 继续叠层")
            elseif remaining < cfg.sunderRefreshSeconds then
                AddReason(eval, 12, "Boss5层将到期，由 tank 负责维持刷新")
            else
                AddReason(eval, -8, "Boss刷新时机未到")
            end
            return
        end

        if isRaidTrash and stacks >= targetStacks then
            AddReason(eval, -8, "团本小怪满层后通常不再由 tank 刷新")
            return
        end

        if stacks <= 0 then
            AddReason(eval, -18, "职责=maintain_only，不主动抢首层")
        elseif stacks < targetStacks then
            AddReason(eval, 8 + missingStacks, "职责=maintain_only，跟进补已有破甲层")
        elseif remaining < cfg.sunderRefreshSeconds then
            AddReason(eval, 10, "职责=maintain_only，负责维持已有破甲")
        else
            AddReason(eval, -6, "职责=maintain_only，当前无需占用主GCD")
        end
        return
    end

    AddReason(eval, -20, "职责=external_armor，Sunder 仅作低优先级仇恨填充")
    if stacks <= 0 then
        AddReason(eval, -8, "当前不负责起手叠甲")
    elseif remaining < cfg.sunderRefreshSeconds then
        AddReason(eval, 2, "已有减甲存在，但通常由他人维持")
    else
        AddReason(eval, -4, "减甲职责外置，优先其他仇恨技能")
    end
end

local function ApplyLevelUtilityScale(eval, context, token)
    if not eval or not eval.passed then
        return
    end
    local lvl = tonumber(context and context.playerLevel) or 60
    if lvl >= 60 then
        return
    end
    local known = IsTokenKnown(token)
    if known == false then
        Reject(eval, "技能未学习")
        return
    end
    local scale, rankValue, maxRankValue = GetTokenRankUtilityScale(token)
    if not scale then
        scale = Clamp(0.5 + (lvl / 60) * 0.5, 0.5, 1)
    end
    local delta = math.floor(eval.score * (scale - 1))
    if delta ~= 0 then
        if rankValue and maxRankValue and maxRankValue > 0 then
            AddReason(
                eval,
                delta,
                "真实技能收益缩放(rank=" .. tostring(math.floor(rankValue + 0.5))
                    .. "/" .. tostring(math.floor(maxRankValue + 0.5))
                    .. ",Lv" .. tostring(lvl)
                    .. ",x" .. string.format("%.2f", scale) .. ")"
            )
        else
            AddReason(eval, delta, "等级收益缩放(Lv" .. tostring(lvl) .. ",x" .. string.format("%.2f", scale) .. ")")
        end
    end
end

local function BuildDpsEvaluations(context)
    local cfg = Decision.GetConfig()
    local hamCfg = Decision.GetHamstringConfig()
    local w = context.weights or NewWeightBag()
    local list = {}
    local threat = context.threat or ReadThreatState()
    local dpsAggressiveBonus = (threat.scaledPct > 95) and GetPolicyParam("dps_threat_aggressive_bonus", 3.0) or 0

    local ex = NewEval(TOKENS.EXECUTE, 95)
    ApplyCommonChecks(ex, context, {
        requireTarget = true,
        usableToken = TOKENS.EXECUTE,
        rangeToken = TOKENS.EXECUTE,
        rageCost = ABILITIES[TOKENS.EXECUTE].rage,
        cooldown = context.cooldown.ex,
        predicate = function(ctx)
            return ctx.targetHealthPct and ctx.targetHealthPct <= 20
        end,
        predicateReason = "目标不在斩杀阶段",
    })
    if ex.passed then
        AddReason(ex, 30, "斩杀阶段优先级最高")
        if w.execute ~= 0 then
            AddReason(ex, w.execute, "白名单权重: Execute")
        end
        if w.dps ~= 0 then
            AddReason(ex, math.floor(w.dps * 0.4), "白名单权重: DPS倾向")
        end
        if dpsAggressiveBonus > 0 then
            AddReason(ex, dpsAggressiveBonus, "仇恨余量较高，可更激进压缩输出空窗")
        end
    end
    table.insert(list, ex)

    local bt = NewEval(TOKENS.BLOODTHIRST, 82)
    ApplyCommonChecks(bt, context, {
        requireTarget = true,
        usableToken = TOKENS.BLOODTHIRST,
        rangeToken = TOKENS.BLOODTHIRST,
        rageCost = ABILITIES[TOKENS.BLOODTHIRST].rage,
        cooldown = context.cooldown.bt,
    })
    if bt.passed then
        AddReason(bt, math.min(20, math.floor((context.rage - 30) / 3)), "怒气满足主循环")
        if context.talents and context.talents.hasBloodthirst then
            AddReason(bt, 6, "天赋已点出 Bloodthirst")
        end
        if context.buffs and context.buffs.flurry then
            AddReason(bt, 4, "Flurry触发中，主循环收益提升")
        end
        if context.buffs and context.buffs.offensiveBurst then
            AddReason(bt, 6, "爆发Buff窗口，优先高收益技能")
        end
        if w.bloodthirst ~= 0 then
            AddReason(bt, w.bloodthirst, "白名单权重: Bloodthirst")
        end
        if w.ap > 0 then
            AddReason(bt, math.floor(w.ap / 120), "白名单权重: AP加成")
        end
        if dpsAggressiveBonus > 0 then
            AddReason(bt, dpsAggressiveBonus, "仇恨余量较高，可更积极使用主循环")
        end
    end
    table.insert(list, bt)

    -- 斩杀阶段下，按当前 AP 与怒气动态比较 BT vs Execute 的瞬时收益。
    -- 这样高 AP/低额外怒气场景下，BT 有机会超过 Execute。
    if context.targetHealthPct and context.targetHealthPct <= 20 and ex.passed and bt.passed then
        local btDamage = EstimateBtDamage(context.attackPower)
        local exDamage, exExtraRage, exModel = EstimateExecuteDamage(context.rage)
        local ratio = exDamage > 0 and (btDamage / exDamage) or 0
        local detail = string.format(
            "AP=%d 估算BT=%.0f vs EX=%.0f(额外怒气=%d,模型=%s:b%.0f+r*%.0f)",
            context.attackPower or 0,
            btDamage,
            exDamage,
            exExtraRage,
            exModel and exModel.source or "unknown",
            exModel and exModel.baseDamage or 0,
            exModel and exModel.perRage or 0
        )

        if ratio >= 1.08 then
            AddReason(bt, 22, "高AP收益: " .. detail)
            AddReason(ex, -18, "斩杀对比被 BT 反超: " .. detail)
        elseif ratio <= 0.92 then
            AddReason(ex, 14, "斩杀收益更高: " .. detail)
            AddReason(bt, -8, "当前更适合 Execute: " .. detail)
        else
            AddReason(ex, 4, "BT/EX收益接近，保留斩杀倾向: " .. detail)
            AddReason(bt, 4, "BT/EX收益接近，可按循环择优: " .. detail)
        end
    end

    local ww = NewEval(TOKENS.WHIRLWIND, 74)
    ApplyCommonChecks(ww, context, {
        requireTarget = true,
        usableToken = TOKENS.WHIRLWIND,
        rangeToken = TOKENS.WHIRLWIND,
        rageCost = ABILITIES[TOKENS.WHIRLWIND].rage,
        cooldown = context.cooldown.ww,
    })
    if ww.passed and context.hostileCount >= 2 then
        AddReason(ww, 18, "多目标环境增益")
    end
    if ww.passed then
        if context.hostileCount <= 1 then
            AddReason(ww, -12, "单体下优先保证 Bloodthirst")
        elseif context.hostileCount >= 3 then
            AddReason(ww, 10, "3+目标时顺劈价值显著提升")
        end
        if context.buffs and context.buffs.offensiveBurst then
            AddReason(ww, 6, "爆发Buff窗口，顺劈收益增强")
        end
        if context.equipment and context.equipment.setPieceMax >= 2 then
            AddReason(ww, 3, "检测到套装环境(>=2件)")
        end
        if w.whirlwind ~= 0 then
            AddReason(ww, w.whirlwind, "白名单权重: Whirlwind")
        end
        if w.haste > 0 then
            AddReason(ww, math.floor(w.haste / 8), "白名单权重: 急速环境")
        end
        if dpsAggressiveBonus > 0 then
            AddReason(ww, dpsAggressiveBonus, "仇恨余量较高，可更积极打出顺劈窗口")
        end
    end
    table.insert(list, ww)

    local sunder = NewEval(TOKENS.SUNDER_ARMOR, 32)
    ApplyCommonChecks(sunder, context, {
        requireTarget = true,
        usableToken = TOKENS.SUNDER_ARMOR,
        rangeToken = TOKENS.SUNDER_ARMOR,
        rageCost = ABILITIES[TOKENS.SUNDER_ARMOR].rage,
        cooldown = 0,
    })
    if sunder.passed then
        local sunderState = ReadSunderState()
        ApplyDpsSunderDuty(sunder, context, cfg, sunderState)
    end
    if sunder.passed then
        local delta, note = CalcSunderValue(context, context.mode, cfg)
        AddReason(sunder, delta, note)
        AddReason(sunder, 3, "可作为填充GCD")
        if context.trinket and context.trinket.anyActive then
            AddReason(sunder, -2, "饰品爆发中，优先直接伤害技能")
        end
        if w.sunder ~= 0 then
            AddReason(sunder, w.sunder, "白名单权重: Sunder")
        end
    end
    table.insert(list, sunder)

    local shout = BuildBattleShoutEval(context, cfg, "DPS", threat)
    if shout.passed and context.weights and context.weights.ap > 0 then
        AddReason(shout, math.floor(context.weights.ap / 180), "白名单权重: AP团队收益")
    end
    table.insert(list, shout)

    local ham = NewEval(TOKENS.HAMSTRING, 28)
    ApplyCommonChecks(ham, context, {
        requireTarget = true,
        usableToken = TOKENS.HAMSTRING,
        rangeToken = TOKENS.HAMSTRING,
        rageCost = ABILITIES[TOKENS.HAMSTRING].rage,
        cooldown = 0,
        predicate = function(ctx)
            if not hamCfg.enabled then
                return false
            end
            if hamCfg.singleTargetOnly and (ctx.hostileCount or 0) > 1 then
                return false
            end
            if (not hamCfg.allowExecutePhase) and ctx.targetHealthPct and ctx.targetHealthPct <= 20 then
                return false
            end
            return true
        end,
        predicateReason = "断筋策略未启用/场景不适配",
    })
    if ham.passed then
        local hs = context.hamstringState or { hasDebuff = false, remaining = 0 }
        local protected = false
        if context.cooldown.bt <= (hamCfg.btProtectMs / 1000) and context.rage < (ABILITIES[TOKENS.BLOODTHIRST].rage + hamCfg.rageSafetyReserve) then
            protected = true
        end
        if context.cooldown.ww <= (hamCfg.wwProtectMs / 1000) and context.rage < (ABILITIES[TOKENS.WHIRLWIND].rage + hamCfg.rageSafetyReserve) then
            protected = true
        end
        if context.targetHealthPct and context.targetHealthPct <= 20 and context.cooldown.ex <= (hamCfg.exProtectMs / 1000)
            and context.rage < (ABILITIES[TOKENS.EXECUTE].rage + hamCfg.rageSafetyReserve) then
            protected = true
        end

        if protected then
            Reject(ham, "主循环保护窗内，断筋让位 BT/WW/EX")
        elseif hamCfg.mode == "legacy" then
            if (not hs.hasDebuff) then
                AddReason(ham, 12, "目标无断筋，短窗补断筋")
            elseif hs.remaining <= hamCfg.refreshSeconds then
                AddReason(ham, 8, "断筋即将到期(" .. string.format("%.1f", hs.remaining) .. "s)")
            else
                Reject(ham, "断筋剩余充足(" .. string.format("%.1f", hs.remaining) .. "s)")
            end
            if ham.passed and context.buffs and (not context.buffs.flurry) then
                AddReason(ham, hamCfg.flurryBaitBonus, "尝试骗乱舞窗口")
            end
            if ham.passed and w.hamstring and w.hamstring ~= 0 then
                AddReason(ham, w.hamstring, "白名单权重: Hamstring")
            end
        else
            local evScore, detail = CalcHamstringEvScore(context, hamCfg)
            if detail and detail.reason then
                Reject(ham, detail.reason)
            elseif evScore < hamCfg.minEvScore then
                Reject(ham, string.format(
                    "骗乱舞EV不足(%.1f<%.1f, P暴击=%.2f, 自然=%.2f, 挥击值=%.2f)",
                    evScore,
                    hamCfg.minEvScore,
                    detail and detail.pHamCrit or 0,
                    detail and detail.naturalChance or 0,
                    detail and detail.swingValue or 0
                ))
            else
                AddReason(ham, evScore, string.format(
                    "骗乱舞EV=%.1f (P暴击=%.2f, 自然=%.2f, Δ=%.2f, 挥击值=%.2f)",
                    evScore,
                    detail and detail.pHamCrit or 0,
                    detail and detail.naturalChance or 0,
                    detail and detail.deltaProc or 0,
                    detail and detail.swingValue or 0
                ))
                if hamCfg.keepDebuffBias ~= 0 then
                    if (not hs.hasDebuff) then
                        AddReason(ham, hamCfg.keepDebuffBias, "功能性附带收益: 目标无断筋")
                    elseif hs.remaining <= hamCfg.refreshSeconds then
                        AddReason(ham, hamCfg.keepDebuffBias * 0.5, "功能性附带收益: 断筋即将到期")
                    end
                end
                if w.hamstring and w.hamstring ~= 0 then
                    AddReason(ham, w.hamstring, "白名单权重: Hamstring")
                end
            end
        end
    end
    table.insert(list, ham)

    ApplyLevelUtilityScale(ex, context, TOKENS.EXECUTE)
    ApplyLevelUtilityScale(bt, context, TOKENS.BLOODTHIRST)
    ApplyLevelUtilityScale(ww, context, TOKENS.WHIRLWIND)
    ApplyLevelUtilityScale(shout, context, TOKENS.BATTLE_SHOUT)
    ApplyLevelUtilityScale(sunder, context, TOKENS.SUNDER_ARMOR)
    ApplyLevelUtilityScale(ham, context, TOKENS.HAMSTRING)

    local wait = NewEval(TOKENS.WAIT, 5)
    if context.targetExists then
        AddReason(wait, 1, "等待白字与怒气")
        if w.dps > 8 or w.execute > 5 then
            AddReason(wait, -6, "白名单提示当前窗口应更积极输出")
        end
    else
        AddReason(wait, 0, "暂无有效目标")
    end
    table.insert(list, wait)

    SortEvaluations(list)
    return list
end

local function BuildTpsEvaluations(context)
    local cfg = Decision.GetConfig()
    local w = context.weights or NewWeightBag()
    local list = {}
    local threat = context.threat or ReadThreatState()
    local sunderState = ReadSunderState()
    local threatUrgency = context.threatUrgency or CalcThreatUrgency(threat)
    local survivalUrgency = context.survivalUrgency or CalcSurvivalUrgency(context.playerHealthPct)
    local tpsThreatBias = context.tpsThreatBias or CalcTpsThreatBias(threat)
    local tauntUrgencyCoeff = GetPolicyParam("taunt_urgency_coeff", 2.2)
    local revengeUrgencyCoeff = GetPolicyParam("revenge_urgency_coeff", 1.2)
    local shieldSlamUrgencyCoeff = GetPolicyParam("shield_slam_urgency_coeff", 1.4)
    local bloodthirstUrgencyCoeff = GetPolicyParam("bloodthirst_tps_urgency_coeff", 0.6)
    local lastStandSurvivalCoeff = GetPolicyParam("last_stand_survival_coeff", 1.7)

    local ls = NewEval(TOKENS.LAST_STAND, 120)
    ApplyCommonChecks(ls, context, {
        requireTarget = false,
        usableToken = TOKENS.LAST_STAND,
        cooldown = context.cooldown.ls,
        ignoreGcd = true,
        predicate = function(ctx)
            return ctx.inCombat and ctx.playerHealthPct <= 30
        end,
        predicateReason = "血量安全，无需Last Stand",
    })
    if ls.passed then
        AddReason(ls, 35, "生存优先")
        AddReason(ls, math.floor((30 - context.playerHealthPct) * 1.2), "血量越低越应急")
        if survivalUrgency > 0 then
            AddReason(ls, math.floor(survivalUrgency * lastStandSurvivalCoeff), "生存紧迫度驱动 Last Stand")
        end
        if w.survival ~= 0 then
            AddReason(ls, w.survival, "白名单权重: 生存")
        end
    end
    table.insert(list, ls)

    local taunt = NewEval(TOKENS.TAUNT, 112)
    ApplyCommonChecks(taunt, context, {
        requireTarget = true,
        usableToken = TOKENS.TAUNT,
        rangeToken = TOKENS.TAUNT,
        cooldown = context.cooldown.taunt,
        predicate = function()
            return (not threat.isTanking) or threat.status <= 1
        end,
        predicateReason = "仇恨已稳定领先，无需嘲讽",
    })
    if taunt.passed then
        AddReason(taunt, 32, "目标仇恨不稳，立即抢回")
        if threat.status <= 0 or threat.scaledPct < 80 then
            AddReason(taunt, 28, "明显丢仇恨，Taunt 进入最高优先级")
        end
        AddReason(taunt, 14, "真嘲讽优先于 Mocking Blow 兜底")
        AddReason(
            taunt,
            math.floor(threatUrgency * (0.35 * tauntUrgencyCoeff)),
            "当前威胁百分比偏低"
        )
        if w.threat ~= 0 then
            AddReason(taunt, math.floor(w.threat * 0.4), "白名单权重: 仇恨")
        end
    end
    table.insert(list, taunt)

    local mb = NewEval(TOKENS.MOCKING_BLOW, 94)
    ApplyCommonChecks(mb, context, {
        requireTarget = true,
        usableToken = TOKENS.MOCKING_BLOW,
        rangeToken = TOKENS.MOCKING_BLOW,
        rageCost = ABILITIES[TOKENS.MOCKING_BLOW].rage,
        cooldown = context.cooldown.mb,
        allowUnusable = true,
        unusablePenalty = -16,
        unusableReason = "当前需切战斗姿态后施放",
        predicate = function(ctx)
            local curThreat = ctx.threat or threat
            return (not curThreat.isTanking) or curThreat.status <= 1 or curThreat.scaledPct < 90
        end,
        predicateReason = "仇恨已稳定领先，无需 Mocking Blow 兜底",
    })
    if mb.passed then
        AddReason(mb, 10, "Taunt 兜底动作")
        if context.cooldown.taunt > context.horizonSec then
            AddReason(mb, 18, "Taunt 不在窗口内，需用 Mocking Blow 抢回节奏")
        else
            AddReason(mb, -36, "Taunt 可用时优先真嘲讽")
        end
        if threat.status <= 0 or threat.scaledPct < 80 then
            AddReason(mb, context.cooldown.taunt > context.horizonSec and 14 or 4, "仇恨明显落后，需要立刻补救")
        end
        AddReason(mb, math.floor(threatUrgency * 0.8), "威胁紧迫度提升兜底价值")
        if w.threat ~= 0 then
            AddReason(mb, math.floor(w.threat * 0.25), "白名单权重: 仇恨")
        end
    end
    table.insert(list, mb)

    local rev = NewEval(TOKENS.REVENGE, 98)
    ApplyCommonChecks(rev, context, {
        requireTarget = true,
        usableToken = TOKENS.REVENGE,
        rangeToken = TOKENS.REVENGE,
        rageCost = ABILITIES[TOKENS.REVENGE].rage,
        cooldown = context.cooldown.rev,
    })
    if rev.passed then
        AddReason(rev, 12, "高性价比仇恨")
        if threat.status <= 1 then
            AddReason(rev, 16, "仇恨未稳时优先低怒高威胁技能")
        end
        if threatUrgency > 0 then
            AddReason(rev, math.floor(threatUrgency * revengeUrgencyCoeff), "威胁紧迫度提升 Revenge 价值")
        end
        if tpsThreatBias > 0 then
            AddReason(rev, math.floor(tpsThreatBias), "TPS 威胁偏置")
        end
        if w.threat ~= 0 then
            AddReason(rev, math.floor(w.threat * 0.5), "白名单权重: 仇恨")
        end
        if w.tps ~= 0 then
            AddReason(rev, w.tps, "白名单权重: TPS倾向")
        end
    end
    table.insert(list, rev)

    local ss = NewEval(TOKENS.SHIELD_SLAM, 90)
    ApplyCommonChecks(ss, context, {
        requireTarget = true,
        usableToken = TOKENS.SHIELD_SLAM,
        rangeToken = TOKENS.SHIELD_SLAM,
        rageCost = ABILITIES[TOKENS.SHIELD_SLAM].rage,
        cooldown = context.cooldown.ss,
    })
    if ss.passed then
        AddReason(ss, 14, "稳定高仇恨")
        if threat.status <= 1 then
            AddReason(ss, 12, "仇恨未稳时加速建立领先")
        end
        if threatUrgency > 0 then
            AddReason(ss, math.floor(threatUrgency * shieldSlamUrgencyCoeff), "威胁紧迫度提升 Shield Slam 价值")
        end
        if tpsThreatBias > 0 then
            AddReason(ss, math.floor(tpsThreatBias), "TPS 威胁偏置")
        end
        if context.talents and context.talents.protPoints >= 21 then
            AddReason(ss, 4, "防护投入较高，盾系技能收益更稳定")
        end
        if w.threat ~= 0 then
            AddReason(ss, math.floor(w.threat * 0.6), "白名单权重: 仇恨")
        end
    end
    table.insert(list, ss)

    local sunder = NewEval(TOKENS.SUNDER_ARMOR, 82)
    ApplyCommonChecks(sunder, context, {
        requireTarget = true,
        usableToken = TOKENS.SUNDER_ARMOR,
        rangeToken = TOKENS.SUNDER_ARMOR,
        rageCost = ABILITIES[TOKENS.SUNDER_ARMOR].rage,
        cooldown = 0,
    })
    if sunder.passed then
        if threat.status <= 1 then
            AddReason(sunder, 16, "仇恨地位偏低，补破甲拉升TPS")
        elseif threat.status == 2 then
            AddReason(sunder, 8, "仇恨接近前排，破甲有稳定收益")
        else
            AddReason(sunder, 2, "已稳住仇恨，破甲收益较平缓")
        end

        ApplyTpsSunderDuty(sunder, context, cfg, sunderState)

        if threat.scaledPct < 90 then
            AddReason(sunder, 10, "威胁百分比<90%，补稳仇恨面")
        end
        if tpsThreatBias > 0 then
            AddReason(sunder, math.floor(tpsThreatBias), "TPS 威胁偏置")
        end
        if w.sunder ~= 0 then
            AddReason(sunder, w.sunder, "白名单权重: Sunder")
        end
        if w.threat ~= 0 then
            AddReason(sunder, math.floor(w.threat * 0.35), "白名单权重: 仇恨")
        end
    end
    if sunder.passed then
        local delta, note = CalcSunderValue(context, context.mode, cfg)
        AddReason(sunder, delta, note)
        AddReason(sunder, 8, "兜底仇恨技能")
    end
    table.insert(list, sunder)

    local shout = BuildBattleShoutEval(context, cfg, "TPS_SURVIVAL", threat)
    if shout.passed and w.tps ~= 0 then
        AddReason(shout, math.floor(w.tps * 0.25), "白名单权重: TPS倾向")
    end
    table.insert(list, shout)

    local bt = NewEval(TOKENS.BLOODTHIRST, 78)
    ApplyCommonChecks(bt, context, {
        requireTarget = true,
        usableToken = TOKENS.BLOODTHIRST,
        rangeToken = TOKENS.BLOODTHIRST,
        rageCost = ABILITIES[TOKENS.BLOODTHIRST].rage,
        cooldown = context.cooldown.bt,
    })
    if bt.passed then
        AddReason(bt, 8, "狂暴坦可用的高威胁回填")
        if threat.status <= 1 then
            AddReason(bt, 10, "仇恨未稳，需强力单体威胁")
        end
        if threatUrgency > 0 then
            AddReason(bt, math.floor(threatUrgency * bloodthirstUrgencyCoeff), "威胁紧迫度提升 BT 价值")
        end
        if sunderState.stacks < cfg.sunderTargetStacks then
            AddReason(bt, -8, "破甲层数未满，先稳破甲更优")
        end
        if context.buffs and context.buffs.offensiveBurst then
            AddReason(bt, 5, "爆发Buff窗口下 BT 威胁更高")
        end
        if w.bloodthirst ~= 0 then
            AddReason(bt, w.bloodthirst, "白名单权重: Bloodthirst")
        end
        if w.ap > 0 then
            AddReason(bt, math.floor(w.ap / 140), "白名单权重: AP加成")
        end
    end
    table.insert(list, bt)

    local sb = NewEval(TOKENS.SHIELD_BLOCK, 76)
    ApplyCommonChecks(sb, context, {
        requireTarget = true,
        usableToken = TOKENS.SHIELD_BLOCK,
        rageCost = ABILITIES[TOKENS.SHIELD_BLOCK].rage,
        cooldown = context.cooldown.sb,
        ignoreGcd = true,
        predicate = function(ctx)
            return ctx.inCombat and ctx.equipment and ctx.equipment.hasShield
        end,
        predicateReason = "当前未装备盾牌/未进入有效挡格场景",
    })
    if sb.passed then
        AddReason(sb, 16, "带盾时主动维持挡格覆盖")
        if context.targetEliteLike then
            AddReason(sb, 12, "Boss/精英目标下挡格收益更稳定")
        end
        if context.hostileCount >= 2 then
            AddReason(sb, 8, "多目标近战压力下优先维持 Shield Block")
        end
        if context.cooldown.rev > context.horizonSec then
            AddReason(sb, 6, "提前准备复仇触发窗口")
        end
        if survivalUrgency > 0 then
            AddReason(sb, math.floor(survivalUrgency * 0.8), "生存紧迫度抬高 Shield Block")
        end
        if threat.status <= 1 then
            AddReason(sb, -8, "当前更急需先稳住仇恨")
        elseif threat.scaledPct < 90 then
            AddReason(sb, -4, "仇恨尚未完全稳定，挡格略让位于抢仇恨")
        else
            AddReason(sb, 4, "仇恨稳定，可主动补挡格层")
        end
        if context.targetBossLike and sunderState.stacks >= cfg.sunderTargetStacks and sunderState.remaining < cfg.sunderRefreshSeconds
            and threat.status >= 2 and threat.scaledPct >= 95 then
            AddReason(sb, -18, "Boss破甲进入刷新窗口，当前应让位 Sunder")
        end
        if (not context.targetEliteLike) and context.hostileCount <= 1 and context.playerHealthPct >= 70 and threat.status >= 3 then
            AddReason(sb, -6, "低压单体场景下可稍后再补")
        end
        if w.survival ~= 0 then
            AddReason(sb, math.floor(w.survival * 0.8), "白名单权重: 生存")
        end
    end
    table.insert(list, sb)

    local wait = NewEval(TOKENS.WAIT, 5)
    if threat.status <= 1 then
        AddReason(wait, -12, "仇恨未稳时不应空转")
        if w.threat > 8 then
            AddReason(wait, -6, "白名单提示当前窗口应主动拉仇恨")
        end
    else
        AddReason(wait, 0, "等待怒气窗口")
    end
    table.insert(list, wait)

    ApplyLevelUtilityScale(shout, context, TOKENS.BATTLE_SHOUT)
    SortEvaluations(list)
    return list
end

local function PickBest(list)
    if not list or #list == 0 then
        return TOKENS.NONE, "无候选技能"
    end
    local best = list[1]
    if not best.passed and best.token ~= TOKENS.WAIT then
        return TOKENS.WAIT, "候选技能均不满足，等待窗口"
    end
    return best.token, (best.reasons[1] or "最高分候选"), best
end

local function IsActionToken(token)
    return token and token ~= TOKENS.WAIT and token ~= TOKENS.NONE
end

local function FindEvalByToken(list, token)
    if not list or not token then
        return nil
    end
    for _, entry in ipairs(list) do
        if entry.token == token then
            return entry
        end
    end
    return nil
end

local function IsEmergencySwitch(context, bestEval, habitCfg)
    if not habitCfg.emergencyOverride or not bestEval or not bestEval.passed then
        return false
    end
    if bestEval.token == TOKENS.EXECUTE and context.targetHealthPct and context.targetHealthPct <= 20 then
        return true
    end
    if context.mode == "TPS_SURVIVAL" and (
        bestEval.token == TOKENS.TAUNT
        or bestEval.token == TOKENS.MOCKING_BLOW
        or bestEval.token == TOKENS.LAST_STAND
    ) then
        return true
    end
    return false
end

local function SelectHabitSkill(context, nextEvaluations, bestSkill, bestReason, bestEval)
    local habitCfg = Decision.GetHabitConfig()
    local nowTs = context.now or GetTime()
    local info = {
        enabled = habitCfg.enabled,
        decision = "disabled",
        lockedSkill = HabitState.lockedSkill,
        bestSkill = bestSkill,
        scoreDelta = 0,
    }
    if not habitCfg.enabled then
        return bestSkill, bestReason, info
    end

    if HabitState.mode ~= context.mode then
        HabitState.lockedSkill = nil
        HabitState.candidateSkill = nil
        HabitState.mode = context.mode
        info.decision = "reset-mode"
    end
    if HabitState.inCombat ~= context.inCombat then
        HabitState.lockedSkill = nil
        HabitState.candidateSkill = nil
        HabitState.inCombat = context.inCombat and true or false
        info.decision = info.decision == "reset-mode" and "reset-mode-combat" or "reset-combat"
    end

    if not context.targetExists then
        HabitState.lockedSkill = nil
        HabitState.candidateSkill = nil
        info.decision = "reset-no-target"
        return bestSkill, bestReason, info
    end

    if not IsActionToken(bestSkill) then
        info.decision = "best-non-action"
        return bestSkill, bestReason, info
    end

    if not HabitState.lockedSkill or not IsActionToken(HabitState.lockedSkill) then
        HabitState.lockedSkill = bestSkill
        HabitState.lockedAt = nowTs
        HabitState.lastSwitchAt = nowTs
        HabitState.candidateSkill = nil
        info.decision = "lock-init"
        info.lockedSkill = HabitState.lockedSkill
        return bestSkill, bestReason, info
    end

    local lockSkill = HabitState.lockedSkill
    local lockEval = FindEvalByToken(nextEvaluations, lockSkill)
    if (not lockEval) or (not lockEval.passed) or IsEmergencySwitch(context, bestEval, habitCfg) then
        HabitState.lockedSkill = bestSkill
        HabitState.lockedAt = nowTs
        HabitState.lastSwitchAt = nowTs
        HabitState.candidateSkill = nil
        info.decision = (not lockEval or not lockEval.passed) and "switch-lock-invalid" or "switch-emergency"
        info.lockedSkill = HabitState.lockedSkill
        return bestSkill, bestReason, info
    end

    if bestSkill == lockSkill then
        HabitState.candidateSkill = nil
        info.decision = "keep-lock-same"
        info.lockedSkill = lockSkill
        return lockSkill, "习惯锁定：维持当前提示", info
    end

    local elapsedMs = math.max((nowTs - HabitState.lockedAt) * 1000, 0)
    local decay = 1 - (elapsedMs / habitCfg.bonusDecayMs)
    if decay < 0 then
        decay = 0
    end
    local stickyBonus = habitCfg.baseLockedBonus * decay
    local bestScore = bestEval and bestEval.score or 0
    local lockScore = lockEval.score or 0
    local effectiveLock = lockScore + stickyBonus
    local scoreDelta = bestScore - effectiveLock
    info.scoreDelta = scoreDelta

    if scoreDelta < habitCfg.switchDelta then
        HabitState.candidateSkill = nil
        info.decision = "keep-lock-delta"
        info.lockedSkill = lockSkill
        return lockSkill, "习惯锁定：收益差未达切换阈值", info
    end

    if HabitState.candidateSkill ~= bestSkill then
        HabitState.candidateSkill = bestSkill
        HabitState.candidateSince = nowTs
        info.decision = "keep-lock-candidate-start"
        info.lockedSkill = lockSkill
        return lockSkill, "习惯锁定：候选技能观察中", info
    end

    local candidateHoldMs = (nowTs - HabitState.candidateSince) * 1000
    if candidateHoldMs < habitCfg.minHoldMs then
        info.decision = "keep-lock-candidate-hold"
        info.lockedSkill = lockSkill
        return lockSkill, "习惯锁定：候选稳定时长不足", info
    end

    HabitState.lockedSkill = bestSkill
    HabitState.lockedAt = nowTs
    HabitState.lastSwitchAt = nowTs
    HabitState.candidateSkill = nil
    info.decision = "switch-delta-hold"
    info.lockedSkill = HabitState.lockedSkill
    return bestSkill, "习惯切换：收益差与稳定时长达标", info
end

local function IsPredictableToken(context, entry)
    if not entry or not entry.token then
        return false
    end
    local token = entry.token
    if token == TOKENS.WAIT or token == TOKENS.NONE then
        return false
    end
    if IsOffGcdToken(token) then
        return false
    end
    if token == TOKENS.BATTLE_SHOUT then
        local shoutState = context and context.battleShoutState or nil
        local needsCast = context and context.mode == "TPS_SURVIVAL"
            and shoutState and shoutState.effectUnits and shoutState.effectUnits > 0
            or (shoutState and shoutState.selfNeedsCast)
        if not entry.passed or not needsCast then
            return false
        end
        if context.inCombat and not context.targetExists then
            return false
        end
        return true
    end
    if token == TOKENS.EXECUTE then
        -- 满血/非斩杀阶段不应提前预测斩杀。
        return context.targetHealthPct and context.targetHealthPct <= 20
    end
    if (token == TOKENS.SUNDER_ARMOR or token == TOKENS.BLOODTHIRST or token == TOKENS.WHIRLWIND or token == TOKENS.REVENGE
        or token == TOKENS.SHIELD_SLAM or token == TOKENS.SHIELD_BLOCK or token == TOKENS.TAUNT or token == TOKENS.MOCKING_BLOW)
        and not context.targetExists then
        return false
    end
    return true
end

local function PickPredictedFromEvaluations(list, context)
    if not list then
        return TOKENS.NONE, nil
    end
    -- 第一优先：可执行且通过检查的技能。
    for _, entry in ipairs(list) do
        if entry.passed and IsPredictableToken(context, entry) then
            return entry.token, entry
        end
    end
    -- 第二优先：不可执行但最可能成为下一手的技能（过滤明显不合理项）。
    for _, entry in ipairs(list) do
        if IsPredictableToken(context, entry) then
            return entry.token, entry
        end
    end
    return TOKENS.NONE, nil
end

local function BuildRejected(list, maxCount)
    local result = {}
    for _, entry in ipairs(list) do
        if not entry.passed then
            table.insert(result, entry)
            if #result >= (maxCount or 3) then
                break
            end
        end
    end
    return result
end

IsOffGcdToken = function(token)
    return token and OFF_GCD_ACTIONABLE_TOKENS[token] and true or false
end

local function FilterNextGcdEvaluations(list)
    local out = {}
    for _, entry in ipairs(list or {}) do
        if not IsOffGcdToken(entry.token) then
            table.insert(out, entry)
        end
    end
    return out
end

local function PickBestOffGcd(list)
    if not list or #list == 0 then
        return TOKENS.NONE, "无可用Off-GCD动作", nil
    end
    local best = list[1]
    if not best.passed and best.token ~= TOKENS.NONE then
        return TOKENS.NONE, "当前无值得插入的Off-GCD动作", best
    end
    return best.token, (best.reasons[1] or "最高分候选"), best
end

local function BuildOffGcdEvaluations(context, mainEvaluations)
    local list = {}
    local appended = {}
    local w = context.weights or NewWeightBag()
    local threat = context.threat or ReadThreatState()

    for _, entry in ipairs(mainEvaluations or {}) do
        if IsOffGcdToken(entry.token) then
            table.insert(list, entry)
            appended[entry.token] = true
        end
    end

    local br = NewEval(TOKENS.BLOODRAGE, 42)
    ApplyCommonChecks(br, context, {
        requireTarget = false,
        usableToken = TOKENS.BLOODRAGE,
        cooldown = context.cooldown.br,
        ignoreGcd = true,
        predicate = function(ctx)
            return ctx.inCombat and ctx.playerHealthPct > 25 and not (ctx.buffs and ctx.buffs.bloodrage)
        end,
        predicateReason = "当前无需 Bloodrage / 已激活 / 血量过低",
    })
    if br.passed then
        if context.rage <= 25 then
            AddReason(br, 16, "怒气偏低，适合用 Bloodrage 填补资源")
        elseif context.rage <= 45 then
            AddReason(br, 8, "中低怒气，Bloodrage 可平滑下个主循环")
        else
            AddReason(br, -8, "当前怒气充足，Bloodrage 收益下降")
        end
        if context.mode == "DPS" then
            if context.cooldown.bt <= context.horizonSec or context.cooldown.ww <= context.horizonSec then
                AddReason(br, 8, "主循环技能即将转好，提前补怒")
            end
        else
            if threat.status <= 1 or threat.scaledPct < 95 then
                AddReason(br, 10, "仇恨未稳时提前补怒更有价值")
            end
            if context.cooldown.ss <= context.horizonSec or context.cooldown.rev <= context.horizonSec then
                AddReason(br, 6, "盾系技能窗口将到，补怒更有价值")
            end
        end
        if context.queue and context.queue.queuedDumpToken and context.queue.queuedDumpToken ~= TOKENS.HOLD then
            AddReason(br, -4, "已存在泄怒队列，Bloodrage 略降权")
        end
        if w.threat ~= 0 and context.mode == "TPS_SURVIVAL" then
            AddReason(br, math.floor(w.threat * 0.2), "白名单权重: 仇恨")
        end
    end
    table.insert(list, br)
    appended[TOKENS.BLOODRAGE] = true

    if not appended[TOKENS.LAST_STAND] and context.mode == "TPS_SURVIVAL" then
        local ls = NewEval(TOKENS.LAST_STAND, 0)
        Reject(ls, "当前无可用生存爆发")
        table.insert(list, ls)
    end
    if not appended[TOKENS.SHIELD_BLOCK] and context.mode == "TPS_SURVIVAL" then
        local sb = NewEval(TOKENS.SHIELD_BLOCK, 0)
        Reject(sb, "当前无可用挡格动作")
        table.insert(list, sb)
    end

    local none = NewEval(TOKENS.NONE, 10)
    AddReason(none, 0, "当前无需插入Off-GCD动作")
    table.insert(list, none)

    SortEvaluations(list)
    return list
end

local function BuildDumpEvaluations(context)
    local w = context.weights or NewWeightBag()
    local qCfg = Decision.GetHsQueueConfig()
    local threat = context.threat or ReadThreatState()
    local reserve = 0
    if context.mode == "DPS" then
        if context.cooldown.bt <= context.horizonSec then
            reserve = math.max(reserve, 30)
        end
        if context.cooldown.ww <= context.horizonSec then
            reserve = math.max(reserve, 25)
        end
        if context.targetHealthPct and context.targetHealthPct <= 20 and context.cooldown.ex <= context.horizonSec then
            reserve = math.max(reserve, 15)
        end
        if context.buffs and context.buffs.offensiveBurst then
            reserve = math.max(reserve - 5, 0)
        end
    else
        if context.cooldown.ss <= context.horizonSec then
            reserve = math.max(reserve, 20)
        end
        if context.cooldown.rev <= context.horizonSec then
            reserve = math.max(reserve, 5)
        end
        if threat.status <= 1 or threat.scaledPct < 90 then
            reserve = math.max(reserve, 20)
        else
            reserve = math.max(reserve, 10)
        end
        if context.cooldown.mb <= context.horizonSec and (threat.status <= 1 or threat.scaledPct < 90) then
            reserve = math.max(reserve, ABILITIES[TOKENS.MOCKING_BLOW].rage)
        end
    end
    if context.trinket and context.trinket.anyActive then
        reserve = math.max(reserve - 3, 0)
    end
    if w.dump ~= 0 then
        reserve = reserve - math.floor(w.dump * 0.3)
    end
    reserve = Clamp(reserve, 0, 100)
    local usableRage = context.rage - reserve

    local list = {}
    local cleave = NewEval(TOKENS.CLEAVE, 65)
    ApplyCommonChecks(cleave, context, {
        requireTarget = true,
        usableToken = TOKENS.CLEAVE,
        rangeToken = TOKENS.CLEAVE,
        rageCost = ABILITIES[TOKENS.CLEAVE].rage,
        cooldown = 0,
        predicate = function(ctx)
            if ctx.mode == "TPS_SURVIVAL" then
                if threat.status <= 1 or threat.scaledPct < 90 then
                    return false
                end
            end
            return ctx.hostileCount >= 2 and usableRage >= ABILITIES[TOKENS.CLEAVE].rage
        end,
        predicateReason = "非多目标/怒气需预留/仇恨未稳",
    })
    if cleave.passed then
        AddReason(cleave, 12, "多目标怒气泄放")
        if context.equipment and context.equipment.dualWieldWeapon then
            AddReason(cleave, 3, "双持场景下多目标泄怒更平滑")
        end
        if w.dump ~= 0 then
            AddReason(cleave, w.dump, "白名单权重: Dump")
        end
        if w.haste > 0 then
            AddReason(cleave, math.floor(w.haste / 10), "白名单权重: 急速促使泄怒")
        end
    end
    table.insert(list, cleave)

    local hs = NewEval(TOKENS.HEROIC_STRIKE, 60)
    ApplyCommonChecks(hs, context, {
        requireTarget = true,
        usableToken = TOKENS.HEROIC_STRIKE,
        rangeToken = TOKENS.HEROIC_STRIKE,
        rageCost = ABILITIES[TOKENS.HEROIC_STRIKE].rage,
        cooldown = 0,
        predicate = function(_)
            if context.mode == "TPS_SURVIVAL" then
                if threat.status <= 1 or threat.scaledPct < 90 then
                    return false
                end
            end
            return usableRage >= ABILITIES[TOKENS.HEROIC_STRIKE].rage
        end,
        predicateReason = "怒气需预留或仇恨未稳",
    })
    if hs.passed and context.hostileCount == 1 then
        AddReason(hs, 8, "单目标怒气泄放")
    end
    if hs.passed and context.buffs and context.buffs.offensiveBurst then
        AddReason(hs, 4, "爆发期允许更积极泄怒")
    end
    if hs.passed then
        if w.dump ~= 0 then
            AddReason(hs, w.dump, "白名单权重: Dump")
        end
        if w.crit > 0 then
            AddReason(hs, math.floor(w.crit / 4), "白名单权重: 暴击环境")
        end
    end
    table.insert(list, hs)

    local hold = NewEval(TOKENS.HOLD, 20)
    AddReason(hold, reserve >= 20 and 18 or 6, "预留怒气 " .. reserve)

    -- HS Queue 优化：利用主手挥击前窗口排队 HS，以提升副手命中稳定性（经典技巧）。
    if qCfg.enabled and context.mode == "DPS" then
        local queue = context.queue or {}
        local queuedToken = queue.queuedDumpToken or TOKENS.HOLD
        local queueWindowOpen = queue.queueWindowOpen and true or false
        local singleTargetOk = (not qCfg.singleTargetOnly) or context.hostileCount <= 1
        local dualWieldOk = context.equipment and context.equipment.dualWieldWeapon
        local hasOffHand = context.swing and context.swing.hasOffHand
        local queueEligible = queueWindowOpen and singleTargetOk and dualWieldOk and hasOffHand
        local hsQueueNeedRage = ABILITIES[TOKENS.HEROIC_STRIKE].rage + qCfg.safetyRage
        local hsQueueRageSafe = context.rage >= (reserve + hsQueueNeedRage)

        if queuedToken ~= TOKENS.HOLD then
            if queuedToken == TOKENS.HEROIC_STRIKE then
                AddReason(hs, 8, "HS 已排队，保持稳定节奏")
            elseif queuedToken == TOKENS.CLEAVE then
                AddReason(cleave, 8, "顺劈已排队，保持稳定节奏")
            end
            AddReason(hold, 4, "已排队，避免无意义重复按键")
        else
            local protect = false
            if context.cooldown.bt <= (qCfg.btProtectMs / 1000) and context.rage < (reserve + ABILITIES[TOKENS.BLOODTHIRST].rage + qCfg.safetyRage) then
                protect = true
            end
            if context.cooldown.ww <= (qCfg.wwProtectMs / 1000) and context.rage < (reserve + ABILITIES[TOKENS.WHIRLWIND].rage + qCfg.safetyRage) then
                protect = true
            end
            if context.targetHealthPct and context.targetHealthPct <= 20 and context.cooldown.ex <= (qCfg.exProtectMs / 1000)
                and context.rage < (reserve + ABILITIES[TOKENS.EXECUTE].rage + qCfg.safetyRage) then
                protect = true
            end

            if queueEligible and hsQueueRageSafe and (not protect) then
                AddReason(hs, 12, "主手前短窗 + 资源安全，轻度建议预排 HS")
            elseif queueEligible and protect then
                AddReason(hs, -6, "主循环保护窗内，压低 HS 预排")
            end
        end
    end

    table.insert(list, hold)

    SortEvaluations(list)
    return list, reserve
end

function Decision.GetRecommendation()
    local context = BuildContext()
    local mainEvaluations = context.mode == "TPS_SURVIVAL" and BuildTpsEvaluations(context) or BuildDpsEvaluations(context)
    local nextEvaluations = FilterNextGcdEvaluations(mainEvaluations)
    local bestSkill, bestReason, bestEval = PickBest(nextEvaluations)
    local nextSkill, reason, habitInfo = SelectHabitSkill(context, nextEvaluations, bestSkill, bestReason, bestEval)
    local displayNextSkill = nextSkill
    local displayNextSource = "direct"
    local displayEval = nil

    if nextSkill == TOKENS.WAIT then
        local habitCfg = Decision.GetHabitConfig()
        local lockSkill = HabitState.lockedSkill
        local lockEval = FindEvalByToken(nextEvaluations, lockSkill)
        if IsActionToken(lockSkill) and lockEval and IsPredictableToken(context, lockEval) then
            local lockCd = GetTokenCooldownRemaining(lockSkill, context)
            if lockCd <= (habitCfg.readySoonMs / 1000) then
                displayNextSkill = lockSkill
                displayNextSource = "wait-lock-readysoon"
                displayEval = lockEval
            end
        end
    end

    if nextSkill == TOKENS.WAIT and displayNextSource == "direct" then
        local predicted, predictedEval = PickPredictedFromEvaluations(nextEvaluations, context)
        if predicted ~= TOKENS.NONE then
            displayNextSkill = predicted
            displayNextSource = "wait-prediction"
            displayEval = predictedEval
        end
    else
        for _, entry in ipairs(nextEvaluations) do
            if entry.token == nextSkill then
                displayEval = entry
                break
            end
        end
    end

    local displayRageCost = GetTokenRageCost(displayNextSkill)
    local displayCooldownRem = GetTokenCooldownRemaining(displayNextSkill, context)
    local displayRageEnough = context.rage >= displayRageCost

    local dumpEvaluations, reserveRage = BuildDumpEvaluations(context)
    local dumpSkill, dumpReason = PickBest(dumpEvaluations)
    local offGcdEvaluations = BuildOffGcdEvaluations(context, mainEvaluations)
    local offGcdSkill, offGcdReason, offGcdEval = PickBestOffGcd(offGcdEvaluations)
    local offGcdRageCost = GetTokenRageCost(offGcdSkill)
    local offGcdCooldownRem = GetTokenCooldownRemaining(offGcdSkill, context)
    local offGcdRageEnough = context.rage >= offGcdRageCost

    return {
        mode = context.mode,
        stance = context.stance,
        horizonMs = context.horizonMs,
        nextGcdSkill = nextSkill,
        nextGcdReason = reason,
        nextSkill = nextSkill,
        reason = reason,
        displayNextGcdSkill = displayNextSkill,
        displayNextSkill = displayNextSkill,
        displayNextSource = displayNextSource,
        displayNextState = {
            cooldownRem = displayCooldownRem,
            rageCost = displayRageCost,
            rageEnough = displayRageEnough,
            passed = displayEval and displayEval.passed or false,
        },
        habitInfo = habitInfo,
        dumpQueueSkill = dumpSkill,
        dumpQueueReason = dumpReason,
        dumpSkill = dumpSkill,
        dumpReason = dumpReason,
        offGcdSkill = offGcdSkill,
        offGcdReason = offGcdReason,
        offGcdState = {
            cooldownRem = offGcdCooldownRem,
            rageCost = offGcdRageCost,
            rageEnough = offGcdRageEnough,
            passed = offGcdEval and offGcdEval.passed or false,
        },
        reserveRage = reserveRage,
        context = context,
        nextEvaluations = nextEvaluations,
        nextRejected = BuildRejected(nextEvaluations, 3),
        dumpEvaluations = dumpEvaluations,
        dumpRejected = BuildRejected(dumpEvaluations, 2),
        offGcdEvaluations = offGcdEvaluations,
        offGcdRejected = BuildRejected(offGcdEvaluations, 2),
    }
end

function DecisionModule:Init()
    -- 决策模块按需计算，不主动监听事件。
end

ns.RegisterModule(DecisionModule)

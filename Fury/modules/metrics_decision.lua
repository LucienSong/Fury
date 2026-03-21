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
local OverpowerDebugState = {
    signature = nil,
    at = 0,
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
    OVERPOWER = "OVERPOWER",
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
local ReadSunderState
local IsOffGcdToken
local FindEvalByToken
local ExtractAuraSpellId
local ResolveHighestKnownSpellId

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
    OVERPOWER = 7384,
    MOCKING_BLOW = 694,
}

local EXECUTE_RANK_IDS = { 5308, 20658, 20660, 20661, 20662 }
local OVERPOWER_RANK_IDS = { 7384, 7887, 11584, 11585 }
local HAMSTRING_RANK_IDS = { 1715, 7372, 7373 }
local SUNDER_RANK_IDS = { 7386, 7405, 8380, 11596, 11597 }
local HS_RANK_IDS = { 78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286 }
local CLEAVE_RANK_IDS = { 845, 7369, 11608, 11609, 20569 }
local BATTLE_SHOUT_RANK_IDS = { 6673, 5242, 6192, 11549, 11550, 11551, 25289 }
local MOCKING_BLOW_RANK_IDS = { 694, 7400, 7402, 20559, 20560 }
local GCD_FALLBACK_SPELL_IDS = {
    SPELL_ID.SUNDER_ARMOR,
    SPELL_ID.BATTLE_SHOUT,
    SPELL_ID.HAMSTRING,
    SPELL_ID.OVERPOWER,
    6572, -- Revenge
    2565, -- Shield Block
    23922, -- Shield Slam
}
local EXECUTE_MODEL_CACHE = nil
local EXECUTE_MODEL_CACHE_AT = 0
local EXECUTE_MODEL_CACHE_TTL = 15
local EquipmentStateCache = {
    dirty = true,
    value = nil,
}
local BattleShoutAuraCache = {
    dirty = true,
    units = {},
    scannedAt = 0,
}

-- Per-frame caches: avoid redundant aura scans within the same GetTime() frame.
local PerFrameCache = {
    frame = 0,
    buffState = nil,
    sunderState = nil,
    hamstringState = nil,
    procWeights = nil,
    procActive = nil,
}

local function InvalidatePerFrameCache()
    PerFrameCache.frame = 0
    PerFrameCache.buffState = nil
    PerFrameCache.sunderState = nil
    PerFrameCache.hamstringState = nil
    PerFrameCache.procWeights = nil
    PerFrameCache.procActive = nil
end

local function IsPerFrameCacheValid()
    local now = GetTime()
    if PerFrameCache.frame ~= now then
        PerFrameCache.frame = now
        PerFrameCache.buffState = nil
        PerFrameCache.sunderState = nil
        PerFrameCache.hamstringState = nil
        PerFrameCache.procWeights = nil
        PerFrameCache.procActive = nil
        return false
    end
    return true
end

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

local function GetDefaultProfile()
    if ns.GetDefaultDecisionProfile then
        return ns.GetDefaultDecisionProfile()
    end
    return nil
end

local function GetDefaultProfileSection(key)
    local profile = GetDefaultProfile()
    if type(profile) == "table" then
        return profile[key]
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
    local defaults = GetDefaultProfileSection("setBonusProfiles")
    if type(defaults) == "table" then
        return defaults
    end
    return SET_BONUS_PROFILES
end

local function GetSetNameProfileHints()
    local profile = GetUnifiedProfile()
    if profile and type(profile.setNameProfileHints) == "table" then
        return profile.setNameProfileHints
    end
    local defaults = GetDefaultProfileSection("setNameProfileHints")
    if type(defaults) == "table" then
        return defaults
    end
    return SET_NAME_PROFILE_HINTS
end

local function GetBuffTrinketWeightProfiles()
    local profile = GetUnifiedProfile()
    if profile and type(profile.buffTrinketWeightProfiles) == "table" then
        return profile.buffTrinketWeightProfiles
    end
    local defaults = GetDefaultProfileSection("buffTrinketWeightProfiles")
    if type(defaults) == "table" then
        return defaults
    end
    return BUFF_TRINKET_WEIGHT_PROFILES
end

local ABILITIES = {
    [TOKENS.BLOODRAGE] = { id = SPELL_ID.BLOODRAGE, name = GetSpellInfo(SPELL_ID.BLOODRAGE) or "Bloodrage", rage = 0 },
    [TOKENS.BLOODTHIRST] = { id = 23881, name = GetSpellInfo(23881) or "Bloodthirst", rage = 30 },
    [TOKENS.WHIRLWIND] = { id = 1680, name = GetSpellInfo(1680) or "Whirlwind", rage = 25 },
    [TOKENS.EXECUTE] = { id = 5308, name = GetSpellInfo(5308) or "Execute", rage = 15 },
    [TOKENS.OVERPOWER] = { id = SPELL_ID.OVERPOWER, name = GetSpellInfo(SPELL_ID.OVERPOWER) or "Overpower", rage = 5 },
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
    -- Overpower
    [7384] = TOKENS.OVERPOWER, [7887] = TOKENS.OVERPOWER, [11584] = TOKENS.OVERPOWER,
    [11585] = TOKENS.OVERPOWER,
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
    -- Single-rank / talent spells (missing from original table)
    [23881] = TOKENS.BLOODTHIRST,       -- Bloodthirst (Fury 31-point talent)
    [1680] = TOKENS.WHIRLWIND,          -- Whirlwind
    [2687] = TOKENS.BLOODRAGE,          -- Bloodrage
    [6572] = TOKENS.REVENGE, [6574] = TOKENS.REVENGE, [7379] = TOKENS.REVENGE,
    [11600] = TOKENS.REVENGE, [11601] = TOKENS.REVENGE, [25288] = TOKENS.REVENGE,
    [2565] = TOKENS.SHIELD_BLOCK,       -- Shield Block
    [23922] = TOKENS.SHIELD_SLAM,       -- Shield Slam (Protection 31-point talent)
    [23923] = TOKENS.SHIELD_SLAM, [23924] = TOKENS.SHIELD_SLAM,
    [23925] = TOKENS.SHIELD_SLAM,
    [12975] = TOKENS.LAST_STAND,        -- Last Stand (Protection talent)
    [355] = TOKENS.TAUNT,               -- Taunt
}

local TOKEN_COOLDOWN_KEY = {
    [TOKENS.BLOODRAGE] = "br",
    [TOKENS.BLOODTHIRST] = "bt",
    [TOKENS.WHIRLWIND] = "ww",
    [TOKENS.EXECUTE] = "ex",
    [TOKENS.OVERPOWER] = "op",
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
    [TOKENS.OVERPOWER] = true,
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

local PLANNER_DEFAULT_DEPTH = 2
local PLANNER_DEEP_DEPTH = 3
local PLANNER_WAIT_STEP_MAX = 0.35
local PLANNER_FUTURE_DECAY = 0.82
local PLANNER_GCD_SECONDS = 1.5
local TOKEN_BASE_COOLDOWN = {
    [TOKENS.BLOODRAGE] = 60,
    [TOKENS.BLOODTHIRST] = 6,
    [TOKENS.WHIRLWIND] = 10,
    [TOKENS.EXECUTE] = 0,
    [TOKENS.OVERPOWER] = 5,
    [TOKENS.HAMSTRING] = 0,
    [TOKENS.BATTLE_SHOUT] = 0,
    [TOKENS.SUNDER_ARMOR] = 0,
    [TOKENS.REVENGE] = 5,
    [TOKENS.SHIELD_BLOCK] = 5,
    [TOKENS.SHIELD_SLAM] = 6,
    [TOKENS.LAST_STAND] = 480,
    [TOKENS.TAUNT] = 10,
    [TOKENS.MOCKING_BLOW] = 120,
    [TOKENS.HEROIC_STRIKE] = 0,
    [TOKENS.CLEAVE] = 0,
}
local DPS_PREMIUM_TOKENS = {
    [TOKENS.BLOODTHIRST] = true,
    [TOKENS.WHIRLWIND] = true,
    [TOKENS.EXECUTE] = true,
    [TOKENS.OVERPOWER] = true,
}
local TPS_PREMIUM_TOKENS = {
    [TOKENS.SHIELD_SLAM] = true,
    [TOKENS.REVENGE] = true,
    [TOKENS.TAUNT] = true,
    [TOKENS.MOCKING_BLOW] = true,
    [TOKENS.SUNDER_ARMOR] = true,
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
    if ResolveHighestKnownSpellId then
        ResolveHighestKnownSpellId(nil)
    end
    local cache = Decision._spellTokenCache
    if cache and cache.spellNameToToken and cache.spellNameToToken[spellName] then
        return cache.spellNameToToken[spellName]
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
    if ResolveHighestKnownSpellId then
        ResolveHighestKnownSpellId(nil)
    end
    local cache = Decision._spellTokenCache
    if cache and cache.tokenBySpellId and cache.tokenBySpellId[spellId] then
        return cache.tokenBySpellId[spellId]
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
    if token == TOKENS.WAIT or token == TOKENS.HOLD then
        return "Interface\\Icons\\INV_Misc_PocketWatch_01"
    end
    if ResolveHighestKnownSpellId then
        ResolveHighestKnownSpellId(nil)
    end
    local info = ABILITIES[token]
    local cache = Decision._spellTokenCache
    local spellId = (cache and cache.highestSpellIdByToken and cache.highestSpellIdByToken[token])
        or (info and info.id)
    if spellId then
        local texture = GetSpellTexture(spellId)
        if texture then
            return texture
        end
    end
    if info and info.name then
        local texture = GetSpellTexture(info.name)
        if texture then
            return texture
        end
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
    local defaultProfile = GetDefaultProfile()
    local legacy = ns.db and ns.db.metrics and ns.db.metrics.decisionHorizonMs
    local raw = profile and profile.decisionHorizonMs
    if raw == nil and legacy ~= nil then
        raw = legacy
    end
    if raw == nil and type(defaultProfile) == "table" then
        raw = defaultProfile.decisionHorizonMs
    end
    if tonumber(raw) then
        return Clamp(math.floor(tonumber(raw) + 0.5), 50, 2000)
    end
    return 400
end

function Decision.GetConfig()
    local profile = GetUnifiedProfile()
    local defaults = GetDefaultProfileSection("decisionConfig") or {}
    local legacy = ns.db and ns.db.metrics and ns.db.metrics.decisionConfig
    local cfg = (profile and profile.decisionConfig) or legacy or defaults
    local targetStacks = Clamp(tonumber(cfg.sunderTargetStacks) or 5, 1, 5)
    return {
        sunderHpThreshold = Clamp(math.floor((tonumber(cfg.sunderHpThreshold) or 50000) + 0.5), 10000, 5000000),
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
    local cfg = (profile and profile.hsQueueConfig) or GetDefaultProfileSection("hsQueueConfig") or {}
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
    local cfg = (profile and profile.hamstringConfig) or GetDefaultProfileSection("hamstringConfig") or {}
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
    local cfg = (profile and profile.habitConfig) or GetDefaultProfileSection("habitConfig") or {}
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

function ns.SetHamstringExecutePhaseEnabled(enabled)
    if not ns.SetDecisionProfile then
        return
    end
    ns.SetDecisionProfile({
        hamstringConfig = {
            allowExecutePhase = enabled and true or false,
        },
    })
end

function ns.IsHamstringExecutePhaseEnabled()
    local cfg = Decision.GetHamstringConfig()
    return cfg.allowExecutePhase and true or false
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
    if start and start > 0 then
        local remain = start + (duration or 0) - GetTime()
        if remain > 0 then
            return remain
        end
    end

    -- Classic Era 下 61304 并不总是可靠，回退到无固有 CD 的主 GCD 技能探针。
    local best = nil
    for i = 1, #GCD_FALLBACK_SPELL_IDS do
        local spellId = GCD_FALLBACK_SPELL_IDS[i]
        local spellName = spellId and GetSpellInfo(spellId) or nil
        if spellName then
            local probeStart, probeDuration = GetSpellCooldown(spellName)
            if probeStart and probeStart > 0 and probeDuration and probeDuration > 0 and probeDuration <= 2.0 then
                local probeRemain = probeStart + probeDuration - GetTime()
                if probeRemain > 0 and ((not best) or probeRemain < best) then
                    best = probeRemain
                end
            end
        end
    end
    return best or 0
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
    local activeForm = GetShapeshiftForm and GetShapeshiftForm() or 0
    local forms = GetNumShapeshiftForms() or 0

    -- 0) 优先读取当前 active form。对战士姿态来说，这比 IsCurrentSpell/Buff 更接近真值。
    if activeForm and activeForm > 0 and activeForm <= forms then
        local icon, name, active, _, spellId = GetShapeshiftFormInfo(activeForm)
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
        if active and guessed then
            return guessed, "form-index-active:" .. tostring(activeForm)
        end
    end

    -- 1) 逐个扫描姿态栏，优先 active，然后按 spellId/icon/name。
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

    -- 2) 再用 spellId 判断当前姿态。
    if IsCurrentSpell and IsCurrentSpell(SPELL_ID.DEFENSIVE_STANCE) then
        return "Defensive", "current-spell:71"
    end
    if IsCurrentSpell and IsCurrentSpell(SPELL_ID.BERSERKER_STANCE) then
        return "Berserker", "current-spell:2458"
    end
    if IsCurrentSpell and IsCurrentSpell(SPELL_ID.BATTLE_STANCE) then
        return "Battle", "current-spell:2457"
    end

    -- 3) 再按 spellId 扫描玩家 Buff（规避少数环境下姿态栏异常）。
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, v10, v11 = UnitBuff("player", i)
        if not name then
            break
        end
        local auraSpellId = ExtractAuraSpellId(nil, nil, v10, v11)
        local byId = MatchStanceBySpellId(auraSpellId)
        if byId then
            return byId, "buff-id:" .. tostring(auraSpellId)
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

    -- B4 fix: warn once when all stance detection layers fail.
    if not Decision._stanceNoneWarned then
        Decision._stanceNoneWarned = true
        if ns.Print then
            ns.Print("|cffff9900[Fury]|r Stance detection fell through all fallbacks (activeForm=" .. tostring(activeForm) .. ", forms=" .. tostring(forms) .. "). Defaulting to None.")
        end
    end
    return "None", "unknown"
end

local function IsBattleStanceStrict()
    local forms = GetNumShapeshiftForms and (GetNumShapeshiftForms() or 0) or 0
    local activeForm = GetShapeshiftForm and (GetShapeshiftForm() or 0) or 0
    if activeForm and activeForm > 0 and activeForm <= forms then
        local _, _, active, _, spellId = GetShapeshiftFormInfo(activeForm)
        return active and spellId == SPELL_ID.BATTLE_STANCE or false
    end
    for i = 1, forms do
        local _, _, active, _, spellId = GetShapeshiftFormInfo(i)
        if active and spellId == SPELL_ID.BATTLE_STANCE then
            return true
        end
    end
    return false
end

local function MaybePrintOverpowerDebug(context, recommendedAction, rankedRecommendations)
    if not (ns.IsMetricsPanelShown and ns.IsMetricsPanelShown()) then
        return
    end
    local recommendedToken = recommendedAction and recommendedAction.token or TOKENS.NONE
    local rankedTop = rankedRecommendations and rankedRecommendations[1] and rankedRecommendations[1].token or TOKENS.NONE
    local opState = context and context.overpowerState or nil
    local opActive = opState and opState.active and true or false
    if recommendedToken ~= TOKENS.OVERPOWER and rankedTop ~= TOKENS.OVERPOWER and not opActive then
        return
    end

    local strictBattle = IsBattleStanceStrict()
    local targetGuid = UnitGUID("target")
    local opRemaining = opState and tonumber(opState.remaining) or 0
    local targetMatch = opState and opState.targetGuid and targetGuid and opState.targetGuid == targetGuid or false
    local signature = table.concat({
        tostring(context and context.stance or "None"),
        tostring(context and context.stanceSource or "unknown"),
        tostring(strictBattle),
        tostring(recommendedToken),
        tostring(rankedTop),
        tostring(opActive),
        string.format("%.2f", opRemaining or 0),
        tostring(targetMatch),
        tostring(opState and opState.targetGuid or "nil"),
        tostring(targetGuid or "nil"),
    }, "|")
    local now = GetTime()
    if OverpowerDebugState.signature == signature and (now - (OverpowerDebugState.at or 0)) < 0.75 then
        return
    end
    OverpowerDebugState.signature = signature
    OverpowerDebugState.at = now

    if ns.Print then
        ns.Print(string.format(
            "OP debug stance=%s source=%s strict=%s rec=%s top=%s active=%s remain=%.2f targetMatch=%s opTarget=%s target=%s",
            tostring(context and context.stance or "None"),
            tostring(context and context.stanceSource or "unknown"),
            strictBattle and "Y" or "N",
            tostring(recommendedToken),
            tostring(rankedTop),
            opActive and "Y" or "N",
            opRemaining or 0,
            targetMatch and "Y" or "N",
            tostring(opState and opState.targetGuid or "nil"),
            tostring(targetGuid or "nil")
        ))
    end
end

local function IsUsable(spellName)
    local usable, noMana = IsUsableSpell(spellName)
    return usable and not noMana
end

local RANK_IDS_BY_TOKEN = {
    [TOKENS.EXECUTE] = EXECUTE_RANK_IDS,
    [TOKENS.OVERPOWER] = OVERPOWER_RANK_IDS,
    [TOKENS.HAMSTRING] = HAMSTRING_RANK_IDS,
    [TOKENS.BATTLE_SHOUT] = BATTLE_SHOUT_RANK_IDS,
    [TOKENS.SUNDER_ARMOR] = SUNDER_RANK_IDS,
    [TOKENS.HEROIC_STRIKE] = HS_RANK_IDS,
    [TOKENS.CLEAVE] = CLEAVE_RANK_IDS,
    [TOKENS.MOCKING_BLOW] = MOCKING_BLOW_RANK_IDS,
    -- Single-rank / talent spells (needed for ResolveHighestKnownSpellId)
    [TOKENS.BLOODTHIRST] = { 23881 },
    [TOKENS.WHIRLWIND] = { 1680 },
    [TOKENS.BLOODRAGE] = { 2687 },
    [TOKENS.REVENGE] = { 6572, 6574, 7379, 11600, 11601, 25288 },
    [TOKENS.SHIELD_BLOCK] = { 2565 },
    [TOKENS.SHIELD_SLAM] = { 23922, 23923, 23924, 23925 },
    [TOKENS.LAST_STAND] = { 12975 },
    [TOKENS.TAUNT] = { 355 },
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
    [TOKENS.OVERPOWER] = {
        floorScale = 0.45,
        ranks = {
            { id = 7384, value = 35 },
            { id = 7887, value = 50 },
            { id = 11584, value = 80 },
            { id = 11585, value = 125 },
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

ResolveHighestKnownSpellId = function(token)
    local cache = Decision._spellTokenCache
    if not cache then
        cache = {
            tokenBySpellId = {},
            highestSpellIdByToken = {},
            spellNameByToken = {},
            spellNameToToken = {},
            knownByToken = {},
        }
        for spellId, mappedToken in pairs(TOKEN_BY_RANK_SPELL_ID) do
            cache.tokenBySpellId[spellId] = mappedToken
        end
        for mappedToken, info in pairs(ABILITIES) do
            if info and info.id then
                cache.tokenBySpellId[info.id] = cache.tokenBySpellId[info.id] or mappedToken
            end
            if info and info.name then
                cache.spellNameToToken[info.name] = cache.spellNameToToken[info.name] or mappedToken
            end
        end
        if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo and BOOKTYPE_SPELL then
            local tabs = GetNumSpellTabs() or 0
            for tab = 1, tabs do
                local _, _, offset, numSlots = GetSpellTabInfo(tab)
                local startSlot = (offset or 0) + 1
                local endSlot = (offset or 0) + (numSlots or 0)
                for slot = startSlot, endSlot do
                    local bookName = GetSpellBookItemName and GetSpellBookItemName(slot, BOOKTYPE_SPELL) or nil
                    local _, spellId = GetSpellBookItemInfo(slot, BOOKTYPE_SPELL)
                    local mappedToken = (spellId and cache.tokenBySpellId[spellId]) or nil
                    if not mappedToken and bookName then
                        mappedToken = cache.spellNameToToken[bookName]
                    end
                    if mappedToken then
                        if spellId then
                            cache.tokenBySpellId[spellId] = mappedToken
                            cache.highestSpellIdByToken[mappedToken] = spellId
                        end
                        if bookName and bookName ~= "" then
                            cache.spellNameByToken[mappedToken] = bookName
                            cache.spellNameToToken[bookName] = mappedToken
                        elseif spellId then
                            local resolvedName = GetSpellInfo(spellId)
                            if resolvedName and resolvedName ~= "" then
                                cache.spellNameByToken[mappedToken] = resolvedName
                                cache.spellNameToToken[resolvedName] = mappedToken
                            end
                        end
                        cache.knownByToken[mappedToken] = true
                    end
                end
            end
        end
        Decision._spellTokenCache = cache
    end

    if not token then
        return nil
    end
    local info = ABILITIES[token]
    if not info then
        return nil
    end
    if cache.highestSpellIdByToken and cache.highestSpellIdByToken[token] then
        return cache.highestSpellIdByToken[token]
    end
    local ranks = RANK_IDS_BY_TOKEN[token]
    if type(ranks) == "table" and #ranks > 0 then
        for i = #ranks, 1, -1 do
            local id = ranks[i]
            if cache.tokenBySpellId and cache.tokenBySpellId[id] == token then
                return id
            end
            if IsPlayerSpell and IsPlayerSpell(id) then
                return id
            end
        end
        return ranks[1]
    end
    return info.id
end

-- All Classic Warrior talent-learned spell IDs that may not appear in
-- standard spellbook scan. Covers 31-point talents + key talent-prerequisite spells.
local TALENT_SPELL_IDS = {
    -- Fury tree
    [23881] = true,  -- Bloodthirst (Fury 31-point)
    [12328] = true,  -- Death Wish (Fury 21-point)
    [18499] = true,  -- Berserker Rage (baseline but may behave like talent on some clients)
    -- Arms tree
    [12294] = true,  -- Mortal Strike (Arms 31-point)
    [21551] = true,  -- Mortal Strike Rank 2
    [21552] = true,  -- Mortal Strike Rank 3
    [21553] = true,  -- Mortal Strike Rank 4
    [12292] = true,  -- Sweeping Strikes (Arms 21-point)
    -- Protection tree
    [23922] = true,  -- Shield Slam (Protection 31-point)
    [23923] = true,  -- Shield Slam Rank 2
    [23924] = true,  -- Shield Slam Rank 3
    [23925] = true,  -- Shield Slam Rank 4
    [12975] = true,  -- Last Stand (Protection talent)
    [12809] = true,  -- Concussion Blow (Protection talent)
}

local function IsTokenKnown(token)
    local id = ResolveHighestKnownSpellId(token)
    if not id then
        return nil
    end
    local cache = Decision._spellTokenCache
    if cache and cache.knownByToken and cache.knownByToken[token] then
        return true
    end
    if IsSpellKnown and IsSpellKnown(id) then
        return true
    end
    if IsPlayerSpell and IsPlayerSpell(id) then
        return true
    end
    if FindSpellBookSlotBySpellID and FindSpellBookSlotBySpellID(id) then
        return true
    end
    -- Talent-spell fallback: talent-learned spells (BT, Shield Slam, etc.) may
    -- not appear in spellbook scan or be reported by IsSpellKnown/IsPlayerSpell
    -- on Classic Era. Fall back to checking if the spell name resolves via
    -- GetSpellInfo AND the spell is actually usable (i.e. player has the talent).
    if TALENT_SPELL_IDS[id] then
        local name = GetSpellInfo(id)
        if name and name ~= "" then
            -- GetSpellInfo returns a name even for unlearned spells in the DB,
            -- so verify usability: IsUsableSpell returns true only if the
            -- player actually has the spell available.
            if IsUsableSpell and IsUsableSpell(name) then
                -- Cache for future lookups.
                if cache and cache.knownByToken then
                    cache.knownByToken[token] = true
                end
                return true
            end
            -- Secondary fallback: check if it appears on the action bar or
            -- tooltip resolves to a valid cast. Some clients expose
            -- GetSpellCooldown for known talent spells even when other APIs fail.
            if GetSpellCooldown then
                local start, dur = GetSpellCooldown(name)
                if start ~= nil then
                    if cache and cache.knownByToken then
                        cache.knownByToken[token] = true
                    end
                    return true
                end
            end
        end
    end
    return false
end

local function GetSpellNameByToken(token)
    local id = ResolveHighestKnownSpellId(token)
    local cache = Decision._spellTokenCache
    if cache and cache.spellNameByToken and cache.spellNameByToken[token] then
        return cache.spellNameByToken[token]
    end
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

ExtractAuraSpellId = function(v8, v9, v10, v11)
    if type(v11) == "number" then
        return v11
    end
    if type(v10) == "number" then
        return v10
    end
    if type(v9) == "number" then
        return v9
    end
    if type(v8) == "number" then
        return v8
    end
    return nil
end

local function AuraMatchesSpell(name, rank, spellId, v8, v9, v10, v11)
    local auraSpellId = ExtractAuraSpellId(v8, v9, v10, v11)
    if auraSpellId == spellId then
        return true
    end
    local expectedName = GetSpellInfo(spellId)
    if expectedName and (name == expectedName or ((rank and rank ~= "") and (name .. "(" .. rank .. ")") == expectedName)) then
        return true
    end
    return false
end

local function HasUnitAuraBySpellId(unit, spellId)
    if not unit or not spellId then
        return false
    end
    for i = 1, 40 do
        local name, rank, _, _, _, _, _, _, _, v10, v11 = UnitBuff(unit, i)
        if not name then
            break
        end
        if AuraMatchesSpell(name, rank, spellId, nil, nil, v10, v11) then
            return true
        end
    end
    for i = 1, 40 do
        local name, rank, _, _, _, _, _, _, _, v10, v11 = UnitDebuff(unit, i)
        if not name then
            break
        end
        if AuraMatchesSpell(name, rank, spellId, nil, nil, v10, v11) then
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
        local name, rank, _, _, _, v6, v7, v8, v9, v10, v11 = UnitBuff(unit, i)
        if not name then
            break
        end
        local duration = 0
        local expirationTime = 0
        local auraSpellId = nil

        if type(v6) == "number" and type(v7) == "number" then
            duration = v6 or 0
            expirationTime = v7 or 0
            auraSpellId = ExtractAuraSpellId(nil, nil, v10, v11)
        elseif type(v6) == "number" and type(v7) == "string" then
            expirationTime = v6 or 0
            auraSpellId = ExtractAuraSpellId(nil, nil, v10, v11)
        else
            auraSpellId = ExtractAuraSpellId(v8, v9, v10, v11)
        end
        if auraSpellId and spellIdSet[auraSpellId] then
            local remaining = 0
            if type(expirationTime) == "number" and expirationTime > 0 then
                remaining = math.max(expirationTime - now, 0)
            end
            return true, remaining, duration or 0, auraSpellId
        end
        for expectedSpellId in pairs(spellIdSet) do
            local expectedName = GetSpellInfo(expectedSpellId)
            if expectedName and (name == expectedName or ((rank and rank ~= "") and (name .. "(" .. rank .. ")") == expectedName)) then
                local remaining = 0
                if type(expirationTime) == "number" and expirationTime > 0 then
                    remaining = math.max(expirationTime - now, 0)
                end
                return true, remaining, duration or 0, expectedSpellId
            end
        end
    end
    return false, 0, 0, nil
end

local function GetTalentTabPoints(tabIndex)
    if not (tabIndex and GetTalentTabInfo) then
        return 0
    end
    local argVariants = {
        { tabIndex },
        { tabIndex, false, false },
        { tabIndex, false, false, 1 },
        { tabIndex, nil, false },
        { tabIndex, nil, false, 1 },
    }
    for i = 1, #argVariants do
        local ok, _, _, points = pcall(GetTalentTabInfo, unpack(argVariants[i]))
        if ok and type(points) == "number" and points >= 0 then
            return points
        end
    end
    return 0
end

local function GetTalentTabCount()
    if not GetNumTalentTabs then
        return 0
    end
    local argVariants = {
        {},
        { false, false },
        { false, false, 1 },
        { nil, false },
        { nil, false, 1 },
    }
    for i = 1, #argVariants do
        local ok, count = pcall(GetNumTalentTabs, unpack(argVariants[i]))
        if ok and type(count) == "number" and count > 0 then
            return count
        end
    end
    return 0
end

local function SumTalentPointsByTab(tabIndex)
    if not (tabIndex and GetNumTalents and GetTalentInfo) then
        return 0
    end
    local talentCount = 0
    local countVariants = {
        { tabIndex },
        { tabIndex, false, false },
        { tabIndex, false, false, 1 },
        { tabIndex, nil, false },
        { tabIndex, nil, false, 1 },
    }
    for i = 1, #countVariants do
        local ok, count = pcall(GetNumTalents, unpack(countVariants[i]))
        if ok and type(count) == "number" and count > 0 then
            talentCount = count
            break
        end
    end
    if talentCount <= 0 then
        return 0
    end
    local total = 0
    local infoVariants = {
        {},
        { false, false },
        { false, false, 1 },
        { nil, false },
        { nil, false, 1 },
    }
    for talentIndex = 1, talentCount do
        local currentRank = 0
        for i = 1, #infoVariants do
            local ok, _, _, _, _, rank = pcall(GetTalentInfo, tabIndex, talentIndex, unpack(infoVariants[i]))
            if ok and type(rank) == "number" then
                currentRank = rank
                break
            end
        end
        total = total + currentRank
    end
    return total
end

local function InvalidateExecuteModelCache()
    EXECUTE_MODEL_CACHE = nil
    EXECUTE_MODEL_CACHE_AT = 0
end

local function InvalidateEquipmentStateCache()
    EquipmentStateCache.dirty = true
end

local function InvalidateBattleShoutAuraCache()
    BattleShoutAuraCache.dirty = true
end

local function ResetHabitState(modeKey, inCombat)
    HabitState.lockedSkill = nil
    HabitState.lockedAt = 0
    HabitState.lastSwitchAt = 0
    HabitState.candidateSkill = nil
    HabitState.candidateSince = 0
    HabitState.mode = nil
    HabitState.modeKey = modeKey
    HabitState.inCombat = inCombat and true or false
end

local function BuildHabitModeKey(context)
    local mode = context and context.mode or "UNKNOWN"
    local stance = context and context.stance or "UNKNOWN"
    local override = context and context.modeOverride or "auto"
    return table.concat({ mode, stance, override }, "|")
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
        local tabs = GetTalentTabCount()
        for i = 1, tabs do
            local points = GetTalentTabPoints(i)
            if i == 1 then
                state.armsPoints = points or 0
            elseif i == 2 then
                state.furyPoints = points or 0
            elseif i == 3 then
                state.protPoints = points or 0
            end
        end
    end

    if state.armsPoints == 0 and state.furyPoints == 0 and state.protPoints == 0 and GetNumTalents and GetTalentInfo then
        for tabIndex = 1, 3 do
            local spent = SumTalentPointsByTab(tabIndex)
            if tabIndex == 1 then
                state.armsPoints = spent
            elseif tabIndex == 2 then
                state.furyPoints = spent
            elseif tabIndex == 3 then
                state.protPoints = spent
            end
        end
    end
    return state
end

local function ComputeEquipmentState()
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

    local state = {
        hasMainHand = mainLink ~= nil,
        hasOffHand = offLink ~= nil,
        hasOffHandItem = offLink ~= nil,
        hasShield = hasShield,
        hasOffhandWeapon = hasOffhandWeapon,
        dualWieldWeapon = hasOffhandWeapon,
        dualWield = hasOffhandWeapon,
        speedMain = 0,
        speedOff = 0,
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

local function ReadEquipmentState()
    if EquipmentStateCache.dirty or type(EquipmentStateCache.value) ~= "table" then
        EquipmentStateCache.value = ComputeEquipmentState()
        EquipmentStateCache.dirty = false
    end
    local state = EquipmentStateCache.value
    if type(state) == "table" then
        local speedMain, speedOff = UnitAttackSpeed("player")
        state.speedMain = speedMain or 0
        state.speedOff = speedOff or 0
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

local function ComputeBuffState()
    local flurry = HasUnitAuraBySpellId("player", SPELL_ID.FLURRY_BUFF)
    -- B2 fix: fallback to name-based detection if spell-ID match fails.
    if not flurry then
        for i = 1, 40 do
            local name = UnitBuff("player", i)
            if not name then break end
            if name == "Flurry" or name == "\228\185\177\232\136\158" then
                flurry = true
                break
            end
        end
    end
    local deathWish = HasUnitAuraBySpellId("player", SPELL_ID.DEATH_WISH_BUFF)
    local reck = HasUnitAuraBySpellId("player", SPELL_ID.RECKLESSNESS_BUFF)
    local bloodrage = HasUnitAuraBySpellId("player", SPELL_ID.BLOODRAGE_BUFF)
    local berserkerRage = HasUnitAuraBySpellId("player", SPELL_ID.BERSERKER_RAGE_BUFF)
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

local function ReadBuffState()
    IsPerFrameCacheValid()
    if PerFrameCache.buffState then
        return PerFrameCache.buffState
    end
    local state = ComputeBuffState()
    PerFrameCache.buffState = state
    return state
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

local function ComputeProcWeightState()
    local weights = NewWeightBag()
    local active = {}

    local procProfiles = GetBuffTrinketWeightProfiles()
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, v10, v11 = UnitBuff("player", i)
        if not name then
            break
        end
        local spellId = ExtractAuraSpellId(nil, nil, v10, v11)
        local profile = procProfiles[spellId]
        if profile and profile.weights then
            AddWeightBag(weights, profile.weights, 1)
            table.insert(active, string.format("%s(%d)", profile.name or name, spellId or 0))
        end
    end

    return weights, active
end

local function BuildProcWeightState()
    IsPerFrameCacheValid()
    if PerFrameCache.procWeights then
        return PerFrameCache.procWeights, PerFrameCache.procActive
    end
    local weights, active = ComputeProcWeightState()
    PerFrameCache.procWeights = weights
    PerFrameCache.procActive = active
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

local function ScanBattleShoutAuraCache()
    local now = GetTime()
    local units = {}
    ForEachGroupUnit(function(unit)
        if not IsUnitBattleShoutCandidate(unit) then
            return
        end
        local active, remaining, duration, auraSpellId = GetUnitBuffInfoBySpellIds(unit, BATTLE_SHOUT_RANK_ID_SET)
        units[unit] = {
            active = active and true or false,
            remaining = remaining or 0,
            duration = duration or 0,
            auraSpellId = auraSpellId,
            expiresAt = active and (now + math.max(remaining or 0, 0)) or 0,
        }
    end)
    BattleShoutAuraCache.units = units
    BattleShoutAuraCache.scannedAt = now
    BattleShoutAuraCache.dirty = false
end

local function ReadBattleShoutState(cfg)
    local refreshSeconds = (cfg and cfg.battleShoutRefreshSeconds) or 12
    if BattleShoutAuraCache.dirty then
        ScanBattleShoutAuraCache()
    end
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
        local cached = BattleShoutAuraCache.units and BattleShoutAuraCache.units[unit] or nil
        local active = cached and cached.active or false
        local remaining = 0
        if active and cached and type(cached.expiresAt) == "number" and cached.expiresAt > 0 then
            remaining = math.max(cached.expiresAt - GetTime(), 0)
        end
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
    -- B1 fix: divide total DPS by hostileCount to estimate single-target DPS.
    local targetDps = totalDps / math.max(hostileCount or 1, 1)
    if targetDps <= 0 then
        return nil, targetDps, snapshot
    end
    return targetHealthAbs / targetDps, targetDps, snapshot
end

-- 前置声明：BuildContext 会提前读取这些函数。
local ReadHamstringState
local ReadOverpowerState

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
    local overpowerState = ReadOverpowerState()
    local sunderState = ReadSunderState()
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
        overpowerState = overpowerState,
        sunderState = sunderState,
        known = {
            battleShout = IsTokenKnown(TOKENS.BATTLE_SHOUT),
            execute = IsTokenKnown(TOKENS.EXECUTE),
            overpower = IsTokenKnown(TOKENS.OVERPOWER),
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
            op = GetCooldownRemaining(GetSpellNameByToken(TOKENS.OVERPOWER)),
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
    local now = GetTime()
    if EXECUTE_MODEL_CACHE and (now - (EXECUTE_MODEL_CACHE_AT or 0)) <= EXECUTE_MODEL_CACHE_TTL then
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
            -- B3 fix: warn once when description parsing fails (localization mismatch).
            model.source = "fallback-default:" .. tostring(spellId)
            if ns.Print and not Decision._executeParseWarned then
                Decision._executeParseWarned = true
                ns.Print(string.format(
                    "|cffff9900[Fury]|r Execute model parse failed for spellId=%s, using fallback (base=%d per=%d max=%d). Desc='%s'",
                    tostring(spellId), model.baseDamage, model.perRage, model.maxExtraRage,
                    tostring(desc or "nil"):sub(1, 80)
                ))
            end
        end
    end

    EXECUTE_MODEL_CACHE = model
    EXECUTE_MODEL_CACHE_AT = now
    return model
end

local function EstimateExecuteDamage(rage)
    -- 自动模型（优先从技能描述解析），仅用于决策排序。
    local model = GetExecuteModel()
    local extraRage = Clamp((rage or 0) - 15, 0, model.maxExtraRage)
    return model.baseDamage + extraRage * model.perRage, extraRage, model
end

ReadSunderState = function()
    IsPerFrameCacheValid()
    if PerFrameCache.sunderState then
        return PerFrameCache.sunderState
    end
    local result = {
        stacks = 0,
        remaining = 0,
        hasDebuff = false,
    }
    if not UnitExists("target") then
        PerFrameCache.sunderState = result
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
            PerFrameCache.sunderState = result
            return result
        end
    end
    PerFrameCache.sunderState = result
    return result
end

ReadHamstringState = function()
    IsPerFrameCacheValid()
    if PerFrameCache.hamstringState then
        return PerFrameCache.hamstringState
    end
    local result = {
        hasDebuff = false,
        remaining = 0,
    }
    if not UnitExists("target") then
        PerFrameCache.hamstringState = result
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
            PerFrameCache.hamstringState = result
            return result
        end
    end
    PerFrameCache.hamstringState = result
    return result
end

ReadOverpowerState = function()
    local result = {
        active = false,
        targetGuid = nil,
        remaining = 0,
        triggeredAt = 0,
    }
    if not UnitExists("target") then
        return result
    end
    local targetGuid = UnitGUID("target")
    if ns.metrics and ns.metrics.GetOverpowerState then
        local state = ns.metrics.GetOverpowerState(targetGuid, GetTime())
        if type(state) == "table" then
            result.active = state.active and IsBattleStanceStrict() or false
            result.targetGuid = state.targetGuid
            result.remaining = tonumber(state.remaining) or 0
            result.triggeredAt = tonumber(state.triggeredAt) or 0
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

local function GetHamstringNextSwingPair(context)
    local queue = context and context.queue or {}
    local equipment = context and context.equipment or {}
    local nextMain = tonumber(queue.timeToMain) or math.huge
    local nextOff = equipment.hasOffhandWeapon and (tonumber(queue.timeToOff) or math.huge) or math.huge
    local first = math.min(nextMain, nextOff)
    local second
    if nextMain <= nextOff then
        second = nextOff
    else
        second = nextMain
    end
    if second == math.huge then
        second = first
    end
    return first, second
end

local function IsPerfectHamstringBaitWindow(context)
    local firstSwing, secondSwing = GetHamstringNextSwingPair(context)
    return (tonumber(context and context.critChance) or 0) <= 25
        and firstSwing <= 0.25
        and secondSwing <= 0.55
        and (tonumber(context and context.rage) or 0) >= 20
        and not (context and context.buffs and context.buffs.flurry)
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
    local perfectWindow = IsPerfectHamstringBaitWindow(context)
    if context and context.buffs and context.buffs.flurry then
        return -60, { reason = "Flurry已激活，断筋骗乱舞收益极低" }
    end
    local flurryUptime = GetHamstringObservedFlurryUptime(context)
    if flurryUptime >= 0.45 and not perfectWindow then
        return -28, { reason = string.format("乱舞覆盖已稳定(%.0f%%)，继续断筋会开始扰乱主循环", flurryUptime * 100) }
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
    local nextSwing, secondSwing = GetHamstringNextSwingPair(context)
    local critChance = tonumber(context and context.critChance) or 0
    if nextSwing > 0.75 then
        return -22, { reason = string.format("最近挥击窗口偏远(%.2fs)，断筋难以快速兑现乱舞收益", nextSwing) }
    end
    if secondSwing > 1.35 and (tonumber(context and context.cooldown and context.cooldown.bt) or math.huge) > 0.85
        and (tonumber(context and context.cooldown and context.cooldown.ww) or math.huge) > 1.10 then
        return -18, { reason = "后续可兑现收益的第二个攻击事件过远，断筋时机不佳" }
    end
    if naturalChance >= 0.55 then
        return -28, { reason = string.format("自然触发乱舞概率已很高(%.0f%%)，无需再用断筋补触发", naturalChance * 100) }
    end
    if critChance >= 38 and not (nextSwing <= 0.22 and secondSwing <= 0.65 and (tonumber(context and context.rage) or 0) >= 28) then
        return -26, { reason = "高暴击环境下仅在极佳双挥击窗口才考虑断筋" }
    end
    if critChance >= 35 and naturalChance >= 0.40 then
        return -24, { reason = "高暴击环境下自然乱舞已足够频繁，断筋不应成为常规填充" }
    end
    local swingValue, chargeCount = EstimateFlurrySwingValue(context, hamCfg)
    if chargeCount <= 0 or swingValue <= 0 then
        return -40, { reason = "未来挥击窗口过短，断筋骗乱舞吃不满3层收益" }
    end
    local deltaProc = Clamp(pHamCrit * (1 - naturalChance), 0, 1)
    if deltaProc < 0.10 then
        return -20, { reason = string.format("额外乱舞触发概率仅%.0f%%，断筋边际收益不足", deltaProc * 100) }
    end
    local timingBonus = 0
    if nextSwing <= 0.30 and secondSwing <= 0.85 then
        timingBonus = 4
    elseif nextSwing <= 0.45 then
        timingBonus = 2
    end
    if critChance <= 25 and nextSwing <= 0.25 and secondSwing <= 0.55 and (tonumber(context and context.rage) or 0) >= 20 and naturalChance <= 0.32 then
        timingBonus = timingBonus + 10
    end
    local reserve = CalcHamstringProtectReserve(context, hamCfg)
    if (tonumber(context and context.rage) or 0) < 18 and (nextSwing > 0.35 or secondSwing > 0.95) then
        return -26, { reason = "怒气偏低且挥击兑现不够快，应优先保留资源" }
    end
    if estTtd and estTtd <= math.max((tonumber(hamCfg and hamCfg.minTargetTtdSeconds) or 10) * 2.0, 24.0)
        and (tonumber(context and context.rage) or 0) < math.max(reserve + 12, 28) then
        return -24, { reason = "中短战斗且怒气偏紧，应优先保证主循环而不是断筋" }
    end
    local rageAfter = (tonumber(context and context.rage) or 0) - ABILITIES[TOKENS.HAMSTRING].rage
    local ragePenalty = math.max(0, reserve - rageAfter) * (tonumber(hamCfg and hamCfg.ragePenaltyScale) or 0.8)
    if flurryUptime >= 0.65 then
        ragePenalty = ragePenalty + (flurryUptime - 0.65) * 10
    end
    if context and context.queue and context.queue.queueWindowOpen and (context.equipment and context.equipment.hasOffhandWeapon) and rageAfter < 30 then
        ragePenalty = ragePenalty + 2
    end
    local score = (tonumber(hamCfg and hamCfg.baseBias) or 1)
        + deltaProc * swingValue * (tonumber(hamCfg and hamCfg.evScale) or 18)
        + timingBonus
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
        timingBonus = timingBonus,
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

-- P1: extract comparator to module-level local to avoid per-call closure allocation.
local function EvalComparator(a, b)
    if a.passed ~= b.passed then
        return a.passed and not b.passed
    end
    if a.score == b.score then
        return a.token < b.token
    end
    return a.score > b.score
end

local function SortEvaluations(list)
    table.sort(list, EvalComparator)
end

local function FilterUnknownEvaluations(list)
    if not list then
        return list
    end
    for i = #list, 1, -1 do
        local entry = list[i]
        local token = entry and entry.token or nil
        if token and ABILITIES[token] and IsTokenKnown(token) == false then
            table.remove(list, i)
        end
    end
    return list
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

local function GetDpsShoutProtectedMainSkill(context)
    if not context or not context.inCombat or not context.targetExists then
        return nil
    end
    local protectWindow = math.max(tonumber(context.gcdRem) or 0, 0) + 1.5
    local cooldown = context.cooldown or {}

    if context.targetHealthPct and context.targetHealthPct <= 20
        and (cooldown.ex or math.huge) <= protectWindow then
        return TOKENS.EXECUTE
    end
    if IsBattleStanceStrict() and context.overpowerState and context.overpowerState.active
        and (context.overpowerState.remaining or 0) > 0
        and (context.overpowerState.remaining or 0) <= protectWindow then
        return TOKENS.OVERPOWER
    end
    if context.known and context.known.bloodthirst and (cooldown.bt or math.huge) <= protectWindow then
        return TOKENS.BLOODTHIRST
    end
    if context.known and context.known.whirlwind and (cooldown.ww or math.huge) <= protectWindow then
        return TOKENS.WHIRLWIND
    end
    return nil
end

local function BuildBattleShoutEval(context, cfg, mode, threat)
    local shoutCfg = cfg or context.config or Decision.GetConfig()
    local shoutState = context.battleShoutState or ReadBattleShoutState(shoutCfg)
    local shout = NewEval(TOKENS.BATTLE_SHOUT, mode == "TPS_SURVIVAL" and 64 or 18)
    local oocMinRage = math.max(ABILITIES[TOKENS.BATTLE_SHOUT].rage, shoutCfg.battleShoutOocMinRage or 10)
    local playerShoutActive = (context.buffs and context.buffs.battleShout) or (shoutState and shoutState.selfActive) or false
    local playerShoutRemaining = tonumber(context.buffs and context.buffs.battleShoutRemaining) or (shoutState and shoutState.selfRemaining) or 0
    local refreshSeconds = (shoutState and shoutState.refreshSeconds) or shoutCfg.battleShoutRefreshSeconds or 12
    local dpsRefreshWindow = math.min(refreshSeconds, 4)
    local playerNeedsCast = (not playerShoutActive)
        or (playerShoutRemaining <= ((mode == "DPS" and context.inCombat) and dpsRefreshWindow or refreshSeconds))
    local needsCast = ((mode == "TPS_SURVIVAL") and IsBattleShoutRefreshWindow(shoutState))
        or playerNeedsCast
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
        if not playerShoutActive then
            AddReason(shout, 12, "自身未覆盖 Battle Shout")
        else
            AddReason(shout, 8, "Battle Shout 即将到期(" .. string.format("%.1f", playerShoutRemaining or 0) .. "s)")
        end
        if shoutState.effectUnits > 1 then
            AddReason(shout, math.floor((shoutState.effectUnits - 1) * 3), "顺手补到附近队友")
        end
        return shout
    end

    if mode == "DPS" then
        if playerShoutActive and playerShoutRemaining > dpsRefreshWindow then
            Reject(shout, "DPS下 Battle Shout 剩余时间充足")
            return shout
        end
        local sunderState = context.sunderState or ReadSunderState()
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

        local protectedToken = GetDpsShoutProtectedMainSkill(context)
        if protectedToken then
            Reject(shout, "主循环保护窗内，Battle Shout 让位 " .. tostring(protectedToken))
            return shout
        end

        AddReason(shout, 6, "Battle Shout 进入补/续窗口")
        if not playerShoutActive then
            AddReason(shout, 10, "自身未覆盖 Battle Shout")
        else
            AddReason(shout, 4, "Battle Shout 即将到期(" .. string.format("%.1f", playerShoutRemaining or 0) .. "s)")
        end
        if shoutState.effectUnits > 1 then
            AddReason(shout, math.floor((shoutState.effectUnits - 1) * 1.5), "兼顾队友覆盖收益")
        end
        if context.targetBossLike then
            AddReason(shout, 2, "Boss战中长期收益更稳定")
        end
        if context.targetHealthPct and context.targetHealthPct <= 20 then
            AddReason(shout, -18, "斩杀期优先直接伤害")
        end
        if context.trinket and context.trinket.anyActive then
            AddReason(shout, -8, "爆发窗口优先直接伤害技能")
        end
        if context.weights and context.weights.dps and context.weights.dps > 0 then
            AddReason(shout, math.floor(context.weights.dps * 0.1), "白名单权重: 团队Buff收益")
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

local function BuildOutOfCombatEvaluations(context)
    local cfg = Decision.GetConfig()
    local threat = context.threat or ReadThreatState()
    local list = {}

    local shout = BuildBattleShoutEval(context, cfg, context.mode, threat)
    if shout.passed and context.weights and context.weights.ap and context.weights.ap > 0 then
        AddReason(shout, math.floor(context.weights.ap / 180), "白名单权重: AP团队收益")
    end
    table.insert(list, shout)

    local wait = NewEval(TOKENS.WAIT, 0)
    AddReason(wait, 0, "脱战状态，仅显示可预铺Buff")
    table.insert(list, wait)

    FilterUnknownEvaluations(list)
    SortEvaluations(list)
    return list
end

local function ShouldRejectSunderForLowHp(context, cfg, sunderState)
    local threshold = tonumber(cfg and cfg.sunderHpThreshold) or 50000
    local targetHealthAbs = tonumber(context and context.targetHealthAbs) or 0
    local stacks = tonumber(sunderState and sunderState.stacks) or 0
    return threshold > 0 and targetHealthAbs > 0 and targetHealthAbs <= threshold and stacks ~= 0
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

    if ShouldRejectSunderForLowHp(context, cfg, sunderState) then
        Reject(eval, "目标HP低于阈值且已有破甲层数，无需继续提示")
        return
    end

    if duty == "maintain_only" and stacks <= 0 then
        Reject(eval, "职责=maintain_only，不负责抢首层")
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

    if ShouldRejectSunderForLowHp(context, cfg, sunderState) then
        Reject(eval, "目标HP低于阈值且已有破甲层数，无需继续提示")
        return
    end

    if duty == "self_stack" then
        if context.targetBossLike then
            local refreshWindow = math.max(cfg.sunderRefreshSeconds + 2, 12)
            local urgentWindow = math.max(cfg.sunderRefreshSeconds * 0.75, 6)
            if stacks < targetStacks then
                AddReason(eval, -16, "Boss战补层职责交给 DPS")
            elseif remaining < refreshWindow then
                AddReason(eval, 22, "Boss破甲进入刷新窗口，由 tank 提前择机续层")
                if remaining <= urgentWindow then
                    AddReason(eval, 18, "破甲剩余已偏短，应明显抬高刷新优先级")
                end
                if remaining <= 3.0 then
                    AddReason(eval, 16, "接近掉层，当前GCD应强烈倾向补 Sunder")
                elseif remaining <= 6.0 then
                    AddReason(eval, 10, "已进入高风险刷新区间，不应继续拖延")
                end
                if threat.status >= 2 and threat.scaledPct >= 95 then
                    AddReason(eval, 16, "仇恨稳定，适合用当前GCD刷新破甲")
                else
                    AddReason(eval, -6, "仇恨未完全站稳，刷新应稍后但不能拖掉层")
                end
                if context.cooldown.ss > context.horizonSec and context.cooldown.rev > context.horizonSec then
                    AddReason(eval, 8, "主威胁技能暂不在窗口，当前补刷新损失更小")
                else
                    AddReason(eval, -2, "高优先仇恨技能就绪，但仍需兼顾破甲掉层风险")
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
            local refreshWindow = math.max(cfg.sunderRefreshSeconds + 2, 12)
            if stacks <= 0 then
                AddReason(eval, -18, "Boss补层由 DPS 负责，tank 不抢首层")
            elseif stacks < targetStacks then
                AddReason(eval, -8 + missingStacks, "Boss补层阶段不建议由 tank 继续叠层")
            elseif remaining < refreshWindow then
                AddReason(eval, 16, "Boss5层进入刷新窗口，由 tank 负责维持")
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

local function BuildBloodthirstEval(context, opts)
    local bt = NewEval(TOKENS.BLOODTHIRST, (opts and opts.baseScore) or 80)
    ApplyCommonChecks(bt, context, {
        requireTarget = true,
        usableToken = TOKENS.BLOODTHIRST,
        rangeToken = TOKENS.BLOODTHIRST,
        rageCost = ABILITIES[TOKENS.BLOODTHIRST].rage,
        cooldown = context.cooldown.bt,
    })
    if bt.passed and opts and type(opts.onPassed) == "function" then
        opts.onPassed(bt)
    end
    ApplyLevelUtilityScale(bt, context, TOKENS.BLOODTHIRST)
    return bt
end

local function BuildSunderEval(context, cfg, opts)
    local sunder = NewEval(TOKENS.SUNDER_ARMOR, (opts and opts.baseScore) or 32)
    ApplyCommonChecks(sunder, context, {
        requireTarget = true,
        usableToken = TOKENS.SUNDER_ARMOR,
        rangeToken = TOKENS.SUNDER_ARMOR,
        rageCost = ABILITIES[TOKENS.SUNDER_ARMOR].rage,
        cooldown = 0,
    })
    if sunder.passed and opts and type(opts.onPassed) == "function" then
        opts.onPassed(sunder)
    end
    ApplyLevelUtilityScale(sunder, context, TOKENS.SUNDER_ARMOR)
    return sunder
end

local function BuildDpsEvaluations(context)
    local cfg = Decision.GetConfig()
    local hamCfg = Decision.GetHamstringConfig()
    local w = context.weights or NewWeightBag()
    local list = {}
    local threat = context.threat or ReadThreatState()
    local dpsAggressiveBonus = (threat.scaledPct > 95) and GetPolicyParam("dps_threat_aggressive_bonus", 3.0) or 0

    if not context.inCombat then
        return BuildOutOfCombatEvaluations(context)
    end

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

    local overpower = NewEval(TOKENS.OVERPOWER, 88)
    ApplyCommonChecks(overpower, context, {
        requireTarget = true,
        usableToken = TOKENS.OVERPOWER,
        rangeToken = TOKENS.OVERPOWER,
        rageCost = ABILITIES[TOKENS.OVERPOWER].rage,
        cooldown = context.cooldown.op,
        predicate = function(ctx)
            local opState = ctx.overpowerState or {}
            return IsBattleStanceStrict()
                and opState.active
                and (opState.remaining or 0) > 0
                and (not opState.targetGuid or opState.targetGuid == UnitGUID("target"))
        end,
        predicateReason = "需战斗姿态且当前目标刚躲闪后才可用",
    })
    if overpower.passed then
        local opState = context.overpowerState or {}
        AddReason(overpower, 22, "目标刚躲闪，压制进入限时窗口")
        if (opState.remaining or 0) <= 1.5 then
            AddReason(overpower, 18, "压制窗口即将结束，应优先打出")
        elseif (opState.remaining or 0) <= 3 then
            AddReason(overpower, 10, "压制窗口有限，应尽快消化")
        end
        if context.buffs and context.buffs.offensiveBurst then
            AddReason(overpower, 4, "爆发Buff窗口，压制收益提升")
        end
        if context.targetBossLike then
            AddReason(overpower, 4, "Boss战中单次高效率技能更值得消化")
        end
        if w.dps ~= 0 then
            AddReason(overpower, math.floor(w.dps * 0.25), "白名单权重: DPS倾向")
        end
        if dpsAggressiveBonus > 0 then
            AddReason(overpower, dpsAggressiveBonus, "仇恨余量较高，可积极消化压制窗口")
        end
    end
    table.insert(list, overpower)

    local bt = BuildBloodthirstEval(context, {
        baseScore = 82,
        onPassed = function(eval)
            AddReason(eval, math.min(20, math.floor((context.rage - 30) / 3)), "怒气满足主循环")
            if context.talents and context.talents.hasBloodthirst then
                AddReason(eval, 6, "天赋已点出 Bloodthirst")
            end
            if context.buffs and context.buffs.flurry then
                AddReason(eval, 4, "Flurry触发中，主循环收益提升")
            end
            if context.buffs and context.buffs.offensiveBurst then
                AddReason(eval, 6, "爆发Buff窗口，优先高收益技能")
            end
            if w.bloodthirst ~= 0 then
                AddReason(eval, w.bloodthirst, "白名单权重: Bloodthirst")
            end
            if w.ap > 0 then
                AddReason(eval, math.floor(w.ap / 120), "白名单权重: AP加成")
            end
            if dpsAggressiveBonus > 0 then
                AddReason(eval, dpsAggressiveBonus, "仇恨余量较高，可更积极使用主循环")
            end
        end,
    })
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

    local sunder = BuildSunderEval(context, cfg, {
        baseScore = 32,
        onPassed = function(eval)
            local sunderState = context.sunderState or ReadSunderState()
            ApplyDpsSunderDuty(eval, context, cfg, sunderState)
            if not eval.passed then
                return
            end
            local delta, note = CalcSunderValue(context, context.mode, cfg)
            AddReason(eval, delta, note)
            AddReason(eval, 3, "可作为填充GCD")
            if context.trinket and context.trinket.anyActive then
                AddReason(eval, -2, "饰品爆发中，优先直接伤害技能")
            end
            if w.sunder ~= 0 then
                AddReason(eval, w.sunder, "白名单权重: Sunder")
            end
        end,
    })
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
        local perfectBaitWindow = IsPerfectHamstringBaitWindow(context)
        if not perfectBaitWindow then
            if context.cooldown.bt <= (hamCfg.btProtectMs / 1000)
                and context.rage >= 26
                and context.rage < (ABILITIES[TOKENS.BLOODTHIRST].rage + hamCfg.rageSafetyReserve) then
                protected = true
            end
            if context.cooldown.ww <= (hamCfg.wwProtectMs / 1000)
                and context.rage >= 21
                and context.rage < (ABILITIES[TOKENS.WHIRLWIND].rage + hamCfg.rageSafetyReserve) then
                protected = true
            end
            if context.targetHealthPct and context.targetHealthPct <= 20 and context.cooldown.ex <= (hamCfg.exProtectMs / 1000)
                and context.rage >= 12
                and context.rage < (ABILITIES[TOKENS.EXECUTE].rage + hamCfg.rageSafetyReserve) then
                protected = true
            end
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
            elseif perfectBaitWindow and evScore >= -4 then
                AddReason(ham, evScore + 10, string.format(
                    "极佳双挥击窗口，允许提前断筋骗乱舞(基础EV=%.1f)",
                    evScore
                ))
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
    ApplyLevelUtilityScale(overpower, context, TOKENS.OVERPOWER)
    ApplyLevelUtilityScale(ww, context, TOKENS.WHIRLWIND)
    ApplyLevelUtilityScale(shout, context, TOKENS.BATTLE_SHOUT)
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

    FilterUnknownEvaluations(list)
    SortEvaluations(list)
    return list
end

local function BuildTpsEvaluations(context)
    local cfg = Decision.GetConfig()
    local w = context.weights or NewWeightBag()
    local list = {}
    local threat = context.threat or ReadThreatState()
    local sunderState = context.sunderState or ReadSunderState()
    local threatUrgency = context.threatUrgency or CalcThreatUrgency(threat)
    local survivalUrgency = context.survivalUrgency or CalcSurvivalUrgency(context.playerHealthPct)
    local tpsThreatBias = context.tpsThreatBias or CalcTpsThreatBias(threat)
    local tauntUrgencyCoeff = GetPolicyParam("taunt_urgency_coeff", 2.2)
    local revengeUrgencyCoeff = GetPolicyParam("revenge_urgency_coeff", 1.2)
    local shieldSlamUrgencyCoeff = GetPolicyParam("shield_slam_urgency_coeff", 1.4)
    local bloodthirstUrgencyCoeff = GetPolicyParam("bloodthirst_tps_urgency_coeff", 0.6)
    local lastStandSurvivalCoeff = GetPolicyParam("last_stand_survival_coeff", 1.7)

    if not context.inCombat then
        return BuildOutOfCombatEvaluations(context)
    end

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

    local sunder = BuildSunderEval(context, cfg, {
        baseScore = 82,
        onPassed = function(eval)
            if threat.status <= 1 then
                AddReason(eval, 16, "仇恨地位偏低，补破甲拉升TPS")
            elseif threat.status == 2 then
                AddReason(eval, 8, "仇恨接近前排，破甲有稳定收益")
            else
                AddReason(eval, 2, "已稳住仇恨，破甲收益较平缓")
            end

            ApplyTpsSunderDuty(eval, context, cfg, sunderState)
            if not eval.passed then
                return
            end

            if threat.scaledPct < 90 then
                AddReason(eval, 10, "威胁百分比<90%，补稳仇恨面")
            end
            if tpsThreatBias > 0 then
                AddReason(eval, math.floor(tpsThreatBias), "TPS 威胁偏置")
            end
            if w.sunder ~= 0 then
                AddReason(eval, w.sunder, "白名单权重: Sunder")
            end
            if w.threat ~= 0 then
                AddReason(eval, math.floor(w.threat * 0.35), "白名单权重: 仇恨")
            end
            local delta, note = CalcSunderValue(context, context.mode, cfg)
            AddReason(eval, delta, note)
            AddReason(eval, 8, "兜底仇恨技能")
        end,
    })
    table.insert(list, sunder)

    local shout = BuildBattleShoutEval(context, cfg, "TPS_SURVIVAL", threat)
    if shout.passed and w.tps ~= 0 then
        AddReason(shout, math.floor(w.tps * 0.25), "白名单权重: TPS倾向")
    end
    table.insert(list, shout)

    local bt = BuildBloodthirstEval(context, {
        baseScore = 78,
        onPassed = function(eval)
            AddReason(eval, 8, "狂暴坦可用的高威胁回填")
            if threat.status <= 1 then
                AddReason(eval, 10, "仇恨未稳，需强力单体威胁")
            end
            if threatUrgency > 0 then
                AddReason(eval, math.floor(threatUrgency * bloodthirstUrgencyCoeff), "威胁紧迫度提升 BT 价值")
            end
            if sunderState.stacks < cfg.sunderTargetStacks then
                AddReason(eval, -8, "破甲层数未满，先稳破甲更优")
            end
            if context.buffs and context.buffs.offensiveBurst then
                AddReason(eval, 5, "爆发Buff窗口下 BT 威胁更高")
            end
            if w.bloodthirst ~= 0 then
                AddReason(eval, w.bloodthirst, "白名单权重: Bloodthirst")
            end
            if w.ap > 0 then
                AddReason(eval, math.floor(w.ap / 140), "白名单权重: AP加成")
            end
        end,
    })
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
    FilterUnknownEvaluations(list)
    SortEvaluations(list)
    return list
end

local function PickBest(list)
    if not list or #list == 0 then
        return TOKENS.NONE, "无候选技能"
    end
    local best = nil
    for _, entry in ipairs(list) do
        if entry.passed then
            best = entry
            break
        end
    end
    if not best then
        best = list[1]
    end
    if not best.passed and best.token ~= TOKENS.WAIT then
        return TOKENS.WAIT, "候选技能均不满足，等待窗口"
    end
    return best.token, (best.reasons[1] or "最高分候选"), best
end

local function IsActionToken(token)
    return token and token ~= TOKENS.WAIT and token ~= TOKENS.NONE
end

FindEvalByToken = function(list, token)
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

    local modeKey = BuildHabitModeKey(context)
    if HabitState.modeKey ~= modeKey then
        ResetHabitState(modeKey, context.inCombat)
        info.decision = "reset-mode"
    end
    if HabitState.inCombat ~= context.inCombat then
        ResetHabitState(modeKey, context.inCombat)
        info.decision = info.decision == "reset-mode" and "reset-mode-combat" or "reset-combat"
    end

    if not context.targetExists then
        ResetHabitState(modeKey, context.inCombat)
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
        local needsCast = ((context and context.mode == "TPS_SURVIVAL")
            and shoutState and shoutState.effectUnits and shoutState.effectUnits > 0)
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
    if token == TOKENS.OVERPOWER then
        local opState = context and context.overpowerState or nil
        local targetGuid = UnitGUID("target")
        if not IsBattleStanceStrict() then
            return false
        end
        if not opState or not opState.active or (opState.remaining or 0) <= 0 then
            return false
        end
        if opState.targetGuid and targetGuid and opState.targetGuid ~= targetGuid then
            return false
        end
        -- 压制只在窗口真实可用时参与预测，避免旧锁/ready-soon 把它带出主推荐树。
        return entry.passed and true or false
    end
    if (token == TOKENS.SUNDER_ARMOR or token == TOKENS.BLOODTHIRST or token == TOKENS.WHIRLWIND or token == TOKENS.OVERPOWER or token == TOKENS.REVENGE
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
    local best = nil
    for _, entry in ipairs(list) do
        if entry.passed then
            best = entry
            break
        end
    end
    if not best then
        best = list[1]
    end
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

    FilterUnknownEvaluations(list)
    SortEvaluations(list)
    return list
end

local function BuildDumpEvaluations(context)
    if not context.inCombat then
        return {}, 0
    end

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

    FilterUnknownEvaluations(list)
    SortEvaluations(list)
    return list, reserve
end

-- P0 fix: replace recursive deep-clone with shallow-copy.
-- Only mutable sub-tables (queue, cooldown, buffs, sunderState, hamstringState,
-- battleShoutState, threat, swing) are shallow-copied. Read-only sub-tables
-- (config, equipment, talents, trinket, weights, known, etc.) are shared by reference.
local function ShallowCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

local function BuildPlannerState(context)
    -- Copy top-level scalars (rage, mode, gcdRem, etc.) plus reference read-only tables.
    local state = ShallowCopy(context)
    -- Shallow-copy only the mutable sub-tables so mutations don't leak back.
    state.queue = ShallowCopy(context.queue or {})
    state.cooldown = ShallowCopy(context.cooldown or {})
    state.buffs = ShallowCopy(context.buffs or {})
    state.swing = ShallowCopy(context.swing or {})
    state.sunderState = ShallowCopy(context.sunderState or { stacks = 0, remaining = 0, hasDebuff = false })
    state.hamstringState = ShallowCopy(context.hamstringState or { hasDebuff = false, remaining = 0 })
    state.battleShoutState = context.battleShoutState
        and ShallowCopy(context.battleShoutState)
        or {
            selfActive = state.buffs.battleShout and true or false,
            selfRemaining = state.buffs.battleShoutRemaining or 0,
            refreshSeconds = state.config and state.config.battleShoutRefreshSeconds or 12,
            effectUnits = 1,
            threatUnits = 1,
            inRangeUnits = 1,
            missingUnits = state.buffs.battleShout and 0 or 1,
            buffedUnits = state.buffs.battleShout and 1 or 0,
        }
    state.threat = context.threat
        and ShallowCopy(context.threat)
        or {
            status = 3,
            scaledPct = 110,
            isTanking = state.mode == "TPS_SURVIVAL",
        }
    return state
end

local function GetPlannerCooldownDuration(token)
    return TOKEN_BASE_COOLDOWN[token] or 0
end

local function SetPlannerCooldown(state, token)
    local key = TOKEN_COOLDOWN_KEY[token]
    if not key then
        return
    end
    state.cooldown[key] = math.max(state.cooldown[key] or 0, GetPlannerCooldownDuration(token))
end

local function RefreshPlannerUrgency(state)
    state.threatUrgency = CalcThreatUrgency(state.threat or {})
    state.survivalUrgency = CalcSurvivalUrgency(state.playerHealthPct or 100)
    state.tpsThreatBias = CalcTpsThreatBias(state.threat or {})
end

local function RefreshPlannerBattleShoutState(state)
    local shoutState = state.battleShoutState or {}
    local refreshSeconds = shoutState.refreshSeconds or (state.config and state.config.battleShoutRefreshSeconds) or 12
    local selfRemaining = math.max(tonumber(shoutState.selfRemaining) or 0, 0)
    local selfActive = selfRemaining > 0
    shoutState.refreshSeconds = refreshSeconds
    shoutState.selfRemaining = selfRemaining
    shoutState.selfActive = selfActive
    shoutState.selfNeedsCast = (not selfActive) or (selfRemaining <= refreshSeconds)
    shoutState.effectUnits = selfActive and math.max(tonumber(shoutState.effectUnits) or 1, 1) or math.max(tonumber(shoutState.missingUnits) or 1, 1)
    shoutState.threatUnits = math.max(tonumber(shoutState.threatUnits) or shoutState.effectUnits or 1, 1)
    shoutState.inRangeUnits = math.max(tonumber(shoutState.inRangeUnits) or shoutState.effectUnits or 1, 1)
    shoutState.buffedUnits = selfActive and math.max(tonumber(shoutState.buffedUnits) or 1, 1) or 0
    shoutState.missingUnits = selfActive and 0 or math.max(tonumber(shoutState.missingUnits) or 1, 1)
    shoutState.shouldCast = shoutState.selfNeedsCast or (state.mode == "TPS_SURVIVAL" and (shoutState.effectUnits or 0) > 0)
    state.battleShoutState = shoutState
    state.buffs.battleShout = selfActive
    state.buffs.battleShoutRemaining = selfRemaining
end

local function AdvancePlannerAuras(state, delta)
    if delta <= 0 then
        RefreshPlannerBattleShoutState(state)
        return
    end
    local sunderState = state.sunderState or {}
    if (sunderState.remaining or 0) > 0 then
        sunderState.remaining = math.max((sunderState.remaining or 0) - delta, 0)
        if sunderState.remaining <= 0 then
            sunderState.remaining = 0
            sunderState.hasDebuff = false
            sunderState.stacks = 0
        end
    end
    state.sunderState = sunderState

    local hamState = state.hamstringState or {}
    if (hamState.remaining or 0) > 0 then
        hamState.remaining = math.max((hamState.remaining or 0) - delta, 0)
        if hamState.remaining <= 0 then
            hamState.remaining = 0
            hamState.hasDebuff = false
        end
    end
    state.hamstringState = hamState

    local buffs = state.buffs or {}
    if buffs.bloodrage then
        buffs.bloodrageRemaining = math.max((buffs.bloodrageRemaining or 10) - delta, 0)
        if buffs.bloodrageRemaining <= 0 then
            buffs.bloodrage = false
        end
    end
    state.buffs = buffs

    local shoutState = state.battleShoutState or {}
    shoutState.selfRemaining = math.max((shoutState.selfRemaining or 0) - delta, 0)
    RefreshPlannerBattleShoutState(state)
end

local function AdvancePlannerTimers(state, delta)
    local dt = math.max(delta or 0, 0)
    state.now = (state.now or 0) + dt
    state.gcdRem = math.max((state.gcdRem or 0) - dt, 0)
    for key, value in pairs(state.cooldown or {}) do
        if type(value) == "number" then
            state.cooldown[key] = math.max(value - dt, 0)
        end
    end

    local queue = state.queue or {}
    local swing = state.swing or {}
    local timeToMain = tonumber(queue.timeToMain or swing.timeToMain) or 99
    local timeToOff = tonumber(queue.timeToOff or swing.timeToOff) or 99
    local mainSwingLanded = timeToMain > 0.0001 and dt >= timeToMain
    local offSwingLanded = timeToOff > 0.0001 and dt >= timeToOff
    local queuedDumpConsumed = false
    timeToMain = math.max(timeToMain - dt, 0)
    timeToOff = math.max(timeToOff - dt, 0)
    if queue.queuedDumpToken and timeToMain <= 0.0001 then
        queuedDumpConsumed = true
        queue.queuedDumpToken = nil
        queue.hsQueued = false
        queue.cleaveQueued = false
        local mainSpeed = tonumber(state.equipment and state.equipment.speedMain) or 2.8
        timeToMain = mainSpeed
    end
    if timeToMain <= 0.0001 then
        local mainSpeed = tonumber(state.equipment and state.equipment.speedMain) or 2.8
        timeToMain = mainSpeed
    end
    if timeToOff <= 0.0001 then
        local offSpeed = tonumber(state.equipment and state.equipment.speedOff) or (tonumber(state.equipment and state.equipment.speedMain) or 2.4)
        timeToOff = offSpeed
    end
    swing.timeToMain = timeToMain
    swing.timeToOff = timeToOff
    queue.timeToMain = timeToMain
    queue.timeToOff = timeToOff
    local qCfg = Decision.GetHsQueueConfig()
    queue.queueWindowOpen = timeToMain <= ((qCfg and qCfg.queueWindowMs or 400) / 1000)
    state.queue = queue
    state.swing = swing
    if mainSwingLanded and not queuedDumpConsumed then
        state.rage = Clamp((state.rage or 0) + 12, 0, 100)
    end
    if offSwingLanded then
        state.rage = Clamp((state.rage or 0) + 6, 0, 100)
    end

    AdvancePlannerAuras(state, dt)
    RefreshPlannerUrgency(state)
end

local function ComputePlannerWaitStep(state)
    local best = PLANNER_WAIT_STEP_MAX
    local function take(value)
        if type(value) == "number" and value > 0.01 then
            best = math.min(best, value)
        end
    end
    take(state.gcdRem)
    take(state.queue and state.queue.timeToMain)
    take(state.queue and state.queue.timeToOff)
    take(state.cooldown and state.cooldown.bt)
    take(state.cooldown and state.cooldown.ww)
    take(state.cooldown and state.cooldown.ss)
    take(state.cooldown and state.cooldown.rev)
    take(state.cooldown and state.cooldown.taunt)
    take(state.cooldown and state.cooldown.mb)
    if best <= 0.01 then
        return 0.2
    end
    return best
end

local function BuildPlannerBundle(state)
    local mainEvaluations = state.mode == "TPS_SURVIVAL" and BuildTpsEvaluations(state) or BuildDpsEvaluations(state)
    local nextEvaluations = FilterNextGcdEvaluations(mainEvaluations)
    local dumpEvaluations, reserveRage = BuildDumpEvaluations(state)
    local offGcdEvaluations = BuildOffGcdEvaluations(state, mainEvaluations)
    return {
        mainEvaluations = mainEvaluations,
        nextEvaluations = nextEvaluations,
        dumpEvaluations = dumpEvaluations,
        offGcdEvaluations = offGcdEvaluations,
        reserveRage = reserveRage,
    }
end

local function BuildPlannerWaitCandidate(bundle)
    local nextWait = FindEvalByToken(bundle.nextEvaluations, TOKENS.WAIT)
    local holdEval = FindEvalByToken(bundle.dumpEvaluations, TOKENS.HOLD)
    local best = nextWait
    local channel = "gcd"
    if holdEval and ((not best) or (holdEval.score > best.score)) then
        best = holdEval
        channel = "wait"
    end
    if not best then
        return nil
    end
    return {
        token = TOKENS.WAIT,
        channel = channel,
        score = best.score,
        rawScore = best.score,
        passed = best.passed,
        reasons = best.reasons,
        sourceEval = best,
        reason = best.reasons and best.reasons[1] or "等待更优窗口",
        rageCost = 0,
        cooldownRem = 0,
        rageEnough = true,
        actionableNow = true,
    }
end

local function CollectPlannerCandidates(state, bundle)
    local list = {}
    local byToken = {}
    local queuedDumpToken = state.queue and state.queue.queuedDumpToken or nil
    local function add(entry, channel)
        if not entry or not entry.token then
            return
        end
        if entry.token == TOKENS.NONE or entry.token == TOKENS.HOLD then
            return
        end
        if (entry.token == TOKENS.HEROIC_STRIKE or entry.token == TOKENS.CLEAVE) and queuedDumpToken then
            return
        end
        if not entry.passed and entry.token ~= TOKENS.WAIT then
            return
        end
        local candidate = {
            token = entry.token,
            channel = channel,
            score = entry.score,
            rawScore = entry.score,
            passed = entry.passed,
            reasons = entry.reasons,
            sourceEval = entry,
            reason = entry.reasons and entry.reasons[1] or "最高分候选",
            rageCost = GetTokenRageCost(entry.token),
            cooldownRem = GetTokenCooldownRemaining(entry.token, state),
            rageEnough = (state.rage or 0) >= GetTokenRageCost(entry.token),
            actionableNow = entry.token ~= TOKENS.WAIT and entry.passed and GetTokenCooldownRemaining(entry.token, state) <= 0.05
                and ((state.rage or 0) >= GetTokenRageCost(entry.token)),
        }
        local existing = byToken[candidate.token]
        if not existing or candidate.score > existing.score then
            if existing then
                for i = #list, 1, -1 do
                    if list[i].token == candidate.token then
                        table.remove(list, i)
                        break
                    end
                end
            end
            byToken[candidate.token] = candidate
            table.insert(list, candidate)
        end
    end

    for _, entry in ipairs(bundle.nextEvaluations or {}) do
        add(entry, "gcd")
    end
    for _, entry in ipairs(bundle.dumpEvaluations or {}) do
        add(entry, "dump")
    end
    for _, entry in ipairs(bundle.offGcdEvaluations or {}) do
        add(entry, "offgcd")
    end

    local waitCandidate = BuildPlannerWaitCandidate(bundle)
    if waitCandidate then
        byToken[TOKENS.WAIT] = waitCandidate
        table.insert(list, waitCandidate)
    end

    table.sort(list, function(a, b)
        if a.channel ~= b.channel and a.token == TOKENS.WAIT then
            return false
        end
        if a.channel ~= b.channel and b.token == TOKENS.WAIT then
            return true
        end
        if a.score == b.score then
            return a.token < b.token
        end
        return a.score > b.score
    end)
    return list
end

local function HasPremiumTokenSoon(state)
    local cooldown = state.cooldown or {}
    if state.mode == "TPS_SURVIVAL" then
        return (cooldown.ss or 99) <= 0.45 or (cooldown.rev or 99) <= 0.35 or (cooldown.taunt or 99) <= 0.35
            or (cooldown.mb or 99) <= 0.45
    end
    return (cooldown.bt or 99) <= 0.45 or (cooldown.ww or 99) <= 0.55
        or ((state.targetHealthPct or 100) <= 20 and (cooldown.ex or 99) <= 0.35)
end

local function EstimatePlannerRageBefore(state, seconds)
    local rage = tonumber(state and state.rage) or 0
    local queue = state and state.queue or {}
    local equipment = state and state.equipment or {}
    if (tonumber(queue.timeToMain) or math.huge) <= seconds then
        rage = rage + 12
    end
    if equipment.hasOffhandWeapon and (tonumber(queue.timeToOff) or math.huge) <= seconds then
        rage = rage + 6
    end
    return Clamp(rage, 0, 100)
end

local function IsPlannerBloodrageRedundant(state)
    if not state or (state.rage or 0) >= 30 then
        return false
    end
    local cooldown = state.cooldown or {}
    local soonest = math.huge
    local needed = 0
    if state.mode == "TPS_SURVIVAL" then
        if (cooldown.ss or math.huge) < soonest then
            soonest = cooldown.ss or math.huge
            needed = GetTokenRageCost(TOKENS.SHIELD_SLAM)
        end
        if (cooldown.rev or math.huge) < soonest then
            soonest = cooldown.rev or math.huge
            needed = GetTokenRageCost(TOKENS.REVENGE)
        end
        if (cooldown.mb or math.huge) < soonest then
            soonest = cooldown.mb or math.huge
            needed = GetTokenRageCost(TOKENS.MOCKING_BLOW)
        end
    else
        if (cooldown.bt or math.huge) < soonest then
            soonest = cooldown.bt or math.huge
            needed = GetTokenRageCost(TOKENS.BLOODTHIRST)
        end
        if (state.hostileCount or 1) >= 2 and (cooldown.ww or math.huge) < soonest then
            soonest = cooldown.ww or math.huge
            needed = GetTokenRageCost(TOKENS.WHIRLWIND)
        end
        if (state.targetHealthPct or 100) <= 20 and (cooldown.ex or math.huge) < soonest then
            soonest = cooldown.ex or math.huge
            needed = GetTokenRageCost(TOKENS.EXECUTE)
        end
    end
    if soonest == math.huge or needed <= 0 or soonest > 0.35 then
        return false
    end
    return EstimatePlannerRageBefore(state, soonest + 0.02) >= needed
end

local function CalcPlannerDumpPairBonus(state, candidate)
    if not candidate or candidate.channel ~= "dump" then
        return 0
    end
    local queue = state.queue or {}
    if not queue.queueWindowOpen then
        return 0
    end
    local cooldown = state.cooldown or {}
    local postRage = math.max((state.rage or 0) - (candidate.rageCost or 0), 0)
    local bonus = 0
    local timeToMain = tonumber(queue.timeToMain) or math.huge

    if timeToMain <= 0.28 then
        bonus = bonus + 4
    end
    if (state.rage or 0) >= 55 then
        bonus = bonus + 4
    end

    if state.mode == "TPS_SURVIVAL" then
        if (cooldown.ss or 99) <= 0.05 and postRage >= GetTokenRageCost(TOKENS.SHIELD_SLAM) then
            bonus = bonus + 10
        elseif (cooldown.rev or 99) <= 0.05 and postRage >= GetTokenRageCost(TOKENS.REVENGE) then
            bonus = bonus + 8
        elseif ((cooldown.taunt or 99) <= 0.05 or (cooldown.mb or 99) <= 0.05) and postRage >= 10 then
            bonus = bonus + 8
        end
        return bonus
    end

    if (cooldown.bt or 99) <= 0.05 and postRage >= GetTokenRageCost(TOKENS.BLOODTHIRST) then
        bonus = bonus + 12
    elseif (state.hostileCount or 1) >= 2 and (cooldown.ww or 99) <= 0.05 and postRage >= GetTokenRageCost(TOKENS.WHIRLWIND) then
        bonus = bonus + 10
    elseif (state.targetHealthPct or 100) <= 20 and (cooldown.ex or 99) <= 0.05 and postRage >= GetTokenRageCost(TOKENS.EXECUTE) then
        bonus = bonus + 12
    end
    return bonus
end

local function CalcPlannerStateBonus(state, candidate)
    local bonus = 0
    if candidate.channel == "dump" and state.queue and state.queue.queueWindowOpen then
        bonus = bonus + 6
        bonus = bonus + CalcPlannerDumpPairBonus(state, candidate)
    end
    if candidate.token == TOKENS.BLOODRAGE and (state.rage or 0) <= 20 then
        bonus = bonus + (HasPremiumTokenSoon(state) and 6 or 3)
    elseif candidate.token == TOKENS.SHIELD_BLOCK then
        bonus = bonus + math.floor((state.survivalUrgency or 0) * 0.2)
    elseif candidate.token == TOKENS.LAST_STAND then
        bonus = bonus + math.floor((state.survivalUrgency or 0) * 0.4)
    elseif candidate.token == TOKENS.SUNDER_ARMOR then
        local sunderState = state.sunderState or {}
        local refreshWindow = math.max((state.config and state.config.sunderRefreshSeconds or 10) + 2, 12)
        if state.mode == "TPS_SURVIVAL" and state.targetBossLike and (sunderState.stacks or 0) >= ((state.config and state.config.sunderTargetStacks) or 5)
            and (sunderState.remaining or 0) < refreshWindow then
            bonus = bonus + 8
        end
    elseif candidate.token == TOKENS.TAUNT then
        bonus = bonus + 10
    elseif candidate.token == TOKENS.MOCKING_BLOW then
        bonus = bonus + 4
    end
    return bonus
end

local function CalcPlannerExecutionPenalty(state, candidate)
    local penalty = 0
    local cost = candidate.rageCost or 0
    if candidate.token ~= TOKENS.WAIT then
        penalty = penalty + (cost * 0.08)
    end
    if candidate.channel == "dump" and state.queue and not state.queue.queueWindowOpen then
        penalty = penalty + 6
    end

    local postRage = math.max((state.rage or 0) - cost, 0)
    if candidate.token == TOKENS.BLOODRAGE then
        postRage = Clamp(postRage + 10, 0, 100)
        if IsPlannerBloodrageRedundant(state) then
            penalty = penalty + 18
        end
    end
    local cooldown = state.cooldown or {}
    local function blockSoon(token, remaining, reserve)
        if candidate.token == token then
            return
        end
        if remaining <= reserve and postRage < GetTokenRageCost(token) then
            penalty = penalty + 28
        end
    end
    if state.mode == "TPS_SURVIVAL" then
        blockSoon(TOKENS.SHIELD_SLAM, cooldown.ss or 99, 0.45)
        blockSoon(TOKENS.REVENGE, cooldown.rev or 99, 0.35)
        blockSoon(TOKENS.TAUNT, cooldown.taunt or 99, 0.35)
        blockSoon(TOKENS.MOCKING_BLOW, cooldown.mb or 99, 0.45)
        if candidate.channel == "dump" and ((cooldown.ss or 99) <= 0.45 or (cooldown.rev or 99) <= 0.35) then
            penalty = penalty + 8
        end
    else
        blockSoon(TOKENS.BLOODTHIRST, cooldown.bt or 99, 0.45)
        if not (candidate.token == TOKENS.BLOODTHIRST and (state.hostileCount or 1) <= 1) then
            blockSoon(TOKENS.WHIRLWIND, cooldown.ww or 99, 0.55)
        end
        if (state.targetHealthPct or 100) <= 20 then
            blockSoon(TOKENS.EXECUTE, cooldown.ex or 99, 0.35)
        end
    end
    if candidate.token == TOKENS.WAIT then
        penalty = penalty + 8
    end
    return penalty
end

local function ApplyVirtualAction(state, candidate)
    local nextState = BuildPlannerState(state)
    local token = candidate and candidate.token or TOKENS.NONE
    if token == TOKENS.NONE then
        return nextState
    end

    if token == TOKENS.WAIT or token == TOKENS.HOLD then
        AdvancePlannerTimers(nextState, ComputePlannerWaitStep(nextState))
        return nextState
    end

    local rageCost = GetTokenRageCost(token)
    nextState.rage = Clamp((nextState.rage or 0) - rageCost, 0, 100)

    if candidate.channel == "dump" then
        nextState.queue.queuedDumpToken = token
        nextState.queue.hsQueued = token == TOKENS.HEROIC_STRIKE
        nextState.queue.cleaveQueued = token == TOKENS.CLEAVE
        nextState.queue.queueWindowOpen = false
        nextState.queue.timeToMain = math.max(nextState.queue.timeToMain or 0, 0.05)
        RefreshPlannerUrgency(nextState)
        return nextState
    end

    if candidate.channel == "offgcd" then
        SetPlannerCooldown(nextState, token)
        if token == TOKENS.BLOODRAGE then
            nextState.rage = Clamp((nextState.rage or 0) + 10, 0, 100)
            nextState.buffs.bloodrage = true
            nextState.buffs.bloodrageRemaining = 10
        elseif token == TOKENS.SHIELD_BLOCK then
            nextState.survivalUrgency = math.max((nextState.survivalUrgency or 0) - 12, 0)
        elseif token == TOKENS.LAST_STAND then
            nextState.playerHealthPct = math.min((nextState.playerHealthPct or 100) + 18, 100)
        end
        RefreshPlannerUrgency(nextState)
        return nextState
    end

    nextState.gcdRem = math.max(nextState.gcdRem or 0, PLANNER_GCD_SECONDS)
    SetPlannerCooldown(nextState, token)

    if token == TOKENS.BATTLE_SHOUT then
        nextState.battleShoutState.selfRemaining = 120
        nextState.battleShoutState.selfActive = true
        nextState.battleShoutState.effectUnits = math.max(nextState.battleShoutState.effectUnits or 1, 1)
        nextState.battleShoutState.threatUnits = math.max(nextState.battleShoutState.threatUnits or nextState.battleShoutState.effectUnits or 1, 1)
        RefreshPlannerBattleShoutState(nextState)
    elseif token == TOKENS.SUNDER_ARMOR then
        local targetStacks = (nextState.config and nextState.config.sunderTargetStacks) or 5
        nextState.sunderState.hasDebuff = true
        nextState.sunderState.stacks = math.min((nextState.sunderState.stacks or 0) + 1, targetStacks)
        nextState.sunderState.remaining = 30
    elseif token == TOKENS.HAMSTRING then
        local hamCfg = Decision.GetHamstringConfig()
        nextState.hamstringState.hasDebuff = true
        nextState.hamstringState.remaining = hamCfg.refreshSeconds or 15
    elseif token == TOKENS.TAUNT then
        nextState.threat.isTanking = true
        nextState.threat.status = 3
        nextState.threat.scaledPct = 110
    elseif token == TOKENS.MOCKING_BLOW then
        nextState.threat.isTanking = true
        nextState.threat.status = math.max(nextState.threat.status or 0, 2)
        nextState.threat.scaledPct = math.max(nextState.threat.scaledPct or 0, 96)
    elseif token == TOKENS.LAST_STAND then
        nextState.playerHealthPct = math.min((nextState.playerHealthPct or 100) + 18, 100)
    end

    RefreshPlannerUrgency(nextState)
    return nextState
end

local function DeterminePlannerDepth(state)
    if HasPremiumTokenSoon(state) then
        return PLANNER_DEEP_DEPTH
    end
    if state.queue and ((state.queue.queuedDumpToken ~= nil) or state.queue.queueWindowOpen) then
        return PLANNER_DEEP_DEPTH
    end
    if (state.gcdRem or 0) > 0.05 then
        return PLANNER_DEEP_DEPTH
    end
    return PLANNER_DEFAULT_DEPTH
end

local function SearchBestAction(state, depth)
    if depth <= 0 then
        return nil, 0
    end
    local bundle = BuildPlannerBundle(state)
    local candidates = CollectPlannerCandidates(state, bundle)
    if #candidates == 0 then
        return nil, 0
    end

    local bestCandidate = nil
    local bestValue = -1e9
    for _, candidate in ipairs(candidates) do
        local immediateValue = candidate.rawScore or 0
        if candidate.channel == "offgcd" then
            immediateValue = immediateValue * 0.72
        elseif candidate.channel == "dump" then
            immediateValue = immediateValue * 0.88
        elseif candidate.token == TOKENS.WAIT then
            immediateValue = immediateValue - 4
        end
        local penalty = CalcPlannerExecutionPenalty(state, candidate)
        local stateBonus = CalcPlannerStateBonus(state, candidate)
        local nextState = ApplyVirtualAction(state, candidate)
        local futureValue = 0
        if depth > 1 then
            local _, nested = SearchBestAction(nextState, depth - 1)
            futureValue = nested * PLANNER_FUTURE_DECAY
        end
        local totalValue = immediateValue + futureValue - penalty + stateBonus
        if (not bestCandidate) or totalValue > bestValue then
            bestCandidate = candidate
            bestValue = totalValue
        end
    end
    if bestCandidate then
        bestCandidate.sequenceValue = bestValue
    end
    return bestCandidate, bestValue
end

local function PromotePlannerDisplayCandidate(state)
    local probeState = BuildPlannerState(state)
    local totalWait = 0
    for _ = 1, 3 do
        local candidate = SearchBestAction(probeState, DeterminePlannerDepth(probeState))
        if (not candidate) or candidate.token ~= TOKENS.WAIT then
            return candidate, probeState
        end
        local premiumSoon = HasPremiumTokenSoon(probeState)
        local nextState = ApplyVirtualAction(probeState, candidate)
        totalWait = totalWait + math.max((nextState.now or 0) - (probeState.now or 0), 0.2)
        probeState = nextState
        if (not premiumSoon) or totalWait >= 1.25 then
            break
        end
    end
    local candidate = SearchBestAction(probeState, DeterminePlannerDepth(probeState))
    return candidate, probeState
end

local function BuildQueueIndicator(context)
    local queuedToken = context.queue and context.queue.queuedDumpToken or nil
    if not queuedToken or queuedToken == TOKENS.HOLD then
        return nil
    end
    return {
        token = queuedToken,
        channel = "dump",
        queued = true,
        glow = true,
        actionableNow = true,
        reason = "Dump 已进入下一次主手挥击队列",
        rageCost = GetTokenRageCost(queuedToken),
        cooldownRem = 0,
        rageEnough = true,
    }
end

local function IsDisplayablePlannedToken(token)
    return token and token ~= TOKENS.NONE and token ~= TOKENS.HOLD
end

local function PlanRecommendationSequence(context)
    local state = BuildPlannerState(context)
    local ranked = {}
    local seen = {}
    for slot = 1, 3 do
        local candidate = SearchBestAction(state, DeterminePlannerDepth(state))
        if candidate and candidate.token == TOKENS.WAIT then
            local promotedCandidate, promotedState = PromotePlannerDisplayCandidate(state)
            if promotedCandidate and promotedCandidate.token and promotedCandidate.token ~= TOKENS.WAIT then
                candidate = promotedCandidate
                state = promotedState
            end
        end
        if not candidate or (not IsDisplayablePlannedToken(candidate.token)) then
            break
        end
        ranked[slot] = {
            token = candidate.token,
            channel = candidate.channel,
            reason = candidate.reason,
            rawScore = candidate.rawScore,
            sequenceValue = candidate.sequenceValue or candidate.rawScore,
            rageCost = candidate.rageCost,
            cooldownRem = candidate.cooldownRem,
            rageEnough = candidate.rageEnough,
            actionableNow = candidate.actionableNow,
            passed = candidate.passed,
        }
        seen[candidate.token] = true
        state = ApplyVirtualAction(state, candidate)
    end
    if #ranked < 3 and #ranked > 1 then
        ranked = { ranked[1] }
    end
    return ranked, BuildQueueIndicator(context)
end

local function GetPassedEvalByToken(list, token)
    local eval = FindEvalByToken(list, token)
    if eval and eval.passed then
        return eval
    end
    return nil
end

local function PickHigherScoreEval(a, b)
    if a and b then
        return (tonumber(a.score) or 0) >= (tonumber(b.score) or 0) and a or b
    end
    return a or b
end

local function BuildRecommendedEntry(context, token, eval, channel, reason)
    if not token or not eval then
        return nil
    end
    return {
        token = token,
        channel = channel,
        reason = reason or (eval.reasons and eval.reasons[1]) or "最高分候选",
        rawScore = eval.score,
        score = eval.score,
        rageCost = GetTokenRageCost(token),
        cooldownRem = GetTokenCooldownRemaining(token, context),
        rageEnough = (context.rage or 0) >= GetTokenRageCost(token),
        actionableNow = true,
        passed = true,
    }
end

local function BuildProjectedRecommendedEntry(context, eval, reason)
    if not eval or not eval.token then
        return nil
    end
    local token = eval.token
    return {
        token = token,
        channel = "gcd",
        reason = reason or "主技能即将转好，主提示提前预留",
        rawScore = eval.score,
        score = eval.score,
        rageCost = GetTokenRageCost(token),
        cooldownRem = GetTokenCooldownRemaining(token, context),
        rageEnough = (context.rage or 0) >= GetTokenRageCost(token),
        actionableNow = false,
        passed = false,
        projected = true,
    }
end

local function ShouldRecommendDpsDump(context, dumpEval, premiumEval, readySoonPremiumEval)
    if not dumpEval or not dumpEval.passed then
        return false
    end
    if context and context.cooldown and (context.cooldown.bt or math.huge) <= 0.05
        and (context.rage or 0) >= GetTokenRageCost(TOKENS.BLOODTHIRST) then
        return false
    end
    if readySoonPremiumEval then
        return false
    end
    if context.queue and context.queue.queuedDumpToken and context.queue.queuedDumpToken ~= TOKENS.HOLD then
        return false
    end
    if not (context.queue and context.queue.queueWindowOpen) then
        return false
    end
    if (context.gcdRem or 0) > 0.05 then
        return true
    end
    if premiumEval and premiumEval.passed then
        return false
    end
    return (context.rage or 0) >= 55 or ((context.queue and context.queue.timeToMain) or 99) <= 0.28
end

local function ShouldRecommendTpsDump(context, dumpEval, revEval, ssEval, tauntEval, mbEval)
    if not dumpEval or not dumpEval.passed then
        return false
    end
    if context.queue and context.queue.queuedDumpToken and context.queue.queuedDumpToken ~= TOKENS.HOLD then
        return false
    end
    if not (context.queue and context.queue.queueWindowOpen) then
        return false
    end
    if (context.threat and ((context.threat.status or 0) <= 1 or (context.threat.scaledPct or 0) < 95)) then
        return false
    end
    if (tauntEval and tauntEval.passed) or (mbEval and mbEval.passed) or (revEval and revEval.passed) or (ssEval and ssEval.passed) then
        return false
    end
    return true
end

local function SelectDpsPrimaryEval(context, nextEvaluations)
    local op = GetPassedEvalByToken(nextEvaluations, TOKENS.OVERPOWER)
    local bt = GetPassedEvalByToken(nextEvaluations, TOKENS.BLOODTHIRST)
    local ww = GetPassedEvalByToken(nextEvaluations, TOKENS.WHIRLWIND)
    local ex = GetPassedEvalByToken(nextEvaluations, TOKENS.EXECUTE)

    if op and context.overpowerState and (context.overpowerState.remaining or 0) <= 1.5 then
        return op
    end
    if (context.hostileCount or 1) >= 2 then
        return op or ww or bt or ex
    end
    if context.targetHealthPct and context.targetHealthPct <= 20 then
        return ex or op or bt or ww
    end
    return op or bt or ww or ex
end

local function BuildOrderedDpsPremiumTokens(context)
    local orderedTokens = {}
    local hasOverpower = context.overpowerState and context.overpowerState.active
    local overpowerUrgent = hasOverpower and (context.overpowerState.remaining or 0) <= 1.5
    if (context.hostileCount or 1) >= 2 then
        orderedTokens = overpowerUrgent
            and { TOKENS.OVERPOWER, TOKENS.WHIRLWIND, TOKENS.BLOODTHIRST, TOKENS.EXECUTE }
            or { TOKENS.WHIRLWIND, TOKENS.OVERPOWER, TOKENS.BLOODTHIRST, TOKENS.EXECUTE }
    elseif context.targetHealthPct and context.targetHealthPct <= 20 then
        orderedTokens = overpowerUrgent
            and { TOKENS.OVERPOWER, TOKENS.EXECUTE, TOKENS.BLOODTHIRST, TOKENS.WHIRLWIND }
            or { TOKENS.EXECUTE, TOKENS.OVERPOWER, TOKENS.BLOODTHIRST, TOKENS.WHIRLWIND }
    else
        orderedTokens = hasOverpower
            and { TOKENS.OVERPOWER, TOKENS.BLOODTHIRST, TOKENS.WHIRLWIND, TOKENS.EXECUTE }
            or { TOKENS.BLOODTHIRST, TOKENS.WHIRLWIND, TOKENS.EXECUTE }
    end
    return orderedTokens
end

local function GetDpsProjectedPremiumWindow(context, token)
    local baseWindow = 0.45
    if token == TOKENS.WHIRLWIND then
        baseWindow = 0.55
    elseif token == TOKENS.EXECUTE or token == TOKENS.OVERPOWER then
        baseWindow = 0.35
    end
    local habitCfg = Decision.GetHabitConfig()
    local readySoonWindow = (tonumber(habitCfg and habitCfg.readySoonMs) or 350) / 1000
    local gcdWindow = tonumber(context and context.gcdRem) or 0
    return math.max(baseWindow, readySoonWindow, gcdWindow)
end

local function PassesProjectedDpsPremiumChecks(context, eval)
    local token = eval and eval.token or nil
    if not token or not DPS_PREMIUM_TOKENS[token] then
        return false
    end
    if not context or not context.inCombat or not context.targetExists then
        return false
    end
    if IsTokenKnown(token) == false then
        return false
    end
    local spellName = GetSpellNameByToken(token)
    if spellName and not InRangeOrNil(spellName, "target") then
        return false
    end
    if spellName and not IsUsable(spellName) then
        return false
    end
    if (context.rage or 0) < GetTokenRageCost(token) then
        return false
    end
    if token == TOKENS.EXECUTE then
        return context.targetHealthPct and context.targetHealthPct <= 20
    end
    if token == TOKENS.OVERPOWER then
        local opState = context.overpowerState or {}
        local targetGuid = UnitGUID("target")
        if not IsBattleStanceStrict() then
            return false
        end
        if not opState.active or (opState.remaining or 0) <= 0 then
            return false
        end
        if opState.targetGuid and targetGuid and opState.targetGuid ~= targetGuid then
            return false
        end
    end
    return true
end

local function FindReadySoonDpsPremiumEval(context, nextEvaluations)
    for _, token in ipairs(BuildOrderedDpsPremiumTokens(context)) do
        local eval = FindEvalByToken(nextEvaluations, token)
        if eval and not eval.passed then
            local cooldownRem = GetTokenCooldownRemaining(token, context)
            if cooldownRem > 0.05
                and cooldownRem <= GetDpsProjectedPremiumWindow(context, token)
                and PassesProjectedDpsPremiumChecks(context, eval) then
                return eval
            end
        end
    end
    return nil
end

local function BuildCurrentRecommendedAction(context, nextEvaluations, dumpEvaluations, offGcdEvaluations)
    local queueIndicator = BuildQueueIndicator(context)
    local bestDumpToken, bestDumpReason, bestDumpEval = PickBest(dumpEvaluations)
    if not bestDumpEval or not bestDumpEval.passed or bestDumpToken == TOKENS.HOLD then
        bestDumpToken, bestDumpReason, bestDumpEval = nil, nil, nil
    end

    if context.mode == "DPS" then
        local bloodrageEval = GetPassedEvalByToken(offGcdEvaluations, TOKENS.BLOODRAGE)
        local premiumEval = SelectDpsPrimaryEval(context, nextEvaluations)
        local readySoonPremiumEval = (not premiumEval) and FindReadySoonDpsPremiumEval(context, nextEvaluations) or nil
        local sunderEval = GetPassedEvalByToken(nextEvaluations, TOKENS.SUNDER_ARMOR)
        local shoutEval = GetPassedEvalByToken(nextEvaluations, TOKENS.BATTLE_SHOUT)
        local hamEval = GetPassedEvalByToken(nextEvaluations, TOKENS.HAMSTRING)

        if bloodrageEval and not premiumEval and not readySoonPremiumEval
            and (context.rage or 0) < 30 and not IsPlannerBloodrageRedundant(context) then
            return BuildRecommendedEntry(context, TOKENS.BLOODRAGE, bloodrageEval, "offgcd"), queueIndicator
        end
        if premiumEval then
            return BuildRecommendedEntry(context, premiumEval.token, premiumEval, "gcd"), queueIndicator
        end
        if readySoonPremiumEval then
            return BuildProjectedRecommendedEntry(context, readySoonPremiumEval, "主技能即将转好，主提示提前预留"), queueIndicator
        end
        if ShouldRecommendDpsDump(context, bestDumpEval, premiumEval, readySoonPremiumEval) then
            return BuildRecommendedEntry(context, bestDumpToken, bestDumpEval, "dump", bestDumpReason), queueIndicator
        end
        if bloodrageEval and (context.rage or 0) < 30 and not IsPlannerBloodrageRedundant(context) then
            return BuildRecommendedEntry(context, TOKENS.BLOODRAGE, bloodrageEval, "offgcd"), queueIndicator
        end
        if sunderEval then
            return BuildRecommendedEntry(context, TOKENS.SUNDER_ARMOR, sunderEval, "gcd"), queueIndicator
        end
        if shoutEval then
            return BuildRecommendedEntry(context, TOKENS.BATTLE_SHOUT, shoutEval, "gcd"), queueIndicator
        end
        if hamEval then
            return BuildRecommendedEntry(context, TOKENS.HAMSTRING, hamEval, "gcd"), queueIndicator
        end
        if bestDumpEval then
            return BuildRecommendedEntry(context, bestDumpToken, bestDumpEval, "dump", bestDumpReason), queueIndicator
        end
        return nil, queueIndicator
    end

    local lsEval = GetPassedEvalByToken(offGcdEvaluations, TOKENS.LAST_STAND)
    local sbEval = GetPassedEvalByToken(offGcdEvaluations, TOKENS.SHIELD_BLOCK)
    local tauntEval = GetPassedEvalByToken(nextEvaluations, TOKENS.TAUNT)
    local mbEval = GetPassedEvalByToken(nextEvaluations, TOKENS.MOCKING_BLOW)
    local revEval = GetPassedEvalByToken(nextEvaluations, TOKENS.REVENGE)
    local ssEval = GetPassedEvalByToken(nextEvaluations, TOKENS.SHIELD_SLAM)
    local sunderEval = GetPassedEvalByToken(nextEvaluations, TOKENS.SUNDER_ARMOR)
    local btEval = GetPassedEvalByToken(nextEvaluations, TOKENS.BLOODTHIRST)
    local shoutEval = GetPassedEvalByToken(nextEvaluations, TOKENS.BATTLE_SHOUT)
    local bloodrageEval = GetPassedEvalByToken(offGcdEvaluations, TOKENS.BLOODRAGE)

    if lsEval then
        return BuildRecommendedEntry(context, TOKENS.LAST_STAND, lsEval, "offgcd"), queueIndicator
    end
    if tauntEval then
        return BuildRecommendedEntry(context, TOKENS.TAUNT, tauntEval, "gcd"), queueIndicator
    end
    if mbEval then
        return BuildRecommendedEntry(context, TOKENS.MOCKING_BLOW, mbEval, "gcd"), queueIndicator
    end
    if sbEval and context.threat and (context.threat.status or 0) >= 2 then
        return BuildRecommendedEntry(context, TOKENS.SHIELD_BLOCK, sbEval, "offgcd"), queueIndicator
    end
    if ShouldRecommendTpsDump(context, bestDumpEval, revEval, ssEval, tauntEval, mbEval) then
        return BuildRecommendedEntry(context, bestDumpToken, bestDumpEval, "dump", bestDumpReason), queueIndicator
    end
    if revEval then
        return BuildRecommendedEntry(context, TOKENS.REVENGE, revEval, "gcd"), queueIndicator
    end
    if ssEval then
        return BuildRecommendedEntry(context, TOKENS.SHIELD_SLAM, ssEval, "gcd"), queueIndicator
    end
    if sunderEval then
        return BuildRecommendedEntry(context, TOKENS.SUNDER_ARMOR, sunderEval, "gcd"), queueIndicator
    end
    if btEval then
        return BuildRecommendedEntry(context, TOKENS.BLOODTHIRST, btEval, "gcd"), queueIndicator
    end
    if shoutEval then
        return BuildRecommendedEntry(context, TOKENS.BATTLE_SHOUT, shoutEval, "gcd"), queueIndicator
    end
    if bloodrageEval and not IsPlannerBloodrageRedundant(context) then
        return BuildRecommendedEntry(context, TOKENS.BLOODRAGE, bloodrageEval, "offgcd"), queueIndicator
    end
    if bestDumpEval then
        return BuildRecommendedEntry(context, bestDumpToken, bestDumpEval, "dump", bestDumpReason), queueIndicator
    end
    return nil, queueIndicator
end

local function AppendRecommendedEntry(list, seen, entry)
    if not entry or not entry.token or entry.token == TOKENS.NONE or entry.token == TOKENS.HOLD or entry.token == TOKENS.WAIT then
        return
    end
    if seen[entry.token] then
        return
    end
    seen[entry.token] = true
    table.insert(list, entry)
end

local function BuildOrderedDpsPremiumEvals(context, nextEvaluations)
    local ordered = {}
    for _, token in ipairs(BuildOrderedDpsPremiumTokens(context)) do
        local eval = GetPassedEvalByToken(nextEvaluations, token)
        if eval then
            table.insert(ordered, eval)
        end
    end
    return ordered
end

local function BuildDpsRankedRecommendations(context, nextEvaluations, dumpEvaluations, offGcdEvaluations)
    local ranked = {}
    local seen = {}
    local bestDumpToken, bestDumpReason, bestDumpEval = PickBest(dumpEvaluations)
    if not bestDumpEval or not bestDumpEval.passed or bestDumpToken == TOKENS.HOLD then
        bestDumpToken, bestDumpReason, bestDumpEval = nil, nil, nil
    end

    local bloodrageEval = GetPassedEvalByToken(offGcdEvaluations, TOKENS.BLOODRAGE)
    local sunderEval = GetPassedEvalByToken(nextEvaluations, TOKENS.SUNDER_ARMOR)
    local shoutEval = GetPassedEvalByToken(nextEvaluations, TOKENS.BATTLE_SHOUT)
    local hamEval = GetPassedEvalByToken(nextEvaluations, TOKENS.HAMSTRING)
    local premiumEvals = BuildOrderedDpsPremiumEvals(context, nextEvaluations)
    local premiumEval = premiumEvals[1]
    local readySoonPremiumEval = (not premiumEval) and FindReadySoonDpsPremiumEval(context, nextEvaluations) or nil

    if not context.inCombat then
        if shoutEval then
            AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.BATTLE_SHOUT, shoutEval, "gcd"))
        end
        return ranked
    end

    if bloodrageEval and not premiumEval and not readySoonPremiumEval
        and (context.rage or 0) < 30 and not IsPlannerBloodrageRedundant(context) then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.BLOODRAGE, bloodrageEval, "offgcd"))
    end
    for _, eval in ipairs(premiumEvals) do
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, eval.token, eval, "gcd"))
    end
    if readySoonPremiumEval then
        AppendRecommendedEntry(
            ranked,
            seen,
            BuildProjectedRecommendedEntry(context, readySoonPremiumEval, "主技能即将转好，主提示提前预留")
        )
    end
    if ShouldRecommendDpsDump(context, bestDumpEval, premiumEval, readySoonPremiumEval) then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, bestDumpToken, bestDumpEval, "dump", bestDumpReason))
    end
    if bloodrageEval and (context.rage or 0) < 30 and not IsPlannerBloodrageRedundant(context) then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.BLOODRAGE, bloodrageEval, "offgcd"))
    end
    if sunderEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.SUNDER_ARMOR, sunderEval, "gcd"))
    end
    if shoutEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.BATTLE_SHOUT, shoutEval, "gcd"))
    end
    if hamEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.HAMSTRING, hamEval, "gcd"))
    end
    if bestDumpEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, bestDumpToken, bestDumpEval, "dump", bestDumpReason))
    end
    return ranked
end

local function BuildTpsRankedRecommendations(context, nextEvaluations, dumpEvaluations, offGcdEvaluations)
    local ranked = {}
    local seen = {}
    local bestDumpToken, bestDumpReason, bestDumpEval = PickBest(dumpEvaluations)
    if not bestDumpEval or not bestDumpEval.passed or bestDumpToken == TOKENS.HOLD then
        bestDumpToken, bestDumpReason, bestDumpEval = nil, nil, nil
    end

    local lsEval = GetPassedEvalByToken(offGcdEvaluations, TOKENS.LAST_STAND)
    local sbEval = GetPassedEvalByToken(offGcdEvaluations, TOKENS.SHIELD_BLOCK)
    local tauntEval = GetPassedEvalByToken(nextEvaluations, TOKENS.TAUNT)
    local mbEval = GetPassedEvalByToken(nextEvaluations, TOKENS.MOCKING_BLOW)
    local revEval = GetPassedEvalByToken(nextEvaluations, TOKENS.REVENGE)
    local ssEval = GetPassedEvalByToken(nextEvaluations, TOKENS.SHIELD_SLAM)
    local sunderEval = GetPassedEvalByToken(nextEvaluations, TOKENS.SUNDER_ARMOR)
    local btEval = GetPassedEvalByToken(nextEvaluations, TOKENS.BLOODTHIRST)
    local shoutEval = GetPassedEvalByToken(nextEvaluations, TOKENS.BATTLE_SHOUT)
    local bloodrageEval = GetPassedEvalByToken(offGcdEvaluations, TOKENS.BLOODRAGE)

    if not context.inCombat then
        if shoutEval then
            AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.BATTLE_SHOUT, shoutEval, "gcd"))
        end
        return ranked
    end

    if lsEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.LAST_STAND, lsEval, "offgcd"))
    end
    if tauntEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.TAUNT, tauntEval, "gcd"))
    end
    if mbEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.MOCKING_BLOW, mbEval, "gcd"))
    end
    if sbEval and context.threat and (context.threat.status or 0) >= 2 then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.SHIELD_BLOCK, sbEval, "offgcd"))
    end
    if ShouldRecommendTpsDump(context, bestDumpEval, revEval, ssEval, tauntEval, mbEval) then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, bestDumpToken, bestDumpEval, "dump", bestDumpReason))
    end
    if revEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.REVENGE, revEval, "gcd"))
    end
    if ssEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.SHIELD_SLAM, ssEval, "gcd"))
    end
    if sunderEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.SUNDER_ARMOR, sunderEval, "gcd"))
    end
    if btEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.BLOODTHIRST, btEval, "gcd"))
    end
    if shoutEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.BATTLE_SHOUT, shoutEval, "gcd"))
    end
    if bloodrageEval and not IsPlannerBloodrageRedundant(context) then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, TOKENS.BLOODRAGE, bloodrageEval, "offgcd"))
    end
    if bestDumpEval then
        AppendRecommendedEntry(ranked, seen, BuildRecommendedEntry(context, bestDumpToken, bestDumpEval, "dump", bestDumpReason))
    end
    return ranked
end

local function BuildRankedRecommendations(context, nextEvaluations, dumpEvaluations, offGcdEvaluations)
    if context.mode == "TPS_SURVIVAL" then
        return BuildTpsRankedRecommendations(context, nextEvaluations, dumpEvaluations, offGcdEvaluations)
    end
    return BuildDpsRankedRecommendations(context, nextEvaluations, dumpEvaluations, offGcdEvaluations)
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
    local recommendedAction, queueIndicator = BuildCurrentRecommendedAction(
        context,
        nextEvaluations,
        dumpEvaluations,
        offGcdEvaluations
    )
    local rankedRecommendations = BuildRankedRecommendations(
        context,
        nextEvaluations,
        dumpEvaluations,
        offGcdEvaluations
    )
    if #rankedRecommendations > 0 then
        recommendedAction = rankedRecommendations[1]
    end

    local compatNextSkill = nextSkill
    local compatNextReason = reason
    local compatDumpSkill = dumpSkill
    local compatDumpReason = dumpReason
    local compatOffGcdSkill = offGcdSkill
    local compatOffGcdReason = offGcdReason

    if recommendedAction and recommendedAction.channel == "gcd" and compatNextSkill == TOKENS.WAIT then
        compatNextSkill = recommendedAction.token
        compatNextReason = recommendedAction.reason
    elseif recommendedAction and recommendedAction.channel == "dump" and (compatDumpSkill == TOKENS.HOLD or compatDumpSkill == TOKENS.NONE) then
        compatDumpSkill = recommendedAction.token
        compatDumpReason = recommendedAction.reason
    elseif recommendedAction and recommendedAction.channel == "offgcd" and (compatOffGcdSkill == TOKENS.NONE or compatOffGcdSkill == TOKENS.WAIT) then
        compatOffGcdSkill = recommendedAction.token
        compatOffGcdReason = recommendedAction.reason
    end
    if queueIndicator and queueIndicator.token then
        compatDumpSkill = queueIndicator.token
        compatDumpReason = queueIndicator.reason
    end

    MaybePrintOverpowerDebug(context, recommendedAction, rankedRecommendations)
    -- P1 fix: guard entire debug block to avoid string construction when panel not shown.
    if ns.IsMetricsPanelShown and ns.IsMetricsPanelShown()
        and context
        and context.mode == "DPS"
        and context.targetExists
        and ns.Print then
        local btEval = FindEvalByToken(nextEvaluations, TOKENS.BLOODTHIRST)
        local btCooldown = GetTokenCooldownRemaining(TOKENS.BLOODTHIRST, context)
        local projectedWindow = GetDpsProjectedPremiumWindow(context, TOKENS.BLOODTHIRST)
        local readySoonEval = FindReadySoonDpsPremiumEval(context, nextEvaluations)
        local queuedDumpToken = context.queue and context.queue.queuedDumpToken or TOKENS.HOLD
        if btEval
            or btCooldown <= math.max(projectedWindow + 0.15, 1.25)
            or (queuedDumpToken and queuedDumpToken ~= TOKENS.HOLD)
            or (context.known and context.known.bloodthirst == false) then
            local btReason = (btEval and btEval.reasons and btEval.reasons[1]) or "-"
            local recommendedToken = recommendedAction and recommendedAction.token or TOKENS.NONE
            local ranked1 = rankedRecommendations and rankedRecommendations[1] and rankedRecommendations[1].token or TOKENS.NONE
            local ranked2 = rankedRecommendations and rankedRecommendations[2] and rankedRecommendations[2].token or TOKENS.NONE
            local ranked3 = rankedRecommendations and rankedRecommendations[3] and rankedRecommendations[3].token or TOKENS.NONE
            local signature = table.concat({
                "bt",
                tostring(recommendedToken),
                tostring(ranked1),
                tostring(ranked2),
                tostring(ranked3),
                tostring(queuedDumpToken),
                tostring(btEval and btEval.passed and true or false),
                tostring(context.known and context.known.bloodthirst or "nil"),
                tostring(readySoonEval and readySoonEval.token or TOKENS.NONE),
                string.format("%.2f", tonumber(btCooldown) or 0),
                string.format("%.2f", tonumber(projectedWindow) or 0),
                tostring((context.rage or 0) >= GetTokenRageCost(TOKENS.BLOODTHIRST)),
                tostring(btReason),
            }, "|")
            local now = GetTime()
            if OverpowerDebugState.btSignature ~= signature or (now - (OverpowerDebugState.btAt or 0)) >= 0.75 then
                OverpowerDebugState.btSignature = signature
                OverpowerDebugState.btAt = now
                ns.Print(string.format(
                    "BT debug rec=%s ranked=%s/%s/%s queued=%s known=%s btPassed=%s readySoon=%s btCd=%.2f win=%.2f rage=%d/%d reason=%s",
                    tostring(recommendedToken),
                    tostring(ranked1),
                    tostring(ranked2),
                    tostring(ranked3),
                    tostring(queuedDumpToken or TOKENS.HOLD),
                    (context.known and context.known.bloodthirst == false) and "N" or "Y",
                    btEval and btEval.passed and "Y" or "N",
                    tostring(readySoonEval and readySoonEval.token or TOKENS.NONE),
                    tonumber(btCooldown) or 0,
                    tonumber(projectedWindow) or 0,
                    tonumber(context.rage or 0) or 0,
                    GetTokenRageCost(TOKENS.BLOODTHIRST),
                    tostring(btReason)
                ))
            end
        end
    end

    return {
        mode = context.mode,
        stance = context.stance,
        horizonMs = context.horizonMs,
        nextGcdSkill = compatNextSkill,
        nextGcdReason = compatNextReason,
        nextSkill = compatNextSkill,
        reason = compatNextReason,
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
        dumpQueueSkill = compatDumpSkill,
        dumpQueueReason = compatDumpReason,
        dumpSkill = compatDumpSkill,
        dumpReason = compatDumpReason,
        offGcdSkill = compatOffGcdSkill,
        offGcdReason = compatOffGcdReason,
        offGcdState = {
            cooldownRem = offGcdCooldownRem,
            rageCost = offGcdRageCost,
            rageEnough = offGcdRageEnough,
            passed = offGcdEval and offGcdEval.passed or false,
        },
        recommendedAction = recommendedAction,
        recommendedSkill = recommendedAction and recommendedAction.token or TOKENS.NONE,
        recommendedReason = recommendedAction and recommendedAction.reason or "当前无明确动作",
        recommendedChannel = recommendedAction and recommendedAction.channel or "none",
        rankedRecommendations = rankedRecommendations,
        queueIndicator = queueIndicator,
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
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("PLAYER_LEVEL_UP")
    frame:RegisterEvent("SPELLS_CHANGED")
    frame:RegisterEvent("LEARNED_SPELL_IN_TAB")
    frame:RegisterEvent("CHARACTER_POINTS_CHANGED")
    frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
    frame:RegisterEvent("RAID_ROSTER_UPDATE")
    frame:RegisterEvent("UNIT_AURA")
    frame:SetScript("OnEvent", function(_, event, arg1)
        if event == "PLAYER_ENTERING_WORLD" then
            InvalidateExecuteModelCache()
            InvalidateEquipmentStateCache()
            InvalidateBattleShoutAuraCache()
            Decision._spellTokenCache = nil
            ResetHabitState(nil, UnitAffectingCombat("player"))
            return
        end
        if event == "PLAYER_LEVEL_UP"
            or event == "SPELLS_CHANGED"
            or event == "LEARNED_SPELL_IN_TAB"
            or event == "CHARACTER_POINTS_CHANGED" then
            InvalidateExecuteModelCache()
            Decision._spellTokenCache = nil
            return
        end
        if event == "PLAYER_EQUIPMENT_CHANGED" then
            InvalidateEquipmentStateCache()
            return
        end
        if event == "GROUP_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
            InvalidateBattleShoutAuraCache()
            return
        end
        if event == "UNIT_AURA" then
            if arg1 == "player" or arg1 == "target" or (type(arg1) == "string" and strfind(arg1, "^party")) then
                InvalidateBattleShoutAuraCache()
                if arg1 == "player" then
                    InvalidateExecuteModelCache()
                end
            end
        end
    end)
    self.eventFrame = frame
end

ns.RegisterModule(DecisionModule)

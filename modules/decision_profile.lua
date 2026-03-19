local _, ns = ...

local DecisionProfileModule = {
    name = "DecisionProfile",
}

local function DeepCopy(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, sub in pairs(v) do
        out[k] = DeepCopy(sub)
    end
    return out
end

local function DeepMerge(base, patch)
    if type(base) ~= "table" then
        base = {}
    end
    if type(patch) ~= "table" then
        return base
    end
    for k, v in pairs(patch) do
        if type(v) == "table" and type(base[k]) == "table" then
            DeepMerge(base[k], v)
        else
            base[k] = DeepCopy(v)
        end
    end
    return base
end

-- 统一参数入口（用户可直接修改此表，/reload 后生效）。
local USER_DECISION_PROFILE = {
  buffTrinketWeightProfiles = {
    [12319] = {
      name = "Flurry",
      weights = {
        dps = 6,
        dump = 3,
        haste = 20,
      },
    },
    [12328] = {
      name = "Death Wish",
      weights = {
        bloodthirst = 5,
        dps = 14,
        execute = 5,
        threat = 8,
      },
    },
    [15366] = {
      name = "Songflower",
      weights = {
        crit = 5,
        dps = 6,
        threat = 3,
      },
    },
    [16609] = {
      name = "Warchief Blessing",
      weights = {
        dps = 7,
        dump = 3,
        haste = 15,
      },
    },
    [1719] = {
      name = "Recklessness",
      weights = {
        bloodthirst = 6,
        crit = 30,
        dps = 16,
        execute = 8,
      },
    },
    [18499] = {
      name = "Berserker Rage",
      weights = {
        threat = 3,
        tps = 2,
      },
    },
    [22888] = {
      name = "Rallying Cry",
      weights = {
        ap = 140,
        crit = 5,
        dps = 10,
        threat = 6,
      },
    },
    [2687] = {
      name = "Bloodrage",
      weights = {
        sunder = 2,
        threat = 4,
        tps = 3,
      },
    },
  },
  decisionConfig = {
    battleShoutOocMinRage = 10,
    battleShoutRefreshSeconds = 12,
    sunderDutyMode = "self_stack",
    sunderHpThreshold = 100000,
    sunderMinTtdSeconds = 9,
    sunderRefreshSeconds = 10,
    sunderTargetStacks = 5,
  },
  habitConfig = {
    enabled = true,
    minHoldMs = 600,
    switchDelta = 10,
    baseLockedBonus = 8,
    bonusDecayMs = 1200,
    readySoonMs = 350,
    emergencyOverride = true,
  },
  hsQueueConfig = {
    enabled = true,
    queueWindowMs = 380,
    safetyRage = 8,
    btProtectMs = 450,
    wwProtectMs = 550,
    exProtectMs = 350,
    singleTargetOnly = true,
  },
  hamstringConfig = {
    enabled = true,
    singleTargetOnly = true,
    refreshSeconds = 8,
    flurryBaitBonus = 8,
    mode = "flurry_ev",
    minTargetTtdSeconds = 10,
    lookaheadSeconds = 3.2,
    minEvScore = 4,
    evScale = 18,
    baseBias = 1,
    yellowLandChance = 0.90,
    naturalProcWindowMaxEvents = 4,
    mainSwingValue = 1.0,
    offSwingValue = 0.65,
    gcdPenalty = 1.0,
    ragePenaltyScale = 0.8,
    keepDebuffBias = 0,
    rageSafetyReserve = 12,
    btProtectMs = 450,
    wwProtectMs = 550,
    exProtectMs = 350,
    allowExecutePhase = false,
  },
  decisionHorizonMs = 400,
  schemaVersion = 1,
  setBonusProfiles = {
    [209] = {
      name = "Battlegear of Might",
      pieces = {
        [3] = {
          sunder = 4,
          survival = 2,
          threat = 6,
          tps = 5,
        },
        [5] = {
          sunder = 6,
          survival = 3,
          threat = 10,
          tps = 8,
        },
      },
    },
    [210] = {
      name = "Battlegear of Wrath",
      pieces = {
        [3] = {
          sunder = 6,
          survival = 4,
          threat = 8,
          tps = 7,
        },
        [5] = {
          sunder = 8,
          survival = 6,
          threat = 12,
          tps = 10,
        },
      },
    },
  },
  setNameProfileHints = {
    {
      pattern = "Might",
      pieces = {
        [3] = {
          threat = 6,
          tps = 5,
        },
        [5] = {
          sunder = 5,
          threat = 10,
          tps = 8,
        },
      },
    },
    {
      pattern = "Wrath",
      pieces = {
        [3] = {
          threat = 8,
          tps = 7,
        },
        [5] = {
          survival = 4,
          threat = 12,
          tps = 10,
        },
      },
    },
    {
      pattern = "Conqueror",
      pieces = {
        [3] = {
          dps = 6,
          whirlwind = 4,
        },
        [5] = {
          dps = 10,
          dump = 4,
          whirlwind = 8,
        },
      },
    },
    {
      pattern = "Dreadnaught",
      pieces = {
        [3] = {
          threat = 10,
          tps = 9,
        },
        [5] = {
          survival = 6,
          threat = 14,
          tps = 12,
        },
      },
    },
  },
  policyParams = {
    bloodthirst_tps_urgency_coeff = 0.8,
    dps_threat_aggressive_bonus = 3.0,
    last_stand_survival_coeff = 1.7,
    revenge_urgency_coeff = 1.2,
    shield_slam_urgency_coeff = 1.6,
    survival_urgency_base = 0.35,
    taunt_urgency_coeff = 3.2,
    threat_urgency_base = 0.6,
    tps_threat_bias_coeff = 0.35,
  },
}

function ns.GetDecisionProfile()
    local base = DeepCopy(USER_DECISION_PROFILE)
    local dbPatch = ns.db and ns.db.metrics and ns.db.metrics.decisionProfile or nil
    if type(dbPatch) == "table" then
        DeepMerge(base, dbPatch)
    end
    return base
end

function ns.SetDecisionProfile(partial)
    if not ns.db or not ns.db.metrics or type(partial) ~= "table" then
        return
    end
    ns.db.metrics.decisionProfile = ns.db.metrics.decisionProfile or {}
    DeepMerge(ns.db.metrics.decisionProfile, partial)
end

function ns.ResetDecisionProfile()
    if not ns.db or not ns.db.metrics then
        return
    end
    ns.db.metrics.decisionProfile = {}
end

function DecisionProfileModule:Init()
    if not ns.db or not ns.db.metrics then
        return
    end
    ns.db.metrics.decisionProfile = ns.db.metrics.decisionProfile or {}
    -- SavedVariables 是账号级共享（Fury.toc: SavedVariables），此处不做角色隔离。
    ns.db.metrics.decisionProfilePreset = nil
end

ns.RegisterModule(DecisionProfileModule)

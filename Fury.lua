local ADDON_NAME, ns = ...
local VERSION = "1.9"

ns.name = ADDON_NAME
ns.modules = {}
ns.addon = CreateFrame("Frame")

local CHANGELOG_ORDER = { "1.9", "1.8", "1.7", "1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0" }

local CHANGELOG = {
    ["1.9"] = {
        date = "2026-03-19",
        sections = {
            ["新增"] = {
                "插件介绍页新增 GitHub 项目地址，便于直接查看源码与发布分支。",
            },
            ["优化"] = {
                "Battle Shout 的 WAIT 预测展示收紧，仅在真实需要补/续时才进入主提示预测。",
                "发布脚本新增 addon-only 独立推送流程，便于只发布 addon/ 内容到 GitHub。",
            },
            ["修复"] = {
                "修复 Battle Shout 在部分 WAIT / 无目标场景下短暂闪现、干扰判断的问题。",
            },
        },
    },
    ["1.8"] = {
        date = "2026-03-18",
        sections = {
            ["新增"] = {
                "新增断筋骗乱舞（Hamstring-Flurry）决策分支，在满足保护窗与怒气安全条件时参与主循环候选。",
                "新增非满级/未学技能的降级决策矩阵，候选会按当前等级与已学最高 rank 自动适配。",
                "设置面板新增“介绍”和“更新”分页，可在游戏内直接查看作者信息、功能简介与版本记录。",
            },
            ["优化"] = {
                "技能可用性判定统一按“已学最高 rank”解析，降低多 rank 场景下的判定偏差。",
                "DPS 候选评分改为“真实技能数据驱动”的 rank 收益缩放（按当前已学 rank 相对满级 rank 归一化）。",
                "设置页全量分页与 Debug 面板完成统一排版微调，提升小窗口下文字可读性。",
            },
            ["修复"] = {
                "修复部分技能在未学习或 rank 不完整时仍被纳入候选的问题，并补充可解释拒绝原因。",
            },
        },
    },
    ["1.7"] = {
        date = "2026-03-17",
        sections = {
            ["新增"] = {
                "新增技能键位提示配置页，可为主技能与泄怒技能分别填写键位并在图标显示。",
            },
            ["优化"] = {
                "设置面板重构为 GatherMate 风格左侧分类导航，支持按功能分组浏览。",
                "主提示图标的 CD 与键位显示样式可读性优化，并修复窄宽度下键位页文案布局。",
            },
            ["修复"] = {
                "修复键位页说明文字与输入行在小窗口宽度下重叠的问题。",
            },
        },
    },
    ["1.6"] = {
        date = "2026-03-17",
        sections = {
            ["新增"] = {
                "玩家参数自定义覆盖改为账号共享，当前账号下角色可共用一套决策参数。",
            },
            ["优化"] = {
                "统一参数策略改为单一调优基线，不再区分 default/latest 双预设。",
                "设置面板与命令文案同步精简，参数回退统一为 /fury profile reset。",
            },
            ["修复"] = {
                "修复预设切换引起的参数来源不一致，确保自定义覆盖稳定落地到 SavedVariables。",
            },
        },
    },
    ["1.5"] = {
        date = "2026-03-17",
        sections = {
            ["新增"] = {
                "主手挥击前短窗新增 HS Queue（卡英勇）决策分支，并补充主/副手挥击节奏可视化字段。",
            },
            ["优化"] = {
                "HS Queue 仅在双持、单目标、怒气安全且主循环保护窗外轻量介入，降低对常规循环的干扰。",
                "离线策略仿真强化 TPS 仇恨紧急度建模，低仇恨时更稳定优先高威胁技能。",
            },
            ["修复"] = {
                "修复部分场景下离线 L2 门禁回归，恢复双层门禁通过状态。",
            },
        },
    },
    ["1.4"] = {
        date = "2026-03-17",
        sections = {
            ["新增"] = {},
            ["优化"] = {
                "默认设置调整为非战斗时显示决策图标，开场观察与调试更直观。",
            },
            ["修复"] = {
                "非战士职业现在不会初始化 Fury 模块，避免无关职业加载插件逻辑。",
            },
        },
    },
    ["1.3"] = {
        date = "2026-03-17",
        sections = {
            ["新增"] = {
                "新增“连按习惯提示”模式，支持在收益差不大时稳定维持当前主技能提示。",
                "新增 /fury habit on|off，可快速开关习惯提示模式。",
            },
            ["优化"] = {
                "主技能切换逻辑加入阈值与去抖策略，减少提示抖动与频繁跳变。",
                "可用提示视觉增强：保留冷却数字，同时叠加更稳定的高亮脉冲反馈。",
            },
            ["修复"] = {
                "修复部分场景下技能可用高亮不明显的问题。",
            },
        },
    },
    ["1.2"] = {
        date = "2026-03-17",
        sections = {
            ["新增"] = {
                "主技能图标支持冷却倒计时显示，读数精确到 0.1 秒。",
                "主技能与泄怒图标新增虚线走马灯边框与外发光提示。",
            },
            ["优化"] = {
                "等待窗口下的主技能预测策略优化为“真实最优优先，WAIT 时再显示预测最优”。",
                "泄怒图标在 HOLD 状态下会按目标数量自动切换 HS/Cleave 预览。",
            },
            ["修复"] = {
                "修复满血场景误预测斩杀技能的问题。",
                "修复敌对目标死亡后数量统计未及时减少的问题。",
            },
        },
    },
    ["1.1"] = {
        date = "2026-03-16",
        sections = {
            ["新增"] = {
                "新增 /fury changelog [version]，可在游戏内查看更新记录。",
                "新增 /fury mode auto|dps|tps，可手动强制决策模式。",
            },
            ["优化"] = {
                "决策树补强：TPS 模式加入嘲讽、仇恨态势分层与 Fury tank 回填逻辑。",
                "技能/姿态识别改为 SpellID 优先，提升多语言客户端兼容性。",
            },
            ["修复"] = {
                "修复部分客户端下防御姿态未触发 TPS 模式的问题（增加多重兜底识别）。",
            },
        },
    },
    ["1.0"] = {
        date = "2026-03-16",
        sections = {
            ["新增"] = {
                "初始化 Fury 插件工程，完成模块化加载框架。",
                "提供决策 Debug 面板、提示图标、设置面板与小地图图标。",
            },
            ["优化"] = {},
            ["修复"] = {},
        },
    },
}

local defaults = {
    minimap = {
        hide = false,
        angle = 220,
    },
    metrics = {
        showPanel = false,
        showIcon = true,
        iconShowOutOfCombat = true,
        iconShowText = false,
        iconLocked = false,
        iconSizePreset = "standard",
        modeOverride = "auto",
        decisionHorizonMs = 400,
        decisionConfig = {
            sunderHpThreshold = 100000,
            sunderRefreshSeconds = 10,
            sunderTargetStacks = 5,
        },
        decisionProfile = {},
        keybindHints = {},
        habitEnabled = true,
        panelPoint = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = 0,
        },
        panelSize = {
            width = 760,
            height = 444,
        },
        iconPoint = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 260,
            y = 0,
        },
    },
    meta = {
        lastSeenVersion = "",
    },
}

local function CopyDefaults(src, dst)
    if type(src) ~= "table" then
        return dst
    end
    if type(dst) ~= "table" then
        dst = {}
    end
    for key, value in pairs(src) do
        if type(value) == "table" then
            dst[key] = CopyDefaults(value, dst[key])
        elseif dst[key] == nil then
            dst[key] = value
        end
    end
    return dst
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff7d0a[Fury]|r " .. tostring(msg))
end

function ns.GetVersion()
    return VERSION
end

local VALID_KEYBIND_TOKENS = {
    BLOODTHIRST = true,
    WHIRLWIND = true,
    EXECUTE = true,
    SUNDER_ARMOR = true,
    REVENGE = true,
    SHIELD_BLOCK = true,
    SHIELD_SLAM = true,
    LAST_STAND = true,
    HEROIC_STRIKE = true,
    CLEAVE = true,
}

local function NormalizeKeybindText(text)
    local raw = strupper(strtrim(tostring(text or "")))
    raw = raw:gsub("%s+", "")
    if raw == "" then
        return nil
    end
    if #raw > 10 then
        raw = raw:sub(1, 10)
    end
    return raw
end

function ns.SetSkillKeybindHint(token, keyText)
    if not ns.db or not ns.db.metrics then
        return
    end
    local t = strupper(tostring(token or ""))
    if not VALID_KEYBIND_TOKENS[t] then
        return
    end
    ns.db.metrics.keybindHints = ns.db.metrics.keybindHints or {}
    local normalized = NormalizeKeybindText(keyText)
    if normalized then
        ns.db.metrics.keybindHints[t] = normalized
    else
        ns.db.metrics.keybindHints[t] = nil
    end
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.GetSkillKeybindHint(token)
    local t = strupper(tostring(token or ""))
    local map = ns.db and ns.db.metrics and ns.db.metrics.keybindHints
    if type(map) ~= "table" then
        return nil
    end
    return map[t]
end

function ns.GetChangelogOrder()
    local out = {}
    for i = 1, #CHANGELOG_ORDER do
        out[i] = CHANGELOG_ORDER[i]
    end
    return out
end

function ns.GetChangelogEntry(version)
    local target = tostring(version or VERSION):gsub("^v", "")
    local entry = CHANGELOG[target]
    if not entry then
        return nil
    end
    local result = {
        version = target,
        date = entry.date or "",
        sections = {},
    }
    for _, sectionName in ipairs({ "新增", "优化", "修复" }) do
        local src = entry.sections and entry.sections[sectionName]
        local dst = {}
        if type(src) == "table" then
            for i = 1, #src do
                dst[i] = src[i]
            end
        end
        result.sections[sectionName] = dst
    end
    return result
end

function ns.PrintChangelog(version)
    local target = tostring(version or VERSION)
    target = target:gsub("^v", "")
    local entry = CHANGELOG[target]
    if not entry then
        ns.Print("未找到版本 " .. target .. " 的更新记录，显示当前版本。")
        target = VERSION
        entry = CHANGELOG[target] or {}
    end

    local title = "Changelog v" .. target
    if entry.date and entry.date ~= "" then
        title = title .. " (" .. entry.date .. ")"
    end
    ns.Print(title)

    local sections = entry.sections or {}
    local orderedSections = { "新增", "优化", "修复" }
    local printed = false
    for _, sectionName in ipairs(orderedSections) do
        local items = sections[sectionName]
        if type(items) == "table" and #items > 0 then
            printed = true
            ns.Print("[" .. sectionName .. "]")
            for i = 1, #items do
                ns.Print("- " .. items[i])
            end
        end
    end
    if not printed then
        ns.Print("- 暂无更新记录")
    end

    local latest = CHANGELOG_ORDER[1]
    if latest and target ~= latest then
        ns.Print("最新版本: v" .. latest .. "（输入 /fury changelog 查看）")
    end
end

function ns.RegisterModule(module)
    if type(module) == "table" then
        table.insert(ns.modules, module)
    end
end

local function SafeCall(module, method)
    if type(module[method]) ~= "function" then
        return
    end
    local ok, err = pcall(module[method], module)
    if not ok then
        ns.Print((module.name or "UnknownModule") .. "." .. method .. " 出错: " .. tostring(err))
    end
end

local function Dispatch(method)
    for _, module in ipairs(ns.modules) do
        SafeCall(module, method)
    end
end

ns.addon:RegisterEvent("ADDON_LOADED")
ns.addon:RegisterEvent("PLAYER_LOGIN")

ns.addon:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        local _, classFile = UnitClass("player")
        if classFile ~= "WARRIOR" then
            ns.disabledForClass = true
            ns.addon:UnregisterEvent("ADDON_LOADED")
            ns.addon:UnregisterEvent("PLAYER_LOGIN")
            return
        end
        FuryDB = CopyDefaults(defaults, FuryDB or {})
        ns.db = FuryDB
        Dispatch("Init")
        ns.Print("v" .. VERSION .. " by Lucien (@硬汉-健将)")
        ns.Print("已加载。输入 /fury 打开设置。")
        if ns.db and ns.db.meta then
            local lastSeen = ns.db.meta.lastSeenVersion or ""
            if lastSeen ~= VERSION then
                ns.Print("已更新到 v" .. VERSION .. "，输入 /fury changelog 查看更新。")
                ns.db.meta.lastSeenVersion = VERSION
            end
        end
    elseif event == "PLAYER_LOGIN" then
        if ns.disabledForClass then
            return
        end
        Dispatch("OnLogin")
    end
end)

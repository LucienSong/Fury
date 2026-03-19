local _, ns = ...

local OptionsModule = {
    name = "Options",
}

local panel
local navButtons = {}
local pages = {}
local activePage = "icon"
local keybindEdits = {}
local keybindDescText
local keybindScrollChild
local changelogBodyText
local aboutBodyText
local aboutScrollChild
local changelogScrollChild

local minimapCheck
local decisionIconCheck
local iconTextCheck
local iconLockCheck
local hamstringExecuteCheck
local iconSizeLabel
local timelineWidthLabel
local timelineSecondsLabel
local horizonLabel
local sunderHpLabel
local sunderRefreshLabel
local sunderStacksLabel
local sunderDutyLabel

local SUNDER_DUTY_MODES = {
    "self_stack",
    "maintain_only",
    "external_armor",
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

local function GetSunderDutyModeLabel(mode)
    if ns.GetSunderDutyModeLabel then
        return ns.GetSunderDutyModeLabel(mode)
    end
    return NormalizeSunderDutyMode(mode)
end

local function ShiftSunderDutyMode(current, step)
    local normalized = NormalizeSunderDutyMode(current)
    local index = 1
    for i = 1, #SUNDER_DUTY_MODES do
        if SUNDER_DUTY_MODES[i] == normalized then
            index = i
            break
        end
    end
    local nextIndex = index + (step or 1)
    if nextIndex < 1 then
        nextIndex = #SUNDER_DUTY_MODES
    elseif nextIndex > #SUNDER_DUTY_MODES then
        nextIndex = 1
    end
    return SUNDER_DUTY_MODES[nextIndex]
end

local KEYBIND_ROWS = {
    { token = "BLOODTHIRST", label = "嗜血 (BT)" },
    { token = "WHIRLWIND", label = "旋风斩 (WW)" },
    { token = "EXECUTE", label = "斩杀 (EXE)" },
    { token = "HAMSTRING", label = "断筋 (HAM)" },
    { token = "SUNDER_ARMOR", label = "破甲 (SND)" },
    { token = "HEROIC_STRIKE", label = "英勇打击 (HS)" },
    { token = "CLEAVE", label = "顺劈斩 (CL)" },
    { token = "BATTLE_SHOUT", label = "战斗怒吼 (BS)" },
    { token = "BLOODRAGE", label = "血性狂暴 (BR)" },
    { token = "REVENGE", label = "复仇 (REV)" },
    { token = "SHIELD_SLAM", label = "盾猛 (SS)" },
    { token = "SHIELD_BLOCK", label = "盾挡 (SB)" },
    { token = "TAUNT", label = "嘲讽 (TAUNT)" },
    { token = "MOCKING_BLOW", label = "惩戒痛击 (MB)" },
    { token = "LAST_STAND", label = "破釜沉舟 (LS)" },
}

local NAV_ITEMS = {
    { id = "about", label = "介绍" },
    { id = "icon", label = "图标" },
    { id = "decision", label = "决策" },
    { id = "sunder", label = "破甲" },
    { id = "profile", label = "参数" },
    { id = "keybind", label = "键位" },
    { id = "changelog", label = "更新" },
}

local function OpenClassicOptions()
    if not panel then
        return
    end
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
end

function ns.OpenOptions()
    if Settings and Settings.OpenToCategory and ns.settingsCategory then
        Settings.OpenToCategory(ns.settingsCategory:GetID())
        return
    end
    OpenClassicOptions()
end

local function RefreshKeybindState()
    for _, row in ipairs(KEYBIND_ROWS) do
        local edit = keybindEdits[row.token]
        if edit then
            edit:SetText((ns.GetSkillKeybindHint and ns.GetSkillKeybindHint(row.token)) or "")
            if edit.ClearFocus then
                edit:ClearFocus()
            end
        end
    end
end

local function RefreshOptionsState()
    if minimapCheck then
        minimapCheck:SetChecked(ns.IsMinimapIconShown())
    end
    if iconTextCheck and ns.IsDecisionIconTextShown then
        iconTextCheck:SetChecked(ns.IsDecisionIconTextShown())
    end
    if iconLockCheck and ns.IsDecisionIconLocked then
        iconLockCheck:SetChecked(ns.IsDecisionIconLocked())
    end
    if hamstringExecuteCheck and ns.IsHamstringExecutePhaseEnabled then
        hamstringExecuteCheck:SetChecked(ns.IsHamstringExecutePhaseEnabled())
    end
    if iconSizeLabel and ns.GetDecisionIconBaseSize then
        iconSizeLabel:SetText("推荐图标大小: " .. tostring(ns.GetDecisionIconBaseSize()) .. "px")
    end
    if timelineWidthLabel and ns.GetDecisionTimelineWidth then
        timelineWidthLabel:SetText("时间线宽度: " .. tostring(ns.GetDecisionTimelineWidth()) .. "px")
    end
    if timelineSecondsLabel and ns.GetDecisionTimelineSeconds then
        timelineSecondsLabel:SetText("时间线长度: " .. tostring(ns.GetDecisionTimelineSeconds()) .. "s")
    end
    if horizonLabel and ns.GetDecisionHorizonMs then
        horizonLabel:SetText("预测窗口: " .. tostring(ns.GetDecisionHorizonMs()) .. "ms")
    end
    local cfg = ns.GetDecisionConfig and ns.GetDecisionConfig() or nil
    if cfg then
        if sunderHpLabel then
            sunderHpLabel:SetText("DPS破甲HP阈值: " .. tostring(cfg.sunderHpThreshold))
        end
        if sunderRefreshLabel then
            sunderRefreshLabel:SetText("破甲刷新秒数: " .. tostring(math.floor(cfg.sunderRefreshSeconds + 0.5)) .. "s")
        end
        if sunderStacksLabel then
            sunderStacksLabel:SetText("破甲目标层数: " .. tostring(cfg.sunderTargetStacks))
        end
        if sunderDutyLabel then
            sunderDutyLabel:SetText("破甲职责: " .. GetSunderDutyModeLabel(cfg.sunderDutyMode))
        end
    end
    if activePage == "keybind" then
        RefreshKeybindState()
        if keybindDescText and panel then
            keybindDescText:SetWidth(math.max((panel:GetWidth() or 760) - 260, 260))
        end
        if keybindScrollChild and panel then
            keybindScrollChild:SetWidth(math.max((panel:GetWidth() or 760) - 280, 300))
        end
    end
    if activePage == "about" and aboutBodyText and aboutScrollChild and panel then
        local bodyWidth = math.max((panel:GetWidth() or 760) - 300, 260)
        aboutBodyText:SetWidth(bodyWidth)
        aboutScrollChild:SetWidth(bodyWidth + 12)
        aboutScrollChild:SetHeight(math.max(24, math.floor(aboutBodyText:GetStringHeight() + 12)))
    end
    if activePage == "changelog" and changelogBodyText and changelogScrollChild and panel then
        local bodyWidth = math.max((panel:GetWidth() or 760) - 300, 260)
        changelogBodyText:SetWidth(bodyWidth)
        changelogScrollChild:SetWidth(bodyWidth + 12)
        changelogScrollChild:SetHeight(math.max(24, math.floor(changelogBodyText:GetStringHeight() + 12)))
    end
end

local function SetActivePage(id)
    activePage = id
    for pageId, page in pairs(pages) do
        page:SetShown(pageId == id)
    end
    for pageId, btn in pairs(navButtons) do
        if pageId == id then
            btn:LockHighlight()
            btn:SetNormalFontObject("GameFontNormal")
        else
            btn:UnlockHighlight()
            btn:SetNormalFontObject("GameFontHighlight")
        end
    end
    RefreshOptionsState()
end

local function CreatePage(parent, id)
    local f = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetAllPoints(parent)
    pages[id] = f
    return f
end

local function BuildAboutPage(parent)
    local page = CreatePage(parent, "about")

    local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Fury - 插件介绍")

    local scroll = CreateFrame("ScrollFrame", "FuryOptionsAboutScroll", page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(520)
    child:SetHeight(1)
    scroll:SetScrollChild(child)
    aboutScrollChild = child

    aboutBodyText = child:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    aboutBodyText:SetPoint("TOPLEFT", 0, 0)
    aboutBodyText:SetWidth(500)
    aboutBodyText:SetJustifyH("LEFT")
    aboutBodyText:SetJustifyV("TOP")
    aboutBodyText:SetWordWrap(true)
    if aboutBodyText.SetNonSpaceWrap then
        aboutBodyText:SetNonSpaceWrap(true)
    end
    aboutBodyText:SetText(table.concat({
        "作者: Lucien   版本: v" .. tostring(ns.GetVersion and ns.GetVersion() or "-"),
        "Classic Hardcore Realm & ID: @硬汉-健将",
        "GitHub: https://github.com/LucienSong/Fury",
        "",
        "Fury 2.0 是 WoW Classic Era 狂暴战决策辅助插件，核心目标是提升实战循环稳定性，",
        "在 DPS/TPS 场景下给出更硬、更可解释的下一技能建议。",
        "",
        "功能简介：",
        "- 单主图标提示当前第一优先动作",
        "- DPS/TPS 两套独立优先级树，不再混排",
        "- 时间线展示全部成功施放技能与泄怒入队状态",
        "- 断筋骗乱舞与主循环保护窗联动",
        "- 未学习/低等级/rank 未满自动降级决策",
        "- Debug 面板展示优先级树、候选评分与淘汰原因",
        "- 键位提示、图标尺寸与显示行为可配置",
        "- 参数覆盖账号角色共享，支持一键恢复基线",
    }, "\n"))
    child:SetHeight(math.max(24, math.floor(aboutBodyText:GetStringHeight() + 12)))
end

local function BuildIconPage(parent)
    local page = CreatePage(parent, "icon")
    local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("图标设置")

    minimapCheck = CreateFrame("CheckButton", "FuryOptionsMinimapCheck", page, "InterfaceOptionsCheckButtonTemplate")
    minimapCheck:SetPoint("TOPLEFT", title, "BOTTOMLEFT", -2, -12)
    _G[minimapCheck:GetName() .. "Text"]:SetText("显示小地图图标")
    minimapCheck:SetScript("OnClick", function(self)
        ns.SetMinimapIconShown(self:GetChecked())
    end)

    iconTextCheck = CreateFrame("CheckButton", "FuryOptionsIconTextCheck", page, "InterfaceOptionsCheckButtonTemplate")
    iconTextCheck:SetPoint("TOPLEFT", minimapCheck, "BOTTOMLEFT", 0, -8)
    _G[iconTextCheck:GetName() .. "Text"]:SetText("显示图标下方技能文字")
    iconTextCheck:SetScript("OnClick", function(self)
        if ns.SetDecisionIconTextShown then
            ns.SetDecisionIconTextShown(self:GetChecked())
        end
    end)

    iconLockCheck = CreateFrame("CheckButton", "FuryOptionsIconLockCheck", page, "InterfaceOptionsCheckButtonTemplate")
    iconLockCheck:SetPoint("TOPLEFT", iconTextCheck, "BOTTOMLEFT", 0, -8)
    _G[iconLockCheck:GetName() .. "Text"]:SetText("锁定主提示图标位置")
    iconLockCheck:SetScript("OnClick", function(self)
        if ns.SetDecisionIconLocked then
            ns.SetDecisionIconLocked(self:GetChecked())
        end
    end)

    iconSizeLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    iconSizeLabel:SetPoint("TOPLEFT", iconLockCheck, "BOTTOMLEFT", 0, -12)
    iconSizeLabel:SetText("")

    local iconSizeMinusButton = CreateFrame("Button", "FuryOptionsIconSizeMinus", page, "UIPanelButtonTemplate")
    iconSizeMinusButton:SetSize(50, 22)
    iconSizeMinusButton:SetPoint("TOPLEFT", iconSizeLabel, "BOTTOMLEFT", 0, -8)
    iconSizeMinusButton:SetText("-4px")
    iconSizeMinusButton:SetScript("OnClick", function()
        if ns.GetDecisionIconBaseSize and ns.SetDecisionIconBaseSize then
            ns.SetDecisionIconBaseSize(ns.GetDecisionIconBaseSize() - 4)
            RefreshOptionsState()
        end
    end)

    local iconSizePlusButton = CreateFrame("Button", "FuryOptionsIconSizePlus", page, "UIPanelButtonTemplate")
    iconSizePlusButton:SetSize(50, 22)
    iconSizePlusButton:SetPoint("LEFT", iconSizeMinusButton, "RIGHT", 8, 0)
    iconSizePlusButton:SetText("+4px")
    iconSizePlusButton:SetScript("OnClick", function()
        if ns.GetDecisionIconBaseSize and ns.SetDecisionIconBaseSize then
            ns.SetDecisionIconBaseSize(ns.GetDecisionIconBaseSize() + 4)
            RefreshOptionsState()
        end
    end)

    timelineWidthLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    timelineWidthLabel:SetPoint("TOPLEFT", iconSizeMinusButton, "BOTTOMLEFT", 0, -14)
    timelineWidthLabel:SetText("")

    local timelineWidthMinusButton = CreateFrame("Button", "FuryOptionsTimelineWidthMinus", page, "UIPanelButtonTemplate")
    timelineWidthMinusButton:SetSize(60, 22)
    timelineWidthMinusButton:SetPoint("TOPLEFT", timelineWidthLabel, "BOTTOMLEFT", 0, -8)
    timelineWidthMinusButton:SetText("-20px")
    timelineWidthMinusButton:SetScript("OnClick", function()
        if ns.GetDecisionTimelineWidth and ns.SetDecisionTimelineWidth then
            ns.SetDecisionTimelineWidth(ns.GetDecisionTimelineWidth() - 20)
            RefreshOptionsState()
        end
    end)

    local timelineWidthPlusButton = CreateFrame("Button", "FuryOptionsTimelineWidthPlus", page, "UIPanelButtonTemplate")
    timelineWidthPlusButton:SetSize(60, 22)
    timelineWidthPlusButton:SetPoint("LEFT", timelineWidthMinusButton, "RIGHT", 8, 0)
    timelineWidthPlusButton:SetText("+20px")
    timelineWidthPlusButton:SetScript("OnClick", function()
        if ns.GetDecisionTimelineWidth and ns.SetDecisionTimelineWidth then
            ns.SetDecisionTimelineWidth(ns.GetDecisionTimelineWidth() + 20)
            RefreshOptionsState()
        end
    end)

    timelineSecondsLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    timelineSecondsLabel:SetPoint("TOPLEFT", timelineWidthMinusButton, "BOTTOMLEFT", 0, -14)
    timelineSecondsLabel:SetText("")

    local timelineSecondsMinusButton = CreateFrame("Button", "FuryOptionsTimelineSecondsMinus", page, "UIPanelButtonTemplate")
    timelineSecondsMinusButton:SetSize(50, 22)
    timelineSecondsMinusButton:SetPoint("TOPLEFT", timelineSecondsLabel, "BOTTOMLEFT", 0, -8)
    timelineSecondsMinusButton:SetText("-1s")
    timelineSecondsMinusButton:SetScript("OnClick", function()
        if ns.GetDecisionTimelineSeconds and ns.SetDecisionTimelineSeconds then
            ns.SetDecisionTimelineSeconds(ns.GetDecisionTimelineSeconds() - 1)
            RefreshOptionsState()
        end
    end)

    local timelineSecondsPlusButton = CreateFrame("Button", "FuryOptionsTimelineSecondsPlus", page, "UIPanelButtonTemplate")
    timelineSecondsPlusButton:SetSize(50, 22)
    timelineSecondsPlusButton:SetPoint("LEFT", timelineSecondsMinusButton, "RIGHT", 8, 0)
    timelineSecondsPlusButton:SetText("+1s")
    timelineSecondsPlusButton:SetScript("OnClick", function()
        if ns.GetDecisionTimelineSeconds and ns.SetDecisionTimelineSeconds then
            ns.SetDecisionTimelineSeconds(ns.GetDecisionTimelineSeconds() + 1)
            RefreshOptionsState()
        end
    end)
end

local function BuildDecisionPage(parent)
    local page = CreatePage(parent, "decision")
    local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("决策与调试")

    local metricsButton = CreateFrame("Button", "FuryOptionsMetricsButton", page, "UIPanelButtonTemplate")
    metricsButton:SetSize(180, 22)
    metricsButton:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    metricsButton:SetText("打开 Debug 面板")
    metricsButton:SetScript("OnClick", function()
        ns.ToggleMetricsPanel()
    end)

    horizonLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    horizonLabel:SetPoint("TOPLEFT", metricsButton, "BOTTOMLEFT", 0, -14)
    horizonLabel:SetText("")

    local horizonMinusButton = CreateFrame("Button", "FuryOptionsHorizonMinus", page, "UIPanelButtonTemplate")
    horizonMinusButton:SetSize(60, 22)
    horizonMinusButton:SetPoint("TOPLEFT", horizonLabel, "BOTTOMLEFT", 0, -8)
    horizonMinusButton:SetText("-50ms")
    horizonMinusButton:SetScript("OnClick", function()
        if ns.SetDecisionHorizonMs and ns.GetDecisionHorizonMs then
            ns.SetDecisionHorizonMs(ns.GetDecisionHorizonMs() - 50)
            RefreshOptionsState()
        end
    end)

    local horizonPlusButton = CreateFrame("Button", "FuryOptionsHorizonPlus", page, "UIPanelButtonTemplate")
    horizonPlusButton:SetSize(60, 22)
    horizonPlusButton:SetPoint("LEFT", horizonMinusButton, "RIGHT", 8, 0)
    horizonPlusButton:SetText("+50ms")
    horizonPlusButton:SetScript("OnClick", function()
        if ns.SetDecisionHorizonMs and ns.GetDecisionHorizonMs then
            ns.SetDecisionHorizonMs(ns.GetDecisionHorizonMs() + 50)
            RefreshOptionsState()
        end
    end)

    hamstringExecuteCheck = CreateFrame("CheckButton", "FuryOptionsHamstringExecuteCheck", page, "InterfaceOptionsCheckButtonTemplate")
    hamstringExecuteCheck:SetPoint("TOPLEFT", horizonMinusButton, "BOTTOMLEFT", 0, -14)
    _G[hamstringExecuteCheck:GetName() .. "Text"]:SetText("斩杀阶段仍允许断筋骗乱舞")
    hamstringExecuteCheck:SetScript("OnClick", function(self)
        if ns.SetHamstringExecutePhaseEnabled then
            ns.SetHamstringExecutePhaseEnabled(self:GetChecked())
            RefreshOptionsState()
        end
    end)

    local hamstringDesc = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hamstringDesc:SetPoint("TOPLEFT", hamstringExecuteCheck, "BOTTOMLEFT", 4, -4)
    hamstringDesc:SetWidth(520)
    hamstringDesc:SetJustifyH("LEFT")
    hamstringDesc:SetText("默认关闭，避免斩杀期断筋抢占 Execute / BT / WW 的 GCD。")
end

local function BuildSunderPage(parent)
    local page = CreatePage(parent, "sunder")
    local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("破甲参数")

    sunderHpLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    sunderHpLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    sunderHpLabel:SetText("")

    local sunderHpMinusButton = CreateFrame("Button", "FuryOptionsSunderHpMinus", page, "UIPanelButtonTemplate")
    sunderHpMinusButton:SetSize(70, 22)
    sunderHpMinusButton:SetPoint("TOPLEFT", sunderHpLabel, "BOTTOMLEFT", 0, -8)
    sunderHpMinusButton:SetText("-10k")
    sunderHpMinusButton:SetScript("OnClick", function()
        if ns.GetDecisionConfig and ns.SetDecisionConfig then
            local cfg = ns.GetDecisionConfig()
            ns.SetDecisionConfig({ sunderHpThreshold = cfg.sunderHpThreshold - 10000 })
            RefreshOptionsState()
        end
    end)

    local sunderHpPlusButton = CreateFrame("Button", "FuryOptionsSunderHpPlus", page, "UIPanelButtonTemplate")
    sunderHpPlusButton:SetSize(70, 22)
    sunderHpPlusButton:SetPoint("LEFT", sunderHpMinusButton, "RIGHT", 8, 0)
    sunderHpPlusButton:SetText("+10k")
    sunderHpPlusButton:SetScript("OnClick", function()
        if ns.GetDecisionConfig and ns.SetDecisionConfig then
            local cfg = ns.GetDecisionConfig()
            ns.SetDecisionConfig({ sunderHpThreshold = cfg.sunderHpThreshold + 10000 })
            RefreshOptionsState()
        end
    end)

    sunderRefreshLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    sunderRefreshLabel:SetPoint("TOPLEFT", sunderHpMinusButton, "BOTTOMLEFT", 0, -12)
    sunderRefreshLabel:SetText("")

    local sunderRefreshMinusButton = CreateFrame("Button", "FuryOptionsSunderRefreshMinus", page, "UIPanelButtonTemplate")
    sunderRefreshMinusButton:SetSize(60, 22)
    sunderRefreshMinusButton:SetPoint("TOPLEFT", sunderRefreshLabel, "BOTTOMLEFT", 0, -8)
    sunderRefreshMinusButton:SetText("-1s")
    sunderRefreshMinusButton:SetScript("OnClick", function()
        if ns.GetDecisionConfig and ns.SetDecisionConfig then
            local cfg = ns.GetDecisionConfig()
            ns.SetDecisionConfig({ sunderRefreshSeconds = cfg.sunderRefreshSeconds - 1 })
            RefreshOptionsState()
        end
    end)

    local sunderRefreshPlusButton = CreateFrame("Button", "FuryOptionsSunderRefreshPlus", page, "UIPanelButtonTemplate")
    sunderRefreshPlusButton:SetSize(60, 22)
    sunderRefreshPlusButton:SetPoint("LEFT", sunderRefreshMinusButton, "RIGHT", 8, 0)
    sunderRefreshPlusButton:SetText("+1s")
    sunderRefreshPlusButton:SetScript("OnClick", function()
        if ns.GetDecisionConfig and ns.SetDecisionConfig then
            local cfg = ns.GetDecisionConfig()
            ns.SetDecisionConfig({ sunderRefreshSeconds = cfg.sunderRefreshSeconds + 1 })
            RefreshOptionsState()
        end
    end)

    sunderStacksLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    sunderStacksLabel:SetPoint("TOPLEFT", sunderRefreshMinusButton, "BOTTOMLEFT", 0, -12)
    sunderStacksLabel:SetText("")

    local sunderStacksMinusButton = CreateFrame("Button", "FuryOptionsSunderStacksMinus", page, "UIPanelButtonTemplate")
    sunderStacksMinusButton:SetSize(60, 22)
    sunderStacksMinusButton:SetPoint("TOPLEFT", sunderStacksLabel, "BOTTOMLEFT", 0, -8)
    sunderStacksMinusButton:SetText("-1")
    sunderStacksMinusButton:SetScript("OnClick", function()
        if ns.GetDecisionConfig and ns.SetDecisionConfig then
            local cfg = ns.GetDecisionConfig()
            ns.SetDecisionConfig({ sunderTargetStacks = cfg.sunderTargetStacks - 1 })
            RefreshOptionsState()
        end
    end)

    local sunderStacksPlusButton = CreateFrame("Button", "FuryOptionsSunderStacksPlus", page, "UIPanelButtonTemplate")
    sunderStacksPlusButton:SetSize(60, 22)
    sunderStacksPlusButton:SetPoint("LEFT", sunderStacksMinusButton, "RIGHT", 8, 0)
    sunderStacksPlusButton:SetText("+1")
    sunderStacksPlusButton:SetScript("OnClick", function()
        if ns.GetDecisionConfig and ns.SetDecisionConfig then
            local cfg = ns.GetDecisionConfig()
            ns.SetDecisionConfig({ sunderTargetStacks = cfg.sunderTargetStacks + 1 })
            RefreshOptionsState()
        end
    end)

    sunderDutyLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    sunderDutyLabel:SetPoint("TOPLEFT", sunderStacksMinusButton, "BOTTOMLEFT", 0, -12)
    sunderDutyLabel:SetText("")

    local sunderDutyPrevButton = CreateFrame("Button", "FuryOptionsSunderDutyPrev", page, "UIPanelButtonTemplate")
    sunderDutyPrevButton:SetSize(90, 22)
    sunderDutyPrevButton:SetPoint("TOPLEFT", sunderDutyLabel, "BOTTOMLEFT", 0, -8)
    sunderDutyPrevButton:SetText("上一档")
    sunderDutyPrevButton:SetScript("OnClick", function()
        if ns.GetDecisionConfig and ns.SetDecisionConfig then
            local cfg = ns.GetDecisionConfig()
            ns.SetDecisionConfig({ sunderDutyMode = ShiftSunderDutyMode(cfg.sunderDutyMode, -1) })
            RefreshOptionsState()
        end
    end)

    local sunderDutyNextButton = CreateFrame("Button", "FuryOptionsSunderDutyNext", page, "UIPanelButtonTemplate")
    sunderDutyNextButton:SetSize(90, 22)
    sunderDutyNextButton:SetPoint("LEFT", sunderDutyPrevButton, "RIGHT", 8, 0)
    sunderDutyNextButton:SetText("下一档")
    sunderDutyNextButton:SetScript("OnClick", function()
        if ns.GetDecisionConfig and ns.SetDecisionConfig then
            local cfg = ns.GetDecisionConfig()
            ns.SetDecisionConfig({ sunderDutyMode = ShiftSunderDutyMode(cfg.sunderDutyMode, 1) })
            RefreshOptionsState()
        end
    end)
end

local function BuildProfilePage(parent)
    local page = CreatePage(parent, "profile")
    local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("参数管理")

    local desc = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    desc:SetWidth(520)
    desc:SetJustifyH("LEFT")
    desc:SetText("当前使用单一调优基线参数。玩家自定义覆盖保存在 FuryDB 并账号角色共享。")

    local profileResetButton = CreateFrame("Button", "FuryOptionsProfileReset", page, "UIPanelButtonTemplate")
    profileResetButton:SetSize(190, 22)
    profileResetButton:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
    profileResetButton:SetText("清空自定义覆盖（恢复基线）")
    profileResetButton:SetScript("OnClick", function()
        if ns.ResetDecisionProfile then
            ns.ResetDecisionProfile()
            ns.Print("已清空自定义参数覆盖，恢复单一调优基线。")
        end
    end)
end

local function BuildKeybindPage(parent)
    local page = CreatePage(parent, "keybind")
    local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("键位提示")

    keybindDescText = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    keybindDescText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    keybindDescText:SetWidth(420)
    keybindDescText:SetJustifyH("LEFT")
    keybindDescText:SetWordWrap(true)
    if keybindDescText.SetNonSpaceWrap then
        keybindDescText:SetNonSpaceWrap(true)
    end
    keybindDescText:SetText("填写技能键位后，推荐图标会显示对应按键。主循环、泄怒、仇恨和 off-GCD 技能共用这份配置，保存在 FuryDB，账号角色共享。")

    local scroll = CreateFrame("ScrollFrame", "FuryOptionsKeybindScroll", page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", keybindDescText, "BOTTOMLEFT", 0, -10)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(520)
    child:SetHeight(1)
    scroll:SetScrollChild(child)
    keybindScrollChild = child

    local prevLabel
    for i, row in ipairs(KEYBIND_ROWS) do
        local label = child:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        if i == 1 then
            label:SetPoint("TOPLEFT", 0, -2)
        else
            label:SetPoint("TOPLEFT", prevLabel, "BOTTOMLEFT", 0, -12)
        end
        label:SetWidth(220)
        label:SetJustifyH("LEFT")
        label:SetText(row.label)

        local edit = CreateFrame("EditBox", "FuryOptionsKeybindEdit" .. i, child, "InputBoxTemplate")
        edit:SetSize(140, 24)
        edit:SetPoint("LEFT", label, "RIGHT", 10, 0)
        edit:SetAutoFocus(false)
        edit:SetMaxLetters(16)
        edit:SetScript("OnEnterPressed", function(self)
            if ns.SetSkillKeybindHint then
                ns.SetSkillKeybindHint(row.token, self:GetText() or "")
            end
            self:ClearFocus()
            RefreshKeybindState()
        end)
        edit:SetScript("OnEditFocusLost", function(self)
            if ns.SetSkillKeybindHint then
                ns.SetSkillKeybindHint(row.token, self:GetText() or "")
            end
            RefreshKeybindState()
        end)
        keybindEdits[row.token] = edit

        local clearBtn = CreateFrame("Button", "FuryOptionsKeybindClear" .. i, child, "UIPanelButtonTemplate")
        clearBtn:SetSize(60, 22)
        clearBtn:SetPoint("LEFT", edit, "RIGHT", 8, 0)
        clearBtn:SetText("清空")
        clearBtn:SetScript("OnClick", function()
            if ns.SetSkillKeybindHint then
                ns.SetSkillKeybindHint(row.token, "")
            end
            RefreshKeybindState()
        end)

        prevLabel = label
    end
    child:SetHeight(math.max(24, (#KEYBIND_ROWS * 36) + 12))
end

local function BuildChangelogPage(parent)
    local page = CreatePage(parent, "changelog")

    local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("更新记录")

    local hint = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    hint:SetJustifyH("LEFT")
    hint:SetText("按时间倒序显示版本更新（新增/优化/修复）。")

    local scroll = CreateFrame("ScrollFrame", "FuryOptionsChangelogScroll", page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(520)
    child:SetHeight(1)
    scroll:SetScrollChild(child)
    changelogScrollChild = child

    changelogBodyText = child:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    changelogBodyText:SetPoint("TOPLEFT", 0, 0)
    changelogBodyText:SetWidth(500)
    changelogBodyText:SetJustifyH("LEFT")
    changelogBodyText:SetJustifyV("TOP")
    changelogBodyText:SetWordWrap(true)
    if changelogBodyText.SetNonSpaceWrap then
        changelogBodyText:SetNonSpaceWrap(true)
    end

    local lines = {}
    local versions = ns.GetChangelogOrder and ns.GetChangelogOrder() or {}
    if #versions == 0 then
        table.insert(lines, "暂无更新记录。")
    else
        for _, version in ipairs(versions) do
            local entry = ns.GetChangelogEntry and ns.GetChangelogEntry(version) or nil
            if entry then
                local dateText = (entry.date and entry.date ~= "") and (" (" .. entry.date .. ")") or ""
                table.insert(lines, "v" .. tostring(entry.version) .. dateText)
                for _, sectionName in ipairs({ "新增", "优化", "修复" }) do
                    local items = entry.sections and entry.sections[sectionName] or nil
                    if type(items) == "table" and #items > 0 then
                        table.insert(lines, "  [" .. sectionName .. "]")
                        for i = 1, #items do
                            table.insert(lines, "  - " .. tostring(items[i]))
                        end
                    end
                end
                table.insert(lines, "")
            end
        end
    end

    changelogBodyText:SetText(table.concat(lines, "\n"))
    child:SetHeight(math.max(24, math.floor(changelogBodyText:GetStringHeight() + 12)))
end

local function BuildPanelContent()
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Fury")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("WoW Classic Era 设置")

    local left = CreateFrame("Frame", nil, panel, BackdropTemplateMixin and "BackdropTemplate" or nil)
    left:SetPoint("TOPLEFT", 12, -58)
    left:SetPoint("BOTTOMLEFT", 12, 12)
    left:SetWidth(156)
    if left.SetBackdrop then
        left:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        left:SetBackdropColor(0.05, 0.05, 0.08, 1)
    end

    local right = CreateFrame("Frame", nil, panel, BackdropTemplateMixin and "BackdropTemplate" or nil)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 10, 0)
    right:SetPoint("BOTTOMRIGHT", -12, 12)
    if right.SetBackdrop then
        right:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        right:SetBackdropColor(0.08, 0.08, 0.12, 1)
    end

    local navY = -14
    for _, item in ipairs(NAV_ITEMS) do
        local btn = CreateFrame("Button", "FuryOptionsNav" .. item.id, left, "UIPanelButtonTemplate")
        btn:SetHeight(24)
        btn:SetPoint("TOPLEFT", 10, navY)
        btn:SetPoint("TOPRIGHT", -10, navY)
        btn:SetText(item.label)
        btn:SetScript("OnClick", function()
            SetActivePage(item.id)
        end)
        navButtons[item.id] = btn
        navY = navY - 30
    end

    BuildAboutPage(right)
    BuildIconPage(right)
    BuildDecisionPage(right)
    BuildSunderPage(right)
    BuildProfilePage(right)
    BuildKeybindPage(right)
    BuildChangelogPage(right)
    SetActivePage("about")
end

local function RegisterPanel()
    panel = CreateFrame("Frame", "FuryOptionsPanel")
    panel.name = "Fury"
    panel:SetScript("OnShow", RefreshOptionsState)
    panel:SetScript("OnSizeChanged", RefreshOptionsState)

    BuildPanelContent()

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "Fury")
        category.ID = category:GetID()
        Settings.RegisterAddOnCategory(category)
        ns.settingsCategory = category
    else
        InterfaceOptions_AddCategory(panel)
    end
end

function OptionsModule:Init()
    RegisterPanel()
end

ns.RegisterModule(OptionsModule)

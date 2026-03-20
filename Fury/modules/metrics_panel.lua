local _, ns = ...

local PanelModule = {
    name = "MetricsPanel",
}

local panel
local lines = {}
local resizeHandle
local closeButton
local LINE_COUNT = 22
local TOP_OFFSET = 42
local LINE_GAP = 26
local MIN_LINE_HEIGHT = 16
local LINE_EXTRA_GAP = 6
local BODY_FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local BODY_FONT_SIZE = 13
local TITLE_FONT_SIZE = 15
local HINT_FONT_SIZE = 12

local function FmtPct(v)
    return string.format("%.1f%%", (v or 0) * 100)
end

local function FmtNum(v)
    return string.format("%.1f", v or 0)
end

local function FmtMs(v)
    return string.format("%dms", math.floor((v or 0) + 0.5))
end

local function ReadThreatText()
    if not UnitExists("target") then
        return "仇恨: -"
    end
    local isTanking, status, scaledPct = UnitDetailedThreatSituation("player", "target")
    local s = status or 0
    local pct = scaledPct or 0
    local lead = isTanking and "稳仇恨" or "未领先"
    return string.format("仇恨: %s(S%d %.0f%%)", lead, s, pct)
end

local function FormatEvalLine(list, prefix, maxCount)
    if not list or #list == 0 then
        return prefix .. " -"
    end
    local out = {}
    local limit = math.min(#list, maxCount or 3)
    for i = 1, limit do
        local e = list[i]
        local reason = e.reasons and e.reasons[1] or "-"
        local mark = e.passed and "OK" or "X"
        table.insert(out, string.format("%s:%s(%.0f,%s)", mark, e.token, e.score, reason))
    end
    return prefix .. " " .. table.concat(out, " | ")
end

local function FormatRankedLine(list, prefix, maxCount)
    if not list or #list == 0 then
        return prefix .. " -"
    end
    local out = {}
    local limit = math.min(#list, maxCount or 3)
    for i = 1, limit do
        local e = list[i]
        if e and e.token then
            local reason = e.reason or (e.reasons and e.reasons[1]) or "-"
            table.insert(out, string.format("%d:%s[%s](%s)", i, e.token, e.channel or "?", reason))
        end
    end
    if #out == 0 then
        return prefix .. " -"
    end
    return prefix .. " " .. table.concat(out, " | ")
end

local function SavePosition()
    if not panel or not ns.db or not ns.db.metrics then
        return
    end
    local point, _, relativePoint, x, y = panel:GetPoint(1)
    ns.db.metrics.panelPoint = {
        point = point or "CENTER",
        relativePoint = relativePoint or "CENTER",
        x = x or 0,
        y = y or 0,
    }
end

local function SaveSize()
    if not panel or not ns.db or not ns.db.metrics then
        return
    end
    ns.db.metrics.panelSize = ns.db.metrics.panelSize or {}
    ns.db.metrics.panelSize.width = math.floor((panel:GetWidth() or 760) + 0.5)
    ns.db.metrics.panelSize.height = math.floor((panel:GetHeight() or 444) + 0.5)
end

local function RestorePosition()
    if not panel then
        return
    end
    local p = ns.db and ns.db.metrics and ns.db.metrics.panelPoint
    panel:ClearAllPoints()
    panel:SetPoint(
        (p and p.point) or "CENTER",
        UIParent,
        (p and p.relativePoint) or "CENTER",
        (p and p.x) or 0,
        (p and p.y) or 0
    )
end

local function RestoreSize()
    if not panel then
        return
    end
    local size = ns.db and ns.db.metrics and ns.db.metrics.panelSize
    local width = (size and size.width) or 760
    local height = (size and size.height) or 444
    panel:SetSize(width, height)
end

local function UpdateLineLayout()
    if not panel then
        return
    end
    local contentWidth = math.max(panel:GetWidth() - 40, 280)
    for i = 1, LINE_COUNT do
        local fs = lines[i]
        if fs then
            fs:SetWidth(contentWidth)
        end
    end
    if resizeHandle then
        resizeHandle:SetPoint("BOTTOMRIGHT", -4, 4)
    end
end

local function RelayoutByTextHeight()
    if not panel then
        return
    end
    local y = -TOP_OFFSET
    for i = 1, LINE_COUNT do
        local fs = lines[i]
        if fs then
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", 16, y)
            local h = fs:GetStringHeight() or 0
            if h < MIN_LINE_HEIGHT then
                h = MIN_LINE_HEIGHT
            end
            y = y - h - LINE_EXTRA_GAP
        end
    end
end

local function SetLine(i, text)
    if lines[i] then
        lines[i]:SetText(text or "")
    end
end

local function Render()
    if not panel or not panel:IsShown() then
        return
    end

    local metrics = ns.metrics
    local snapshot = metrics and metrics.GetSnapshot and metrics.GetSnapshot() or nil
    local decision = ns.decision and ns.decision.GetRecommendation and ns.decision.GetRecommendation() or nil
    if not decision then
        SetLine(1, "状态: 决策模块未就绪")
        for i = 2, LINE_COUNT do
            SetLine(i, "")
        end
        RelayoutByTextHeight()
        return
    end

    local modeText = decision.mode == "TPS_SURVIVAL" and "防御姿态: TPS/生存导向" or "战斗/狂暴姿态: DPS 导向"
    local ctx = decision.context
    local stateText = snapshot and (snapshot.inProgress and "战斗中" or "脱战(显示上一场)") or "暂无战斗"
    local durationText = snapshot and (FmtNum(snapshot.duration) .. "s") or "-"
    local dpsText = snapshot and FmtNum(snapshot.dps) or "-"
    local rageText = ctx and FmtNum(ctx.rage) or "-"
    local apText = ctx and tostring(math.floor((ctx.attackPower or 0) + 0.5)) or "-"
    local critText = ctx and string.format("%.1f%%", ctx.critChance or 0) or "-"
    local hitText = ctx and string.format("%.1f%%", ctx.hitModifier or 0) or "-"
    local hpText = ctx and FmtPct((ctx.playerHealthPct or 100) / 100) or "-"
    local targetText = ctx and (ctx.targetHealthPct and FmtPct(ctx.targetHealthPct / 100) or "-") or "-"
    local hostiles = ctx and (ctx.hostileCount or 0) or 0
    local gcdMs = ctx and math.max(ctx.gcdRem or 0, 0) * 1000 or 0
    local threatText = ReadThreatText()
    local queue = ctx and ctx.queue or nil
    local ham = ctx and ctx.hamstringState or nil
    local level = ctx and (ctx.playerLevel or 0) or 0
    local timeToMhMs = queue and math.floor((math.max(queue.timeToMain or 0, 0) * 1000) + 0.5) or 0
    local timeToOhMs = queue and math.floor((math.max(queue.timeToOff or 0, 0) * 1000) + 0.5) or 0
    local queuedText = queue and (queue.queuedDumpToken or "HOLD") or "-"
    local qOpenText = queue and (queue.queueWindowOpen and "Y" or "N") or "-"
    local hamText = "-"
    if ham then
        hamText = ham.hasDebuff and ("Y(" .. string.format("%.1f", ham.remaining or 0) .. "s)") or "N"
    end

    local modeOverride = (ctx and ctx.modeOverride) or "auto"
    SetLine(1, "模式: " .. modeText .. "   覆盖: " .. modeOverride)
    SetLine(2, "预测窗口: " .. FmtMs(decision.horizonMs) .. "   状态: " .. stateText)
    local stanceSource = (ctx and ctx.stanceSource) or "-"
    local talents = ctx and ctx.talents or nil
    local equip = ctx and ctx.equipment or nil
    local buffs = ctx and ctx.buffs or nil
    local trinket = ctx and ctx.trinket or nil
    local weights = ctx and ctx.weights or nil
    local setProfiles = ctx and ctx.activeSetProfiles or nil
    local procProfiles = ctx and ctx.activeProcProfiles or nil
    local talentText = talents and string.format("天赋A/F/P=%d/%d/%d", talents.armsPoints or 0, talents.furyPoints or 0, talents.protPoints or 0) or "天赋:-"
    local equipText = equip and string.format(
        "双持武器:%s 盾:%s 套装最多:%d",
        equip.dualWieldWeapon and "是" or "否",
        equip.hasShield and "是" or "否",
        equip.setPieceMax or 0
    ) or "装备:-"
    local buffText = buffs and string.format(
        "Buff[F:%s DW:%s RK:%s]",
        buffs.flurry and "Y" or "N",
        buffs.deathWish and "Y" or "N",
        buffs.recklessness and "Y" or "N"
    ) or "Buff:-"
    local trinketText = trinket and string.format("饰品[就绪:%s 激活:%s]", trinket.anyReady and "Y" or "N", trinket.anyActive and "Y" or "N")
        or "饰品:-"
    local weightText = weights and string.format(
        "权重[D:%d T:%d EX:%d BT:%d WW:%d SU:%d DP:%d]",
        math.floor(weights.dps or 0),
        math.floor(weights.tps or 0),
        math.floor(weights.execute or 0),
        math.floor(weights.bloodthirst or 0),
        math.floor(weights.whirlwind or 0),
        math.floor(weights.sunder or 0),
        math.floor(weights.dump or 0)
    ) or "权重:-"
    local setText = (setProfiles and #setProfiles > 0) and ("Set:" .. table.concat(setProfiles, ",")) or "Set:-"
    local procText = (procProfiles and #procProfiles > 0) and ("Proc:" .. table.concat(procProfiles, ",")) or "Proc:-"
    SetLine(3, "姿态: " .. decision.stance .. " (" .. stanceSource .. ")   敌对目标数(6s): " .. hostiles .. "   " .. threatText)
    SetLine(4, "角色血量: " .. hpText .. "   目标血量: " .. targetText .. "   怒气: " .. rageText .. "   AP: " .. apText)
    SetLine(5, "等级: " .. tostring(level) .. "   暴击: " .. critText .. "   命中修正: " .. hitText .. "   " .. talentText)
    SetLine(6, equipText .. "   " .. buffText .. "   " .. trinketText)
    SetLine(7, weightText)
    SetLine(8, setText)
    SetLine(9, procText)
    local rec1 = decision.recommendedAction or ((decision.rankedRecommendations or {})[1])
    local queueIndicator = decision.queueIndicator
    local function fmtRanked(rec)
        if not rec or not rec.token then
            return "-"
        end
        local channel = rec.channel or "?"
        return tostring(rec.token) .. "[" .. channel .. "]"
    end
    SetLine(10, "GCD剩余: " .. FmtMs(gcdMs) .. "   当前推荐: " .. fmtRanked(rec1))
    local habitInfo = decision.habitInfo
    local habitText = ""
    if habitInfo and habitInfo.enabled then
        habitText = string.format(
            "   习惯锁定:%s(%s Δ%.1f)",
            tostring(habitInfo.lockedSkill or "-"),
            tostring(habitInfo.decision or "-"),
            tonumber(habitInfo.scoreDelta or 0)
        )
    end
    SetLine(11, "推荐1原因: " .. ((rec1 and rec1.reason) or decision.nextGcdReason or decision.reason or "-") .. habitText)
    SetLine(
        12,
        "Queue状态: " .. (queueIndicator and queueIndicator.token or "EMPTY")
            .. "   Queue解释: " .. (queueIndicator and queueIndicator.reason or "-")
            .. "   展示源: " .. (decision.displayNextSource or "-")
            .. "   展示GCD: " .. (decision.displayNextSkill or "WAIT")
            .. "   OffGCD: " .. (decision.offGcdSkill or "NONE")
            .. "   预留怒气: " .. (decision.reserveRage or 0)
            .. "   队列:" .. queuedText
            .. "   窗口:" .. qOpenText
            .. "   断筋:" .. hamText
    )
    SetLine(
        13,
        "当前推荐解释: " .. ((rec1 and rec1.reason) or decision.recommendedReason or "-")
            .. string.format("   MH/OH: %d/%dms", timeToMhMs, timeToOhMs)
    )
    if ctx and ctx.cooldown then
        SetLine(14, string.format("CD BR/BT/WW/EX: %.2f / %.2f / %.2f / %.2f", ctx.cooldown.br or 0, ctx.cooldown.bt or 0, ctx.cooldown.ww or 0, ctx.cooldown.ex or 0))
        SetLine(15, string.format("CD REV/SB/SS/LS: %.2f / %.2f / %.2f / %.2f", ctx.cooldown.rev or 0, ctx.cooldown.sb or 0, ctx.cooldown.ss or 0, ctx.cooldown.ls or 0))
    else
        SetLine(14, "CD BR/BT/WW/EX: - / - / - / -")
        SetLine(15, "CD REV/SB/SS/LS: - / - / - / -")
    end
    if snapshot then
        SetLine(16, "DPS: " .. dpsText .. "   怒气浪费/饥饿: " .. FmtPct(snapshot.rage.wastePct) .. " / " .. FmtPct(snapshot.rage.starvedPct))
        SetLine(17, "Flurry覆盖: " .. FmtPct(snapshot.rotation.flurryUptimePct) .. "   黄字未命中: " .. FmtPct(snapshot.hitTable.yellowMissRate) .. "   时长: " .. durationText)
        SetLine(18, "建议命中率: " .. FmtPct(snapshot.advisory and snapshot.advisory.hitRate or 0) .. "   命中/总建议: "
            .. tostring(snapshot.advisory and snapshot.advisory.matched or 0) .. "/" .. tostring(snapshot.advisory and snapshot.advisory.total or 0))
    else
        SetLine(16, "DPS: -   怒气浪费/饥饿: - / -")
        SetLine(17, "Flurry覆盖: -   黄字未命中: -   时长: -")
        SetLine(18, "建议命中率: -")
    end

    SetLine(19, FormatRankedLine(decision.rankedRecommendations, "优先级树:", 3))
    SetLine(20, FormatEvalLine(decision.nextEvaluations, "候选打分:", 3))
    SetLine(21, FormatEvalLine(decision.dumpEvaluations, "Dump打分:", 3))
    SetLine(22, FormatEvalLine(decision.offGcdEvaluations, "OffGCD打分:", 3))
    RelayoutByTextHeight()
end

function ns.ToggleMetricsPanel()
    if not panel then
        return
    end
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
    end
    if ns.db and ns.db.metrics then
        ns.db.metrics.showPanel = panel:IsShown()
    end
end

function ns.IsMetricsPanelShown()
    return panel and panel:IsShown() or false
end

local function ApplyPanelTypography(title, hint)
    if title and title.SetFont then
        title:SetFont(BODY_FONT, TITLE_FONT_SIZE, "")
    end
    if hint and hint.SetFont then
        hint:SetFont(BODY_FONT, HINT_FONT_SIZE, "")
    end
    for i = 1, LINE_COUNT do
        local fs = lines[i]
        if fs and fs.SetFont then
            fs:SetFont(BODY_FONT, BODY_FONT_SIZE, "")
        end
    end
end

local function BuildPanel()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    panel = CreateFrame("Frame", "FuryMetricsPanel", UIParent, template)
    panel:SetSize(760, 444)
    panel:SetFrameStrata("HIGH")
    panel:EnableMouse(true)
    panel:SetMovable(true)
    if panel.SetResizable then
        panel:SetResizable(true)
    end
    if panel.SetMinResize then
        panel:SetMinResize(620, 360)
    end
    if panel.SetMaxResize then
        panel:SetMaxResize(1200, 900)
    end
    panel:RegisterForDrag("LeftButton")
    panel:SetClampedToScreen(true)
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)

    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
    end

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Fury Decision Debug Panel")

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPRIGHT", -14, -14)
    hint:SetText("拖动移动/右下角缩放  /fury metrics  /fury horizon 400")

    closeButton = CreateFrame("Button", "FuryMetricsPanelCloseButton", panel, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -4, -4)
    closeButton:SetScript("OnClick", function()
        panel:Hide()
        if ns.db and ns.db.metrics then
            ns.db.metrics.showPanel = false
        end
    end)

    for i = 1, LINE_COUNT do
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        if fs.SetNonSpaceWrap then
            fs:SetNonSpaceWrap(true)
        end
        fs:SetWidth(720)
        fs:SetPoint("TOPLEFT", 16, -TOP_OFFSET - (i - 1) * LINE_GAP)
        fs:SetText("")
        lines[i] = fs
    end
    ApplyPanelTypography(title, hint)

    resizeHandle = CreateFrame("Button", nil, panel)
    resizeHandle:SetSize(18, 18)
    resizeHandle:SetPoint("BOTTOMRIGHT", -4, 4)
    resizeHandle:EnableMouse(true)
    resizeHandle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeHandle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeHandle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeHandle:SetScript("OnMouseDown", function()
        panel:StartSizing("BOTTOMRIGHT")
    end)
    resizeHandle:SetScript("OnMouseUp", function()
        panel:StopMovingOrSizing()
        SaveSize()
        UpdateLineLayout()
        Render()
    end)

    panel:SetScript("OnSizeChanged", function()
        UpdateLineLayout()
        RelayoutByTextHeight()
    end)

    panel:SetScript("OnShow", Render)
    panel:SetScript("OnUpdate", function(self, elapsed)
        self._tick = (self._tick or 0) + elapsed
        if self._tick < 0.25 then
            return
        end
        self._tick = 0
        Render()
    end)

    RestoreSize()
    RestorePosition()
    UpdateLineLayout()
    RelayoutByTextHeight()
end

function PanelModule:Init()
    BuildPanel()
    if ns.metrics then
        ns.metrics.RegisterListener("metrics-panel", Render)
    end
    if ns.db and ns.db.metrics and ns.db.metrics.showPanel then
        panel:Show()
    else
        panel:Hide()
    end
end

ns.RegisterModule(PanelModule)

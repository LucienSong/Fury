local _, ns = ...

local IconModule = {
    name = "MetricsIcon",
}

local frame
local iconTexture
local iconGlow
local iconGlowAnim
local iconMarquee
local marqueeSegments = {}
local iconGlowHost
local iconShine
local cooldownText
local skillText
local skillKeyText
local dumpIcon
local dumpGlow
local dumpGlowAnim
local dumpMarquee
local dumpMarqueeSegments = {}
local dumpGlowHost
local dumpShine
local dumpText
local dumpKeyText
local currentPreset

local SHORT_LABEL = {
    BLOODTHIRST = "BT",
    WHIRLWIND = "WW",
    EXECUTE = "EXE",
    SUNDER_ARMOR = "SND",
    REVENGE = "REV",
    SHIELD_BLOCK = "SB",
    SHIELD_SLAM = "SS",
    LAST_STAND = "LS",
}

local SIZE_PRESETS = {
    compact = { icon = 40, gap = 4, padX = 4, frameHeight = 78, frameHeightText = 90, textGap = 1, dumpWidth = 72 },
    standard = { icon = 50, gap = 5, padX = 5, frameHeight = 90, frameHeightText = 104, textGap = 1, dumpWidth = 86 },
    large = { icon = 60, gap = 6, padX = 6, frameHeight = 102, frameHeightText = 118, textGap = 1, dumpWidth = 102 },
}

local PRESET_LABEL = {
    compact = "紧凑",
    standard = "标准",
    large = "大号",
}

local MARQUEE_OUTER_OFFSET = 5
local HS_NAME = GetSpellInfo(78) or "Heroic Strike"
local CLEAVE_NAME = GetSpellInfo(845) or "Cleave"
local HS_RANK_IDS = { 78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286 }
local CLEAVE_RANK_IDS = { 845, 7369, 11608, 11609, 20569 }

local function BuildDashedMarquee(container, segmentTable)
    local stroke = 3
    local function addSegment(point, x, y, w, h)
        local tex = container:CreateTexture(nil, "OVERLAY")
        tex:SetColorTexture(1, 0.95, 0.2, 1)
        tex:SetPoint(point, x, y)
        tex:SetSize(w, h)
        tex:SetAlpha(0.25)
        table.insert(segmentTable, tex)
    end

    local gap = 8
    local dash = 6
    for offset = 0, 40, gap do
        addSegment("TOPLEFT", offset, 0, dash, stroke)
        addSegment("BOTTOMLEFT", offset, 0, dash, stroke)
        addSegment("TOPLEFT", 0, -offset, stroke, dash)
        addSegment("TOPRIGHT", 0, -offset, stroke, dash)
    end
end

local function UpdateDashedMarquee(segmentTable, phase)
    local total = #segmentTable
    if total == 0 then
        return
    end
    local bright = ((phase - 1) % total) + 1
    for i = 1, total do
        segmentTable[i]:SetAlpha(i == bright and 1 or 0.25)
    end
end

local function SetNativeOverlayGlow(host, shouldShow)
    if not host then
        return
    end
    if shouldShow then
        if not host._furyGlowShown and ActionButton_ShowOverlayGlow then
            ActionButton_ShowOverlayGlow(host)
            host._furyGlowShown = true
        end
    else
        if host._furyGlowShown and ActionButton_HideOverlayGlow then
            ActionButton_HideOverlayGlow(host)
        end
        host._furyGlowShown = false
    end
end

local function SetPulse(tex, anim, shouldShow)
    if not tex then
        return
    end
    if shouldShow then
        tex:Show()
        if anim and not anim:IsPlaying() then
            anim:Play()
        end
    else
        if anim then
            anim:Stop()
        end
        tex:SetAlpha(0.15)
        tex:Hide()
    end
end

local function SetShine(shineFrame, host, shouldShow)
    -- Classic Era 下 AutoCastShine 在自定义宿主上存在不稳定崩溃，先禁用星芒通路。
    if shineFrame then
        shineFrame._furyShineOn = false
    end
    return
end

local function InRangeOrNil(spellName)
    local ok = IsSpellInRange(spellName, "target")
    if ok == nil then
        return true
    end
    return ok == 1
end

local function IsDumpSkillUsable(token)
    if token == "HEROIC_STRIKE" then
        local usable, noMana = IsUsableSpell(HS_NAME)
        return usable and not noMana and InRangeOrNil(HS_NAME)
    elseif token == "CLEAVE" then
        local usable, noMana = IsUsableSpell(CLEAVE_NAME)
        return usable and not noMana and InRangeOrNil(CLEAVE_NAME)
    end
    return false
end

local function IsDumpQueued(token)
    if not IsCurrentSpell then
        return false
    end
    if token == "HEROIC_STRIKE" then
        if IsCurrentSpell(HS_NAME) then
            return true
        end
        for i = 1, #HS_RANK_IDS do
            if IsCurrentSpell(HS_RANK_IDS[i]) then
                return true
            end
        end
        return false
    elseif token == "CLEAVE" then
        if IsCurrentSpell(CLEAVE_NAME) then
            return true
        end
        for i = 1, #CLEAVE_RANK_IDS do
            if IsCurrentSpell(CLEAVE_RANK_IDS[i]) then
                return true
            end
        end
        return false
    end
    return false
end

local function GetQueuedDumpToken()
    if not IsCurrentSpell then
        return nil
    end
    if IsDumpQueued("CLEAVE") then
        return "CLEAVE"
    end
    if IsDumpQueued("HEROIC_STRIKE") then
        return "HEROIC_STRIKE"
    end
    return nil
end

local function SavePosition()
    if not frame or not ns.db or not ns.db.metrics then
        return
    end
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    ns.db.metrics.iconPoint = {
        point = point or "CENTER",
        relativePoint = relativePoint or "CENTER",
        x = x or 0,
        y = y or 0,
    }
end

local function RestorePosition()
    if not frame then
        return
    end
    local p = ns.db and ns.db.metrics and ns.db.metrics.iconPoint
    frame:ClearAllPoints()
    frame:SetPoint(
        (p and p.point) or "CENTER",
        UIParent,
        (p and p.relativePoint) or "CENTER",
        (p and p.x) or 260,
        (p and p.y) or 0
    )
end

function ns.SetDecisionIconShown(show)
    if not ns.db or not ns.db.metrics then
        return
    end
    ns.db.metrics.showIcon = show and true or false
    if frame then
        frame:SetShown(ns.db.metrics.showIcon)
    end
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.ToggleDecisionIcon()
    if not ns.db or not ns.db.metrics then
        return
    end
    ns.SetDecisionIconShown(not ns.db.metrics.showIcon)
end

function ns.IsDecisionIconShown()
    return ns.db and ns.db.metrics and ns.db.metrics.showIcon
end

function ns.SetDecisionIconShowOutOfCombat(show)
    if not ns.db or not ns.db.metrics then
        return
    end
    ns.db.metrics.iconShowOutOfCombat = show and true or false
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.IsDecisionIconShowOutOfCombat()
    return ns.db and ns.db.metrics and ns.db.metrics.iconShowOutOfCombat
end

function ns.SetDecisionIconTextShown(show)
    if not ns.db or not ns.db.metrics then
        return
    end
    ns.db.metrics.iconShowText = show and true or false
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.IsDecisionIconTextShown()
    return ns.db and ns.db.metrics and ns.db.metrics.iconShowText
end

function ns.SetDecisionIconLocked(locked)
    if not ns.db or not ns.db.metrics then
        return
    end
    ns.db.metrics.iconLocked = locked and true or false
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.IsDecisionIconLocked()
    return ns.db and ns.db.metrics and ns.db.metrics.iconLocked
end

function ns.GetDecisionIconSizePreset()
    local preset = ns.db and ns.db.metrics and ns.db.metrics.iconSizePreset
    if preset == "compact" or preset == "standard" or preset == "large" then
        return preset
    end
    return "standard"
end

function ns.GetDecisionIconSizePresetLabel()
    local preset = ns.GetDecisionIconSizePreset()
    return PRESET_LABEL[preset] or "标准"
end

function ns.SetDecisionIconSizePreset(preset)
    if not ns.db or not ns.db.metrics then
        return
    end
    local p = tostring(preset or ""):lower()
    if p == "small" then
        p = "compact"
    elseif p == "normal" then
        p = "standard"
    elseif p == "big" then
        p = "large"
    end
    if p ~= "compact" and p ~= "standard" and p ~= "large" then
        return
    end
    ns.db.metrics.iconSizePreset = p
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

local function ApplyLayout(showText)
    if not frame then
        return
    end
    local presetName = ns.GetDecisionIconSizePreset()
    local layoutKey = presetName .. ":" .. (showText and "text" or "notext")
    if currentPreset == layoutKey then
        return
    end
    currentPreset = layoutKey
    local cfg = SIZE_PRESETS[presetName] or SIZE_PRESETS.standard
    local icon = cfg.icon
    local gap = cfg.gap
    local padX = cfg.padX
    local width = padX * 2 + icon * 2 + gap
    local height = showText and cfg.frameHeightText or cfg.frameHeight

    frame:SetSize(width, height)
    iconTexture:SetSize(icon, icon)
    iconGlow:SetSize(icon + 40, icon + 40)
    dumpIcon:SetSize(icon, icon)
    dumpGlow:SetSize(icon + 40, icon + 40)

    iconTexture:ClearAllPoints()
    iconTexture:SetPoint("LEFT", padX, 0)
    dumpIcon:ClearAllPoints()
    dumpIcon:SetPoint("LEFT", iconTexture, "RIGHT", gap, 0)
    dumpGlow:ClearAllPoints()
    dumpGlow:SetPoint("CENTER", dumpIcon, "CENTER", 0, 0)
    if dumpMarquee then
        dumpMarquee:ClearAllPoints()
        dumpMarquee:SetPoint("TOPLEFT", dumpIcon, "TOPLEFT", -MARQUEE_OUTER_OFFSET, MARQUEE_OUTER_OFFSET)
        dumpMarquee:SetPoint("BOTTOMRIGHT", dumpIcon, "BOTTOMRIGHT", MARQUEE_OUTER_OFFSET, -MARQUEE_OUTER_OFFSET)
    end
    if iconMarquee then
        iconMarquee:ClearAllPoints()
        iconMarquee:SetPoint("TOPLEFT", iconTexture, "TOPLEFT", -MARQUEE_OUTER_OFFSET, MARQUEE_OUTER_OFFSET)
        iconMarquee:SetPoint("BOTTOMRIGHT", iconTexture, "BOTTOMRIGHT", MARQUEE_OUTER_OFFSET, -MARQUEE_OUTER_OFFSET)
    end

    if cooldownText and cooldownText.SetFont then
        cooldownText:ClearAllPoints()
        cooldownText:SetPoint("BOTTOM", iconTexture, "TOP", 0, 2)
        cooldownText:SetWidth(icon + 10)
        cooldownText:SetFont(STANDARD_TEXT_FONT, math.max(math.floor(icon * 0.48), 12), "OUTLINE")
    end
    if iconGlowHost then
        iconGlowHost:SetSize(icon, icon)
        iconGlowHost:ClearAllPoints()
        iconGlowHost:SetPoint("CENTER", iconTexture, "CENTER", 0, 0)
    end
    if dumpGlowHost then
        dumpGlowHost:SetSize(icon, icon)
        dumpGlowHost:ClearAllPoints()
        dumpGlowHost:SetPoint("CENTER", dumpIcon, "CENTER", 0, 0)
    end
    if iconShine then
        iconShine:SetAllPoints(iconGlowHost)
    end
    if dumpShine then
        dumpShine:SetAllPoints(dumpGlowHost)
    end

    if showText then
        skillText:ClearAllPoints()
        skillText:SetPoint("TOP", iconTexture, "BOTTOM", 0, -cfg.textGap)
        skillText:SetWidth(icon + 6)

        dumpText:ClearAllPoints()
        dumpText:SetPoint("TOP", dumpIcon, "BOTTOM", 0, -cfg.textGap)
        dumpText:SetWidth(cfg.dumpWidth)
    end
    if skillKeyText then
        skillKeyText:ClearAllPoints()
        skillKeyText:SetPoint("CENTER", iconTexture, "CENTER", 0, 0)
        skillKeyText:SetWidth(icon)
        if skillKeyText.SetFont then
            skillKeyText:SetFont(STANDARD_TEXT_FONT, math.max(math.floor(icon * 0.6), 10), "OUTLINE")
        end
    end
    if dumpKeyText then
        dumpKeyText:ClearAllPoints()
        dumpKeyText:SetPoint("CENTER", dumpIcon, "CENTER", 0, 0)
        dumpKeyText:SetWidth(icon)
        if dumpKeyText.SetFont then
            dumpKeyText:SetFont(STANDARD_TEXT_FONT, math.max(math.floor(icon * 0.6), 10), "OUTLINE")
        end
    end
end

local function GetKeybindText(token)
    if not token or token == "" or token == "WAIT" or token == "NONE" then
        return nil
    end
    if ns.GetSkillKeybindHint then
        local txt = ns.GetSkillKeybindHint(token)
        if txt and txt ~= "" then
            return txt
        end
    end
    return nil
end

local function Render()
    if not frame then
        return
    end
    if not ns.IsDecisionIconShown() then
        frame:Hide()
        return
    end

    local inCombat = UnitAffectingCombat("player")
    if (not inCombat) and (not ns.IsDecisionIconShowOutOfCombat()) then
        frame:Hide()
        return
    end

    if not frame:IsShown() then
        frame:Show()
    end
    frame:SetAlpha(1)
    frame:EnableMouse(true)
    local showText = ns.IsDecisionIconTextShown()
    ApplyLayout(showText)

    local rec = ns.decision and ns.decision.GetRecommendation and ns.decision.GetRecommendation() or nil
    if not rec then
        iconTexture:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        iconTexture:Show()
        dumpIcon:SetTexture(ns.decision and ns.decision.GetTokenTexture and ns.decision.GetTokenTexture("HEROIC_STRIKE") or "Interface\\Icons\\INV_Misc_QuestionMark")
        dumpIcon:SetAlpha(0.25)
        skillText:SetText("N/A")
        dumpText:SetText("Dump: N/A")
        cooldownText:Hide()
        if iconGlowAnim then
            iconGlowAnim:Stop()
        end
        SetNativeOverlayGlow(iconGlowHost, false)
        SetPulse(iconGlow, iconGlowAnim, false)
        SetShine(iconShine, iconGlowHost, false)
        if dumpGlowAnim then
            dumpGlowAnim:Stop()
        end
        SetNativeOverlayGlow(dumpGlowHost, false)
        SetPulse(dumpGlow, dumpGlowAnim, false)
        SetShine(dumpShine, dumpGlowHost, false)
        if dumpMarquee then
            dumpMarquee:Hide()
        end
        if iconMarquee then
            iconMarquee:Hide()
        end
        local showTextFallback = ns.IsDecisionIconTextShown()
        skillText:SetShown(showTextFallback)
        dumpText:SetShown(showTextFallback)
        skillKeyText:SetText("")
        skillKeyText:Hide()
        dumpKeyText:SetText("")
        dumpKeyText:Hide()
        return
    end

    local displaySkill = rec.displayNextSkill or rec.nextSkill
    local showMain = displaySkill and displaySkill ~= "WAIT" and displaySkill ~= "NONE"
    if showMain then
        iconTexture:SetTexture(ns.decision.GetTokenTexture(displaySkill))
        iconTexture:Show()
        skillText:SetText(SHORT_LABEL[displaySkill] or displaySkill or "")
        local keyText = GetKeybindText(displaySkill)
        if keyText then
            skillKeyText:SetText(keyText)
            skillKeyText:Show()
        else
            skillKeyText:SetText("")
            skillKeyText:Hide()
        end
    else
        iconTexture:SetTexture("")
        iconTexture:Hide()
        skillText:SetText("")
        skillKeyText:SetText("")
        skillKeyText:Hide()
    end

    local nextState = rec.displayNextState or {}
    local cooldownRem = tonumber(nextState.cooldownRem) or 0
    local rageEnough = nextState.rageEnough and true or false
    if showMain and cooldownRem > 0.05 then
        cooldownText:SetText(string.format("%.1f", cooldownRem))
        cooldownText:Show()
    else
        cooldownText:Hide()
    end
    local shouldGlow = showMain and cooldownRem <= 0.05 and rageEnough
    -- 改用 WoW 原生动作条可用高亮效果。
    SetNativeOverlayGlow(iconGlowHost, shouldGlow)
    SetPulse(iconGlow, iconGlowAnim, shouldGlow)
    SetShine(iconShine, iconGlowHost, shouldGlow)
    if iconMarquee then
        iconMarquee:Hide()
    end

    local dumpSkill = rec.dumpSkill or "HOLD"
    local hostileCount = rec.context and rec.context.hostileCount or 1
    local preferredDump = dumpSkill
    if dumpSkill == "HOLD" then
        preferredDump = hostileCount >= 2 and "CLEAVE" or "HEROIC_STRIKE"
    end
    if preferredDump == "CLEAVE" then
        dumpIcon:SetTexture(ns.decision.GetTokenTexture("CLEAVE"))
    else
        dumpIcon:SetTexture(ns.decision.GetTokenTexture("HEROIC_STRIKE"))
    end
    dumpText:SetText("Dump: " .. dumpSkill)
    local dumpRageEnough = false
    if rec and rec.context and type(rec.context.rage) == "number" and type(rec.reserveRage) == "number" then
        if dumpSkill == "HEROIC_STRIKE" then
            dumpRageEnough = (rec.context.rage - rec.reserveRage) >= 15
        elseif dumpSkill == "CLEAVE" then
            dumpRageEnough = (rec.context.rage - rec.reserveRage) >= 20
        end
    end
    local dumpPredicted = dumpSkill == "HOLD"
    local dumpUsable = IsDumpSkillUsable(preferredDump)
    local dumpAvailable = (not dumpPredicted) and dumpRageEnough and dumpUsable
    local queuedToken = GetQueuedDumpToken()
    local dumpQueued = queuedToken ~= nil
    local dumpDisplayToken = preferredDump

    -- 队列优先：如果玩家已经按下 HS/Cleave 并进入“下一次主手挥击”队列，
    -- 就以队列中的技能作为展示与高亮依据。
    if dumpQueued then
        dumpDisplayToken = queuedToken
        if queuedToken == "CLEAVE" then
            dumpIcon:SetTexture(ns.decision.GetTokenTexture("CLEAVE"))
        else
            dumpIcon:SetTexture(ns.decision.GetTokenTexture("HEROIC_STRIKE"))
        end
        dumpIcon:SetAlpha(1)
    else
        dumpIcon:SetAlpha(dumpAvailable and 1 or 0.35)
    end
    local dumpKey = GetKeybindText(dumpDisplayToken)
    if dumpKey then
        dumpKeyText:SetText(dumpKey)
        dumpKeyText:Show()
    else
        dumpKeyText:SetText("")
        dumpKeyText:Hide()
    end

    -- 仅进入施放队列时才做醒目高亮。
    SetNativeOverlayGlow(dumpGlowHost, dumpQueued)
    SetPulse(dumpGlow, dumpGlowAnim, dumpQueued)
    SetShine(dumpShine, dumpGlowHost, dumpQueued)
    if dumpMarquee then
        dumpMarquee:Hide()
    end

    local showAny = showMain or dumpSkill == "HEROIC_STRIKE" or dumpSkill == "CLEAVE"
    frame:SetAlpha(showAny and 1 or 0.45)

    skillText:SetShown(showText and showMain)
    dumpText:SetShown(showText)

    local backdropColor = rec.mode == "TPS_SURVIVAL" and { 0.1, 0.2, 0.35, 0.9 } or { 0.35, 0.22, 0.06, 0.9 }
    local hideBackdrop = ns.IsDecisionIconLocked and ns.IsDecisionIconLocked()
    if frame.SetBackdropColor then
        frame:SetBackdropColor(backdropColor[1], backdropColor[2], backdropColor[3], hideBackdrop and 0 or backdropColor[4])
    end
    if frame.SetBackdropBorderColor then
        frame:SetBackdropBorderColor(1, 1, 1, hideBackdrop and 0 or 0.6)
    end
end

function ns.RefreshDecisionIcon()
    if not frame then
        return
    end
    -- 先显式拉起，避免之前 Hide 后没有 OnUpdate 的情况。
    if not frame:IsShown() then
        frame:Show()
    end
    Render()
end

local function Build()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    frame = CreateFrame("Frame", "FuryDecisionHintIcon", UIParent, template)
    frame:SetSize(110, 76)
    frame:SetFrameStrata("HIGH")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetScript("OnDragStart", function(self)
        if ns.IsDecisionIconLocked and ns.IsDecisionIconLocked() then
            return
        end
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:SetScript("OnEvent", function()
        if ns.RefreshDecisionIcon then
            ns.RefreshDecisionIcon()
        end
    end)

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
    end

    iconTexture = frame:CreateTexture(nil, "ARTWORK")
    iconTexture:SetSize(50, 50)
    iconTexture:SetPoint("LEFT", 5, 0)
    iconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    iconGlowHost = CreateFrame("Button", nil, frame)
    iconGlowHost:SetSize(50, 50)
    iconGlowHost:SetPoint("CENTER", iconTexture, "CENTER", 0, 0)
    iconGlowHost:SetAlpha(1)
    iconGlowHost:EnableMouse(false)
    iconShine = CreateFrame("Frame", nil, frame)
    iconShine:SetAllPoints(iconGlowHost)
    iconShine._furyShineOn = false

    iconGlow = frame:CreateTexture(nil, "OVERLAY")
    iconGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    iconGlow:SetBlendMode("ADD")
    iconGlow:SetVertexColor(1, 0.95, 0.2, 0.85)
    iconGlow:SetPoint("CENTER", iconTexture, "CENTER", 0, 0)
    iconGlow:SetSize(90, 90)
    iconGlow:Hide()

    iconGlowAnim = iconGlow:CreateAnimationGroup()
    iconGlowAnim:SetLooping("BOUNCE")
    local glowAlpha = iconGlowAnim:CreateAnimation("Alpha")
    glowAlpha:SetFromAlpha(0.2)
    glowAlpha:SetToAlpha(0.85)
    glowAlpha:SetDuration(0.35)
    glowAlpha:SetSmoothing("IN_OUT")

    iconMarquee = CreateFrame("Frame", nil, frame)
    iconMarquee:SetPoint("TOPLEFT", iconTexture, "TOPLEFT", -MARQUEE_OUTER_OFFSET, MARQUEE_OUTER_OFFSET)
    iconMarquee:SetPoint("BOTTOMRIGHT", iconTexture, "BOTTOMRIGHT", MARQUEE_OUTER_OFFSET, -MARQUEE_OUTER_OFFSET)
    iconMarquee:SetFrameLevel(frame:GetFrameLevel() + 2)
    iconMarquee:Hide()
    BuildDashedMarquee(iconMarquee, marqueeSegments)

    dumpIcon = frame:CreateTexture(nil, "ARTWORK")
    dumpIcon:SetSize(50, 50)
    dumpIcon:SetPoint("LEFT", iconTexture, "RIGHT", 5, 0)
    dumpIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    dumpIcon:SetTexture(ns.decision and ns.decision.GetTokenTexture and ns.decision.GetTokenTexture("HEROIC_STRIKE") or "Interface\\Icons\\INV_Misc_QuestionMark")
    dumpGlowHost = CreateFrame("Button", nil, frame)
    dumpGlowHost:SetSize(50, 50)
    dumpGlowHost:SetPoint("CENTER", dumpIcon, "CENTER", 0, 0)
    dumpGlowHost:SetAlpha(1)
    dumpGlowHost:EnableMouse(false)
    dumpShine = CreateFrame("Frame", nil, frame)
    dumpShine:SetAllPoints(dumpGlowHost)
    dumpShine._furyShineOn = false

    dumpGlow = frame:CreateTexture(nil, "OVERLAY")
    dumpGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    dumpGlow:SetBlendMode("ADD")
    dumpGlow:SetVertexColor(1, 0.95, 0.2, 0.85)
    dumpGlow:SetPoint("CENTER", dumpIcon, "CENTER", 0, 0)
    dumpGlow:SetSize(90, 90)
    dumpGlow:Hide()

    dumpGlowAnim = dumpGlow:CreateAnimationGroup()
    dumpGlowAnim:SetLooping("BOUNCE")
    local dumpAlpha = dumpGlowAnim:CreateAnimation("Alpha")
    dumpAlpha:SetFromAlpha(0.2)
    dumpAlpha:SetToAlpha(0.85)
    dumpAlpha:SetDuration(0.35)
    dumpAlpha:SetSmoothing("IN_OUT")

    dumpMarquee = CreateFrame("Frame", nil, frame)
    dumpMarquee:SetPoint("TOPLEFT", dumpIcon, "TOPLEFT", -MARQUEE_OUTER_OFFSET, MARQUEE_OUTER_OFFSET)
    dumpMarquee:SetPoint("BOTTOMRIGHT", dumpIcon, "BOTTOMRIGHT", MARQUEE_OUTER_OFFSET, -MARQUEE_OUTER_OFFSET)
    dumpMarquee:SetFrameLevel(frame:GetFrameLevel() + 2)
    dumpMarquee:Hide()
    BuildDashedMarquee(dumpMarquee, dumpMarqueeSegments)

    skillText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    skillText:SetPoint("TOP", iconTexture, "BOTTOM", 0, -2)
    skillText:SetWidth(56)
    skillText:SetJustifyH("CENTER")

    dumpText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dumpText:SetPoint("TOP", dumpIcon, "BOTTOM", 0, -2)
    dumpText:SetWidth(86)
    dumpText:SetJustifyH("CENTER")

    cooldownText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    cooldownText:SetPoint("BOTTOM", iconTexture, "TOP", 0, 2)
    cooldownText:SetWidth(60)
    cooldownText:SetJustifyH("CENTER")
    cooldownText:SetTextColor(1, 0.95, 0.3)
    cooldownText:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
    cooldownText:Hide()

    skillKeyText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    skillKeyText:SetPoint("CENTER", iconTexture, "CENTER", 0, 0)
    skillKeyText:SetWidth(50)
    skillKeyText:SetJustifyH("CENTER")
    skillKeyText:SetTextColor(1, 1, 1)
    skillKeyText:SetFont(STANDARD_TEXT_FONT, 30, "OUTLINE")
    skillKeyText:Hide()

    dumpKeyText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dumpKeyText:SetPoint("CENTER", dumpIcon, "CENTER", 0, 0)
    dumpKeyText:SetWidth(50)
    dumpKeyText:SetJustifyH("CENTER")
    dumpKeyText:SetTextColor(1, 1, 1)
    dumpKeyText:SetFont(STANDARD_TEXT_FONT, 30, "OUTLINE")
    dumpKeyText:Hide()

    ApplyLayout(ns.IsDecisionIconTextShown())

    frame:SetScript("OnUpdate", function(self, elapsed)
        self._tick = (self._tick or 0) + elapsed
        if self._tick < 0.12 then
            return
        end
        self._tick = 0
        Render()
    end)

    RestorePosition()
end

function IconModule:Init()
    Build()
    frame:SetShown(ns.IsDecisionIconShown() and true or false)
    ns.RefreshDecisionIcon()
end

ns.RegisterModule(IconModule)

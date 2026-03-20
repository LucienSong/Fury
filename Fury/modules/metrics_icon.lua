local _, ns = ...

local IconModule = {
    name = "MetricsIcon",
}

local iconFrame
local timelinePanel
local rankedSlots = {}
local timelineMarkers = {}
local currentPreset

local renderState = {
    lastQueuedToken = nil,
    previewToken = nil,
    previewCommitted = false,
    previewCommitUntil = 0,
}

local timelineEvents = {}
local transientItems = {}
local transientPool = {}

local StartPreviewTransfer

local TIMELINE_MARKER_BOOTSTRAP = 12
local TIMELINE_EVENT_HARD_CAP = 48
local SLOT_MOVE_DURATION = 0.18
local TRANSIENT_MOVE_DURATION = 0.24
local DISMISS_MOVE_DURATION = 0.18
local TIMELINE_FADE_SECONDS = 1.0
local RENDER_TICK = 0.08

local SHORT_LABEL = {
    BLOODRAGE = "BR",
    BLOODTHIRST = "BT",
    WHIRLWIND = "WW",
    EXECUTE = "EXE",
    OVERPOWER = "OP",
    SUNDER_ARMOR = "SND",
    BATTLE_SHOUT = "BS",
    REVENGE = "REV",
    SHIELD_BLOCK = "SB",
    SHIELD_SLAM = "SS",
    LAST_STAND = "LS",
    HEROIC_STRIKE = "HS",
    CLEAVE = "CLV",
    TAUNT = "TNT",
    MOCKING_BLOW = "MB",
    HAMSTRING = "HAM",
    WAIT = "WAIT",
}

local SIZE_PRESETS = {
    compact = {
        baseIcon = 42,
        scales = { 1.00, 0.86, 0.74 },
        gap = 6,
        padX = 4,
        topPad = 8,
        bottomPad = 6,
        labelHeight = 15,
        textGap = 1,
        frameMinWidth = 160,
        timelineHeight = 24,
    },
    standard = {
        baseIcon = 52,
        scales = { 1.00, 0.86, 0.74 },
        gap = 6,
        padX = 6,
        topPad = 8,
        bottomPad = 6,
        labelHeight = 16,
        textGap = 1,
        frameMinWidth = 188,
        timelineHeight = 28,
    },
    large = {
        baseIcon = 62,
        scales = { 1.00, 0.86, 0.74 },
        gap = 7,
        padX = 6,
        topPad = 8,
        bottomPad = 8,
        labelHeight = 18,
        textGap = 2,
        frameMinWidth = 212,
        timelineHeight = 32,
    },
}

local PRESET_LABEL = {
    compact = "紧凑",
    standard = "标准",
    large = "大号",
}

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

local function Clamp(value, lo, hi)
    if value < lo then
        return lo
    end
    if value > hi then
        return hi
    end
    return value
end

local function GetMetricsDb()
    return ns.db and ns.db.metrics or nil
end

local function RefreshHudMouseInteraction()
    if not iconFrame then
        return
    end
    local editable = (ns.IsDecisionIconEditMode and ns.IsDecisionIconEditMode() or false)
        and (ns.IsDecisionIconShown and ns.IsDecisionIconShown() or false)
    iconFrame:EnableMouse(editable)
    if iconFrame.SetMouseClickEnabled then
        iconFrame:SetMouseClickEnabled(editable)
    end
    if iconFrame.SetMouseMotionEnabled then
        iconFrame:SetMouseMotionEnabled(editable)
    end
end

local function SaveFramePosition(targetFrame, key)
    local metricsDb = GetMetricsDb()
    if not targetFrame or not metricsDb then
        return
    end
    local point, _, relativePoint, x, y = targetFrame:GetPoint(1)
    metricsDb[key] = {
        point = point or "CENTER",
        relativePoint = relativePoint or "CENTER",
        x = x or 0,
        y = y or 0,
    }
end

local function RestoreFramePosition(targetFrame, key, defaultX, defaultY)
    if not targetFrame then
        return
    end
    local metricsDb = GetMetricsDb()
    local p = metricsDb and metricsDb[key]
    targetFrame:ClearAllPoints()
    targetFrame:SetPoint(
        (p and p.point) or "CENTER",
        UIParent,
        (p and p.relativePoint) or "CENTER",
        (p and p.x) or defaultX,
        (p and p.y) or defaultY
    )
end

function ns.SetDecisionIconShown(show)
    local metricsDb = GetMetricsDb()
    if not metricsDb then
        return
    end
    metricsDb.showIcon = show and true or false
    if iconFrame then
        iconFrame:SetShown(metricsDb.showIcon)
    end
    if timelinePanel then
        timelinePanel:SetShown(metricsDb.showIcon)
    end
    RefreshHudMouseInteraction()
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.ToggleDecisionIcon()
    local metricsDb = GetMetricsDb()
    if not metricsDb then
        return
    end
    ns.SetDecisionIconShown(not metricsDb.showIcon)
end

function ns.IsDecisionIconShown()
    local metricsDb = GetMetricsDb()
    return metricsDb and metricsDb.showIcon
end

function ns.SetDecisionIconTextShown(show)
    local metricsDb = GetMetricsDb()
    if not metricsDb then
        return
    end
    metricsDb.iconShowText = show and true or false
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.IsDecisionIconTextShown()
    local metricsDb = GetMetricsDb()
    return metricsDb and metricsDb.iconShowText
end

function ns.SetDecisionIconEditMode(enabled)
    local metricsDb = GetMetricsDb()
    if not metricsDb then
        return
    end
    metricsDb.iconEditMode = enabled and true or false
    RefreshHudMouseInteraction()
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.IsDecisionIconEditMode()
    local metricsDb = GetMetricsDb()
    return metricsDb and metricsDb.iconEditMode
end

function ns.GetDecisionIconSizePreset()
    local metricsDb = GetMetricsDb()
    local preset = metricsDb and metricsDb.iconSizePreset
    if preset == "compact" or preset == "standard" or preset == "large" then
        return preset
    end
    return "standard"
end

function ns.GetDecisionIconSizePresetLabel()
    return PRESET_LABEL[ns.GetDecisionIconSizePreset()] or "标准"
end

function ns.SetDecisionIconSizePreset(preset)
    local metricsDb = GetMetricsDb()
    if not metricsDb then
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
    metricsDb.iconSizePreset = p
    currentPreset = nil
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.GetDecisionIconBaseSize()
    local metricsDb = GetMetricsDb()
    local raw = tonumber(metricsDb and metricsDb.iconBaseSize)
    if raw and raw > 0 then
        return Clamp(math.floor(raw + 0.5), 32, 84)
    end
    local preset = ns.GetDecisionIconSizePreset()
    local cfg = SIZE_PRESETS[preset] or SIZE_PRESETS.standard
    return cfg.baseIcon or 52
end

function ns.SetDecisionIconBaseSize(size)
    local metricsDb = GetMetricsDb()
    if not metricsDb then
        return
    end
    metricsDb.iconBaseSize = Clamp(math.floor(tonumber(size) or 52), 32, 84)
    currentPreset = nil
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.GetDecisionTimelineWidth()
    local metricsDb = GetMetricsDb()
    return Clamp(math.floor(tonumber(metricsDb and metricsDb.timelineWidth) or 220), 140, 420)
end

function ns.SetDecisionTimelineWidth(width)
    local metricsDb = GetMetricsDb()
    if not metricsDb then
        return
    end
    metricsDb.timelineWidth = Clamp(math.floor(tonumber(width) or 220), 140, 420)
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

function ns.GetDecisionTimelineSeconds()
    local metricsDb = GetMetricsDb()
    return Clamp(math.floor(tonumber(metricsDb and metricsDb.timelineSeconds) or 5), 3, 12)
end

function ns.SetDecisionTimelineSeconds(seconds)
    local metricsDb = GetMetricsDb()
    if not metricsDb then
        return
    end
    metricsDb.timelineSeconds = Clamp(math.floor(tonumber(seconds) or 5), 3, 12)
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

local function GetKeybindText(token)
    if not token or token == "" or token == "NONE" then
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

local function GetSlotLabel(index, rec)
    if not rec or not rec.token then
        return ""
    end
    return tostring(index) .. ":" .. (SHORT_LABEL[rec.token] or rec.token or "")
end

local function CreateSlot(parent)
    local slot = {}
    slot.frame = CreateFrame("Frame", nil, parent)
    slot.frame:Hide()

    slot.texture = slot.frame:CreateTexture(nil, "ARTWORK")
    slot.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    slot.glowHost = CreateFrame("Button", nil, slot.frame)
    slot.glowHost:SetAlpha(1)
    slot.glowHost:EnableMouse(false)

    slot.glow = slot.frame:CreateTexture(nil, "OVERLAY")
    slot.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    slot.glow:SetBlendMode("ADD")
    slot.glow:SetVertexColor(1, 0.95, 0.2, 0.85)
    slot.glow:Hide()

    slot.glowAnim = slot.glow:CreateAnimationGroup()
    slot.glowAnim:SetLooping("BOUNCE")
    local alpha = slot.glowAnim:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0.2)
    alpha:SetToAlpha(0.85)
    alpha:SetDuration(0.35)
    alpha:SetSmoothing("IN_OUT")

    slot.cooldownText = slot.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    slot.cooldownText:SetTextColor(1, 0.95, 0.3)
    slot.cooldownText:Hide()

    slot.label = slot.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slot.label:SetJustifyH("CENTER")
    slot.label:Hide()

    slot.keyText = slot.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    slot.keyText:SetTextColor(1, 1, 1)
    slot.keyText:SetJustifyH("CENTER")
    slot.keyText:Hide()

    slot.currentX = 0
    slot.targetX = 0
    slot.y = -8
    slot.lastToken = nil
    return slot
end

local function CreateTimelineMarker(parent)
    local marker = CreateFrame("Frame", nil, parent)
    marker:SetSize(16, 16)
    marker:Hide()

    marker.texture = marker:CreateTexture(nil, "ARTWORK")
    marker.texture:SetAllPoints(marker)
    marker.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    marker.border = marker:CreateTexture(nil, "BORDER")
    marker.border:SetTexture("Interface\\Buttons\\WHITE8X8")
    marker.border:SetPoint("TOPLEFT", marker, "TOPLEFT", -1, 1)
    marker.border:SetPoint("BOTTOMRIGHT", marker, "BOTTOMRIGHT", 1, -1)
    marker.border:SetVertexColor(0, 0, 0, 0.35)

    marker.glow = marker:CreateTexture(nil, "OVERLAY")
    marker.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    marker.glow:SetBlendMode("ADD")
    marker.glow:SetVertexColor(0.35, 0.8, 1, 0.95)
    marker.glow:SetPoint("CENTER", marker, "CENTER", 0, 0)
    marker.glow:SetSize(34, 34)
    marker.glow:Hide()

    marker.glowAnim = marker.glow:CreateAnimationGroup()
    marker.glowAnim:SetLooping("BOUNCE")
    local alpha = marker.glowAnim:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0.15)
    alpha:SetToAlpha(0.9)
    alpha:SetDuration(0.35)
    alpha:SetSmoothing("IN_OUT")

    marker.kindText = marker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    marker.kindText:SetPoint("BOTTOM", marker, "TOP", 0, -2)
    marker.kindText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    marker.kindText:Hide()

    return marker
end

local function EnsureTimelineMarker(index)
    if not timelinePanel then
        return nil
    end
    if not timelineMarkers[index] then
        timelineMarkers[index] = CreateTimelineMarker(timelinePanel)
    end
    return timelineMarkers[index]
end

local function CreateTransientVisual(parent)
    local item = {}
    item.frame = CreateFrame("Frame", nil, parent)
    item.frame:Hide()

    item.texture = item.frame:CreateTexture(nil, "ARTWORK")
    item.texture:SetAllPoints(item.frame)
    item.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    item.border = item.frame:CreateTexture(nil, "BORDER")
    item.border:SetTexture("Interface\\Buttons\\WHITE8X8")
    item.border:SetPoint("TOPLEFT", item.frame, "TOPLEFT", -1, 1)
    item.border:SetPoint("BOTTOMRIGHT", item.frame, "BOTTOMRIGHT", 1, -1)
    item.border:SetVertexColor(0, 0, 0, 0.35)

    item.glow = item.frame:CreateTexture(nil, "OVERLAY")
    item.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    item.glow:SetBlendMode("ADD")
    item.glow:SetVertexColor(1, 0.95, 0.2, 0.45)
    item.glow:Hide()

    return item
end

local function AcquireTransientVisual()
    local item = transientPool[#transientPool]
    if item then
        transientPool[#transientPool] = nil
        return item
    end
    return CreateTransientVisual(iconFrame)
end

local function ReleaseTransientVisual(item)
    if not item then
        return
    end
    item.frame:Hide()
    item.frame:SetAlpha(1)
    item.texture:SetTexture("")
    item.glow:Hide()
    transientPool[#transientPool + 1] = item
end

local function StartTransientVisual(spec)
    if not iconFrame then
        return nil
    end
    local item = AcquireTransientVisual()
    local now = GetTime()
    item.token = spec.token
    item.startedAt = now
    item.duration = math.max(spec.duration or TRANSIENT_MOVE_DURATION, 0.01)
    item.fromX = spec.fromX or 0
    item.toX = spec.toX or item.fromX
    item.fromY = spec.fromY or 0
    item.toY = spec.toY or item.fromY
    item.fromSize = math.max(spec.fromSize or 16, 8)
    item.toSize = math.max(spec.toSize or item.fromSize, 8)
    item.alphaFrom = spec.alphaFrom or 1
    item.alphaTo = spec.alphaTo or 0
    item.texturePath = spec.texture or "Interface\\Icons\\INV_Misc_QuestionMark"
    item.glowShown = spec.glow and true or false

    item.texture:SetTexture(item.texturePath)
    item.glow:SetShown(item.glowShown)
    item.frame:Show()
    item.frame:SetAlpha(item.alphaFrom)

    transientItems[#transientItems + 1] = item
    return item
end

local function UpdateTransientVisuals()
    local now = GetTime()
    for i = #transientItems, 1, -1 do
        local item = transientItems[i]
        local progress = (now - (item.startedAt or now)) / math.max(item.duration or TRANSIENT_MOVE_DURATION, 0.01)
        if progress >= 1 then
            table.remove(transientItems, i)
            ReleaseTransientVisual(item)
        else
            local eased = progress * (2 - progress)
            local x = item.fromX + ((item.toX - item.fromX) * eased)
            local y = item.fromY + ((item.toY - item.fromY) * eased)
            local size = item.fromSize + ((item.toSize - item.fromSize) * eased)
            item.frame:ClearAllPoints()
            item.frame:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", x, y)
            item.frame:SetSize(size, size)
            item.glow:SetPoint("CENTER", item.frame, "CENTER", 0, 0)
            item.glow:SetSize(size + 24, size + 24)
            item.frame:SetAlpha(item.alphaFrom + ((item.alphaTo - item.alphaFrom) * eased))
        end
    end
end

local function BuildLegacyFallbackRanked(rec)
    if not rec then
        return {}
    end
    local ranked = {}
    local function add(token, channel, reason, state)
        if not token or token == "" or token == "NONE" or token == "HOLD" then
            return
        end
        ranked[#ranked + 1] = {
            token = token,
            channel = channel,
            reason = reason,
            cooldownRem = state and state.cooldownRem or 0,
            rageCost = state and state.rageCost or 0,
            rageEnough = state and state.rageEnough or true,
            actionableNow = token ~= "WAIT" and (not state or ((state.cooldownRem or 0) <= 0.05 and state.rageEnough ~= false)),
            passed = state and state.passed or true,
        }
    end
    add(rec.displayNextSkill or rec.nextGcdSkill or rec.nextSkill, "gcd", rec.nextGcdReason or rec.reason, rec.displayNextState)
    add(rec.offGcdSkill, "offgcd", rec.offGcdReason, rec.offGcdState)
    add(rec.dumpQueueSkill or rec.dumpSkill, "dump", rec.dumpQueueReason or rec.dumpReason, nil)
    return ranked
end

local function SetSlotPosition(slot, x, y)
    slot.frame:ClearAllPoints()
    slot.frame:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", x, y)
    slot.currentX = x
    slot.y = y
end

local function StartSlotMove(slot, fromX, toX, y, fresh)
    slot.targetX = toX
    slot.y = y
    slot.anim = {
        fromX = fromX,
        toX = toX,
        y = y,
        startedAt = GetTime(),
        duration = SLOT_MOVE_DURATION,
        fresh = fresh and true or false,
    }
    SetSlotPosition(slot, fromX, y)
    slot.frame:SetAlpha(fresh and 0.35 or 0.8)
end

local function UpdateSlotAnimations()
    local now = GetTime()
    for i = 1, #rankedSlots do
        local slot = rankedSlots[i]
        if slot and slot.anim then
            local anim = slot.anim
            local progress = (now - anim.startedAt) / math.max(anim.duration or SLOT_MOVE_DURATION, 0.01)
            if progress >= 1 then
                SetSlotPosition(slot, anim.toX, anim.y)
                slot.frame:SetAlpha(1)
                slot.anim = nil
            else
                local eased = progress * (2 - progress)
                local x = anim.fromX + ((anim.toX - anim.fromX) * eased)
                SetSlotPosition(slot, x, anim.y)
                slot.frame:SetAlpha(anim.fresh and (0.35 + 0.65 * eased) or (0.8 + 0.2 * eased))
            end
        end
    end
end

local function FindPendingQueueEvent(token)
    for i = 1, #timelineEvents do
        local event = timelineEvents[i]
        if event.kind == "queued" and event.token == token and event.pending then
            return event
        end
    end
    return nil
end

local function PushTimelineEvent(kind, token, pending, extra)
    extra = extra or {}
    if (not token or token == "" or token == "NONE" or token == "HOLD") and not extra.texture then
        return nil
    end
    local now = GetTime()
    if pending then
        local existing = FindPendingQueueEvent(token)
        if existing then
            existing.at = now
            return existing
        end
    else
        local previous = timelineEvents[1]
        if previous and previous.kind == kind and previous.token == token and previous.spellId == extra.spellId
            and (not previous.pending) and math.abs(now - (previous.at or 0)) < 0.12 then
            return previous
        end
    end
    local event = {
        kind = kind,
        token = token,
        spellId = extra.spellId,
        spellName = extra.spellName,
        texture = extra.texture,
        label = extra.label,
        at = now,
        pending = pending and true or false,
        deferUntil = extra.deferUntil,
    }
    table.insert(timelineEvents, 1, event)
    while #timelineEvents > TIMELINE_EVENT_HARD_CAP do
        table.remove(timelineEvents)
    end
    return event
end

local function PushTimelineSpellCast(spellId, spellName)
    local decision = ns.decision
    local token = decision and decision.GetTokenForSpellId and decision.GetTokenForSpellId(spellId) or nil
    if not token and decision and decision.GetTokenForSpellName then
        token = decision.GetTokenForSpellName(spellName)
    end

    local texture = nil
    if token and decision and decision.GetTokenTexture then
        texture = decision.GetTokenTexture(token)
    end
    if not texture and spellId then
        texture = GetSpellTexture(spellId)
    end
    if not texture and spellName then
        texture = GetSpellTexture(spellName)
    end

    local event = PushTimelineEvent("casted", token or spellName or tostring(spellId or ""), false, {
        spellId = spellId,
        spellName = spellName,
        texture = texture,
        label = token and SHORT_LABEL[token] or "",
    })
    if token then
        StartPreviewTransfer(token, event)
    end
end

local function ReleasePendingQueueEvent(token)
    local event = FindPendingQueueEvent(token)
    if event then
        event.pending = false
        event.at = GetTime()
        event.deferUntil = nil
    else
        PushTimelineEvent("queued", token, false)
    end
end

local function PruneTimelineEvents()
    local now = GetTime()
    local window = ns.GetDecisionTimelineSeconds and ns.GetDecisionTimelineSeconds() or 5
    for i = #timelineEvents, 1, -1 do
        local event = timelineEvents[i]
        if (not event) or ((not event.pending) and (now - (event.at or 0) > window)) then
            table.remove(timelineEvents, i)
        end
    end
end

local function UpdateQueuedTimeline(rec)
    local queuedToken = rec and rec.context and rec.context.queue and rec.context.queue.queuedDumpToken or nil
    if queuedToken == "HOLD" then
        queuedToken = nil
    end
    if queuedToken and renderState.lastQueuedToken ~= queuedToken then
        local event = PushTimelineEvent("queued", queuedToken, true, {
            texture = GetTokenTexture(queuedToken),
            label = SHORT_LABEL[queuedToken] or "",
        })
        StartPreviewTransfer(queuedToken, event)
    elseif (not queuedToken) and renderState.lastQueuedToken then
        ReleasePendingQueueEvent(renderState.lastQueuedToken)
    elseif queuedToken and renderState.lastQueuedToken and queuedToken ~= renderState.lastQueuedToken then
        ReleasePendingQueueEvent(renderState.lastQueuedToken)
        local event = PushTimelineEvent("queued", queuedToken, true, {
            texture = GetTokenTexture(queuedToken),
            label = SHORT_LABEL[queuedToken] or "",
        })
        StartPreviewTransfer(queuedToken, event)
    end
    renderState.lastQueuedToken = queuedToken
end

local function RefreshTimelineVisual()
    if not timelinePanel then
        return
    end
    PruneTimelineEvents()

    local width = timelinePanel.bar:GetWidth()
    local height = timelinePanel.bar:GetHeight()
    if width <= 4 or height <= 4 then
        return
    end

    local markerSize = math.max(height - 6, 12)
    local window = ns.GetDecisionTimelineSeconds and ns.GetDecisionTimelineSeconds() or 5

    local anyShown = false
    local now = GetTime()
    local markerCount = math.max(#timelineEvents, #timelineMarkers)
    for i = 1, markerCount do
        local marker = EnsureTimelineMarker(i)
        local event = timelineEvents[i]
        if not event then
            marker:Hide()
            SetPulse(marker.glow, marker.glowAnim, false)
        elseif event.deferUntil and now < event.deferUntil then
            marker:Hide()
            SetPulse(marker.glow, marker.glowAnim, false)
        else
            local age = math.max(now - (event.at or 0), 0)
            local progress = event.pending and 0 or math.min(age / math.max(window, 1), 1)
            local x = math.floor(progress * math.max(width - markerSize - 2, 1))
            marker:SetSize(markerSize, markerSize)
            marker.glow:SetSize(markerSize + 18, markerSize + 18)
            marker:ClearAllPoints()
            marker:SetPoint("LEFT", timelinePanel.bar, "LEFT", x + 2, 0)
            local texture = event.texture
            if not texture and event.token and ns.decision and ns.decision.GetTokenTexture then
                texture = ns.decision.GetTokenTexture(event.token)
            end
            marker.texture:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            local alpha = 1
            if not event.pending then
                local remaining = window - age
                if remaining < TIMELINE_FADE_SECONDS then
                    alpha = alpha * Clamp(remaining / TIMELINE_FADE_SECONDS, 0, 1)
                end
            end
            marker.texture:SetAlpha(alpha)
            if event.kind == "queued" then
                marker.border:SetVertexColor(0.2, 0.45, 0.65, 0.55)
            else
                marker.border:SetVertexColor(0, 0, 0, 0.35)
            end
            marker.border:SetAlpha(alpha)
            marker.kindText:SetAlpha(alpha)
            marker.kindText:SetText(event.pending and "" or (event.label or ""))
            if (not event.pending) and event.label and event.label ~= "" then
                marker.kindText:Show()
            else
                marker.kindText:Hide()
            end
            SetPulse(marker.glow, marker.glowAnim, event.pending and event.kind == "queued")
            marker:Show()
            anyShown = true
        end
    end
end

local function SetSlotVisual(slot, rec, index, showText)
    if not slot then
        return
    end
    if not rec or not rec.token or rec.token == "NONE" then
        slot.texture:SetTexture("")
        slot.texture:Hide()
        slot.cooldownText:Hide()
        slot.label:SetText("")
        slot.label:Hide()
        slot.keyText:SetText("")
        slot.keyText:Hide()
        SetNativeOverlayGlow(slot.glowHost, false)
        SetPulse(slot.glow, slot.glowAnim, false)
        slot.frame:Hide()
        slot.lastToken = nil
        return
    end

    slot.frame:Show()
    local token = rec.token
    local texture = ns.decision and ns.decision.GetTokenTexture and ns.decision.GetTokenTexture(token) or nil
    slot.texture:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    slot.texture:SetAlpha(token == "WAIT" and 0.62 or 1)
    slot.texture:Show()

    local cooldownRem = tonumber(rec.cooldownRem) or 0
    if token ~= "WAIT" and cooldownRem > 0.05 then
        slot.cooldownText:SetText(string.format("%.1f", cooldownRem))
        slot.cooldownText:Show()
    else
        slot.cooldownText:Hide()
    end

    if showText then
        slot.label:SetText(GetSlotLabel(index, rec))
        slot.label:Show()
    else
        slot.label:SetText("")
        slot.label:Hide()
    end

    local keyText = GetKeybindText(token)
    if keyText and token ~= "WAIT" then
        slot.keyText:SetText(keyText)
        slot.keyText:Show()
    else
        slot.keyText:SetText("")
        slot.keyText:Hide()
    end

    local shouldGlow = token ~= "WAIT" and rec.actionableNow and not rec.suppressGlow
    SetNativeOverlayGlow(slot.glowHost, shouldGlow)
    SetPulse(slot.glow, slot.glowAnim, shouldGlow)
end

local function GetTokenTexture(token)
    if token and ns.decision and ns.decision.GetTokenTexture then
        return ns.decision.GetTokenTexture(token)
    end
    return nil
end

local function GetTimelineVisualHeight(baseIcon, cfg)
    return math.max(
        math.floor((tonumber(baseIcon) or 0) * 0.58 + 0.5),
        tonumber(cfg and cfg.timelineHeight) or 28,
        22
    )
end

local function ApplyHudLayout(showText)
    if not iconFrame or not timelinePanel then
        return nil
    end
    local presetName = ns.GetDecisionIconSizePreset()
    local cfg = SIZE_PRESETS[presetName] or SIZE_PRESETS.standard
    local baseIcon = ns.GetDecisionIconBaseSize()
    local timelineWidth = ns.GetDecisionTimelineWidth and ns.GetDecisionTimelineWidth() or 220
    local layoutKey = table.concat({
        presetName,
        showText and "text" or "notext",
        tostring(baseIcon),
        tostring(timelineWidth),
    }, ":")
    if currentPreset == layoutKey and iconFrame._layout then
        return iconFrame._layout
    end
    currentPreset = layoutKey

    local slotSize = math.max(math.floor(baseIcon + 0.5), 24)
    local timelineHeight = GetTimelineVisualHeight(slotSize, cfg)
    local labelHeight = showText and cfg.labelHeight or 0
    local slotBlockHeight = slotSize + labelHeight + 8
    local innerHeight = math.max(slotBlockHeight, timelineHeight)
    local frameWidth = cfg.padX + slotSize + cfg.gap + timelineWidth + cfg.padX
    local frameHeight = cfg.topPad + innerHeight + cfg.bottomPad
    local slotY = -cfg.topPad - math.floor((innerHeight - slotBlockHeight) / 2)
    local timelineX = cfg.padX + slotSize + cfg.gap
    local timelineY = -cfg.topPad - math.floor((innerHeight - timelineHeight) / 2)

    iconFrame:SetSize(frameWidth, frameHeight)

    local slot = rankedSlots[1]
    slot.frame:SetSize(slotSize, slotBlockHeight)
    slot.texture:SetSize(slotSize, slotSize)
    slot.texture:ClearAllPoints()
    slot.texture:SetPoint("TOP", slot.frame, "TOP", 0, 0)
    slot.glowHost:ClearAllPoints()
    slot.glowHost:SetPoint("CENTER", slot.texture, "CENTER", 0, 0)
    slot.glowHost:SetSize(slotSize, slotSize)
    slot.glow:SetSize(slotSize + 40, slotSize + 40)
    slot.glow:ClearAllPoints()
    slot.glow:SetPoint("CENTER", slot.texture, "CENTER", 0, 0)
    slot.cooldownText:ClearAllPoints()
    slot.cooldownText:SetPoint("BOTTOM", slot.texture, "TOP", 0, 2)
    slot.cooldownText:SetWidth(slotSize + 10)
    slot.cooldownText:SetFont(STANDARD_TEXT_FONT, math.max(math.floor(slotSize * 0.42), 10), "OUTLINE")
    slot.label:ClearAllPoints()
    slot.label:SetPoint("TOP", slot.texture, "BOTTOM", 0, -cfg.textGap)
    slot.label:SetWidth(slotSize + 10)
    slot.keyText:ClearAllPoints()
    slot.keyText:SetPoint("CENTER", slot.texture, "CENTER", 0, 0)
    slot.keyText:SetWidth(slotSize)
    slot.keyText:SetFont(STANDARD_TEXT_FONT, math.max(math.floor(slotSize * 0.5), 9), "OUTLINE")

    for i = 2, 3 do
        local hiddenSlot = rankedSlots[i]
        if hiddenSlot then
            hiddenSlot.frame:Hide()
            hiddenSlot.lastToken = nil
        end
    end

    timelinePanel:ClearAllPoints()
    timelinePanel:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", timelineX, timelineY)
    timelinePanel:SetSize(timelineWidth, timelineHeight)
    timelinePanel.bar:ClearAllPoints()
    timelinePanel.bar:SetAllPoints(timelinePanel)

    iconFrame._layout = {
        slotX = { cfg.padX },
        slotY = slotY,
        slotSize = slotSize,
        timelineX = timelineX,
        timelineY = timelineY,
        timelineWidth = timelineWidth,
        timelineHeight = timelineHeight,
    }
    return iconFrame._layout
end

local function StartDismissPreview(token, layout)
    local slot = rankedSlots[1]
    if not slot or not token or not slot.frame:IsShown() then
        return
    end
    local size = layout and layout.slotSize or math.max(slot.texture:GetWidth(), 16)
    StartTransientVisual({
        token = token,
        texture = GetTokenTexture(token),
        fromX = slot.currentX or 0,
        toX = (slot.currentX or 0) - size,
        fromY = slot.y or 0,
        toY = slot.y or 0,
        fromSize = size,
        toSize = size,
        alphaFrom = math.max(slot.frame:GetAlpha(), 0.85),
        alphaTo = 0,
        duration = DISMISS_MOVE_DURATION,
    })
end

StartPreviewTransfer = function(token, event)
    local slot = rankedSlots[1]
    if not slot or not event or not token or renderState.previewToken ~= token or renderState.previewCommitted then
        return
    end
    if not slot.frame:IsShown() then
        return
    end
    local layout = ApplyHudLayout(ns.IsDecisionIconTextShown())
    if not layout then
        return
    end
    local markerSize = math.max(layout.timelineHeight - 6, 12)
    event.deferUntil = GetTime() + TRANSIENT_MOVE_DURATION
    StartTransientVisual({
        token = token,
        texture = event.texture or GetTokenTexture(token),
        fromX = slot.currentX or layout.slotX[1] or 0,
        toX = layout.timelineX + 2,
        fromY = slot.y or layout.slotY or 0,
        toY = layout.timelineY + math.floor((layout.timelineHeight - markerSize) / 2),
        fromSize = layout.slotSize or markerSize,
        toSize = markerSize,
        alphaFrom = 1,
        alphaTo = 0.9,
        duration = TRANSIENT_MOVE_DURATION,
        glow = event.pending and event.kind == "queued",
    })
    renderState.previewCommitted = true
    renderState.previewCommitUntil = event.deferUntil or 0
end

local function BuildVisibleRanked(rec)
    local ranked = {}
    if rec then
        ranked = rec.rankedRecommendations or {}
        if #ranked == 0 then
            ranked = BuildLegacyFallbackRanked(rec)
        end
        if #ranked == 0 and rec.recommendedAction and rec.recommendedAction.token then
            ranked[1] = rec.recommendedAction
        end
    end
    local visible = {}
    local queuedDumpToken = rec and rec.context and rec.context.queue and rec.context.queue.queuedDumpToken or nil
    if queuedDumpToken == "HOLD" then
        queuedDumpToken = nil
    end
    for i = 1, 3 do
        local entry = ranked[i]
        if entry and entry.token and entry.token ~= "NONE" and entry.token ~= "HOLD" then
            if entry.token == "WAIT" then
                visible[i] = nil
            elseif queuedDumpToken and entry.token == queuedDumpToken then
                visible[i] = nil
            else
                local out = {}
                for k, v in pairs(entry) do
                    out[k] = v
                end
                out.suppressGlow = i ~= 1
                visible[i] = out
            end
        else
            visible[i] = nil
        end
    end
    return visible
end

local function UpdateSlots(rec, showText)
    local layout = ApplyHudLayout(showText)
    local ranked = BuildVisibleRanked(rec)
    local showAny = false
    local slot = rankedSlots[1]
    local slotRec = ranked[1]
    local nextPreviewToken = slotRec and slotRec.token or nil

    if renderState.previewToken and renderState.previewToken ~= nextPreviewToken and not renderState.previewCommitted then
        StartDismissPreview(renderState.previewToken, layout)
    end
    if renderState.previewToken ~= nextPreviewToken then
        renderState.previewToken = nextPreviewToken
        renderState.previewCommitted = false
        renderState.previewCommitUntil = 0
    end

    SetSlotVisual(slot, slotRec, 1, showText)
    if slotRec and slotRec.token then
        showAny = true
        local targetX = layout.slotX[1]
        local targetY = layout.slotY
        local changedToken = slot.lastToken ~= slotRec.token
        if changedToken then
            StartSlotMove(slot, targetX + math.floor((layout.slotSize or 20) * 0.35), targetX, targetY, true)
        elseif math.abs((slot.targetX or targetX) - targetX) > 0.5 then
            StartSlotMove(slot, slot.currentX or targetX, targetX, targetY, false)
        elseif not slot.anim then
            SetSlotPosition(slot, targetX, targetY)
            slot.frame:SetAlpha(1)
            slot.targetX = targetX
        end
        if renderState.previewCommitted and renderState.previewToken == slotRec.token
            and GetTime() < (renderState.previewCommitUntil or 0) then
            slot.frame:SetAlpha(math.min(slot.frame:GetAlpha(), 0.18))
        end
        slot.lastToken = slotRec.token
    else
        slot.lastToken = nil
    end
    for i = 2, 3 do
        local extraSlot = rankedSlots[i]
        if extraSlot then
            SetSlotVisual(extraSlot, nil, i, showText)
        end
    end
    return showAny
end

local function Render()
    if not iconFrame or not timelinePanel then
        return
    end
    if not ns.IsDecisionIconShown() then
        iconFrame:Hide()
        return
    end

    iconFrame:Show()

    local showText = ns.IsDecisionIconTextShown()
    ApplyHudLayout(showText)

    local rec = ns.decision and ns.decision.GetRecommendation and ns.decision.GetRecommendation() or nil
    if not rec then
        for i = 1, 3 do
            SetSlotVisual(rankedSlots[i], nil, i, showText)
        end
        renderState.previewToken = nil
        renderState.previewCommitted = false
        renderState.previewCommitUntil = 0
        RefreshTimelineVisual()
        return
    end

    UpdateSlots(rec, showText)
    UpdateQueuedTimeline(rec)
    RefreshTimelineVisual()
    iconFrame:SetAlpha(1)
    timelinePanel:SetAlpha(1)

    local backdropColor = rec.mode == "TPS_SURVIVAL" and { 0.1, 0.2, 0.35, 0.9 } or { 0.35, 0.22, 0.06, 0.9 }
    local showBackdrop = ns.IsDecisionIconEditMode and ns.IsDecisionIconEditMode()
    if iconFrame.SetBackdropColor then
        iconFrame:SetBackdropColor(backdropColor[1], backdropColor[2], backdropColor[3], showBackdrop and backdropColor[4] or 0)
    end
    if iconFrame.SetBackdropBorderColor then
        iconFrame:SetBackdropBorderColor(1, 1, 1, showBackdrop and 0.6 or 0)
    end
    timelinePanel.bar:SetAlpha(0)
end

function ns.RefreshDecisionIcon()
    if not iconFrame or not timelinePanel then
        return
    end
    Render()
end

local function HandleEvent(event, arg1, _, arg3, arg4)
    if event == "UNIT_POWER_UPDATE" and arg1 ~= "player" then
        return
    end
    if event == "UNIT_AURA" then
        if arg1 ~= "player" and arg1 ~= "target" and (type(arg1) ~= "string" or not strfind(arg1, "^party")) then
            return
        end
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" and arg1 == "player" then
        local spellId = type(arg3) == "number" and arg3 or (type(arg4) == "number" and arg4 or nil)
        local spellName = spellId and GetSpellInfo(spellId) or nil
        if spellId and ns.decision and ns.decision.GetTokenForSpellId then
            local token = ns.decision.GetTokenForSpellId(spellId)
            if token == "HEROIC_STRIKE" or token == "CLEAVE" then
                ReleasePendingQueueEvent(token)
            end
        end
        if spellId or spellName then
            PushTimelineSpellCast(spellId, spellName)
        end
    end
    if ns.RefreshDecisionIcon then
        ns.RefreshDecisionIcon()
    end
end

local function BuildTimelinePanel()
    timelinePanel = CreateFrame("Frame", "FuryDecisionTimelinePanel", iconFrame)
    timelinePanel:SetFrameStrata("HIGH")
    timelinePanel:EnableMouse(false)

    timelinePanel.bar = timelinePanel:CreateTexture(nil, "BACKGROUND")
    timelinePanel.bar:SetColorTexture(0.08, 0.08, 0.08, 0)

    for i = 1, TIMELINE_MARKER_BOOTSTRAP do
        timelineMarkers[i] = CreateTimelineMarker(timelinePanel)
    end
end

local function BuildIconFrame()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    iconFrame = CreateFrame("Frame", "FuryDecisionHintIcon", UIParent, template)
    iconFrame:SetFrameStrata("HIGH")
    iconFrame:EnableMouse(false)
    iconFrame:SetMovable(true)
    iconFrame:RegisterForDrag("LeftButton")
    iconFrame:SetClampedToScreen(true)
    iconFrame:SetScript("OnDragStart", function(self)
        if not (ns.IsDecisionIconEditMode and ns.IsDecisionIconEditMode()) then
            return
        end
        self:StartMoving()
    end)
    iconFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveFramePosition(self, "iconPoint")
    end)
    if iconFrame.SetBackdrop then
        iconFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
    end

    for i = 1, 3 do
        rankedSlots[i] = CreateSlot(iconFrame)
    end

    iconFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    iconFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    iconFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    iconFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    iconFrame:RegisterEvent("UNIT_POWER_UPDATE")
    iconFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    iconFrame:RegisterEvent("SPELL_UPDATE_USABLE")
    iconFrame:RegisterEvent("ACTIONBAR_UPDATE_USABLE")
    iconFrame:RegisterEvent("ACTIONBAR_UPDATE_STATE")
    iconFrame:RegisterEvent("CURRENT_SPELL_CAST_CHANGED")
    iconFrame:RegisterEvent("UNIT_AURA")
    iconFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    iconFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    iconFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
        HandleEvent(event, arg1, arg2, arg3, arg4)
    end)

    iconFrame:SetScript("OnUpdate", function(self, elapsed)
        UpdateSlotAnimations()
        UpdateTransientVisuals()
        RefreshTimelineVisual()
        self._tick = (self._tick or 0) + elapsed
        if self._tick < RENDER_TICK then
            return
        end
        self._tick = 0
        Render()
    end)
end

function IconModule:Init()
    BuildIconFrame()
    BuildTimelinePanel()
    RestoreFramePosition(iconFrame, "iconPoint", 260, 0)
    iconFrame:SetShown(ns.IsDecisionIconShown() and true or false)
    RefreshHudMouseInteraction()
    ns.RefreshDecisionIcon()
end

ns.RegisterModule(IconModule)

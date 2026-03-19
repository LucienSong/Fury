local _, ns = ...

local MinimapModule = {
    name = "Minimap",
}

local button
local icon

local function Atan2(y, x)
    if math.atan2 then
        return math.atan2(y, x)
    end
    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 and y >= 0 then
        return math.atan(y / x) + math.pi
    elseif x < 0 and y < 0 then
        return math.atan(y / x) - math.pi
    elseif x == 0 and y > 0 then
        return math.pi / 2
    elseif x == 0 and y < 0 then
        return -math.pi / 2
    end
    return 0
end

local function GetSavedAngle()
    if not ns.db or not ns.db.minimap then
        return 220
    end
    return ns.db.minimap.angle or 220
end

local function SetSavedAngle(angle)
    ns.db.minimap.angle = angle
end

local function ApplyPosition(angle)
    if not button then
        return
    end
    local rad = math.rad(angle)
    local radius = 80
    local x = math.cos(rad) * radius
    local y = math.sin(rad) * radius
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function IsShown()
    return not ns.db.minimap.hide
end

function ns.SetMinimapIconShown(show)
    ns.db.minimap.hide = not show
    if button then
        button:SetShown(show)
    end
end

function ns.ToggleMinimapIcon()
    ns.SetMinimapIconShown(not IsShown())
    if IsShown() then
        ns.Print("已显示小地图图标。")
    else
        ns.Print("已隐藏小地图图标。")
    end
end

function ns.IsMinimapIconShown()
    return IsShown()
end

function MinimapModule:Init()
    button = CreateFrame("Button", "FuryMinimapButton", Minimap)
    button:SetSize(32, 32)
    button:SetMovable(true)
    button:SetFrameStrata("MEDIUM")
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", 0, 0)

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("CENTER", 1, -1)

    icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 1, 1)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetTexture(GetSpellTexture(2458) or "Interface\\Icons\\Ability_Racial_Avatar")

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            ns.ToggleMinimapIcon()
            return
        end
        ns.OpenOptions()
    end)

    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local x, y = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            x = x / scale
            y = y / scale
            local angle = math.deg(Atan2(y - my, x - mx))
            if angle < 0 then
                angle = angle + 360
            end
            SetSavedAngle(angle)
            ApplyPosition(angle)
        end)
    end)

    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Fury")
        GameTooltip:AddLine("左键: 打开设置", 1, 1, 1)
        GameTooltip:AddLine("右键: 显示/隐藏图标", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    ApplyPosition(GetSavedAngle())
    button:SetShown(IsShown())
end

function MinimapModule:OnLogin()
    if icon then
        icon:SetTexture(GetSpellTexture(2458) or "Interface\\Icons\\Ability_Racial_Avatar")
    end
end

ns.RegisterModule(MinimapModule)

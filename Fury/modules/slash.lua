local _, ns = ...

local SlashModule = {
    name = "Slash",
}

function SlashModule:Init()
    SLASH_FURY1 = "/fury"
    SlashCmdList.FURY = function(msg)
        local input = strlower(strtrim(msg or ""))
        if input == "" then
            ns.OpenOptions()
            return
        end

        local cmd, rest = input:match("^(%S+)%s*(.-)$")
        if cmd == "config" or cmd == "options" or cmd == "setting" or cmd == "settings" then
            ns.OpenOptions()
        elseif cmd == "minimap" then
            ns.ToggleMinimapIcon()
        elseif cmd == "metrics" or cmd == "meter" or cmd == "panel" then
            ns.ToggleMetricsPanel()
        elseif cmd == "icon" then
            if rest == "on" then
                ns.SetDecisionIconShown(true)
            elseif rest == "off" then
                ns.SetDecisionIconShown(false)
            elseif rest == "text on" and ns.SetDecisionIconTextShown then
                ns.SetDecisionIconTextShown(true)
            elseif rest == "text off" and ns.SetDecisionIconTextShown then
                ns.SetDecisionIconTextShown(false)
            elseif rest == "lock on" and ns.SetDecisionIconLocked then
                ns.SetDecisionIconLocked(true)
            elseif rest == "lock off" and ns.SetDecisionIconLocked then
                ns.SetDecisionIconLocked(false)
            elseif rest:match("^size%s+") and ns.SetDecisionIconSizePreset then
                local preset = rest:gsub("^size%s+", "")
                ns.SetDecisionIconSizePreset(preset)
            else
                ns.ToggleDecisionIcon()
            end
            local textFlag = ns.IsDecisionIconTextShown and ns.IsDecisionIconTextShown() and "开" or "关"
            local lockFlag = ns.IsDecisionIconLocked and ns.IsDecisionIconLocked() and "开" or "关"
            local sizeLabel = ns.GetDecisionIconSizePresetLabel and ns.GetDecisionIconSizePresetLabel() or "标准"
            ns.Print("图标: " .. (ns.IsDecisionIconShown() and "开启" or "关闭") .. "，文字: " .. textFlag .. "，锁定: " .. lockFlag .. "，尺寸: " .. sizeLabel)
        elseif cmd == "horizon" then
            local ms = tonumber(rest)
            if not ms then
                ns.Print("用法: /fury horizon 400")
                return
            end
            if ns.SetDecisionHorizonMs and ns.GetDecisionHorizonMs then
                ns.SetDecisionHorizonMs(ms)
                ns.Print("已设置预测窗口: " .. tostring(ns.GetDecisionHorizonMs()) .. "ms")
            else
                ns.Print("决策模块未就绪，请 /reload 后重试。")
            end
        elseif cmd == "mode" then
            local m = rest
            if m ~= "auto" and m ~= "dps" and m ~= "tps" then
                local current = ns.GetDecisionModeOverride and ns.GetDecisionModeOverride() or "auto"
                ns.Print("用法: /fury mode auto|dps|tps  (当前: " .. current .. ")")
                return
            end
            if ns.SetDecisionModeOverride and ns.GetDecisionModeOverride then
                ns.SetDecisionModeOverride(m)
                ns.Print("已设置决策模式: " .. ns.GetDecisionModeOverride())
            else
                ns.Print("决策模块未就绪，请 /reload 后重试。")
            end
        elseif cmd == "habit" then
            if rest ~= "on" and rest ~= "off" then
                local current = ns.IsDecisionHabitEnabled and ns.IsDecisionHabitEnabled() and "on" or "off"
                ns.Print("用法: /fury habit on|off  (当前: " .. current .. ")")
                return
            end
            if ns.SetDecisionHabitEnabled and ns.IsDecisionHabitEnabled then
                ns.SetDecisionHabitEnabled(rest == "on")
                ns.Print("已设置连按习惯提示: " .. (ns.IsDecisionHabitEnabled() and "on" or "off"))
            else
                ns.Print("决策模块未就绪，请 /reload 后重试。")
            end
        elseif cmd == "changelog" or cmd == "log" then
            local v = rest ~= "" and rest or nil
            if ns.PrintChangelog then
                ns.PrintChangelog(v)
            else
                ns.Print("Changelog 模块未就绪，请 /reload 后重试。")
            end
        elseif cmd == "profile" then
            if rest == "reset" then
                if ns.ResetDecisionProfile then
                    ns.ResetDecisionProfile()
                    ns.Print("已清空自定义参数覆盖，恢复单一调优基线参数。")
                else
                    ns.Print("参数模块未就绪，请 /reload 后重试。")
                end
            elseif rest == "default" or rest == "latest" then
                if ns.ResetDecisionProfile then
                    ns.ResetDecisionProfile()
                    ns.Print("已不再区分 default/latest，统一恢复为单一调优基线参数。")
                else
                    ns.Print("参数模块未就绪，请 /reload 后重试。")
                end
            else
                local h = ns.GetDecisionHorizonMs and ns.GetDecisionHorizonMs() or 400
                local cfg = ns.GetDecisionConfig and ns.GetDecisionConfig() or {}
                local hamExecute = ns.IsHamstringExecutePhaseEnabled and ns.IsHamstringExecutePhaseEnabled() and "on" or "off"
                local sunderDuty = cfg.sunderDutyMode or "self_stack"
                local sunderDutyLabel = ns.GetSunderDutyModeLabel and ns.GetSunderDutyModeLabel(sunderDuty) or sunderDuty
                ns.Print("统一参数入口: modules/decision_profile.lua（可直接编辑后 /reload）")
                ns.Print(
                    "当前: baseline=tuned, horizon=" .. tostring(h)
                        .. "ms, sunderDuty=" .. sunderDuty
                        .. "(" .. sunderDutyLabel .. ")"
                        .. ", sunderHp=" .. tostring(cfg.sunderHpThreshold or 0)
                        .. ", refresh=" .. tostring(cfg.sunderRefreshSeconds or 0)
                        .. "s, stacks=" .. tostring(cfg.sunderTargetStacks or 0)
                        .. ", hamExecute=" .. hamExecute
                )
                ns.Print("命令: /fury profile reset")
            end
        else
            ns.Print("命令: /fury, /fury options, /fury minimap, /fury metrics, /fury icon [on/off|text on/off|ooc on/off|lock on/off|size compact|size standard|size large], /fury horizon 400, /fury mode auto|dps|tps, /fury habit on|off, /fury changelog [version], /fury profile [reset]")
        end
    end
end

ns.RegisterModule(SlashModule)

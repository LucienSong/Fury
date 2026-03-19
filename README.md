# Fury (WoW Classic Era AddOn)

作者：`Lucien`  
WoW Classic Hardcore Realm & ID：`@硬汉-健将`  
当前版本：`2.1`
项目地址：`https://github.com/LucienSong/Fury`

Fury 2.1 是一个面向 WoW Classic Era 的狂暴战决策辅助插件，目标是在实战中帮助你用更稳定、更可解释的优先级树逼近 DPS / TPS 最优操作。

## 核心功能

- 单主图标建议：主提示区只显示当前第一优先动作
- 完整施放时间线：显示所有成功施放技能，并保留泄怒入队状态
- DPS / TPS 硬优先级树：不再只按当前分数混排
- 泄怒建议：独立判断是否该用 `Heroic Strike` 或 `Cleave`
- DPS / TPS 模式切换：支持自动按姿态切换，也支持手动强制模式
- Debug 面板：展示优先级树、推荐理由、候选打分、淘汰原因、命中率等
- 键位提示：可为核心技能配置键位并叠加在提示图标上
- 断筋骗乱舞：在保护窗外且怒气安全时，把 `Hamstring` 纳入收益评估
- 降级决策矩阵：非 60 级、未学技能、rank 不完整时自动降级适配
- 设置分页：图标、决策、破甲、参数、键位、介绍、更新分组清晰

## 安装

将插件目录解压或复制到：

- `World of Warcraft/_classic_era_/Interface/AddOns/Fury`

进入游戏后，如果聊天框中看到：

```text
[Fury] 已加载。输入 /fury 打开设置。
```

说明插件已正常加载。

## 命令速查

| 场景 | 命令 | 说明 |
| --- | --- | --- |
| 通用入口 | `/fury` | 打开设置面板 |
| 通用入口 | `/fury options` | 打开设置面板（别名） |
| 面板开关 | `/fury metrics` | 显示/隐藏 Debug 面板 |
| 小地图图标 | `/fury minimap` | 显示/隐藏小地图图标 |
| 预测窗口 | `/fury horizon 400` | 设置决策预测窗口（`50-2000ms`） |
| 决策模式 | `/fury mode auto` | 自动按姿态切换 DPS/TPS |
| 决策模式 | `/fury mode dps` | 强制使用 DPS 导向 |
| 决策模式 | `/fury mode tps` | 强制使用 TPS/生存导向 |
| 图标总开关 | `/fury icon on` / `/fury icon off` | 开启/关闭决策提示图标 |
| 图标文字 | `/fury icon text on` / `off` | 开启/关闭图标文字 |
| 非战斗显示 | `/fury icon ooc on` / `off` | 控制脱战时是否显示图标 |
| 图标锁定 | `/fury icon lock on` / `off` | 锁定/解锁图标拖拽 |
| 图标尺寸 | `/fury icon size compact\|standard\|large` | 切换图标尺寸档位 |
| 习惯提示 | `/fury habit on` / `off` | 开启/关闭连按习惯提示 |
| 参数回退 | `/fury profile reset` | 清空自定义覆盖，恢复调优基线 |
| 更新记录 | `/fury changelog` | 查看当前版本更新内容 |
| 更新记录 | `/fury changelog 1.0` | 查看指定版本更新内容 |

## 设置页结构

- `介绍`：作者信息、插件定位、功能概览
- `图标`：小地图图标、非战斗显示、图标文字、锁定、尺寸
- `决策`：Debug 面板开关、预测窗口
- `破甲`：HP 阈值、刷新秒数、目标层数
- `参数`：恢复统一调优基线
- `键位`：配置主技能与泄怒技能键位提示
- `更新`：查看版本更新记录

## 决策概览

- `auto`：防御姿态走 `TPS_SURVIVAL`，战斗/狂暴姿态走 `DPS`
- `dps` / `tps`：通过 `/fury mode dps|tps` 手动强制
- 默认预测窗口 `400ms`，可通过 `/fury horizon <ms>` 调整
- 斩杀阶段会动态比较 `Execute` 与 `Bloodthirst`
- `Sunder Armor` 会根据目标血量、层数和剩余时间动态评估
- 单目标且条件满足时，`Hamstring` 会作为乱舞触发辅助候选参与评分
- 脱战时仅保留可预铺的 `Battle Shout`，不再显示其他战斗动作

## 文件结构

- `Fury.toc`：插件元数据与加载顺序
- `Fury.lua`：插件入口、版本信息、Changelog、生命周期
- `modules/`：功能模块
- `CHANGELOG.md`：版本更新记录

## 更新记录

- 游戏内输入 `/fury changelog`
- 或直接查看 `CHANGELOG.md`

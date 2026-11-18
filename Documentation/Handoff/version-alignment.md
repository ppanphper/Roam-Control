# 下一轮版本与功能对齐

此文件提供核查起点，不是已完成的全量差异分析，也不是已经批准的功能实施清单。

## 三条独立基线

| 基线 | 已知版本 | 用途 | 限制 |
|---|---|---|---|
| 本仓库 fork | `f6c3cc8`，Roam Control 0.9.0 Build 29 | 实际可改、可构建的项目 | 尚未编译；工程最低 iOS 27 |
| 用户可用 wloc | 1.2.1 Build 31，移除 WlocTunnel 的外部版 | iOS 26.5.2 与 LiveContainer 体验参考 | 没有对应完整源码；号码不能与上游直接排序 |
| 官方公开发行版 | 2026-11-18 查询为 0.9.9 Build 105，2026-10-20 发布 | 公开功能、更新说明的对齐参考 | 当前不公开完整应用源码；文档要求 iOS 27+ |

官方发行版信息见 [版本快照](evidence/version-baselines.json)。新会话应重新查询当时的官方 release，记录具体 tag、build、发布日期和来源；不要永远把此快照当成最新。

当前 fork 相对于 `0654d132` 只修改：`Documentation/PublicBetaRelease.md`、`LICENSE`、`LICENSE-BETA1-MIT`、`LICENSING.md`、`NOTICE`、`README.md`、`THIRD_PARTY_NOTICES.md`。历史版本已有代码与后来新增代码的许可证应分别核对，当前任务不改许可证。

## 当前源码中的明确入口

| 功能/模块 | 入口 | 当前证据 |
|---|---|---|
| 配对、导入记录、Keychain | `RoamControl/Services/Pairing/` | 源码存在；尚未在本 fork 构建/实测 |
| 外部 VPN 与位置会话 | `RoamControl/Services/Tunnel/LocalDeviceSessionCoordinator.swift` | LocalDevVPN 地址与回调逻辑已存在 |
| 连接诊断 | `RoamControl/Services/Tunnel/ConnectionDiagnosticsCoordinator.swift` | 源码存在 |
| 地图搜索与选点 | `RoamControl/Features/Map/MapViewModel.swift`、`HomeView.swift` | 已有基础流程 |
| 步行路线与控制 | `WalkingRoutePlanner.swift`、`WalkingSimulationController.swift` | 已有路线规划、暂停/继续和返回逻辑 |
| 收藏、历史、设置 | `SavedPlacesView.swift`、`Models/AppPreferences.swift` | 已有基础实现 |
| 统计 | `Services/UsageAnalyticsService.swift`、`Configuration/Local.xcconfig` | 公开默认接收配置为空，需核对私有构建配置 |
| Rust 开发服务桥接 | `Native/RoamPairingFFI/src/lib.rs` | `idevice` 固定 revision `2bc58aaea40c9ced0167c8e7b512ee13c34c760f` |

上表短文件名均位于 `RoamControl/Features/Map/`，但 `HomeView.swift` 位于 `RoamControl/Features/Home/`；后续核对时使用实际路径，不只靠关键词搜索判定缺失。

## 优先核查的候选差距

| 主题 | 对照依据 | 下一步核查 | 建议顺序 |
|---|---|---|---|
| iOS 26.5.2 构建与运行 | 已可用 wloc；本 fork deployment target=27.0 | API availability、后台任务、配对导入、原生库最低系统；不能只改版本数字 | P0 |
| LiveContainer 兼容性 | 用户已跑通的外部版 | 通知修复、后台任务标识、文件导入、Keychain、回调目标与不同客体隔离 | P0 |
| 无付费会员的完整会话 | 当前安装条件 | 外部 VPN → 导入本机配对 → 连接 → 设置/更新/恢复位置 | P0 |
| 中文与多语言 | wloc 中文界面；官方 0.9.9 宣布十种语言 | 当前硬编码文案、本地化资源、权限提示、界面切换与布局 | P1 候选 |
| 驾车/骑行、自定义速度 | 官方当前功能说明 | 当前是否只有步行；路线模型、更新节奏与速度配置差距 | P1 候选 |
| GPX 导入/导出、手绘路线、摇杆 | 官方当前 README | 逐项检查 UI/数据模型/会话支持；未完成源码审查前不写成全部确认缺失 | P1/P2 候选 |
| 会话恢复与后台限制 | 官方 0.9.9 更新说明 | 当前已有恢复能力与新版改进的具体区别；不能承诺 iOS 永不挂起 | P1 候选 |
| 收藏/历史/偏好备份与恢复 | 官方迁移文档 | 当前持久化与导出格式；迁移是否保留标识；配对记录单独处理 | P1 候选 |
| 搜索、反查、坐标兼容 | wloc 静态分析与官方地图更新说明 | 当前 MapKit 行为、国内外坐标处理、是否需要第三方回退及隐私取舍 | 待用户选择 |
| 统计与外部请求控制 | 既有隐私分析 | 当前 fork 的实际出站请求、默认关闭统计、明确功能请求的数据边界 | P1 候选 |

P0 是建议先验证的兼容基础；其余为待讨论的候选范围，不代表用户要求全部加入。

## 新会话先交付什么

1. 确认当前本地分支/工作区状态，读取本目录与仓库已有构建文档，核对远端来源。
2. 重新核实官方最新 release，并把 wloc 参考包与上游分开。
3. 输出逐项表格：功能、当前源码证据、参考版本证据、现状（已有/部分/缺失/未知）、iOS 26.5.2 风险、验证办法、建议优先级。
4. 对当前 fork 尝试构建之前先判断工具链和依赖需求；若执行构建，准确区分编译通过、模拟器 UI、实机连接和实际定位验证。
5. 提出最小实施顺序，先与用户对齐功能范围，再进入实现。用户负责手机测试；提供清晰步骤并根据回报记录结果。

不要重新从 NE 权限、购买会员或手机证书信任开始排障；不要在没有功能清单的情况下整包覆盖、升级系统或批量改造。

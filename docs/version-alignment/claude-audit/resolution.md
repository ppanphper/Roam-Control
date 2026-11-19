# Claude Code 功能对齐审计与整改结论

2026-11-18，America/Los_Angeles。目标：iPhone 13 Pro / iOS 26.5.2（23F84）/ 无付费会员 / LiveContainer + LocalDevVPN。手机由用户测试，本轮没有操作物理手机。

## 结论与交付

**已完成四轮真实 Claude Code 只读审计及整改。在已确定的公开功能对齐范围内，已发现的源码缺陷均已关闭；本地回归、Release 构建及模拟器启动流程通过。iOS 26.5.2 实际功能等价与稳定性尚待用户验收。** 这不等于保证绝无错误，也不把模拟器、传输替身或合成协议帧作为真实设备结果。

最终包为 `outputs/Roam-Control-0.9.9-Build31-2026-11-18_22-10-38.ipa`，SHA-256：`6efb93239fc96f6ca64375c35e2220471f10a25f90f77759db064710c0752eee`。这是独立身份的未签名个人开发包，不覆盖可用 wloc；交付索引见 [delivery.json](../../../outputs/delivery.json)，手机步骤见 [构建与手机验收](../build-and-device-validation.md)。

## 独立审计证据

Claude Code CLI 2.1.303，经 Node 24.22.1 启动，请求 `opus`，实际返回 `claude-opus-5-5`。只开放 Read、Glob、Grep，禁用持久会话与其他 MCP；全部六次审计正常退出、无工具权限拒绝。审计未运行测试，以下验证由主会话执行。各轮原报告保留原文，不用最终结果改写早期发现。

| 轮次 | 原始报告 | 结果及后续 |
|---|---|---|
| 1 功能/运行双路 | [feature-audit](feature-audit.md)、[runtime-audit](runtime-audit.md) | 均为“部分达成”；发现旧逻辑回退、GPX 双转换、会话/计时/协议风险；否定 Build30 的完整对齐判断 |
| 2 功能/运行双路 | [followup-feature](followup-feature.md)、[followup-runtime](followup-runtime.md) | 原指定问题源码关闭；继续发现配对副本、连续重连额度、前台计时、通知次序、恢复记录、ETA和目的地元数据问题 |
| 3 收尾专项 | [final-review](final-review.md) | 7类修复源码关闭；仍发现旧恢复记录在后续 clear-only 失败时复活的 P3 |
| 4 恢复记录专项 | [recovery-review](recovery-review.md) | P3关闭；确认未写保留旧记录、不确定写入保留新记录、clear-only不set、确认清除后忘记记录四条语义未退化；未发现新的确证源码缺陷 |

每轮元数据、prompt/report SHA-256 和受审文件摘要位于本目录。第四轮115文件在审计期间未改变。审计结束后修正 `Tests/AppModelIntegrationTests.swift` 的无序JSON字节比较；提交前仅移除 `MovementRoute.swift` 文件末尾一个空行（运行逻辑不变）并重新Release构包。最终包103项构建源文件摘要逐项匹配当前文件。

## Evidence → Finding → Path

| 发现与证据 | 修复调用链 | 验证与边界 |
|---|---|---|
| 首轮 P1-01：历史记为起点；二轮目的地地址丢失 | RoutePlanner/点绘 → MovementRoute.requestedDestination/historyDestination → AppModel 历史；运动端点仍为折线坐标 | 回归覆盖原始 POI、地址、坐标、反转/改模式/JSON；真实路线服务待手机 |
| 首轮 P1-02：到达/摇杆无法保留连接选新点 | Home New Location → MovementController.reset → continueAsFixedLocation | 恢复记录改为 fixed，设备连接保留；UI与外部地图连续性待 A04 |
| 首轮 P1-03/B1：失败后无法移除配对/重置，错误不可见 | canDiscardLocationState 统一门禁；配对页显示操作错误 | 普通失败放行；未清除责任仍阻止移除和重置；回归通过 |
| 首轮 P2-01/02/03/05/06：停止确认、地址复制、到达时刻、数字区域及显示插值缺失 | Home/MovementPanel/RouteUnits/MapPositionInterpolator | 恢复确认和复制、按语言格式化、每分钟刷新ETA、200ms显示插值；MKPolyline按ID缓存，避免逐帧遍历20k点 |
| 首轮 P2-04/R1：Force GPX往返重复转换、Apple吸附点被150m门限拒绝 | GPXService/MovementRoute来源标记/CoordinateTransform | 原复现约554.67m偏移已修；标准WGS84及旧数据兼容、改模式不丢来源；Apple路线以正常速度接驳480m案例通过 |
| 首轮 B2/B3/R2/R4/R6：外部停留超时、取消卡圈、后台phase未投递、活动重连缺失 | LocalDevVPNReturnGate/ForegroundDiscoveryBudget/RetryPolicy → AppModel事件 → MovementController | 只计前台时间，旧attempt隔离；每次独立断线两次重试，成功重置；取消后只clear；生命周期8项通过 |
| 首轮 B4/B5/R5：到期原因/进度丢失、兼容模式中途改变、坏快照丢恢复入口 | 会话冻结compatibility、系统失败保留路线、坏运动子快照降级fixed | 原因可见；恢复责任保留；AppModel回归与运动测试通过 |
| 首轮 R1：首次set/clear的DTX回复判定风险 | idevice framing/outgoing关联 → location_dtx.rs | 拒绝错误/无关回复，接受匹配void ACK和归档null；10项Rust合成帧测试；两架构原生库由当前源码重建，仍须 A01 真实协议验证 |
| 配对准备/通知/副本：首轮与二轮发现 | 准备页→有限后台lease→同步提交到期通知→回调或3秒兜底；asCopy→PairingPickerCopy.use/defer | 暂存副本成功/失败/取消清理、路径和符号链接边界通过；原文件不删；容器路径/通知送达须实机 |
| 第三轮P3：Y写入不确定后clear-only失败又读回旧X | idle/failed → retainUnconfirmedActiveRecovery 同步退役内存和磁盘旧fallback | 修复前36项中6项失败；修复后36/36；覆盖两种终态、重启、clear-only；Claude第四轮关闭 |

## 实际验证

| 检查 | 结果 | 证据 |
|---|---|---|
| 原 AppModel 集成 | 30/30 | `work/claude-audit-20261118/app-model-final.log`；生产AppModel+传输替身 |
| 审计回归 | 36/36 | `app-regressions-final.log`；错误记录回退的修复前证据为 `recovery-promotion-before.log` |
| 功能数据 | 53/53 | `feature-data-final.log` |
| 运动/GPX/坐标 | 6组+SDK类型检查通过 | `movement-final.log` |
| 运动生命周期 | 8/8+SDK类型检查 | `movement-lifecycle-final.log` |
| 地图插值 | 4组通过 | `map-interpolator-after.log`；其源码收尾阶段未变 |
| 重连/计时/配对策略 | 通过 | `runtime-policies-final.log` |
| Rust | 10/10 | `rust-after.log`；均为本地/合成协议测试，原生源码此后未变 |
| 本地化 | 10语×647键，309个编译器界面键覆盖 | `localization-compiler-final.log`；原13项动态文案测试通过 |
| Release UI全流程 | 8/8，0失败，129.513秒 | `work/ui-validation-2026-11-18_20-13-05/results.xcresult`；在最后仅AppModel恢复P3修复前执行 |
| 最终源码Release启动 | 1/1，0失败，19.492秒 | `work/ui-validation-2026-11-18_20-19-17/results.xcresult`；首次引导、配对选择器取消、退出重启与设置 |
| Device Release构包 | 通过 | `package-final.log`、最终IPA/JSON；无NE、空统计、独立标识、ZIP/权限/语言/平台/源哈希校验 |

已实际查看点绘ETA、大字体及配对选择器等截图，副本在 `outputs/audit-build31-final/`。模拟器Keychain -34018、MapKit VectorKit资源断言、CoreLocation权限和XCTest无障碍诊断不算配对通过，也没有宣称零日志错误。

原集成测试曾因两次 JSONEncoder 输出键顺序不同而失败；诊断显示 memory equal=true、bytes equal=false、decoded equal=true。已改为比较完整 SessionRecoveryRecord（所有字段及时间戳），写入前不改文件的断言仍比较实际前后字节，未删除断言或忽略数据差异。原始失败及诊断日志保留；修正后的30项集成检查另执行5次均通过。一次Release UI选择器参数写错导致xcodebuild退出70；修正目标名为RoamUITests后明确运行1项并通过，不把零测试当成功。

所有日志摘要与SHA-256见 [validation.json](validation.json)。原生重建证据见 [native-build-verification.json](native-build-verification.json)。

## 尚需用户实机验收

优先顺序：A01实际set/update/clear → A02外部停留和回跳 → A03多次断线重连/取消 → A04保留连接选新点 → A07配对导入/通知 → A08 GPX/坐标。随后完成蜂窝、锁屏、后台、中断恢复、Files与VoiceOver。设备清除确认与外部地图取得真实GPS分别记录。

官方闭源算法、像素、私有备份格式及系统时区行为不宣称等价；wloc仅有整体可用反馈，没有逐项比较通过证据。许可证保持不变，无国家安装计数、诊断上传或默认第三方搜索。固定系统/免费会员/外部VPN条件没有改变。

## 工作区状态

分支 `codex/version-alignment-20261118`；工作区 `/Volumes/Extra disk/Directories/Users/pandy/ai-code/Roam-Control-version-alignment-20261118`；起始 `main@402ff6f`，实际合并目标 `origin/main`，远程origin。审计结束时实现和本地验证完成，尚未提交；本目录closeout-check.json保留当时的检查快照。用户随后已授权仅在fork `ppanphper/Roam-Control` 创建PR、合并至main及清理，不向上游提PR。最终包、截图、审计文档及实际收尾记录保留在同级 `Roam-Control-artifacts/version-alignment-20261118`；清理前完整备份ignored证据，合并后同步主目录main。实际PR/合并结果以GitHub和该归档的closeout记录为准。

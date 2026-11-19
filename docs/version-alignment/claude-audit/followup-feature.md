# Roam Control 二轮复核（功能与运行可靠性，只读）

## 结论

本轮指定的 19 项里，**源码层面全部关闭**。修复引入了 **1 个回归（P2）**：配对文件用拷贝式选择器导入后，含私钥的副本留在 App 的 tmp 目录里，没有删除。此外还有 3 个 P3 小问题，见末尾。

还有两件事改了口径：

- 首轮报告说"没有插值"，现在不成立了：`HomeView.swift:270-279` 加了 `TimelineView` 帧级插值，`MapViewModel.swift:152-159` 按模式设定初始跟随距离。
- 首轮报告说"没有预备页和通知"，现在也不成立了：`PairingSetupView.swift:157-190` 有 "Get Settings ready" 预备页，并请求通知权限。

逐帧路径上没有对 2 万点的遍历。`MovementPath` 的查找都是二分（`MovementPhysics.swift:98-106`），`MovementSnapshot.isValid` 是 O(1)，折线按 route id 缓存（`HomeView.swift:182-183,262`），逐帧的工作只有插值和相机居中。

测试日志都是替身测试，不是实机反馈：

- `app-regressions` 修复前 0/5，修复后 **22/22**。日志里已经包含第 22 项，无需再标"待重跑"。
- `movement-lifecycle` 修复前 3/8，修复后 8/8。
- `movement`、`map-interpolator` 和 `app-model` 的 30 项全部通过。

## 逐项状态

| 编号 | 状态 | 依据（当前源码） |
|---|---|---|
| P1-01 历史记成起点 | 关闭 | `AppModel.swift:405-407` 改为写入 `route.destination`，摇杆不记历史。测试 AuditRegression:31 |
| P1-02 无法切回固定位置 | 关闭，UI 需实机确认 | 到达后、摇杆移动或暂停时有 New Location（`HomeView.swift:844-847,1182-1197`）。它调用 `movement.reset()` 和 `AppModel.continueAsFixedLocation()`（`AppModel.swift:450-458`），不 stop，恢复记录换成 fixed，之后走 `fixedControls` 的 Update 路径 |
| P1-03 / B1 失败后无法重置或移除配对 | 关闭 | 改为统一判定 `canDiscardLocationState`（`AppModel.swift:67-75`），与生产代码 `canAcknowledgeManualRestoration`（`LocalDeviceSessionCoordinator.swift:350-354`）一致。普通失败时 `restorationStatus` 为 `.notRequired`（`:179-180`），可以放行。重置有专用文案（`AppModel.swift:4-9`），移除失败在配对页显示（`PairingSetupView.swift:86-91`） |
| P2-01 停止无确认 | 关闭 | `HomeView.swift:923-936` 有确认框，路线会话会提示进度将被重置 |
| P2-02 复制地址 | 关闭 | `MovementPanel.swift:286-321` 复制可读名称和地址，分享坐标单独保留 |
| P2-03 到达时刻 | 关闭（另有 P3 见下） | `MovementPanel.swift:350-367` |
| P2-04 Force 下 GPX 双重转换 | 关闭 | 导出时加 `roam:deviceWGS84` 标记（`GPXService.swift:67`），导入后 origin 变为 `.wgs84`（`MovementRoute.swift:66,86`），反转、改模式、JSON 恢复都保留该标记。外部 GPX 仍按 Force 修正。测试 `MovementTests.swift:181-228` |
| P2-05 数字格式 | 关闭 | `FeaturePreferences.swift:14-28` 带 locale，所有调用处都传了 `l10n.locale` |
| P2-06 插值与初始距离 | 关闭，流畅度需实机确认 | `MapPositionInterpolator.swift`；`HomeView.swift:185-202,1322-1341` |
| P2-07 配对页"iOS 27"文案 | 关闭 | 全仓已没有 "iOS 27"；新文案在 `:135`，十语言都有 |
| P2-08 统计归类错误 | 关闭 | `UsageAnalyticsService.swift:16-26`。在已有固定会话上开始运动时仍记为 `activeLocationUpdated`（`AppModel.swift:489-498`），统计默认关闭，影响可忽略 |
| 功能 R1：150 m 接驳门限 | 源码关闭，需实机 | Apple 路线不再受门限限制，改为用连接段走过去（`CoordinateTransform.swift:97-105`） |
| 功能 R2 / 运行 R5：恢复记录解码过严 | 关闭 | 快照损坏时降级为 fixed，保留恢复入口（`SessionRecoveryRecord.swift:64-79`）。写入前校验 `isValid`（`AppModel.swift:411,431`） |
| 功能 R4：配对文件选择器 | 源码关闭，需 LiveContainer 实机；**修复引入回归，见下** | `PairingSetupView.swift:459-488` 改为 `asCopy` 拷贝式选择器 |
| 运行 B3：取消后停在 preparing | 关闭 | `MovementController.swift:168-170` 在 idle 时对 preparing 执行 `reset()`。HomeView 的 Cancel 走 `movement.stop`（`:938-941`） |
| 运行 B5：会话中改兼容模式会跳点 | 关闭 | 兼容模式在会话开始时冻结进恢复记录（`AppModel.swift:57-61,473-474`），会话中设置项被禁用（`MovementPreferencesView.swift:37-42`），备份恢复也受同一判定保护 |
| 运行 R2：依赖 SwiftUI onChange | 源码关闭，后台投递仍需实机 | 改为在 AppModel 层分发阶段变化（`AppModel.swift:78-84,120-124`；`MovementController.swift:255-259`）。HomeView 不再调用 `handleSessionPhase`，没有重复驱动 |

旧路径的集成也核对过：Resume Location（`HomeView.swift:663-676`）、旧步行记录重新规划（`:1365-1378`）、恢复后用 `restore` 加 `start` 重新注册观察者（`:1359-1364`）、`reset()` 后旧观察者失效（测试已覆盖），都成立。

## 剩余确证问题

### 1）P2 回归：配对文件副本留在 tmp

- **位置**：
  - `PairingSetupView.swift:466` 用 `asCopy: true`，系统会把文件拷到 `tmp/<bundle>-Inbox/`。
  - `PairingSetupView.swift:37-42` 和 `PairingService.swift:28-41` 读完以后没有删除这个副本。
  - 全仓只有 GPX 导出会清理临时文件（`GPXDocumentPicker.swift:42-45`）。
- **触发**：每次 Import Existing File 或 Replace Pairing File。
- **影响**：含私钥的 RPPairing 明文副本留在沙盒 tmp 里，直到系统清理。这与 `:284` 写的"stored only in its Keychain"不符。基线用 `fileImporter`，不会产生副本。
- **最小修复**：在 `importRecord` 读完数据后（不论成功还是失败），如果 URL 位于 `FileManager.default.temporaryDirectory` 下，就 `try? removeItem(at: url)`。或者在 Coordinator 里先读成 `Data` 再删文件，只把 `Data` 传出去。
- **验证**：导入后检查 tmp 目录下的 Inbox 为空。可以加一个替身测试，断言导入后副本 URL 已不存在。

### 2）P3：暂停或预览时"预计到达"时刻不随时间更新

- **位置**：`MovementPanel.swift:350-367` 用的是 `Date.now`，但视图没有任何依赖会随时间变化，暂停或停留在预览页时不会重算。
- **修复**：给这一行包一层 `TimelineView(.everyMinute)`。

### 3）P3：历史和 Resume 记录的是路线终点的伪地点

- **位置**：`AppModel.swift:405-406` 配合 `MovementRoute.swift:81-91`。
- **影响**：Apple 路线写进历史的是吸附到道路上的最后一个顶点，副标题是 "Route"，origin 是 `.route`，不是用户选中的原始 POI 和地址。与收藏的 id 也对不上，可能出现重复条目。偏移通常只有几十米。
- **修复**：`startMovementSession` 接收一个可选的原始目的地 `LocationTarget`，作为 `historyTarget`。

### 4）P3：GPX 导入后切换模式要重新导入

- **位置**：`HomeView.swift:168-174` 中 `replacingMode` 的分支在界面上走不到，因为预览状态下不显示模式选择器（`:685-697`）。"Edit Route" 会清掉 GPX 预览。
- **影响**：公开说明是"用所选模式使用"，先选模式再导入是满足的，所以只是体验问题。
- **修复**：在 GPX 预览里加 `MovementModePicker`。

## 需要实机确认（不是已证实的 bug）

1. 路线到达后点 New Location，再选新点并 Update，外部地图位置应连续，不出现 Restoring（P1-02）。
2. 让 LocalDevVPN 失败后，分别从设置里重置、从配对页移除配对（P1-03）。
3. 开始路线后立刻切到 Apple 地图，看位置是否推进（运行 R2）。
4. 从离路较远的模拟位置发起改向（功能 R1）。
5. 在 LiveContainer 里导入配对文件（功能 R4）。
6. 用 2 万点的 GPX 驾车，开着跟随和插值时观察是否卡顿。逐帧都会重算 Map 内容并设置相机，代价只能在实机或 Instruments 上确认。

# Roam Control 功能对齐独立审计报告（功能与旧逻辑保留专项）

## 1. 结论：部分达成

公开 0.9.9 的主要功能都已经有完整的代码链路，从界面入口一直走到模型、业务实现和持久化/设备调用：三种运动模式、自定义速度与单位、点绘/手绘、GPX、摇杆、备份、十种语言和 RTL、更新检查、本地诊断都在。运动和绘图的核心语义也做了独立实现：5Hz 推进、加减速、驾车停顿、按笔划撤销、途经点、恢复快照。这部分没有发现 P0 级的启动或运行崩溃路径。

但是在用新的 Home/Movement 替换旧的 Home/Walking 时，有三处旧逻辑被确认丢失或损坏：

1. 路线会话写入历史的是"路线起点"，不再是目的地。
2. 路线到达后、或摇杆会话进行中，无法不停止会话就切回固定位置（旧版的"New Location"入口消失）。
3. 设备会话停在 `.failed` 状态时，"重置 Roam Control"和"移除配对"会被拦截；其中"移除配对"被拦截时界面完全没有提示。

另外还有若干 P2 级的公开或旧行为缺口。因此不能认定"原有功能和相关逻辑没有遗漏"。

## 2. 证据边界

- **本次读过的源码**：`HomeView`、`MovementController`、`MovementPhysics`、`RouteDraft`、`JoystickPad`、`MovementPanel`、`GPXService`、`GPXDocumentPicker`、`CoordinateTransform`、`RoutePlanner`、`MapViewModel`、`AppModel`、`FeaturePreferences`、`BackupService`/`BackupRestoreView`、`SessionRecoveryView`、`Settings`/`Language`/`MovementPreferences`/`Updates`/`PairingSetup`/`ConnectionHealth`（局部）、`LocalDeviceSessionCoordinator`（相关段落）、`Info.plist`、测试 `AppModelIntegrationTests`/`MovementTests`（局部）。
- **对比的基线**：`baseline-402ff6f/` 下的 `HomeView`、`LocationSelectionCard`、`WalkingRoutePreviewCard`、`WalkingSimulationController`、`AppModel`，以及 tracked diff。
- **对照的公开资料**：`official-CHANGELOG.md`、`official-README.md`、`official-Documentation-UserGuide.md`。
- **全部结论都是静态源码推理。** 本次没有运行任何构建或测试，也没有设备证据，不代表实机协议、后台调度或 LiveContainer 路由已经通过。
- **对实现方文档的处理**：`implementation-status.md` 只用于定位入口，没有作为证据采信。顺带发现它写的 `JoystickControl` 并不存在，实际文件是 `Features/Movement/JoystickPad.swift`。
- **按约定不计为遗漏的范围差异**：国家安装计数、诊断上传、统计服务器、官方 iOS27 包下载、wloc 第三方搜索、闭源算法与备份格式的等价性。另外 App ID 从 `com.sean.roamcontrol` 改为 `com.ppanphper.roamcontrol` 是计划内的独立身份；而且旧基线在 iOS 26 上无法构建，不存在可迁移的旧安装数据。

## 3. 功能覆盖矩阵

| 功能 | 公开/原 fork 证据 | 当前入口 | 状态 | 缺口与验证 |
|---|---|---|---|---|
| 搜索/建议/结果清空 | 基线 HomeView:78-100；UserGuide 21-29 | `HomeView.swift:319-348`；`MapViewModel.swift:82-119,209-248` | 完整 | 无 |
| 坐标输入 | UserGuide 24 | `MapViewModel.swift:86-99,321-342`（origin=manualCoordinate） | 完整 | 无 |
| 地图点选与反查 | 基线 HomeView:64-73 | `HomeView.swift:300-313`；`MapViewModel.swift:72-80,250-319` | 完整 | 无 |
| 复制地点/地址 | 基线 `LocationSelectionCard.swift:171-180,263-280`；UserGuide 29 | `MovementPanel.swift:277-282` 改为分享坐标 | 部分 | 见 P2-02 |
| 收藏增删、改名、排序、清空 | 基线 SavedPlaces；CHANGELOG 0.9.1 | `HomeView.swift:193-211`；`AppModel.swift:114-177` | 完整 | 无 |
| 历史 30 条与"Resume" | 基线 `AppModel.swift:281-289`（历史记目的地） | `AppModel.swift:354-366,588-593`；`HomeView.swift:612-625` | 回退 | 见 P1-01 |
| 固定位置启动/更新/停止 | 基线 LocationSelectionCard | `HomeView.swift:590-610,547-553`；`AppModel.swift:328-335,430-445` | 完整 | 停止无确认，见 P2-01 |
| 三种运动模式 | CHANGELOG 118-126 | `RoutePlanner.swift:24-28`；`MovementPhysics.swift:66-96` | 完整（独立算法） | 闭源细节不承诺等价 |
| 目标速度、实时速度、单位 | CHANGELOG 0.9.9、161-169 | `MovementPanel.swift:165-240`；`MovementPreferencesView`；`FeaturePreferences.swift:4-32` | 基本完整 | 数字格式没有跟随 App 语言，见 P2-05 |
| 剩余距离/ETA/到达时刻 | 基线 `WalkingRoutePreviewCard.swift:115-143,443-451` | `MovementPanel.swift:295-327`；`MovementController.swift:53-55` | 部分 | 到达时刻消失，见 P2-03 |
| 暂停/继续 | 基线 WalkingRoutePreviewCard:222-232 | `HomeView.swift:834-840`；`MovementController.swift:100-115` | 完整 | 无 |
| 返程（Route Back） | 基线 :181-187 | `HomeView.swift:842-848`；`MovementController.swift:117-134` | 完整（运动中也可用） | 无 |
| 到达后改选固定位置（New Location） | 基线 :252-259 与 HomeView:235-239；UserGuide 99 | 无入口 | 缺失 | 见 P1-02 |
| 改向（Redirect） | README 59 | `HomeView.swift:850-853,1063-1109` | 部分 | 有 150 m 接驳门限，见风险 R1 |
| 途经点/点绘 | CHANGELOG 0.9.3 | `HomeView.swift:306-308,691-722`；`RouteDraft.swift:17-31` | 完整 | 无 |
| 手绘/按笔划撤销/双指操作 | CHANGELOG 0.9.4 | `HomeView.swift:285-299,1043-1061`；`RouteDraft.swift:34-68,71-114` | 完整 | 双指平移跟随行为见 R5 |
| 面板折叠 | CHANGELOG 0.9.4 | `HomeView.swift:496-501,557-571` | 完整 | 无 |
| GPX 文件选择导入 | CHANGELOG 151-159、0.9.6 | `HomeView.swift:677-679,220-227,1125-1145`；`GPXDocumentPicker.swift:29`（拷贝式） | 完整 | 无 |
| 从 Files 打开 GPX | CHANGELOG 0.9.5 | `Info.plist:14-28,77-100`；`AppModel.swift:553-557`；`HomeView.swift:158-163,1115-1123` | 代码完整，环境未知 | LiveContainer 下的路由见 R3 |
| GPX 导出 | CHANGELOG 157-158 | `HomeView.swift:864-867,1147-1158`；`GPXService.swift:50-69` | 部分 | Force 模式往返坐标被双重转换，见 P2-04 |
| 摇杆渐进/松手/后台 | CHANGELOG 128-136 | `HomeView.swift:743-768,772-773,172-176`；`JoystickPad.swift:23-30`；`MovementPhysics.swift:140-183` | 完整 | 摇杆中无法切回固定位置，见 P1-02 |
| 地图跟随/拖动脱离/缩放保持 | CHANGELOG 138-149 | `HomeView.swift:285-299,458-463,1210-1215` | 部分 | 没有显示插值，也没有按模式的初始距离，见 P2-06 |
| 朝北/方向保持 | 基线 HomeView:181-192 | `HomeView.swift:448-457,1199-1204`；`MapViewModel.swift:152-163` | 完整 | 无 |
| 中断恢复（固定/路线/摇杆/旧记录） | 基线 HomeView:540-575；CHANGELOG 208-214 | `HomeView.swift:1217-1259`；`AppModel.swift:386-402`；`SessionRecoveryView.swift` | 基本完整 | 解码严格可能整条丢失，见 R2 |
| 备份/恢复/首运行恢复 | CHANGELOG 0.9.4、182-189 | `BackupRestoreView.swift`；`BackupService.swift`；`OnboardingView.swift:93,103` | 完整（本 fork 格式） | 无 |
| 重置/重放引导 | UserGuide 145-152；基线 `AppModel.swift:188` | `SettingsView.swift:122-136,319-326`；`AppModel.swift:241-242` | 回退 | 见 P1-03 |
| 十语言、即时切换、RTL | CHANGELOG 0.9.9 | `RoamControlApp.swift:11-28`；`AppLanguage.swift`；`LanguagePickerView`；10 个 lproj | 基本完整 | 数字格式见 P2-05 |
| 权限文案 | — | 10 份 `InfoPlist.strings` | 完整 | 随系统语言，属预期 |
| 无障碍（大字体/VoiceOver 摇杆/减少动态效果） | README 66 | `JoystickPad.swift:65-92`；HomeView 中的 `dynamicTypeSize`/`reduceMotion` 分支 | 代码完整 | 实际可用性需手工回归 |
| 配对导入/生成/移除 | 基线 PairingSetup | `PairingSetupView.swift`；`AppModel.swift:291-322,571-586` | 部分 | 移除被拦截且无提示（P1-03）；文案矛盾（P2-07） |
| 诊断（本地预览后分享） | CHANGELOG 216-227 | `ConnectionHealthView.swift:82-127` | 完整（不上传，属范围内差异） | 无 |
| 更新（手动/自动，仅本 fork） | CHANGELOG 257-263 | `UpdatesView.swift`；`ReleaseUpdateService.swift:97-140` | 完整 | 无 |
| 时区跟随 | CHANGELOG 0.9.3 | 未找到显式实现 | 未知 | 证据不足 |

## 4. 已证实的 bug

### P1-01：路线会话把"路线起点"写进历史，Resume 指向错误位置

- **位置**：`RoamControl/App/AppModel.swift:354-366`，问题在 365 行 `historyTarget: target`。
- **调用链**：Start Route → `HomeView.swift:1083-1086` → `MovementController.swift:76`（`position = currentTarget ?? route?.start`），此时 `distanceTravelled == 0`，所以 `MovementController.swift:222` 返回 `route.start` → `MovementRoute.swift:74-76,88-91` 构造出 name="Route Start" 的 LocationTarget → `AppModel.startMovementSession` → `startLocationSession(..., historyTarget: target)` → `AppModel.swift:427` 的 `addToHistory`。
- **触发条件**：任意 Apple Maps、点绘、手绘或 GPX 路线开始；每次改向；旧步行记录恢复（`HomeView.swift:1240-1252`）。路线恢复时若位置在途中，还会写入一个"目的地名字 + 途中坐标"的条目。
- **影响**：
  - 历史里堆积"路线起点"条目，目的地不进入历史。
  - `AppModel.swift:103-106` 的 `resumeLocation` 变成路线起点，所以 `HomeView.swift:612-623` 的 "Resume Location" 会把手机固定到起点。
  - 每次改向都会额外写一条当前位置。
- **基线证据**：基线 `AppModel.swift:281-289` 的 `startWalkingLocationSession(historyTarget: destination)`；该函数现在作为死代码仍保留在当前 `AppModel.swift:337-352`。测试 `AppModelIntegrationTests.swift:71-79` 只验证了摇杆不刷历史，没有覆盖路线。
- **最小修复**：`startMovementSession` 在 `snapshot.route != nil` 时用 `snapshot.route!.destination`（最好用原始选中的目的地 LocationTarget，保留 subtitle/origin）作为 `historyTarget`；摇杆保持不记历史。
- **验证**：在 `AppModelIntegrationTests` 中，`startMovementSession(at: route.start, snapshot:)` 之后断言 `locationHistory.first?.id == route.destination.id`。修复前应失败，修复后再跑 `scripts/test-app-model.sh`。

### P1-02：路线到达后或摇杆会话中，无法不停止会话就改选固定位置

- **位置**：
  - `RoamControl/Features/Home/HomeView.swift:932`：`showsMovementControls = !isRedirecting && movement.phase != .idle`，`.arrived` 也算在内。
  - `:938-940`：`canSelectLocation` 因此为 false，搜索栏、地图点选、收藏选择全部失效。
  - `:502-508,513-519`：MapActionPicker 被隐藏。
  - `:786-798`：只剩 Reverse/Redirect；Done 仅在 `!isLocationSessionActive` 时出现。
  - `:1089-1101`：Redirect 强制进入 `.route/.appleMaps`，而且改向时 picker 依然隐藏（`:513`）。
- **触发条件**：路线进入 `.arrived`；或者摇杆会话处于 moving。
- **影响**：要换到固定点，只能先 Stop & Restore（真实位置会短暂恢复，进度也被清掉）再重新启动。旧版"保持连接、改选新位置"的语义丢失；摇杆也无法切到固定位置或路线。
- **基线证据**：
  - 基线 `WalkingRoutePreviewCard.swift:181-201,252-259` 的 New Location。
  - 基线 `HomeView.swift:235-239`：`walkingSimulation.reset()` 后回到 `LocationSelectionCard`，会话仍处于 active，可直接 Update Location。
  - UserGuide 第 99 行："New Location keeps the active connection"。
- **最小修复**：在 `.arrived` 状态（以及摇杆 moving 状态）增加 "New Location/Done" 按钮：调用 `movement.reset()`，保留设备会话，`mapAction = .fixed`，`mapModel.show(activeDisplayTarget)`。按钮只清控制器、不调用 stop。`reset()` 不会触碰设备会话，`fixedControls` 的 Update 路径已经可以复用。
- **验证**：
  - 静态：在 `MovementController` 测试中驱动到 `.arrived` 后调用 `reset()`，断言 `deviceSession.phase` 仍为 active。
  - UI：用传输替身或设备走一条短路线到达，确认能直接选新点并 Update，期间不出现 Restoring。
  - 对手机用户：到达 → New Location → 选新点 → Update，确认外部地图位置连续，没有回到真实位置。

### P1-03：会话处于 `.failed` 时，重置被拦截且报错文案错误，移除配对被静默拦截

- **位置**：
  - `RoamControl/App/AppModel.swift:241-242`：`resetApp` 要求 `deviceSession.phase == .idle`。
  - `:571-575`：`removePairingRecord` 有同样的条件，失败时只写 `interruptedSessionError`。
- **调用链**：任何普通启动失败都会走 `LocalDeviceSessionCoordinator.swift:739-756` 的 `fail()` 或 `:720-721`，结果 `phase = .failed(msg)` 并一直保持。`stop()` 在 `.failed` 时直接 return（`:307-311`）。能把状态拉回 idle 的 `reset()` 被排在 guard 之后，永远执行不到。界面上没有任何可见的 Stop 入口（`HomeView.swift:548`）。
  - 重置：`SettingsView.swift:319-326` 弹出错误，文案来自 `BackupService.swift:11`："…before restoring a backup."，与重置无关。
  - 移除配对：`PairingSetupView.swift:41-48,93-95` 不显示 `interruptedSessionError`，用户看不到任何反馈。`HomeView.swift:92-130` 的恢复浮层也只在 `interruptedSession != nil` 时出现。
- **触发条件**：例如"Install LocalDevVPN…"、发现失败，或者 UserGuide 164-170 描述的"发现的设备与配对不符"。官方排障建议正是"remove the pairing and pair again"，这一步现在走不通。
- **影响**：用户只能先找到一次能让会话进入 discovering 的操作来绕开，排障和重置路径实际上失效。
- **基线证据**：基线 `AppModel.swift:188-191` 和 `:405-407` 都无条件允许。另外当前 `restoreBackup`（`AppModel.swift:186-189`）已经对"failed 且无恢复记录"放行，三个函数口径不一致。
- **最小修复**：把两个 guard 改成与 `restoreBackup` 相同的判定：`.failed` 且 `restorationStatus` 不是 `requiresRecovery`、并且 `activeSessionRecovery`/`interruptedSession` 都为 nil 时放行。重置使用独立的错误类型和文案。在 `PairingSetupView` 中显示移除失败的原因。
- **验证**：在 `AppModelIntegrationTests` 中执行 `app.deviceSession.restorationStatus = .notRequired; app.deviceSession.emit(.failed("discovery failed"))`，然后：
  - `try await app.resetApp()` 应成功（当前会抛错）；
  - 另起一个实例调用 `await removePairingRecord()`，断言 `pairingStatus == .notPaired`（当前仍为 paired）。

### P2-01：Stop & Restore 没有二次确认

- **位置**：`HomeView.swift:547-553,859-862`。
- **触发条件**：运动中误触。按钮紧挨着 Pause（`:547`）。
- **影响**：误触会立即清除模拟位置、丢失路线进度。
- **基线证据**：基线 `WalkingRoutePreviewCard.swift:34-43,236-238` 有确认框，提示"progress will be reset"；UserGuide 第 42、94 行写明 "after confirmation"。
- **最小修复**：在 `stopButton` 外层加 `confirmationDialog`，至少覆盖 `movement.phase != .idle` 的情况。
- **验证**：在 Simulator UI 中点击 Stop，应先出现确认框。

### P2-02："复制可读地点/地址"被换成只能分享坐标

- **位置**：`MovementPanel.swift:277-282`。
- **基线证据**：基线 `LocationSelectionCard.swift:171-180,263-280`；UserGuide 第 29 行 "The copy button copies the readable place and address."。`LocationSelectionCard.swift` 仍在编译，但已经没有任何引用（grep 只命中定义本身）。
- **影响**：拿不到可读地址，只能分享经纬度。
- **最小修复**：在 `MapPlaceSummary` 中恢复复制名称/地址的按钮，或者在 ShareLink 中带上名称与地址。
- **验证**：在 Simulator 中选点 → 点复制 → 检查剪贴板内容。

### P2-03：路线预览和运动中不再显示"预计到达时刻"

- **位置**：`MovementPanel.swift:295-327`，只显示距离和时长。
- **基线证据**：基线 `WalkingRoutePreviewCard.swift:125-129,443-451` 显示 Arrive 时刻。
- **最小修复**：在 `RouteInformation` 中追加 `Date.now + duration`，并按 `l10n.locale` 格式化。
- **验证**：UI 截图对照。

### P2-04：Force 模式下 GPX 导出后再导入，坐标被转换两次

- **位置**：`GPXService.swift:59-61`，导出时写入的是设备空间坐标。导入后 `RouteSource.gpx.targetOrigin = .manualCoordinate`（`MovementRoute.swift:7`），而 `CoordinateTransform.swift:42-48` 在 Force 下对 manualCoordinate 也做修正。运动时 `AppModel.swift:381` 的 `deviceTarget` 会再修正一次。
- **触发条件**：坐标兼容选 Force，并且路线位于中国大陆范围内。
- **影响**：重新导入的 GPX 实际写入位置偏移约数百米。计划要求的"导出再读几何保持"在 Force 下不成立。测试 `MovementTests.swift:115-139` 只覆盖了 automatic。
- **最小修复**：导出时在 `<gpx>` 扩展中标记坐标为设备空间，导入时跳过修正；或者 Force 下导出源坐标，但需要与导入的口径统一。
- **验证**：在 `testRedirectCompatibility` 中加一组 Force 往返：`encode(route, .force)` → `decode` → `deviceTarget(.force)`，与原设备坐标的距离应小于 0.001 m。

### P2-05：距离/速度数字按系统区域格式化，没有跟随 App 所选语言

- **位置**：`FeaturePreferences.swift:14-25`（`Int(...)` 插值和 `.formatted(.number…)` 都没有带 locale）。对比同一界面的时长格式化 `MovementPanel.swift:315` 用的是 `l10n.locale`。
- **触发条件**：App 语言与系统区域不一致。
- **影响**：同一行里时长与距离的数字格式不一致；与 0.9.9 "locale-sensitive display" 的公开说明不完全对齐。
- **最小修复**：给 `distance`/`speed` 传入 `Locale` 参数。
- **验证**：系统设为德语、App 设为英语，查看 `1.5 km` 的显示。

### P2-06：地图标记没有插值，也没有按模式的初始跟随距离

- **位置**：`HomeView.swift:269-279` 的标记位置直接取 5Hz 的 `activeDisplayTarget`；`:1210-1215` 和 `MapViewModel.swift:152-163` 沿用当前相机距离。如果刚预览过整条路线，开始后会以全路线视野跟随。全仓 grep `TimelineView|interpolat|CADisplayLink` 均无结果。
- **基线/公开证据**：CHANGELOG 140-149（显示帧级插值、各模式合理的初始跟随距离）；DESIGN.md 第 23 行同样假定存在插值。
- **最小修复**：用 `TimelineView(.animation)` 在两次写入之间做线性插值，并且只用于显示；开始运动时按模式设定初始相机距离。
- **验证**：在 Simulator 用传输替身录屏，确认标记移动是否平滑。

### P2-07：配对页说明文字与实际行为矛盾

- **位置**：`PairingSetupView.swift:214` 写着 "New on-device pairing is available on iOS 27"，而同一页 `:100-117` 在 26.x 的真机上已经开放这个按钮。
- **影响**：会误导 26.5.2 用户。
- **最小修复**：改为"需要物理 iPhone；在 iOS 26 上为实验性功能"等准确表述，并同步十种语言。

### P2-08（低影响）：运动会话的统计事件被归为"固定位置"

- **位置**：`AppModel.swift:464-466`，`.movement` 会被映射为 `.fixedLocationStarted`。
- **影响**：统计默认关闭且配置为空，实际影响很小；只有用户开启统计时类别会失真。CHANGELOG 252 有独立的 Driving/Cycling 事件。
- **最小修复**：按 `snapshot.mode`/`isJoystick` 映射到对应事件。

## 5. 未验证风险

- **R1：活动会话中预览 Apple 路线时有 150 m 接驳门限。**
  - 位置：`HomeView.swift:1065-1075` → `CoordinateTransform.swift:94`。
  - 风险：MKRoute 折线的首个顶点吸附在道路上。如果模拟位置在离路超过 150 m 的地方（公园、水面、上一条手绘或 GPX 的终点），就会报 `redirectTooFar`，路线无法开始。基线 `WalkingSimulationController.swift:135` 是直接跳到首点，没有这个限制。
  - 验证：在 Simulator 中对一个离路很远的坐标调用 `RoutePlanner.preview`，测量首个顶点与起点的距离；在手机上从大型公园中心发起改向。
- **R2：恢复记录解码过严，可能整条丢失。**
  - 位置：`MovementSnapshot.swift:46-48` 和 `MovementRoute.swift:112-128` 在校验不通过时直接抛错，`AppModel.swift:751-757` 把它吞成 nil。
  - 风险：设备可能仍处于模拟状态，但 App 已经不再提示恢复，与计划中"失败保留线索"的要求冲突。目前没有找到由 App 自身写出无效快照的路径，所以列为风险。
  - 验证：手工写入一个点数超过 20000 或 mode 不匹配的 `activeSessionRecovery` 后重启，观察 `interruptedSession` 是否为 nil；建议增加降级为 `.fixed(lastReportedLocation)` 的兜底。
- **R3：LiveContainer 下从 Files "用此应用打开" GPX。** 客体 App 的 `CFBundleDocumentTypes`（`Info.plist:14-28`）多半不会被系统注册，App 内的文件选择器才是可靠路径。需要手机验证。
- **R4：配对导入仍使用 SwiftUI `fileImporter`**（`PairingSetupView.swift:33-40`）。官方在 0.9.6 针对重签名环境把备份和 GPX 的导入换成了拷贝式选择器（CHANGELOG 72-77）。基线本来就是这样，不算回退，但在 LiveContainer 中存在"选择器不返回"的风险。
- **R5：跟随状态下的双指平移。** `MagnifyGesture` 作为 simultaneousGesture（`HomeView.swift:293-299`）可能把双指平移也当作缩放，结束后会被拉回跟随点，与官方"拖动临时脱离跟随"的描述不一致。是否会触发取决于手势识别，需要实机验证。
- **R6：后台推进。** 运动 tick 运行在主线程 Task 上（`MovementController.swift:277-295`），能否持续取决于 BGContinuedProcessing 或前台降级。`boundedElapsed` 会在挂起后限制跳变，但不会补回挂起期间应走的进度，只能由设备验收。

## 6. 证据不足或不计为缺陷

- **时区跟随**：没有找到显式实现，iOS 自身行为也未经验证，状态记为未知。
- **配对"Get Settings ready"预备页与配对超时通知**（CHANGELOG 0.9.3/0.9.5）：只有 `waitingForSettings` 阶段的说明，没有计时前的预备页，也没有本地通知。官方实现闭源，基线同样没有。
- **WalkingPace 三档预设被自定义速度取代**：自定义速度覆盖了原有能力，不计为缺陷。
- **死代码**：`LocationSelectionCard`、`WalkingRoutePreviewCard`、`WalkingSimulationController`、`WalkingRoutePlanner`、`AppModel.startWalkingLocationSession` 都已不可达。不影响运行，可在后续清理。

## 7. 建议主会话执行的验证

1. 按 P1-01 和 P1-03 的描述在 `Tests/AppModelIntegrationTests.swift` 中补断言，运行 `zsh scripts/test-app-model.sh`。预期修复前失败、修复后通过。
2. 在 `Tests/MovementTests.swift` 的 `testRedirectCompatibility` 中加入 Force 的 GPX 往返用例，运行 `zsh scripts/test-movement.sh`。
3. 在 Simulator UI（`scripts/test-ui-simulator.sh`）中检查：Stop 是否有确认框（P2-01）、复制地址（P2-02）、到达时刻（P2-03）。
4. 交给手机用户的验收补充项：
   - 路线到达后不停止会话直接改选固定点（P1-02）；
   - 结束一条路线后检查历史首项和 Resume 指向（P1-01）；
   - 故意让 LocalDevVPN 关闭导致失败，然后尝试 Settings→重置 和 Device Setup→移除配对（P1-03）；
   - 从离路较远的模拟位置发起改向（R1）；
   - 在 LiveContainer 中从 Files 打开 GPX（R3）。

在 P1-01、P1-02、P1-03 修复并验证通过之前，不建议宣称"功能对齐已完成"。

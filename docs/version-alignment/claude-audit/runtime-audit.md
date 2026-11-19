# Roam Control 启动与运行可靠性独立审计报告（只读）

## 0. 结论

**独立结论：部分达成。**

- 主体状态机已经重写，多数关键语义在源码层成立：首次写入前先落盘恢复记录、清除结果三态回传、取消后迟到回调被丢弃、BG 任务失败后降级到前台执行、clear-only 恢复、旧恢复记录可解码。
- 但源码层有 **2 个已证实的 P1 缺陷**：
  - 普通失败之后，移除配对和重置 App 都会被拦住，而且"移除配对"没有任何提示；
  - 新增的 30 秒 LocalDevVPN 返回超时，在 App 回到前台的瞬间就会触发，导致会话失败。
- 有 **1 项 P1 功能缺口**：活动会话中途断隧道后不会自动重连。这与官方 0.9.7/0.9.9 的公开说明不一致。
- 有 **1 项 P0 级未验证风险**：每次会话的首次 set 和最后的 clear 都改走了自写的 DTX 回复解析，不再使用 idevice 库方法。这一改动没有任何测试，也没有实机证据。
- 现有测试替身把异步阶段转换简化成了同步，上面的 P1-B2 和 P2-B3 这类问题因此在测试里看不出来。

**证据边界**

- 本报告只基于 Read/Glob/Grep 读源码，并与 `402ff6f` 基线、idevice `2bc58aa` 源码及官方公开 CHANGELOG 对照。
- 没有编译，没有运行测试，没有接触设备。
- 无法确认 xcframework 静态库确实由当前 `lib.rs` 构建。
- Simulator 分支在 `beginAttempt` 处直接失败（`LocalDeviceSessionCoordinator.swift:156-157`），所以发现服务、LocalDevVPN、原生会话、BG 调度在现有 UI/Simulator 测试里完全没有被执行过。
- `implementation-status.md` 的陈述没有被当作证据。

---

## 1. 已证实缺陷

### P1-B1　普通失败后无法移除配对或重置 App；移除操作静默失效（相对基线的回归）

- **位置**
  - `RoamControl/App/AppModel.swift:571-575`：`removePairingRecord` 的守卫是 `deviceSession.phase == .idle`，失败时只写入 `interruptedSessionError`。
  - `AppModel.swift:241-242`：`resetApp` 守卫相同，失败时抛出 `BackupError.sessionActive`。
  - `Services/Backup/BackupService.swift:11`：这个错误的文案是"…before restoring a backup"，与重置无关。
- **触发条件**：任何没有写过位置的失败都会让 `phase` 停在 `.failed`，直到下一次会话开始。例如：
  - 发现超时，`LocalDeviceSessionCoordinator.swift:410-422`；
  - Rust 返回"The saved pairing is no longer valid. Reset Device Setup and pair again."，`lib.rs:632-637`。
- **调用链**：`PairingSetupView.swift:93-94` → 确认对话框 `:46-47` → `removePairingRecord()` → 守卫失败 → `interruptedSessionError` 被赋值。但这个字段只在 `HomeView.swift:92-105` 的恢复浮层里显示，而浮层要求 `interruptedSession != nil`。普通失败时这个条件不成立，所以用户点了没有任何反馈。
- **其他退出路径也不可达**：`LocalDeviceSessionCoordinator.reset()`（`:326-332`）本来能把 `.failed` 转回 `.idle`，但它只在上述两个守卫通过之后才会被调用。
- **影响**：错误文案提示用户"重置并重新配对"，按提示操作却没有反应；重置 App 报出无关的错误。临时办法是重启 App（`phase` 回到 `.idle`）或者直接重新配对。
- **基线对照**：`baseline-402ff6f/RoamControl/App/AppModel.swift:188-191, 405-407` 没有这个守卫，可以直接 reset。
- **最小修复**：守卫改为"没有运行中的 worker、不忙、`restorationStatus` 不是 `requiresRecovery`/`pending`/`clearing`、`interruptedSession == nil`"，允许 `.failed` 通过。拒绝时返回专用错误，并在 PairingSetup 和 Settings 页面显示出来。
- **可执行验证**：在 `Tests/AppModelIntegrationTests.swift` 里增加用例：
  1. `app.deviceSession.emit(.failed("discovery timeout"))`；
  2. `await app.removePairingRecord()`；
  3. 断言 `pairingStatus == .notPaired`（当前会失败）；
  4. 对 `resetApp()` 同样断言不抛错。

### P1-B2　新增的 30 秒 LocalDevVPN 返回超时在 App 回到前台时立即触发，抢先让会话失败

- **位置**
  - `LocalDeviceSessionCoordinator.swift:1007-1013`：打开 LocalDevVPN 时启动 `Task.sleep(30s)`，到时如果 `phase == .openingLocalDevVPN` 就 `fail`。
  - `:274-301`：回到前台后的自动发现要先等 900 ms。
  - `:178-180`：`handleOpenURL` 只接受 `.openingLocalDevVPN` 阶段。
- **触发条件**：用户在 LocalDevVPN 里停留超过 30 秒（首次安装 VPN 配置需要确认并输密码），或者回调 scheme 回不来，用户只能手动切回 App。
- **调用链**：`openLocalDevVPNForPendingSession` → App 进入后台并被挂起，计时冻结但时钟继续走 → 回到前台时超时任务已经过期，立即执行 → 守卫条件全部成立 → `fail("LocalDevVPN did not return…")`。随后 900 ms 的发现任务和 `handleOpenURL` 都因为 phase 已经不对而退出。
- **影响**：目标环境下 LocalDevVPN 首次启用很可能直接失败。在 LiveContainer 里，客体 App 的 URL scheme 能否被路由也未经验证，这条路径的触发概率因此更高。
- **基线对照**：基线只声明了 `localDevVPNReturnTimeout`（`:75`），只在 `:145/:664/:821` 处取消，从来没有启动过。这是新引入的行为。
- **同类问题**：`mobileDataDeadline` 60 秒（`:962-969`）也是新增的，在去"设置"里关蜂窝的流程中会以同样方式触发。归为 P2。
- **最小修复**：
  - 超时处理里检查 `UIApplication.shared.applicationState == .active`，不在前台就重新计时；
  - `appDidBecomeActive` 和 `handleOpenURL` 一进来先取消超时；
  - 或者只累计前台时间。
- **可执行验证（用户实机，T03 变体）**：开始固定位置 → 自动跳到 LocalDevVPN 后等 40 秒 → 手动切回。预期：继续发现设备。当前预计：显示 "LocalDevVPN did not return…"。LiveContainer 和独立安装两种方式各测一次，并记录是否发生了自动回跳。

### P2-B3　在移动数据引导里点"取消"后，运动控制器一直停在 `.preparing`

- **位置**：`Features/Map/MovementController.swift:167-172`。`.idle` 分支只处理 `stopping`/`moving`/`paused`/`arrived`，不处理 `.preparing`。
- **调用链**：开始路线 → `.preparing`，设备进入 `.discovering` → 出现移动数据引导，点 Cancel（`HomeView.swift:76`，调用 `appModel.stopLocationSession`）→ `finishWithoutNativeWrite`（`LocalDeviceSessionCoordinator.swift:348-360`）→ `.idle` → `handleSessionPhase(.idle)` 什么也不做。
- **影响**：面板一直显示"Starting Location…"转圈，用户要再点一次 Stop & Restore 才能退出。
- **最小修复**：在 `.idle` 分支里，当 `phase == .preparing && !startInProgress` 时执行 `reset()`。
- **验证**：在 `Tests/MovementTests.swift` 里：
  1. `app.startup = .discovering`；
  2. 开始路线；
  3. `app.deviceSession.phase = .idle`；
  4. `motion.handleSessionPhase(.idle)`；
  5. 断言 `motion.phase == .idle`（当前为 `.preparing`）。

### P2-B4　BG 任务到期的原因被丢掉，运动进度无提示地被清空

- **位置**
  - `LocalDeviceSessionCoordinator.swift:727-737`：设置了 `pendingFailureMessage` 和 `cancellationRequested = true`。
  - `:720`：`!requestedStop || !confirm` 在"已请求停止"且"已确认清除"时为假，结果走 `.idle`，消息被丢弃。
  - `MovementController.swift:163-169`：`.stopping` 之后收到 `.idle` 会执行 `reset()`。
  - `AppModel.swift:608-609`：清除恢复记录。
- **影响**：iOS 结束后台任务后，路线和进度都没了，界面上也没有说明原因。真实位置已经恢复，所以不涉及安全问题。行为与基线 `:647-661` 等价（基线也是静默回到 idle），但新代码显然想报告原因，却没有生效。
- **修复**：把"由 iOS 到期触发"作为单独状态，在 idle 之后展示一次说明；运动侧保留快照，供用户选择重新开始。

### P2-B5　会话进行中修改坐标兼容模式，下一次 5Hz 写入会跳点

- **位置**
  - `AppModel.swift:381`：每次 tick 都读取当前的 `featurePreferences.compatibility`。
  - `Features/Settings/MovementPreferencesView.swift:32`：没有根据会话状态禁用这个选项。
  - `Services/Routes/CoordinateTransform.swift:42-47`。
- **影响**：在中国大陆从 Automatic 切到 Off（或反过来），设备位置会瞬间偏移几百米。`start()` 里的拼接（`joined`）也假设兼容模式不变。
- **修复**：开始会话时把兼容模式记进快照或恢复记录，会话内使用这个固定值；或者在会话活动期间禁用该选项。
- **验证**：用 AppModel 替身调用 `startMovementSession`，取一个大陆 `.map` 来源的点并 `updateMovementLocation`；把 compatibility 改为 `.off` 后再更新一次，比较两次 `lastWrittenTarget` 的距离差。

---

## 2. 未验证风险（源码推断，需要测试或实机确认）

| 编号 | 级别 | 位置 | 风险 | 依据 | 建议 |
|---|---|---|---|---|---|
| R1 | **P0** | `Native/RoamPairingFFI/src/lib.rs:919-941`（`send_location_command`）；`:898-917`；`:780-783`；`:796-808` | 首次 set、每 4 秒刷新和 stop 都依赖自写的 DTX 回复校验：头部 `[20..24] == 1`，`msg_type` 为 0，或 3 且无数据。只要 iOS 26.5.2 对这两个方法的回复类型不同（例如 type 3 带一个 null 归档对象），每次会话的首次写入都会失败。 | 基线使用 idevice 的 `LocationSimulationClient::set/clear`（`baseline lib.rs:572-604`）；库实现（`idevice/src/services/dvt/location_simulation.rs:74-110`）只读一条消息，不检查类型。Rust 测试（`lib.rs:1080-1177`）只覆盖预取消和 authTag。 | 先做实机 T03，确认首次 set 和 stop 成功；在 Debug 构建中记录前几条回复的 `msg_type` 和是否有数据；补一个基于真实抓包的解析单测。 |
| R2 | P1 | `HomeView.swift:146, 1160-1161`；`MovementController.swift:154-162` | 运动从 `.preparing` 进入 `.moving` 只靠 SwiftUI 的 `.onChange` 驱动。如果会话在 App 处于后台时才变成 `.active`（开始后马上切到地图），App 内部的 SwiftUI 是否会投递这次变化没有保证，可能导致位置一直停在起点。 | `MovementSessionDouble.swift:44` 在 `start` 内部同步变成 `.active`，异步转换从未被测试。 | 在 AppModel 或协调器层直接订阅 `onPhaseChange` 并调用 `movement.handleSessionPhase`，不再依赖视图。实机测试：开始路线后立刻切到 Apple 地图，观察 20 秒内模拟位置是否沿路线移动。 |
| R3 | P1 | `OnDevicePairingCoordinator.swift:77-80, 96-98, 109-113, 151-156`；全仓库没有 `beginBackgroundTask` | 在 LiveContainer 中，系统只看宿主的 `BGTaskSchedulerPermittedIdentifiers`，`register` 可能返回 false，于是降级到前台执行。在机配对要求用户切到"设置"输入 PIN，这时 App 会被挂起，看不到 PIN，也收不到连接。界面没有任何提示，也没有本地通知作为后备。 | 官方 `official-CHANGELOG.md:204` 依赖本地通知加 LiveContainer 的 "Fix Local Notifications"；基线在这种情况下直接报错（`baseline OnDevicePairingCoordinator.swift:95-99`）。 | 实机在 LiveContainer 中查看 Connection Health 的 executionMode，并尝试在机配对。以导入 RPPairing 文件为主路径。 |
| R4 | P1（功能缺口） | `LocalDeviceSessionCoordinator.swift:695-708`；`lib.rs:915-916, 943-951` | 只有"还没写过位置"或"clear-only"的失败才会重试（最多 2 次）。活动会话中途断隧道时，`write_location` 返回不可重试错误，直接进入 `requiresRecovery`，需要用户手动恢复。 | 官方 `official-CHANGELOG.md:17, 39, 64` 宣称在 App 可运行时会自动重连；`build-and-device-validation.md:36` 只要求保留恢复入口。 | 明确定为"本 fork 不承诺"，或者在 clear 失败且隧道仍在时重新发现、重新 set。实机测试：路线进行中关掉再打开 LocalDevVPN。 |
| R5 | P2 | `MovementSnapshot.swift:46-48`；`AppModel.swift:751-757`；`AppModel.swift:370-379, 646` | 快照解码时严格校验，失败会让整条 `SessionRecoveryRecord` 解码失败，恢复提示随之消失，而设备可能仍处于模拟状态。另外，`updateMovementLocation` 写入恢复记录前没有做 `isValid` 检查，`.active` 回调会直接把它落盘。 | 当前的生成路径会限制速度和模式，暂时找不到能产生非法快照的具体路径。 | 外层解码失败时，降级为只含 `lastReportedLocation` 的 fixed 记录。测试：写入一个速度为 999 的快照后重启，断言仍然出现恢复提示。 |
| R6 | P2 | `LocalDeviceSessionCoordinator.swift:695-706, 849-852` | 移动数据模式下，未写入前的可重试失败会走普通 `beginDiscovery`，5 秒后把引导从 `.turnOff` 换成 `.connectionHelp`。基线（`:629-630`）是重新进入移动数据引导。 | 源码对比 | 实机做移动数据场景测试。 |
| R7 | P2 | `AppModel.swift:627-647, 693-715` | 每次 5Hz tick 都会执行一次 `removeObject(priorKey)`；每 5 秒在主线程把整条路线（最多 2 万个点）编码成 JSON，写入 UserDefaults。 | 源码 | 用 2 万点的 GPX 跑驾车，用 Instruments 观察卡顿。 |

## 3. 证据不足（不判为缺陷）

- **静态库来源**：头文件三处一致（`Native/.../roam_pairing.h:90-105` 与两个 xcframework 的 Headers）。C 符号没有类型信息，如果 `.a` 是旧版本，链接仍会成功，但运行时参数会错位。建议：
  - `strings Frameworks/RoamPairingFFI.xcframework/ios-arm64/libroam_pairing_ffi.a | grep -c "LocalDevVPN interface is unavailable"`；
  - 再 grep `"did not confirm that its simulated location was cleared"`；
  - `nm -gU … | grep rc_location_session_update`。
- **LiveContainer 环境**：`roamcontrol-pandy://` 能否回跳、Keychain 是否隔离、BG `register` 的返回值都无法从源码判断。降级路径在代码里存在（`:484-531`）。
- **`10.7.1.1`/`IFF_POINTOPOINT` 接口选择**（`:1062-1092`）：依据只有交接文档 `Documentation/Handoff/runtime-and-privacy.md:19`。

## 4. 已在源码层核实成立的部分

- **FFI 签名一致**：Swift 调用与 C 头文件的参数顺序和类型逐一对应，`RCLocationClearStatus` 的取值与 Rust `repr(C)` 一致。
- **原生线程到 MainActor 的边界**：迟到结果用 `activeRunIdentifier` 丢弃（`:661-662, :677-678`）；context 只在主线程上 `destroy` 后释放；`update` 与 `destroy` 都在主线程执行，没有释放后使用的问题。
- **写前落盘**：`onLocationWriteWillBegin` 在启动 worker 前同步落盘（`:605-608`，`AppModel.swift:84-91`）。
- **清除三态**：取消时如果从未写过就是 `NotNeeded`；clear-only 预取消为 `Unconfirmed`；只有收到 clear 回复才算 `Confirmed`（`lib.rs:811-820`）。
- **准备期间取消**：`sessionPreparationToken` 加 `startGeneration` 双重防护，迟到的 Keychain 读取不会再写位置（`AppModel.swift:446-457`，`MovementController.swift:250-262`）。
- **BG 降级**：注册失败、提交抛错、3 秒内没有被系统拉起，都会转入前台执行；之后才到的 BG 回调会被 `setTaskCompleted(false)` 结束。
- **数值边界**：运动 dt 限制在 0.5 秒以内；经度会回绕；速度按模式夹紧；Rust 侧再校验一次坐标。
- **旧记录兼容**：`movement`、`origin`、`nameKey` 缺失时可以正常解码；旧 `walkingRoute` 记录走重新规划路径（`HomeView.swift:1239-1252`）。
- **备份**：journal 在启动时先于 FeaturePreferences 读取回放（`AppModel.swift:57`），导入时先校验全部内容再写入。

## 5. 主要运行状态矩阵

| 输入事件 | 前置状态 | 预期 | 实际代码 | 缺口 |
|---|---|---|---|---|
| 开始固定位置 | idle，已配对 | 落盘 → 发现 → set → active | `AppModel:404-467` → `beginAttempt` → `runNative`（写前落盘）→ 回调进入 `.active` | 依赖 R1 |
| 活动中更新位置或运动 tick | active | 写入并确认 | `rc_location_session_update` 只写互斥量就返回 `.updated`；200 ms 内由 worker 写出，失败表现为会话结束 | 语义是乐观的，没有逐次确认 |
| 从 LocalDevVPN 返回超过 30 秒 | `openingLocalDevVPN` | 继续发现 | 超时立即 fail | **P1-B2** |
| 未写入前隧道失败 | connecting | 有限重试 | 重试 2 次后 failed，保留旧恢复记录 | 移动数据场景见 R6 |
| 活动中断隧道 | active | 自动重连（官方） | failed + `requiresRecovery` | **R4** |
| Stop & Restore | active | 确认清除后回到 idle | `.stopping` → Confirmed → idle → 清除记录 | ✓ |
| Stop 时清除失败 | active | 保留恢复入口 | failed + `requiresRecovery` + `interruptedSession` | ✓ |
| 恢复真实位置 | 有 `interruptedSession` | 只做 clear | `clearOnly`，不触发 started 回调 | ✓；`AppModel:636-644`、`522-526` 成为死代码 |
| 普通失败后移除配对或重置 | failed，无恢复记录 | 允许操作 | 被拦截，移除操作无反馈 | **P1-B1** |
| 移动数据引导中取消 | 运动 `.preparing` | 运动回到 idle | 停在 preparing | **P2-B3** |
| BG 到期 | active，运动中 | 告知原因并保留进度 | 无提示地回到 idle 并 reset | **P2-B4** |
| 后台变为 active | 运动 `.preparing` | 开始 tick | 依赖视图层 onChange | **R2** |
| 运动中修改兼容模式 | moving | 不跳点 | 跳点 | **P2-B5** |
| 崩溃重启 | 已落盘 `.movement` 记录 | 提示恢复 | 解码严格，非法记录会被静默丢弃 | R5 |
| 暂停、改速、反向、到达 | moving | 立即落盘 | 状态变化时清零节流 | ✓ |

## 6. 测试替身的覆盖缺口

- **`Tests/AppModelTestRuntime.swift`**
  - `start` 内同步变成 `.active`（`:40-47`），没有 discovering/connecting 的异步过程；
  - `updateLocation` 总是触发写前回调，而生产代码只在坐标变化时触发（生产 `:203-207`）；
  - `restorationStatus` 由测试手动设置；
  - 没有重试、BG/前台模式和超时；
  - `reset()` 无条件变为 idle。
- **`Tests/MovementSessionDouble.swift:37-45`**：同步 active，掩盖了 R2 和 B3。
- **Rust**：只有 4 个 host 测试，没有覆盖 DTX 解析和 fresh-channel clear。
- **Simulator UI**：会话在 `beginAttempt` 处立即失败，设备专属分支（`#if !targetEnvironment(simulator)`：`:156-175, 227-241, 1000-1022`）从未被执行。

## 7. 建议的验证顺序（交给主会话和用户）

1. **主会话，本地**：
   - 对静态库执行第 3 节里的 `strings`/`nm` 检查；
   - 加入 B1、B3、B5、R5 四个单测（步骤见各条），确认当前失败、修复后通过。
2. **用户，实机 iPhone 13 Pro / iOS 26.5.2 / LiveContainer**，每项记录 executionMode 和外部地图里的实际位置：
   1. T03：首次 set → 更新到 B 点 → Stop，验证 R1；
   2. LocalDevVPN 停留 40 秒后再返回，验证 B2；
   3. 开始路线后立即切到 Apple 地图，验证 R2；
   4. 路线进行中关掉再打开 LocalDevVPN，验证 R4；
   5. 在机配对时查看 executionMode，验证 R3；
   6. 失败后点"移除配对"，验证 B1。

实机测试回报之前，不能声称 iOS 26.5.2 协议和容器兼容已经通过。

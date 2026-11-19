# 第二轮运行可靠性复核（只读源码）

## 结论

**本轮指定项在源码层全部关闭或已有实现。剩余确证问题 1 个 P2、2 个 P3，另有 1 处需要实机确定后果的通知次序问题。**

- **生产调用链用的就是新策略**：
  - `LocationSessionRetryPolicy.action` 在 `LocalDeviceSessionCoordinator.swift:722`，`finishMessage` 在 `:757`；
  - `ForegroundDiscoveryBudget` 在 `:1056`；
  - `LocalDevVPNReturnGate` 在 `:90/:199`。
- **测试只覆盖纯函数**：`scripts/test-runtime-policies.sh` 只编译了 policy 和 expiry 这两个纯文件。MovementLifecycle 和 AuditRegression 用的是会话替身。协调器本身仍在 `#if targetEnvironment(simulator)`（`:166`）处被短路，没有任何测试覆盖。
- **Rust 侧**：10 项测试（`lib.rs` 4 项，`location_dtx.rs` 6 项）都是合成帧（代码注释 `location_dtx.rs:264` 也这样写明），不能代表 iOS 26.5.2 的真实回复。静态库是否由当前源码构建，我无法用工具证明。

## 逐编号状态

| 编号 | 状态 | 源码依据 |
|---|---|---|
| B2：LocalDevVPN 30 秒返回超时 | **关闭**（还需实机） | 超时任务已删除（"did not return" 只剩在 Localizable 里的孤立文案）。只有回调 URL（`:188-196`）或回到前台后 900 ms（`:295-312`）才会开始发现；门控是一次性的，旧的启动 ID 无效。 |
| B2 同类：移动数据 60 秒超时 | **关闭** | 只累计前台时间：每次心跳间隔超过 2 秒就不计入，不在前台就退出；进入后台时取消，回到前台时重新计时（`:286-293, 1051-1072`）。 |
| B4：BG 到期后原因丢失、进度被清空 | **关闭**（还需实机） | `locationTaskExpired`（`:808-818`）写入 `pendingFailureMessage`，策略遇到 `forcedFailure` 直接 `.finish`，`finishMessage` 返回这条原因，最终进入 `.failed("iOS stopped…")`。运动侧经 `.stopping` 进入 `.failed`，走的是 `fail()` 而不是 `reset()`，路线和进度保留，可以重新开始。 |
| R1：自写 DTX 回复解析 | **源码层正确；协议是否匹配仍需实机** | 见下方 R1 小节。 |
| R2：phase 只靠视图驱动 | **关闭** | `AppModel.swift:120-124` 直接广播给 `observeSessionPhase`；`MovementController.swift:257` 订阅；HomeView 已不再调用。 |
| R3：LiveContainer 中在机配对 | **已实现，需实机** | BG 注册失败时降级为前台模式并申请 `beginBackgroundTask` 租约（`OnDevicePairingCoordinator.swift:188-205`），PIN 在 App 不处于前台时发本地通知（`:71-75, 293-307`）。租约约 30 秒是否够用、LiveContainer 能否送达通知，源码无法判断。 |
| R4：活动中断隧道后不重连 | **关闭**（有 P2 残留） | 传输断开时 `closed_error` 是 Socket 错误，映射为 Disconnected，属于可重试；写失败后会在新 channel 上尝试 clear，失败则状态为 Unconfirmed，策略返回 `.reconnect`，重新 set（`:730-742`）。运动侧暂停 ticks 并保留用户的暂停状态（`MovementController.swift:177-182`）。 |
| R6：移动数据模式下重试 | **关闭** | `scheduleReconnect` 在移动数据模式下回到 `enterMobileDataGuidance`（`:790-791`）；`beginStopRecovery` 保留移动数据模式标志（`:769-773`）。 |
| 功能：计时前准备页 | **关闭** | `PairingSetupView.swift:157-190` 的 "Get Settings ready"：先请求通知权限，用户点 Start 后才调用 `start()`，原生 90 秒计时这时才开始。 |
| 功能：重试 | **关闭** | 失败后按钮变为 "Try Pairing Again"（`:152-155`），重新走准备页；`start()` 会换新的 attemptID 并清掉旧通知（`:93-98`）。 |
| 功能：按阶段的到期提示 | **关闭**（通知次序见问题 3） | `PairingExpiryStage` 四个阶段各有文案；原生返回码 3 对应 `.expired`（`lib.rs:231`），在 `pairingTaskExpired`（`:389-413`）里按当前 phase 选择；`.storing` 阶段只结束任务，不判失败。 |

**专项核查**

- **取消后绝不再次 set：✓**
  - 策略里只要 `wasCancelled`，就只会返回 `.clearOnly` 或 `.finish`（`LocationSessionRetryPolicy.swift:37-42`）。
  - 重连等待期间（没有 worker）用户取消，走 `beginStopRecovery`：换新的 attemptID，转为 clear-only。
  - Rust 侧在连接期间或 make_channel 时取消会直接 `Ok(())`；循环在每次写入前都检查取消（`lib.rs:760,773,780,899-903`）。
- **过期回调或旧结果不影响新 attempt：✓**
  - 原生回调用 `activeRunIdentifier` 隔离；
  - 重连任务和两个 deadline 用 `attemptIdentifier` 隔离；
  - BG 的启动和到期回调用 `submittedTaskIdentifier` 隔离；
  - 打开 URL 失败的回调同时比对 attemptID 和 launchID。
- **旧的清除责任不会被新 attempt 的 notNeeded 冲掉：✓**
  - 只有在原本就没有未清除责任时，`beginAttempt` 才把状态重置为 notRequired（`:179`）；
  - `mayRequireRecovery` 把旧责任算进 unresolved（`:707-714`）。

## R1：DTX 回复判定

**源码层已确认**

- 外发请求的观察器只记录"非 0 channel、会话号 0、expects_reply=1"的请求，能跨分片写入保持帧边界。
- 回复必须同时满足：
  - 同一 channel；
  - 同一 identifier；
  - 会话号为 1；
  - expects_reply 为 0；
  - 没有 aux；
  - 类型 0 且无数据，或类型 3 且无数据或根对象 UID 为 0 的 `$null`（`location_dtx.rs:206-253`）。
- 类型 4 的错误、非 null 对象、无关回复都不会被当成成功；没有回复就超时，不会确认清除。
- 空 ACK 和归档 null 都能通过。
- 归档解码失败时，reader 退出，结果是 Disconnected，不会被当成成功。

**需实机**

- idevice 的 `set`/`clear` 不检查回复内容（`location_simulation.rs:79,107`），所以 Build 29 能用，并不能证明 iOS 26.5.2 的回复形态落在本实现接受的范围内。
- 如果被拒，表现是"The iPhone did not accept the selected location."。这条路径会先尝试 clear，属于安全失败。

## 剩余确证问题

**1. P2：自动重连次数按整个会话累计，不按每次断线累计**
- **位置**：`LocalDeviceSessionCoordinator.swift:174, 736, 777`（只在这三处重置或累加）；`:682-699` 的 `nativeLocationStarted` 没有清零。
- **触发**：同一个路线会话里，隧道已经两次断开并自动恢复，第三次断开时策略直接 `.finish`，进入 `requiresRecovery`，需要用户手动恢复。
- **最小修复**：在 `nativeLocationStarted` 里加 `reconnectAttemptCount = 0`。只有 set 成功后才会走到这里，所以不会引起无限重试。

**2. P3：标准发现的 30 秒超时和重连的 60 秒 deadline 不区分前台（与 B2 同类，基线已有）**
- **位置**：`:425-439`、`:799-806`，都是普通的 `Task.sleep`。
- **触发**：出现 "Still Connecting" 后，用户按提示（`MobileDataGuidanceView.swift:152`）手动切到 LocalDevVPN 查看状态，而不是点按钮；或者前台模式下重连期间离开 App。离开超过 30 秒（或 60 秒）再回来，超时会立即触发并 fail。
- **最小修复**：改用 `ForegroundDiscoveryBudget` 心跳循环，和 `armMobileDataDeadlineIfActive` 一样；或者在 `appWillResignActive` 时取消，`appDidBecomeActive` 时重新计时。

**3. 次序缺陷，后果需实机：配对到期通知在任务结束之后才发出**
- **位置**：`OnDevicePairingCoordinator.swift:403-411` 先调用 `showExpiry`，但 `PairingNotifications.swift:45-49` 只是创建一个 Task，`center.add` 还没执行。随后同步执行的 `fail()`、`finishBackgroundTask()`（`:427-439`）已经调用了 `endBackgroundTask` 或 `setTaskCompleted`，App 可能在通知真正提交前就被挂起。另外，租约的到期回调（`:190-196`）本身也没有同步结束租约。
- **最小修复**：
  - `showExpiry` 改为同步调用 `center.add(request) { … }`，在完成回调里再结束租约或 BG 任务；
  - 租约到期回调里用 `MainActor.assumeIsolated` 同步调用 `endForegroundLease()`。
- **实机验证**：在 LiveContainer 中开始配对，切到"设置"后什么也不做，等租约到期，看是否收到 "Pairing expired" 通知。

**4. P3：带着旧的未清除责任开始新会话、且新会话在写入前失败时，恢复记录的内容被换成新目标**
- **位置**：协调器 `:707-713` 保持 `didAttemptLocationWrite == true`，导致 `AppModel.swift:729-736` 用的是 `activeSessionRecovery`（新目标，实际从未写入），而不是 `recoveryBeforeAttempt`。
- **影响**：清除责任没有丢，clear-only 恢复也不依赖坐标；但恢复界面显示的"最后位置"和可续跑的快照属于新会话。
- **最小修复**：在 `.failed` 分支中，如果 `recoveryBeforeAttempt != nil`，说明新会话没有到过 `.active`，这时优先使用 `recoveryBeforeAttempt`。

## 交给用户的实机项（不是已证实的 bug）

1. **T03（R1）**：开始固定位置 → 更新到 B 点 → Stop，检查外部地图里的位置是否先后变化、最后恢复到真实位置。
2. **B2**：自动跳到 LocalDevVPN 后停留 40 秒以上再手动返回，预期继续发现设备；同时记录 LiveContainer 下是否会自动回跳。
3. **R4**：路线进行中关掉再打开 LocalDevVPN，预期面板短暂回到"准备中"，随后继续沿路线移动；用户之前的暂停状态应保持。
4. **R3**：在 LiveContainer 中查看 Connection Health 的执行模式，完成一次在机配对，检查 PIN 通知是否送达、约 30 秒租约内能否完成。
5. **R6**：在移动数据模式下开始会话，触发一次失败或重试，检查是否回到"关闭移动数据"引导。
6. **B4**：有条件时观察 BG 任务到期后，失败文案是否显示，以及路线能否重新开始。

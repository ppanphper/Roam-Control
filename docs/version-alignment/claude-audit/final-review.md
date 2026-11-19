**结论：7 项在源码层全部关闭。只发现 1 个确证的 P3 残留（第 4 项相关，只影响显示和续跑，不会丢失清除责任，也不会导致启动或运行错误）。** 配对通知能否送达、LiveContainer 下副本的落盘路径、iOS 26.5.2 的协议回复，仍需你在实机上验证。

## 逐项状态

| # | 状态 | 源码依据 |
|---|---|---|
| 1 配对副本清理 | **关闭**；LiveContainer 需实机 | 选择器的返回 URL 只在选取回调里包成 `PairingPickerCopy`（`PairingSetupView.swift:482-487`）。取消时传 nil，系统也不会生成副本。App 唯一的调用处是 `:37-42`，在 `copy.use` 里通过 `defer` 删除副本（`PairingPickerCopy.swift:11`），读取成功、抛错、`isCancelled` 提前返回三种情况都会执行。`SecurePairingService.importRecord`（`PairingService.swift:28-41`）不删任何文件。删除前的路径边界检查（`:24-33`）：<br>• 按路径组件判断前缀，`tmp-sibling` 这类同名前缀的目录不会误判；<br>• 第一级子目录名必须以 `-Inbox` 结尾，并且至少还有一层文件；<br>• 把路径换到解析后的 tmp 下，再要求 `resolvingSymlinksInPath` 结果不变，并且是普通文件。所以符号链接的文件、符号链接的 Inbox 都不会被删。<br>• `/private/var` 与 `/var` 两种写法都能覆盖。<br>测试 `LocationSessionRetryPolicyTests.swift:139-179` 覆盖了成功、失败、取消、外部文件、同级目录、tmp 下的普通文件和两种符号链接。 |
| 2 重连计数与前台计时 | **关闭** | 连续重连计数：<br>• `nativeLocationStarted` 里调用了 `retries.locationStarted()` 清零（`LocalDeviceSessionCoordinator.swift:689`）；<br>• 只有 set 成功才会走到这里，不会无限重试。<br>普通发现的 30 秒（`:429`）和重连的 60 秒（`:803`）都改用 `foregroundDeadline`（`:1063-1082`）：<br>• 不在前台、处于 `openingLocalDevVPN`、`foregroundRevision` 变了（中途有过 resign）、或两次心跳间隔超过 2 秒，这几种时间都不计入；<br>• 只在前台时才触发超时。<br>旧 attempt 的计时不会影响新请求：<br>• 发现计时在 `cleanupDiscovery` 里被取消，而所有新发现和终止路径都会先调用它；<br>• 任务在 MainActor 上唤醒后先检查 `isCancelled`；<br>• 重连 deadline 额外核对 `attemptIdentifier`，并在 `clearPendingSession`、`stop`、`nativeLocationStarted` 里取消。 |
| 3 到期通知次序 | **源码关闭；能否送达需实机** | `showExpiry` 改为同步调用 `center.add(request){…}`（`PairingNotifications.swift:51`）。<br>**正常到期**：先 `submit` 挂起提交（`OnDevicePairingCoordinator.swift:412`），`fail` 和 `finishBackgroundTask` 被 `isPending` 挡住（`:452`）；等 completion 回调或 3 秒兜底（`:415-419`）再结束任务。<br>**UIKit 租约到期**：在原回调里用 `MainActor.assumeIsolated` 同步处理（`:195-198`）；`endingLeaseImmediately` 路径不挂起提交，最后用 `defer` 立即结束租约（`:394`）。已有挂起时，因为 `expiryMessage != nil` 直接 return，`defer` 仍会立即结束租约。<br>**迟到的 completion**：同时核对 `pairingAttemptIdentifier` 和 `complete(for:)`（`:435`），旧 attempt 或已被兜底释放的回调都会被忽略。 |
| 4 WriteEvidence | **关闭**（另有一个 P3，见下） | 依据 `LocationSessionRetryPolicy.swift:56-72`。<br>Rust 侧在首次 set 之前就置 `needs_clear`（`lib.rs:783`），所以 set 超时只会得到 `Confirmed` 或 `Unconfirmed`，不会得到 `NotNeeded`（`:797-838`）。<br>• **新 attempt 写入前就失败**（`.notNeeded`）：`didAttemptWrite` 回到 false，AppModel 用 `recoveryBeforeAttempt`（`AppModel.swift:720-724`）。<br>• **同一 attempt 已写过，或 clear 未确认**：`attemptMayHaveWritten` 保留，之后重连的 `notNeeded` 不会把它冲掉，记录仍是当前目标。<br>• **set 超时但 clear 已确认**：状态为 `.deviceConfirmed`，按 `forget` 处理，结果正确。<br>两种相反的情况都有测试（`LocationSessionRetryPolicyTests.swift:40-59`）。 |
| 5 ETA 刷新 | **关闭** | 加了 `TimelineView(.everyMinute)`（`MovementPanel.swift:351-354`），暂停和预览时也会每分钟重算。 |
| 6 原始目的地 | **关闭** | Apple 路线把原始 target 作为 `requestedDestination` 传入（`RoutePlanner.swift:56`）。点选路线只在 `.points` 来源时传入（`HomeView.swift:1132`）。历史记录和 `selectedTarget` 用 `historyDestination`（`AppModel.swift:405-406`）；实际运动和恢复记录用的 `destination` 仍是折线端点（`:402`）。<br>• **反转**：反转后 `historyDestination` 是另一端的端点，与改动前一致；再反转一次恢复原 POI。<br>• **改模式**：`replacingMode` 保留原始目的地。<br>• **接驳段**：`replacingPoints` 只在终点前加一段接驳（`CoordinateTransform.swift:105`），终点不变，保留原始目的地是正确的。<br>• **JSON 兼容**：用 `decodeIfPresent` 解码，旧数据能读入；旧版本读到新数据时忽略多出的键。 |
| 7 GPX 预览切模式 | **关闭** | GPX 预览里新增了模式选择器（`HomeView.swift:686-688`）。这时 `routeSource` 一定是 `.gpx`（从"文件"打开时会在 `:1251` 设置），所以 `onChange` 走 `replacingMode` 这一支（`:169-170`），`deviceWGS84` 标记保留（`MovementRoute.swift:128`）。 |

## 确证残留（P3，真实 bug，影响很小）

**位置**：`AppModel.swift:729-736`（`.idle` 分支 `:676-681` 同理）、`:741-748`、`:533-563`。

**问题**：一次 attempt 被判为"可能已写入"，但从未到达 `.active` 就失败时，代码把 `activeSessionRecovery` 提升为 `interruptedSession`，却没有清掉 `recoveryBeforeAttempt`，留下了一份过期的旧记录。

**触发条件**：
1. 已经有一条未恢复的中断会话 X；
2. 开始新会话 Y，首次 set 超时，而且 fresh clear 也失败（`.unconfirmed`）。最终 `.failed` 时 `interruptedSession` 变为 Y，`recoveryBeforeAttempt` 仍是 X；
3. 用户点"恢复真实位置"。这是 clear-only 的新 attempt，`writeEvidence` 被重置为未写入。如果这次也失败（例如发现超时），会走 `:720` 的分支，`retainRecoveryBeforeUnwrittenAttempt` 把 `interruptedSession` 和持久化记录都换回 X。

**影响**：恢复界面显示的"最后位置"和可续跑的快照退回到 X。清除责任还在（协调器状态是 `requiresRecovery`），clear-only 也不依赖坐标，所以不会出现无法恢复或误判已恢复。

**最小修复**：在 `restoreRealLocationFromInterruptedSession` 调用 `deviceSession.restore` 之前加一行 `recoveryBeforeAttempt = nil`。或者在 `:729` 和 `:676` 这两个提升分支里，一并清掉 `recoveryBeforeAttempt`、`awaitingFirstLocationWrite`，并删除 `priorSessionRecoveryKey`。

## 需实机（不是已证实的 bug）

1. **LiveContainer 导入配对文件后，检查 Inbox 是否为空。** 如果 LiveContainer 把 `TMPDIR` 重定向到访客目录，而选择器副本落在宿主的 `tmp`，清理会因为路径不匹配而跳过，副本残留。这个方向是安全的，不会误删用户文件，但需要实际看一眼。
2. **R3 / 第 3 项：** 切到"设置"后什么也不做，等租约到期，看是否收到 "Pairing expired" 通知。`center.add` 在挂起前能否完成提交，源码无法判断。BG 任务到期回调经 `Task` 跳到 MainActor（`OnDevicePairingCoordinator.swift:232-236`），不是同步结束，影响也需要实机观察。
3. **第 2 项：** 出现 "Still Connecting" 后手动切到 LocalDevVPN，停留 40 秒以上再返回，预期不会立即失败。路线进行中断开隧道 3 次以上，预期每次都能自动恢复。
4. **原有范围不变：** R1 DTX 回复形态、B2 回跳、R4/R6/B4 等，继续按上一轮清单在 26.5.2 实机上验证。

**P3 已关闭。** 我只读了源码，没有采信实现者的结论，四条既有语义都没有退化，也没发现新的确证缺陷。

## 为什么关闭

**之前的缺陷链**：中断记录 X 还在时开始新会话 Y。`prepareRecovery` 把 `recoveryBeforeAttempt` 设为 X（`AppModel.swift:477`），首次写入回调把 X 存到持久化的 prior key（`:127-128`）。Y 失败、被提升为中断记录后，这两处 X 都没清掉。之后的 clear-only 在写入前失败，`retainRecoveryBeforeUnwrittenAttempt` 取 `recoveryBeforeAttempt ?? interruptedSession`（`:747`），又换回了 X。

**现在**：两个提升分支都改走 `retainUnconfirmedActiveRecovery()`：
- `.idle` 分支在 `:677`；
- `.failed` 分支在 `:726-727`。

这个函数在 `:738-740` 清掉 `recoveryBeforeAttempt` 和 `awaitingFirstLocationWrite`，删除 prior key，再把 Y 写入 active key（`:741-742`）。之后 clear-only 失败时，`:747` 只能取到 Y。

**真实协调器的路径也成立：**
- `restore` 经 `beginAttempt` 重置写入证据（`LocalDeviceSessionCoordinator.swift:166`）。
- clear-only 不调用 `beginWorker`，也不触发写入回调（`:626-627`）。所以在发现阶段失败时 `didAttemptLocationWrite == false`，一定进入 `:717` 分支。这正是 P3 的触发路径，已经修住。
- clear-only 到达 `.active` 后再失败时，证据会被 `startedLocation` 置为 true（`:687`），改走 `:722` 或 `:677` 分支。此时 `:687-690` 已经清过过期的 X，`interruptedSession` 不变。

**有没有漏网的情况：**
- `retainUnconfirmedActiveRecovery` 在 `activeSessionRecovery == nil` 时会提前返回，不清 `recoveryBeforeAttempt`。但 `prepareRecovery` 总是同时设置这两个变量，`forget` 和 `retainRecoveryBeforeUnwrittenAttempt` 也总是同时清掉它们，所以不存在"X 还在、active 却为空"的状态。
- `clearActiveSessionRecovery`（`:798`）没有任何调用者，不会制造这种状态。
- 只要 `interruptedSession` 非空，`activeSessionRecovery` 不是空就是同一条记录。所以 `:677` 在恢复过程中走到时，不会换成别的记录。

**重启路径**：启动时先读 active key，再读 prior key（`:820-825`）。提升时 prior key 已删，active key 是 Y，重启后不会读回 X。

## 关联语义（均未退化）

| 语义 | 依据 |
|---|---|
| 新尝试确证未写，保留 X | `.notNeeded` 让 `didAttemptWrite` 回到 false（`LocationSessionRetryPolicy.swift:70`），走 `:672` 或 `:717` 分支，用 `recoveryBeforeAttempt` 恢复 X。这条路径没有被改动。 |
| 新 set 不确定，保留 Y | `:677`、`:727` 提升 Y 并持久化。下一次尝试 Z 时，`:477` 取到的是 Y，不是 X。 |
| clear-only 绝不 set | `restore` 传 `clearOnly: true`（`:160-161`），worker 用 clear-only 标志运行（`:660`），重连也保持 `clearOnly`（`:774`）。修复没有碰这些路径。测试检查了 `restoreOnlyRequests == 1` 且 `lastWrittenTarget == nil`。 |
| 真实确认 clear 后忘记恢复 | `:662-671`、`:712-715` 的 `.deviceConfirmed` 判断仍然排在最前，调用 `forgetSessionRecovery`。 |

## 测试

我没有运行测试，36/36 是你提供的结果。

`AuditRegressionTests.swift:142-167` 对 `.failed` 和 `.idle` 两种终态，各检查了 4 件事：
- prior key 已被清掉；
- clear-only 失败后仍保留 Y；
- 重启后仍是 Y；
- 只发了 clear-only 请求。

测试替身的 `restore` 会把 `didAttemptLocationWrite` 重置为 false（`AppModelTestRuntime.swift:48-49`），和真实协调器 `:166` 一致。所以测试走的正是 `:717` 分支，修复前确实会失败，修复前日志里有失败项也说得通。

有一点局限：写入证据是测试里手动赋值的（`:151`），不是真实协调器算出来的。真实协调器那一段我是靠读 `:626-631` 和 `:705-716` 推断的。

## 源码层结论

P3 已关闭。功能完整性和启动、运行稳定性都没有新的源码问题，不需要再修。

## 需实机验证（不算源码缺陷）

范围和上一轮 `final-review.md` 相同：
- LiveContainer 导入配对文件后，Inbox 副本是否清掉；
- 租约到期时能否收到 "Pairing expired" 通知；
- 在 LocalDevVPN 停留 40 秒以上返回、隧道多次断开时，前台计时和自动重连是否正常；
- R1、B2、R4、R6、B4 在 iOS 26.5.2 上的协议行为。

另外，P3 这条路径（首次 set 超时，而且 fresh clear 也未确认）在真机上很难自然触发，属于低频路径，不必专门复现。

请先阅读 `Documentation/Handoff/README.md`、`docs/version-alignment/implementation-status.md`、`docs/version-alignment/build-and-device-validation.md` 和 `DESIGN.md`。

用户已经授权从版本差距审查推进到完整功能对齐，并指定 gpt-6.2-sol 并发编码；不要再次询问是否开始实施。原始审查快照是 `docs/version-alignment/2026-11-18-version-and-feature-alignment.md`，其中“尚未实现/只做P0”等文字仅代表扩大授权前的历史阶段。

主工作区是 `~/ai-code/Roam-Control`，本次实现位于同级 `Roam-Control-version-alignment-20261118`，分支 `codex/version-alignment-20261118`。起始基准为 `main@402ff6f`，实际合并目标 `origin/main`，远程 origin。用户已授权仅向自己的fork提交PR、合并及清理；先核对实际Git/PR状态和工作区是否存在。合并后的代码使用主目录main，不重建已清理的任务分支。未获操作手机授权。

固定目标：iPhone 13 Pro / iOS 26.5.2（23F84）/ 无付费 Apple 开发者会员 / LiveContainer + LocalDevVPN。保留已可用的 wloc 1.2.1 Build31 外部版；本次 App ID 是 `com.ppanphper.roamcontrol`、显示名 `Roam Control Dev`、回调 `roamcontrol-pandy`，不替换参考安装。手机测试由用户完成。

三个版本基线不能混淆：原 fork 是 0.9.0 Build29；用户可用参考包是 wloc 1.2.1 Build31；2026-11-18 重新确认的官方最新是 0.9.9 Build105（2026-10-20 发布），新版完整源码没有公开。以后需要最新信息时再次查询。完整对齐基于公开用户功能独立实现，不承诺闭源算法、像素或备份格式完全相同。

交付状态、实际构建结果、包名与哈希以 implementation-status 和 outputs 的清单为准。严格区分本地算法/transport double、iOS26.2模拟器、设备Release构包与用户26.5.2实机反馈。收到手机反馈后按具体测试编号定位，保留恢复失败证据，不把“设备确认清除”当成外部地图已取得真实GPS。没有用户手机结果时，不写“LiveContainer实机全通过”。

保持许可证、默认关闭统计和空配置，不增加国家安装计数/诊断上传/第三方搜索。更新只检查本 fork，不自动下载安装官方iOS27包。所有后续改动保持可验证，并按工作区规则保留或完成收尾。

用户最后要求真实Claude Code独立审计，已执行四轮（六份原文），全部确证源码发现已整改并复审关闭。先读 `docs/version-alignment/claude-audit/resolution.md`，再按需读原始feature/runtime、followup、final-review、recovery-review。不要将首轮部分达成误当当前结论，也不要把源码关闭扩写成实机通过。真实CLI模型为claude-opus-5-5。

最终IPA：`outputs/Roam-Control-0.9.9-Build31-2026-11-18_22-10-38.ipa`，SHA-256 `6efb93239fc96f6ca64375c35e2220471f10a25f90f77759db064710c0752eee`；以delivery.json核对。36项审计回归、30项AppModel、53项数据、8项生命周期、6组运动、10项Rust、本地策略均通过。Release UI全8项通过，最后仅AppModel修复后再跑1项首次启动流程。十语647键/309界面键覆盖。原生Rust未再变化，无需无故重建。所有测试有各自设备/替身边界。

本轮最后只调整测试中JSON对象无序键的字节比较：完整解码记录仍逐字段相等，写入前磁盘不变仍检查字节。证据在recovery-serialization-diagnostic.log。当前生产源码与最终包摘要一致。上面的未提交状态属于审计结束时快照；后续已授权fork内部PR合并及清理。最终包、文档与收尾记录位于同级Roam-Control-artifacts/version-alignment-20261118，实际PR/合并状态以GitHub及归档记录为准。继续首先处理用户手机反馈，未经授权不操作手机。

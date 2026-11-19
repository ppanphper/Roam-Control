# Roam Control 开发交接

更新时间：2026-11-18，America/Los_Angeles。原安装排障上下文保留在下文。**用户随后已授权完整功能对齐，并指定 gpt-6.2-sol 并发编码；当前应先读[实际实施与验证状态](../../docs/version-alignment/implementation-status.md)和[构建与手机验收](../../docs/version-alignment/build-and-device-validation.md)，不要再停留在范围选择阶段。**

开发使用同级独立工作区 `Roam-Control-version-alignment-20261118`、分支 `codex/version-alignment-20261118`，起始基准 `main@402ff6f`。用户随后已授权提交PR、合并和清理：目标仅为用户fork `ppanphper/Roam-Control:main`，不向上游提PR。手机仍由用户验收。合并后按task-done同步主工作区并清理任务资源；先核对实际Git/PR状态，不假定开发工作区仍存在。本页下方“尚未实现/未验证”描述的是迁入时快照，当前结果以上述交付记录为准。

## 当前审计交付

用户追加要求由Claude Code审计功能保留和启动/运行可靠性，已完成四轮六份原文报告。首轮“部分达成”发现均已修复；最后恢复记录P3由第四轮关闭。先读[审计整改结论](../../docs/version-alignment/claude-audit/resolution.md)和[最终验证](../../docs/version-alignment/claude-audit/validation.json)。

审计阶段交付为 `outputs/Roam-Control-0.9.9-Build31-2026-11-18_22-10-38.ipa`，SHA-256 `6efb93239fc96f6ca64375c35e2220471f10a25f90f77759db064710c0752eee`。`outputs/delivery.json`为唯一当前索引；旧候选不再交付。清理后的IPA、截图及审计文档保存在同级 `Roam-Control-artifacts/version-alignment-20261118/`，原始ignored文件由task-done完整备份；实际合并和清理结果记在该目录的closeout记录。源码与本地检查已完成，实机功能仍待用户按A01–A09验收；不能说实机已完整对齐或保证绝无错误。

## 必须先知道

- 主工作区：`~/ai-code/Roam-Control`；用户 fork：`ppanphper/Roam-Control`。迁入前 `main` / `origin/main` 均为 `f6c3cc8e921213dc098472bac3ffa5c913758055`，工作区干净。
- 当前 fork 是 Roam Control **0.9.0 Build 29** 的早期代码，不是现有 wloc 1.2.1 的完整对应源码。
- 本地比较 `0654d132..f6c3cc8` 只有 7 个文档/许可证文件变化；应用、Rust、Xcode 工程和框架目录没有变化。无需再下载或覆盖一份历史源码。
- 当前仓库 `LICENSE` 是 PolyForm Noncommercial 1.0.0；`LICENSE-BETA1-MIT` 保留历史版本许可。此前下载的 MIT 源码包是另一固定提交；不要把两者的许可证描述混用，也不要擅自替换当前许可证。
- 用户目标设备是 **iPhone 13 Pro，iOS 26.5.2（23F84）**，没有有效 Apple Developer Program 付费会员。继续采用 **LiveContainer + 外部 LocalDevVPN** 方案，不把购买会员、升级 iOS 27 或获取内置 NE 权限当作前置条件。
- 用户已经确认容器内的外部隧道版 wloc 可以正常使用。后续手机测试由用户自己做；没有重新授权前，不继续镜像/USB 手机操作。

## 已经完成

1. 定位内置隧道失败：已安装签名/profile 缺少 Network Extension 能力，系统报告权限不足；不是缺少证书信任入口，也不是配对文件能补齐的权限。
2. 从 wloc 1.2.1（31）的 IPA 仅移除 `WlocTunnel.appex`，启用主程序已经存在的 LocalDevVPN 分支；主程序和其余 19 个 ZIP 条目内容/权限未变。
3. 独立版经 SideStore 免费签名安装；修正系统“本地网络”权限后，助手验证了配对和 LocalDevVPN 可达性。
4. 将同一外部隧道版导入 LiveContainer，开启“修复本地通知”，成功进入首次运行界面。后续用户报告“已经测试可以正常使用”。
5. 已核查源码来源、关键隐私路径和版本基线。没有在这份 fork 上编译、改应用代码或运行位置测试。

## 阅读顺序

- [技术结论与验证边界](runtime-and-privacy.md)：不要重复走已经排除的签名/证书路线。
- [版本对齐起点](version-alignment.md)：三个版本基线、候选差距、下一轮输出格式。
- [资料与证据索引](artifacts.md)：包哈希、历史报告位置、已迁入的精简证据。
- [新会话提示词](next-session-prompt.md)：可直接复制到本项目下新开的会话。

## 验证口径

- **助手验证**：独立版安装、配对、外部隧道可达；容器版导入和启动到欢迎页。
- **用户确认**：容器版正常使用。没有提供逐项定位/路线/蜂窝测试记录，不把这句话扩写为所有功能全通过。
- **未验证**：本 fork 的构建、iOS 26.5.2 兼容性、路线/摇杆/GPX 等全部功能、长期后台维持、容器与独立版并存时所有回调行为。
- 原始构包 manifest 中的“尚未安装”是构包当时的状态；后来的独立版检查和用户反馈已覆盖安装可用性，不能忽略时间顺序。
- 没有执行独立版卸载；当前应用数量、VPN 状态、配对状态和手机连接情况可能已由用户改变，后续不要假定仍是排障时快照。

本次迁移仅添加交接文档和精简证据，不包含账号凭证、配对文件、私钥、原始手机日志、源码实现修改或设备操作。

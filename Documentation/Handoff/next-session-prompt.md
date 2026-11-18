请把 `~/ai-code/Roam-Control` 作为主项目，先阅读：

1. `Documentation/Handoff/README.md`
2. `Documentation/Handoff/version-alignment.md`
3. `Documentation/Handoff/runtime-and-privacy.md`
4. `Documentation/Handoff/artifacts.md`

我想先对齐当前 fork 缺少的功能，再决定自己的改造和升级范围。请把三个基线分开比较：当前仓库源码、我已在 LiveContainer 中验证可用的 wloc 1.2.1 外部 LocalDevVPN 版、你重新查询确认的 Roam Control 官方最新发行版。不要把 wloc 1.2.1 和官方 0.9.x 的版本号直接排序，也不要把当前 fork 当成 wloc 的完整对应源码。

我的目标环境是 iOS 26.5.2，没有有效 Apple 开发者付费会员，继续采用 LiveContainer + LocalDevVPN。之前的安装和权限排障已解决，不要重走购买会员、根证书信任或申请内置 Network Extension 权限的路线。手机测试由我自己做，请给我测试步骤，不要自动操作手机。

先检查仓库状态、源码、构建配置与依赖，并核实官方最新版本、发布日期、功能说明及对应源码是否公开。输出一张有证据的差异表：功能、当前实现位置、参考版本依据、已有/部分/缺失/未知、iOS 26.5.2 兼容风险、验证办法、建议优先级。

重点核对：iOS 26.5.2 与 LiveContainer 兼容、配对文件导入、设置/更新/恢复位置、中文与多语言、路线与自定义速度、GPX、摇杆、备份恢复、后台/会话恢复，以及统计和第三方搜索/反查的隐私行为。已有能力不要重复实现；搜不到关键词不能单独作为缺失证明。

先给出差距清单和最小实施顺序，与我对齐范围后再改功能。本轮不要直接升级系统、替换已可用安装包或批量补齐功能。需要修改项目文件时遵守我的 AGENTS.md，使用同级独立工作区；保留当前许可证及历史许可说明，不覆盖其他未提交改动。明确区分静态推断、编译验证和我反馈的实机结果。

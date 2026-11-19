# 完整功能对齐交付记录

> **Claude Code 四轮审计已完成，发现的源码缺陷已整改并复审关闭。** 首轮“部分达成”结论和全部原文仍保留，最终整改、验证和实机未知见[审计结论](claude-audit/resolution.md)。最终包为本 fork **0.9.9 Build31**；Build30及中间Build31候选不再作为本次交付。

2026-11-18，America/Los_Angeles。用户已从“先核对范围”扩大为完整实现，并指定 gpt-6.2-sol 并发编码。本轮按[实施计划](implementation-plan.md)和[设计文档](../../DESIGN.md)完成公开用户功能的独立实现；运行时、运动、地图、多语言和更新提示由指定模型分工编码，主会话集成、审查和验证。

**代码实现和本地验证已完成，iOS 26.5.2 + LiveContainer 实机验收待用户完成。** 审计阶段没有操作物理手机或覆盖可用wloc；随后用户已授权在自己的fork提交PR、合并及清理，上游仓库不在提交目标内。

## 版本和交付身份

| 对象 | 固定基线 | 证据与结论 |
|---|---|---|
| 原 fork | Roam Control 0.9.0 Build29，`f6c3cc8`；本轮从含交接的 `402ff6f` 开始 | 源码/原样编译证据；早期固定位置和步行能力已存在，原 iOS27 API 在本机 SDK26.2 构建失败 |
| 已可用参考包 | wloc 1.2.1 Build31 外部 LocalDevVPN 版 | 包身份/哈希已复核；用户确认 LiveContainer 整体可用，未提供逐项功能测试；不能把版本号与官方0.9.x直接排序 |
| 官方参考 | 0.9.9 Build105，2026-10-20 发布；2026-11-18 重查确认最新 | [公开发行与源码证据](evidence/version-recheck.json)；新版完整应用源码未公开，官方要求iOS27+ |
| 本次个人开发包 | Roam Control Dev 0.9.9 Build31 | 独立实现公开功能、部署下限26.0；并不是官方Build105，也不声称wloc的完整对应源码 |

[原始差异表](2026-11-18-version-and-feature-alignment.md)保留功能、当前入口、参考依据、风险、验证办法和P0/P1/P2顺序，代表实施前快照。最终实现状态如下。

## 功能覆盖

`本地通过`指算法、模拟传输、编译或明确的模拟器流程；不代表位置协议已在手机执行。全部设备定位相关功能仍需要[手机验收](build-and-device-validation.md)。

| 功能与原优先级 | 本次实现入口 | 本地验证 | 待实机/等价边界 |
|---|---|---|---|
| P0 iOS26构建、独立客体 | `Services/BackgroundTaskIdentifier`、Pairing/Tunnel、工程和Info.plist | Simulator构建、device Release归档；同步BG提交API，原生库重建 | 26.5.2容器签名、系统调度、回调仍待测 |
| P0 外部LocalDevVPN | `LocalDeviceSessionCoordinator`、`Native/RoamPairingFFI` | 框架导出/类型/包结构；只用外部通道、10.7.1.1接口选择、有限重连与前台降级 | 没有NE扩展；蜂窝/其他VPN/后台由手机实测 |
| P0 配对导入与生成 | `PairingService`、`OnDevicePairingCoordinator`、`PairingSetupView` | 公私钥一致性、32字节密钥与16字节alt_irk联验；准备页、重试/阶段超时可构建 | 真实Keychain和在机配对协议待测；已有文件导入不依赖新配对成功 |
| P0 固定位置与恢复 | `AppModel`、原生set/update/clear | transport double验证原始显示坐标、最终设备转换、清除失败保存恢复、clear-only恢复 | “设备确认清除”不等于GPS已更新；手动确认单独标记 |
| P0 会话可靠性 | 同上；`MovementSnapshot` | 准备token、取消迟到请求、无写入重试保留旧记录；写前落盘、确认后替换；暂停/改向/到达立即保存 | 进程终止、锁屏、长期后台、断网重连待测 |
| P1 收藏、历史、排序 | `SavedPlacesView`、`AppModel` | 持久化/备份核心校验；旧数据可解码 | 容器间数据不会自动迁移 |
| P1 备份恢复 | `BackupService`、`BackupRestoreView`、Onboarding | 版本化JSON、边界校验、恢复journal、非法输入不覆盖；模拟器导出入口 | 仅本fork格式；不含配对、会话、统计身份；Files实测待用户 |
| P1 十语言与RTL | `Services/Localization`、`Resources/*.lproj`、LanguagePicker | 每语647键、权限文本/占位符；系统语言/动态错误测试；中→阿→英即时切换及RTL截图 | 地点名和系统原始错误不强制翻译；设备权限弹窗遵循系统语言机制 |
| P1 自定义速度和单位 | `FeaturePreferences`、MovementPreferences、MovementPanel | 数值/范围/持久化；三模式速度控件、区域默认单位 | 目标速度与实际模拟速度区分；设备推进效果待测 |
| P1 诊断和隐私 | `ConnectionHealthView`、Privacy、Updates | 本地诊断先预览、坐标默认排除；自动更新默认关闭、仅fork只读查询 | 没有诊断上传、国家安装计数或默认第三方搜索；MapKit会联网 |
| P1 更新提示 | `ReleaseUpdateService`、`UpdateNoticeView`、Home | SemVer、draft/prerelease过滤、忽略持久化、自动横幅与手动检查区分；网络夹具验证 | 不下载或自动安装；没有本fork稳定发行时明确显示 |
| P2 三模式路线 | `RoutePlanner`、`MovementController`、`MovementPhysics` | MapKit三种transportType可编译；5Hz、加减速、转弯降速/停顿、制动、暂停/返回测试 | 路线可达性依赖Apple服务；几何停顿不是交通灯数据；ETA为估算 |
| P2 点绘、途经点、手绘 | Home、`RouteDraft` | 已选终点保持、点按/撤销/清空；模拟器一指绘制、stroke撤销和预览通过 | 双指地图操作与各地区路线需手机回归 |
| P2 GPX | `GPXService`、`GPXDocumentPicker` | 5MB/20k点边界、坐标清洗、拒绝外部实体和断开分段、读写往返；Files选择/取消UI通过 | 外部Files“用此应用打开”与LiveContainer路由待实机 |
| P2 摇杆 | `JoystickPad`、`MovementController` | 渐进速度、松手/暂停、恢复快照、历史不洪泛；界面入口通过 | 真实设备连续移动和中断待测 |
| P2 地图跟随/改向 | MapViewModel、Home、CoordinateTransform | 拖动脱离、缩放保留跟随的实现；GPX↔地图来源共同设备坐标接驳测试 | 动画流畅性及实际坐标偏差待手机对照 |
| P2 大字体/深色/折叠 | Home、MovementPanel、Settings | 实际截图及交互，短卡收起/长卡滚动、动作固定、大字体无重叠、RTL镜像 | VoiceOver实用性和Reduce Motion视觉效果仍列手工回归 |

## 实际验证

审计回归36/36、原AppModel集成30/30、功能数据53/53、运动生命周期8/8、运动/GPX/坐标6组、地图插值4组、运行策略、Rust10项均通过。十语言各647键，编译器提取309个界面键全部覆盖。原生两架构库从当前源码重建并核对FFI导出。

Release模拟器8项UI全部通过；最后一次仅AppModel恢复记录修复后，重跑相关集成/回归和Release首次启动、配对选择器取消、退出重启流程，1项通过。Device Release重新归档、打包并核对103项构建源文件摘要。算法/传输替身与合成DTX测试不等于设备通信；未签名模拟器Keychain不计为配对通过。

完整结论、原始失败与修复证据、日志路径见[审计整改](claude-audit/resolution.md)及[最终验证JSON](claude-audit/validation.json)。早期[implementation-validation.json](evidence/implementation-validation.json)仅对应Build30历史快照。截图和当前IPA保存在outputs，源代码许可证未变。

## 包和未完成的设备验收

最终包条目由构包校验后写入，见 [交付清单](../../outputs/delivery.json)。最低系统、Bundle ID、时间戳、十语言、无NE、统计空配置、ZIP/可执行权限和哈希均以该包JSON为准。

尚未确认：26.5.2实际启动/签名、LiveContainer客体隔离、Keychain导入、LocalDevVPN与native设备协议、真实GPS恢复、蜂窝/后台、第三方App位置，以及时区跟随与恢复。官方闭源算法和备份格式、wloc未逐项测试的能力不宣称完全等价。没有通过升级iOS、购买会员或申请NE权限绕开原限制。

## Git交付与产物保留

开发工作区为 `/Volumes/Extra disk/Directories/Users/pandy/ai-code/Roam-Control-version-alignment-20261118`，分支 `codex/version-alignment-20261118`，起始 `main@402ff6f`。本次变更仅通过用户fork `ppanphper/Roam-Control` 内部PR交付到 `main`（本地 `origin/main`），不向上游提交PR。用户已授权提交、合并及清理；实际PR/合并状态以GitHub记录为准。

合并后使用task-done核验并同步干净的主目录main，备份ignored文件，再清理本任务工作区和本地/远程分支。IPA、截图与审计文档的保留位置为同级 `/Volumes/Extra disk/Directories/Users/pandy/ai-code/Roam-Control-artifacts/version-alignment-20261118`；完整原始证据由该目录下ignored-backups保留，实际结果写入closeout记录。不要假定旧工作区路径在清理后仍可用。

代码实现、本地检查和审计已完成；手机验收仍待用户。提交或合并不会改变实机验证结论。

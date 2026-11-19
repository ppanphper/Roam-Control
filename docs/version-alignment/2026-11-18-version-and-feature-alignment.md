# 版本与功能对齐：先打通 iOS 26.5.2，再选择增量功能

> 本文件是实施前证据快照。用户随后已授权完整实现；当前范围与实际结果见 [实施计划](implementation-plan.md) 和 [交付记录](implementation-status.md)。下文的“只做 P0 / 尚未编译 / 无源码修改”等文字不代表本轮最终状态。

核查日期：2026-11-18，America/Los_Angeles。状态：**差距核查完成，功能范围待用户选择；未修改应用代码。**

建议第一阶段只做 P0：iOS 26 的 API/构建适配、LiveContainer 内的配对导入与会话启动、设置/更新位置、可靠停止恢复。当前 fork 已有基础定位、步行、收藏历史和中断恢复，不应重新实现。中文、备份、自定义速度属于下一阶段候选；驾车/骑行、GPX、手绘、摇杆单独选择。

## 1. 范围、基线与验证口径

授权依据为本次用户请求和 `Documentation/Handoff/` 交接要求。目标固定为 iPhone 13 Pro、iOS 26.5.2（23F84）、无有效付费 Apple Developer Program 会员、LiveContainer + LocalDevVPN。本轮网络只读取官方发布资料、Apple API 文档及交接指定的公开仓库；本地只审查项目、指定参考包和既有证据。没有操作手机、读取用户配对密钥、替换安装包或测试定位。后续手机测试由用户完成。

| 基线 | 本轮确认 | 能证明什么 | 不能据此推出什么 |
|---|---|---|---|
| 当前 fork | `ppanphper/Roam-Control`；HEAD `402ff6fb9bad17746a2a7883a944c43a5c2f4974`；应用代码仍为 `f6c3cc8` 的 **0.9.0 Build 29**；deployment target `27.0` | 这是实际可修改源码；`0654d132..f6c3cc8` 只改 7 个文档/许可文件，之后一个提交只加交接资料 | 不是 wloc 1.2.1 的完整对应源码，也没有本 fork 在 26.5.2 的可用性证明 |
| 用户可用 wloc | **1.2.1 Build 31**；外部版 SHA-256 `3c151fe6dc56005256bc12ec452e14e40d3774e57ae568a14a6fd3dfc529a267`；主程序哈希与交接一致；plist 最低 iOS `18.0`；未含 WlocTunnel，保留 Live Activity 扩展 | 包身份本轮复核；既有助手记录证明独立版配对/隧道可达、容器版导入/启动；用户报告容器版“已经测试可以正常使用” | plist 最低版本不证明全部功能兼容；没有路线、GPX、摇杆、备份、蜂窝和长期后台的逐项通过记录 |
| 官方公开最新 | **v0.9.9 / Build 105**；发布于 **2026-10-20 19:33:03 UTC（洛杉矶 12:33:03）**；tag 指向 `00d42fe69ce920bba49c8a36e8890aafd60ab069`；当前公开 main 为 `07df7c8978d137d17c90b9bbef5c2c53a858303d` | `/releases/latest` 与全部 15 条公开 release 元数据一致，未发现更新的稳定版或预发布版；官方说明 iOS 27+、LocalDevVPN、LiveContainer 通知修复 | 官方宣称功能不是本轮实测；公开 main 的完整 tree 无 Swift/Rust/Xcode 项目，README 也声明当前应用源码不公开，不能从 latest 的 Source code ZIP 获得 Build 105 完整源码 |

**三个版本号不直接排序。** wloc 的 `1.2.1` 不代表比官方 `0.9.9` 更新或能力更全。公开的 `ios151/wloc` 当前仍为 `264641e856e5006cb1219777ec5f337d55d73a0c`，包含代理脚本与 Worker，不是该 IPA 的完整 iOS 应用源码；不把它的证书/MITM 使用流程套到本项目。

证据等级：**源码**表示静态可达实现；**包声明**只表示包中声明；**官方说明**表示维护者宣称；**编译**为本轮实际命令结果；**助手历史验证/用户反馈**引用交接记录。表内“未知”保留未覆盖项，不用缺少关键词替代缺失证明。

版本元数据、查询来源及文档 SHA-256 见 [本轮版本证据](evidence/version-recheck.json)，包元数据见 [wloc 包复核](evidence/wloc-package-recheck.json)。

## 2. 构建与兼容性：已经确认的 P0 问题

本机为 Xcode **26.2（17C52）**、iPhoneOS/Simulator SDK **26.2**。实际执行了未改源码的 unsigned Debug 编译，退出码 **65**，**没有编译通过或产出可交付 IPA**：

```sh
# 从本任务独立工作区根目录执行；不覆盖 deployment target，不签名，不安装。
xcodebuild -project RoamControl.xcodeproj -scheme RoamControl \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath work/version-alignment/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

编译器在 `OnDevicePairingCoordinator.swift:114` 报 `submitTaskRequest` 已改名为 `submit(_:)`，并提示此 `await` 无异步操作；另外报告 target `27.0` 超出该 SDK 的部署版本范围。完整错误/警告摘录及原日志哈希见 [构建证据](evidence/baseline-build.txt)。编译停在首批错误处，不能声称只剩这一处问题。

这是实际的新旧 API 差异：Apple 官方资料将异步 `submitTaskRequest(_:)` 标为 **iOS 27+**；iOS 26 SDK 提供同步 throwing `submit(_:)`。源码另有同样调用 `LocalDeviceSessionCoordinator.swift:451`。降低 target 时必须处理此分支和生命周期；本轮未修改它们。[A1][A2]

`BGContinuedProcessingTask`/Request、`MKReverseGeocodingRequest`、使用到的 `MKMapItem.location/address` 在本机 SDK 标为 iOS 26，不能一概当成 iOS 27 专属而重写。**API 可用不等于调度获准**：位置会话必须完成 BG 注册、提交、收到任务回调才会进入 native session；现有代码没有直接启动前台会话的降级分支。LiveContainer 下的 bundle 标识/宿主关联因此属于启动门禁。[A3]

依赖情况：

- 已提交 `Frameworks/RoamPairingFFI.xcframework` 的 iPhone arm64 和 Simulator arm64 两个静态库及头文件；初步编译无需先重建 Rust。静态对象最低版本分别观察到 iOS 10.0/Simulator 14.0，没有观察到原生库声明 iOS 27 门槛；这不能证明协议兼容或预编译库与源码完全对应。
- `Cargo.toml`/lock 将 `idevice` 固定在 `2bc58aaea40c9ced0167c8e7b512ee13c34c760f`，不是浮动最新版。本轮没有更新依赖。
- Rust 已安装的 target 只有 `aarch64-apple-darwin` 和 `x86_64-pc-windows-msvc`；若为恢复确认修改 Rust，需补齐两个 iOS target，并核对脚本默认的 `/Applications/Xcode-beta.app` 路径。脚本在已有 xcframework 时拒绝覆盖，应在独立工作区中保留旧产物再重建。
- 本工作区没有 `Local.private.xcconfig`；公开配置未指定开发团队，两个 TelemetryDeck 配置为空。未签名构建不需要付费会员作为前置。

## 3. 功能差异表

P0 = 当前目标环境与正确性门槛；P1 = 基础链通过后优先选择的增量；P2 = 按使用需求另选。`S01` 等精确入口见下一节；`T01` 等验收见第 6 节。下表“状态”针对当前 fork。

| 功能 | 当前实现位置/状态 | wloc 1.2.1 外部版依据 | 官方 0.9.9 依据 | iOS 26.5.2 风险或差距 | 验证办法 | 优先级 |
|---|---|---|---|---|---|---|
| 系统兼容与构建 | **部分**：S01；target=27，实际编译失败 | 包最低18；用户确认26.5.2容器正常使用 | R1要求27+；R2不公开对应源码 | async BG提交API确需适配；目标版本降低本身不充分 | 本地修后重新编译；T01 | **P0** |
| LiveContainer + 外部隧道 | **已有实现/兼容未知**：S02；单主App target，无NE扩展 | 外部包身份已复核，历史连接及用户反馈成立 | R1支持容器，要求首次启动前修复本地通知 | BG任务注册/提交是会话启动门禁；同scheme回调和客体隔离待测 | T01、T03、T06 | **P0** |
| 配对文件导入 | **已有，但接受格式与会话条件有差别**：S03 | 历史独立版配对有效；容器完整导入过程未逐项记录 | R1保留配对；R3说明不随普通备份迁移 | 只校验RPPairing字段；`.plist`后缀不等于兼容lockdown plist；导入允许缺`alt_irk`，会话却要求存在 | T02：导入→重启→连接联验 | **P0** |
| 在机生成新配对 | **已有代码/目标OS未知**：S01、S03 | 本轮没有在26.5.2生成新配对的证据 | R1面向27+ | BG路径/API和协议能力均需单测；不作为已有文件导入的前置 | 文件导入先过；确有需求再测新配对 | P1候选 |
| 设置/更新固定位置 | **已有**：S04；首次set与活动会话update完整 | 用户整体可用反馈；未提供A/B点记录 | R1/R2明确保留 | native状态或UI选点不等于目标App实际接受位置 | T03 | **P0回归** |
| 停止并恢复真实位置 | **部分**：S04；有clear，但丢弃其错误 | 整体可用不证明恢复失败场景 | R4记录后续恢复确认改进 | Rust忽略clear结果；取消分支直接报成功；断隧道可能掩盖恢复失败 | T04、T06 | **P0** |
| 步行与三档速度 | **已有**：S05；1.0/1.4/1.8 m/s，暂停/继续/返回 | 逐项能力未知，不能由版本号补全 | R2/R4包含步行 | Swift路线约每秒推进；不等于后期约5Hz运动；原有能力先回归 | T05 | **P0回归** |
| 驾车/骑行/任意速度 | **部分**：步行三档已有；另外两模式及任意速度**缺失**，S05 | 未逐项核验 | R4：0.9.5三模式；R1：0.9.9自定义速度 | 当前仅MKDirections.walking；须定义模式、速度单位/范围、恢复字段与更新节奏 | T08；先选最小自定义速度 | 自定义速度P1；多模式P2候选 |
| GPX导入/导出 | **缺失**：S06 | 本轮plist声明GPX文档接收；实际解析/导出未知 | R4：0.9.5导入/导出、0.9.6文件选择器兼容改进 | 当前无可接入外部轨迹的路线模型；容器文件选择、无效坐标和分段需处理 | T09 | P2 |
| 手绘/多点路线 | **缺失**：S06 | 未核验 | R2/R4说明Manual/Freehand | 当前地图点按只选单点；不是多点编辑器 | T09 | P2 |
| 摇杆 | **缺失**：S06；可复用已有位置update FFI | 未核验 | R4说明方向输入、渐进速度、停止/恢复 | 必须增加方向到坐标的运动逻辑，处理松手、后台/中断，不能只加控件 | T10 | P2 |
| 简体中文/多语言 | **缺失应用译文**：S07；英文常量、无翻译资源 | 交接记载中文界面；本轮GPX类型名也是中文；语言切换未知 | R1：十种语言、即时切换和RTL | 权限/错误/单位/无障碍一起覆盖；不必为当前目标追十语种 | T07 | P1，先中英 |
| 收藏/历史/偏好 | **已有**：S08；历史最多30条，本地JSON持久化 | 逐项未知 | R2/R3包含 | 换App ID/客体不会自动迁移旧容器数据 | T05、T11 | P0回归 |
| 备份恢复 | **缺失可搬移备份**：S08；本地持久化不等于导出/导入 | 未核验 | R3/R4：收藏、历史、部分偏好；排除配对/会话/统计身份 | 需版本化格式、校验、失败不覆盖；与wloc备份格式兼容未知 | T11 | P1，迁移前优先 |
| 后台/中断会话恢复 | **部分**：S09；固定/步行记录已有，步行约5秒落盘并重新规划 | 长期后台/断线未知 | R1承诺运行获准时改进恢复；R4记录后台/蜂窝改进 | 未保存原路线几何/暂停进度；普通失败可清恢复记录；BG到期会取消会话 | T06 | 最小可靠性P0；强化P1 |
| 搜索/反查/坐标兼容 | **已有Apple路径；额外提供方/坐标转换能力未知或未实现**：S10 | 既有静态证据指向Worker搜索/反查；部署/完整请求未验证 | R1仅宣称坐标兼容改进，未公开算法 | 统计关闭不阻止MapKit；不能照搬未知坐标偏移修正或默认增加第三方传输 | T12；先复现具体坐标偏差 | 基线核对P0；扩展待选 |
| 匿名统计/安装计数 | **已有默认关闭与空配置**：S11；当前未见新版国家计数实现 | 旧检查时开关false、配置空；第三方地图请求另算 | R5：新版自托管可选统计，另有不受该开关控制的国家安装计数 | 不把官方新增上报当成功能缺口补齐；不将“统计关”描述成零网络 | T12；检查最终包配置 | 保持现状P0；细化控制P1候选 |

“缺失”的审查边界：已沿根 Scene、Home 全部菜单/弹层/动作、Settings、SavedPlaces、唯一文件导入、全部模型、路线规划/执行、会话 FFI、资源和工程入口检查。GPX/手绘/摇杆/备份不存在对应完整 UI→模型→执行/存储链；不是根据一次关键词搜索下结论。只判定当前 fork，不外推闭源包。

## 4. 当前源码定位与证据索引

以下路径相对于工作区根目录，行号固定在 `402ff6f`。本轮没有修改这些源文件。

| 索引 | 源码位置 | 关键观察 |
|---|---|---|
| S01 | `RoamControl.xcodeproj/project.pbxproj:144,162,181,206`；`RoamControl/Services/Pairing/OnDevicePairingCoordinator.swift:114`；`RoamControl/Services/Tunnel/LocalDeviceSessionCoordinator.swift:451` | deployment27、两处异步提交 |
| S02 | `LocalDeviceSessionCoordinator.swift:48,122,140,227,410`（同上目录）；`RoamControl/Services/BackgroundTaskIdentifier.swift:4`；`Configuration/RoamControl-Info.plist:5,28` | 外部VPN、自动返回/前台重试、BG门禁、动态标识 |
| S03 | `RoamControl/Features/Pairing/PairingSetupView.swift:32,203,213,296`；`RoamControl/Services/Pairing/PairingService.swift:20,28,69,115,123`；`Native/RoamPairingFFI/src/lib.rs:482` | 导入与Keychain；公私钥各32 bytes和identifier；alt_irk导入可省但连接必需 |
| S04 | `RoamControl/App/AppModel.swift:272,298,392`；`LocalDeviceSessionCoordinator.swift:156,258,508,592`；`Native/RoamPairingFFI/src/lib.rs:577,585,604` | set/update/clear，clear错误被忽略，取消直接idle |
| S05 | `RoamControl/Features/Map/WalkingRoutePlanner.swift:16,36`；`WalkingSimulationController.swift:6,76,101,149,231`；`WalkingRoutePreviewCard.swift:95,340`（均同一Map目录） | 仅walking；三档步速；运行中不能直接改pace |
| S06 | `RoamControl/App/RoamControlApp.swift`；`RoamControl/Features/Home/HomeView.swift:64,277`；`RoamControl/Features/Settings/SettingsView.swift`；`WalkingSimulationController.swift:76`；`RoamControl/Models/` | 根页面和功能入口完整检查；轨迹仅来自MKRoute；唯一文件导入在配对页 |
| S07 | `RoamControl.xcodeproj/project.pbxproj:93`；`RoamControl/Resources/`；Settings/Home/Pairing页面及Info.plist | en/Base，无翻译目录/strings/catalog，文案英文 |
| S08 | `RoamControl/Features/Map/SavedPlacesView.swift:16`；`RoamControl/App/AppModel.swift:98,418,507`；`RoamControl/Models/AppPreferences.swift` | 收藏历史和偏好本地保存，无可搬移格式 |
| S09 | `RoamControl/Models/SessionRecoveryRecord.swift:3`；`RoamControl/App/AppModel.swift:425,476`；`RoamControl/Features/Home/HomeView.swift:540`；`LocalDeviceSessionCoordinator.swift:647` | 中断记录、重规划、失败清记录、后台到期取消 |
| S10 | `RoamControl/Features/Map/MapViewModel.swift:49,189,229,253,286`；`WalkingRoutePlanner.swift:23` | 搜索补全、搜索、地图选点/坐标反查、路线走MapKit |
| S11 | `RoamControl/App/AppModel.swift:158,530`；`RoamControl/Services/UsageAnalyticsService.swift:45,59,64,102,146,171`；`Configuration/Local.xcconfig:3` | consent=false、ID撤销、双配置门控、有限事件载荷；未显式取消在途请求 |

`LocalDeviceSessionCoordinator.swift` 的短路径始终指向 `RoamControl/Services/Tunnel/`；Map短路径指向 `RoamControl/Features/Map/`。

| 证据 | 来源与性质 | 复核方法/限制 |
|---|---|---|
| E01 | [版本查询](evidence/version-recheck.json)：官方API、固定head文档、完整tree；网络读取 | 重查记录中的latest/release列表/固定commit URL；哈希固定本轮读取内容 |
| E02 | [包复核](evidence/wloc-package-recheck.json)：本地IPA哈希、ZIP成员与plist；REA inventory `ev_23d3cf33b257824651f6bc925a789fb1f91069beeac8ed751be9c16f75d0a99a` | 对交接指定IPA执行SHA-256并解析plist；仅包身份/声明，非运行行为 |
| E03 | [历史验证](../../Documentation/Handoff/evidence/verification.json)、[诊断](../../Documentation/Handoff/evidence/standalone-success-diagnostic.txt)、[隐私与分流记录](../../Documentation/Handoff/runtime-and-privacy.md) | 复用已有记录；本轮没有再次抓包/操作手机 |
| E04 | S01–S11：当前源码及资源/工程清单 | `git show 402ff6f:<路径>`，沿入口调用到实现；不是执行证据 |
| E05 | [实际编译](evidence/baseline-build.txt)、A1–A3、本机SDK头文件 | 按第2节命令复现；本机失败不等于所有未来SDK均失败 |

## 5. 建议实施顺序与范围选择

**建议首轮只选择 P0，不一次追平官方所有功能。**

1. **P0-A：可构建的26.5.2基线。** 适配BG提交API/availability和部署目标；复用现有静态库完成初次编译。核对实际主程序/扩展最低系统、bundle回调/BG声明；使用独立App ID和显示名以保留可用wloc。独立App ID不自动证明LiveContainer Keychain隔离。
2. **P0-B：容器内完整会话。** 优先已有RPPairing导入；对会话必需字段提供明确验证。打通手动开VPN→连接→A点→B点→恢复真实位置；验证BG门禁，失败时按证据决定是否加入前台降级。保留已有基础功能，修复恢复确认及必要的失败记录；若改Rust，同步重建原生库。
3. **P0-C：用户完成基础回归。** 执行T01–T06以及T12的基线检查；分别记录UI状态与目标App实际位置。首个可交付包须来自独立工作区Release构建，校验哈希/最低系统，保存到该工作区`outputs/`；普通编译不递增build，实际分发测试包按项目规则递增。只有实机回报后才能记为26.5.2兼容通过。
4. **P1供选择：** 先中英界面与收藏/历史/偏好备份，再最小自定义步速和恢复增强。建议保留统计默认关闭、空配置，不加入国家安装计数；地图隐私说明独立于统计开关。迁移旧数据时需用户提供不含配对秘密的实际备份样本才能承诺格式兼容。
5. **P2供选择：** 驾车/骑行、统一路线数据模型、GPX/手绘、摇杆。先确定是否需要这些能力；路线模型、速度和恢复契约统一后再添加入口，避免每个功能维护一套位置会话。

不作为本轮实施项：购买会员、升级iOS27、申请内置NE能力、替换已可用wloc、重新做已存在的配对导入/步行/收藏历史，以及默认增加第三方搜索或上报服务。新在机配对、坐标转换/第三方回退需有具体需求和复现证据后单独确定。

## 6. 交给用户的手机验收清单

这些是**未来测试步骤**，本轮未执行。P0修好并提供新测试包后再开始。保存原wloc，先用新App ID并存；一次仅运行一个位置会话。每项记录包版本/哈希、系统与容器版本、网络类型、UI结果和外部地图实际结果；诊断中不附配对私钥或真实敏感坐标。

| 测试 | 步骤 | 通过口径 |
|---|---|---|
| T01 启动/容器 | 新包导入LiveContainer，首次启动前按已验证方式开启“修复本地通知”；启动、退回容器再进 | 无崩溃；数据空间可区分；未覆盖原wloc；版本正确 |
| T02 配对导入 | 手动开LocalDevVPN；导入已有有效RPPairing；执行连接诊断；退出重开再查。另用开发方提供的无密钥无效样本测试错误提示 | 导入和会话所需字段联验；有效记录可连接且重开保留，无效记录不会覆盖可用记录。只反馈字段校验结果，不发送文件/密钥 |
| T03 A→B | Wi-Fi下选公开测试点A，开始；外部地图看实际位置；返回新包更新到B。再测试自动打开VPN回调 | A/B分别生效；UI与实际一致；自动返回正确客体，或能明确手动返回继续 |
| T04 停止恢复 | 在活动会话点击停止恢复；观察UI，再等待外部地图取得新真实位置 | 不以idle作为单一依据；恢复失败/待确认可识别，不误报成功；未完成恢复不转入下一次位置测试 |
| T05 已有能力 | 一条短步行路线依次测试三档速度、暂停/继续、返回；新建收藏、改名、删除，重开查看历史/主题 | 原有功能不回退；暂停时停止推进；收藏历史持久化；实际定位与进度一致 |
| T06 中断/后台 | 分别测试短暂切后台/锁屏、断VPN再连、终止新App后重开；记录持续时间，不预设永远后台 | 清楚区分运行/停止/恢复待处理；无假成功；恢复记录适当保留；能继续或可靠恢复真实位置。蜂窝另作一轮，不把Wi-Fi结果外推 |
| T07 中英界面（选P1后） | 切中文/英文，遍历权限、配对、错误、路线速度、恢复、无障碍标签；试大字体 | 关键文案完整、数值单位清楚，无截断/重叠；语言切换行为符合已选范围 |
| T08 速度/模式（选后） | 测边界速度、无效值、路线中切速、重开恢复；每个新增模式各一短路线 | 速度单位/限制一致；实际运动不跳变；恢复速度不丢失 |
| T09 GPX/手绘（选后） | 选本地与Files文件；有效、空文件、坏XML、越界坐标、多个track segment、缺时间戳；导出再导入 | 输入策略明确，不静默连接不相干轨迹；取消/失败不破坏当前路线；导出往返保持几何 |
| T10 摇杆（选后） | 静止、轻推、满推、松手、切后台、断VPN、停止恢复 | 松手与中断按定义停止；速度/方向连续；不把每次位置更新塞入历史 |
| T11 备份（选后） | 收藏/历史/偏好备份到Files；在另一测试客体恢复；取消、损坏/旧版本文件测试 | 数据不静默丢失/覆盖；配对、会话、统计身份不混入普通备份；实测两个客体隔离 |
| T12 隐私/坐标 | 先由开发方检查最终包统计配置；用户分别执行纯启动、地图搜索、坐标选点、路线；需要时用用户导出的App隐私报告辅助观察 | 启动统计保持约定；地图请求单独记录，不称为零网络；固定公开点在地图选点、输入坐标、外部App之间核对。域名报告不能证明完整参数或服务端保存策略 |

## 7. 关键发现与证据链

| 发现 | 结论、状态与置信度 | 证据 | 下一步 |
|---|---|---|---|
| F01 | **已确认（编译+官方API，高）**：现有源码不是可直接交付26.5.2的构建基线 | E04/S01、E05/A1–A2 | P0-A适配并重新构建；尚不承诺修后成功 |
| F02 | **已确认（静态，高）**：基础定位/步行/持久化/恢复入口已有，缺的是兼容可靠性和后期扩展 | E04/S03–S09；E01/R1、R4 | 避免重写已有功能；按P0/P1/P2选范围 |
| F03 | **已确认（源码行为，高）；实机影响未验证**：clear错误被丢弃，取消可报成功，普通失败会清恢复记录 | E04/S04、S09 | 独立验收真实位置恢复；修复需覆盖Swift状态和Rust回传 |
| F04 | **已确认（包身份+历史记录，高）；逐项覆盖未知**：用户认可的wloc外部版与本轮核对包一致 | E02、E03 | 保留可用包；只在用户逐项测试后升级兼容结论 |
| F05 | **静态/文档结论，高；运行请求与服务端未知**：当前MapKit、wloc第三方搜索、官方国家计数是不同数据路径 | E04/S10–S11、E03、E01/R5 | 不把统计开关当总网络开关；不默认继承新增上报 |

**调用路径P01（源码，不是实机已跑通声明）：** 文件导入→RPPairing校验/Keychain（E04/S03）→LocalDevVPN发现（E04/S02）→BG注册/提交（E04/S01–S02，当前编译受阻F01）→Rust set/update（E04/S04）→取消/clear（E04/S04，确认缺口F03）→用户观察真实位置（T04，待验证）。

时间线：2026-11-17完成参考包构建与原始分析；2026-11-18交接记录保留后续安装验证和用户容器可用反馈；本轮2026-11-18复核公开最新、包身份、源码并取得原样编译失败证据。旧manifest“尚未安装”不覆盖后续记录。

## 8. 来源与本地交付状态

下列公开资料均在2026-11-18重新读取。R1为发行记录；R2–R5锁定公开main的commit，避免把之后网页变化当成本轮依据。

- R1 官方v0.9.9发行记录：`https://github.com/seanhowarthdev/Roam-Control/releases/tag/v0.9.9`
- R2 官方README：`https://github.com/seanhowarthdev/Roam-Control/blob/07df7c8978d137d17c90b9bbef5c2c53a858303d/README.md`
- R3 迁移/备份说明：`https://github.com/seanhowarthdev/Roam-Control/blob/07df7c8978d137d17c90b9bbef5c2c53a858303d/Documentation/Migration095.md`
- R4 CHANGELOG：`https://github.com/seanhowarthdev/Roam-Control/blob/07df7c8978d137d17c90b9bbef5c2c53a858303d/CHANGELOG.md`
- R5 隐私说明：`https://github.com/seanhowarthdev/Roam-Control/blob/07df7c8978d137d17c90b9bbef5c2c53a858303d/Documentation/Privacy.md`
- A1 Apple异步提交API：`https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submittaskrequest(_:completionhandler:).md`
- A2 Apple同步提交API：`https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submit(_:).md`
- A3 Apple持续任务限制：`https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask.md`

官方UserGuide部分段落仍主要描述walking；本报告以对应release、CHANGELOG和README交叉核对功能，不用旧段落否定新版功能。公开Privacy的“应用不发送位置”等措辞不等于MapKit服务完全离线，也不等于服务器行为已被本轮审计。

工作区：`/Volumes/Extra disk/Directories/Users/pandy/ai-code/Roam-Control-version-alignment-20261118`；分支：`codex/version-alignment-20261118`。起始基准为本地`main@402ff6f`，为了保留已提交但未推送的交接资料；预期合并目标为fork的`origin/main`。未提交/推送、无PR；工作区保留待范围选择。当前许可证及历史许可文件未修改。

已执行 `task-done codex/version-alignment-20261118 --base origin/main --remote origin --check --json`，刷新远端后返回 `pending`：起始交接提交尚未进入远端目标、存在本轮未提交文档/证据，以及需要保留的ignored编译生成物。没有执行`--apply`，没有清理工作区或分支。文档本地链接、证据JSON与哈希、改动空白检查已通过；应用源码/配置/静态库/脚本/许可证对HEAD无改动。

正式交付为本报告与`evidence/`四个精简文件；原始网络快照、REA完整记录、编译日志和生成物保留在本工作区`work/version-alignment/`，不属于待提交文档。后续功能实现须先取得用户范围选择；没有安排自动跟踪或手机操作。

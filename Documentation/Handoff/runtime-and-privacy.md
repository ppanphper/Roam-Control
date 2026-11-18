# wloc 技术结论与验证边界

范围：用户提供的 wloc 1.2.1（31）IPA、本人 iPhone 上的安装及相关公开项目。授权来自本会话的排障、逆向及隐私检查请求。本文件整理既有证据，不新增设备或网络流量测试。

## 内置隧道为何失败

已安装应用签名/profile 未获得所需 Network Extension 能力。系统观察为 `entitled=0`、`hasProviderPermission=0`，以及 `NEConfigurationErrorDomain 10` / `NEVPNErrorDomain 5`（permission denied）。LiveContainer 客体不会凭空获得宿主没有的系统权限；配对文件用于开发服务配对，并不是授予 NE 的签名凭证。

此前核对过对应版本的 SideStore/SideSign 免费团队 capability 及签名流程。不要重复尝试手写 entitlement、换同一台手机的配对文件、找根证书信任或无授权 profile 重签名来解决这个实例。没有向 Apple 实际提交过一次强制 NE 申请，不能声称本次拿到了 Apple 拒绝申请的 API 响应。

## 已跑通的外部隧道路径

`0x100149bdc` 枚举 `Bundle.main.builtInPlugInsURL` 中前缀为 `WlocTunnel` 的扩展，找到时返回 provider bundle ID。`0x10014a4b8` 选择内置（0）、LocalDevVPN（1）或代理应用（2）。

仅删除 `Payload/RoamControl.app/PlugIns/WlocTunnel.appex/` 的目录、Info.plist、可执行文件三个 ZIP 条目后，wloc 使用已经存在的外部路径。保留主程序和 Live Activity 扩展。`externalTunnelSource=localDevVPN`，已有启动 URL 为 `localdevvpn://enable?scheme=roamcontrol`。

其他已定位函数：`0x100112b08` 读取来源，`0x1000087ec` 写入来源，`0x10012f670` 启动分流，`0x100134b94` 打开 LocalDevVPN，`0x100130944` 构造 URL。地址只适用于 evidence/package-manifest.json 所标识的原始主 Mach-O，不能套用到新构建。

独立版的系统“本地网络”权限原本关闭；开启后配对/可达性检查通过。LocalDevVPN 的标准设备地址为 `10.7.0.1/32`、隧道地址为 `10.7.1.1/32`。连接成功不等于已经开始模拟位置。

LiveContainer 3.8.13 中已导入该包，首次启动前开启“修复本地通知”。不要为了后续功能对齐卸载已可用的 wloc。新构建宜用独立 App ID，先与现有版本并存验证。

## 正常使用与飞行模式

先连接 LocalDevVPN，再进入容器中的 wloc，完成配对检查、选择位置、开始会话，等 App 明确显示会话启动后再观察目标 App。选择地图上的位置本身不是定位已经生效的证明。

原始 wloc 二进制的提示没有固定“10 秒”要求。Wi-Fi 下通常直接建立连接；移动数据场景出现指引时，按要求临时开启飞行模式并返回 wloc，等“安全位置会话已就绪，现在可以关闭飞行模式”再关闭。未将蜂窝流程列为助手实机通过项。

LocalDevVPN 的 `roamcontrol` 回调在独立版与容器版并存时可能产生入口歧义，这属于后续回归项；可先手动开启 VPN，再从 LiveContainer 返回目标客体检查。不要把疑似回调问题写成已经复现的故障。

## 隐私检查结果

- 本次读取的独立版设置 `sharesAnonymousUsageStatistics=false`，`anonymousUsageIdentifier` 不存在，两个 `RoamControlTelemetry*` 配置为空。
- 已检查的统计配置/发送分支会检查开关及非空配置，因此本包当时的这一 TelemetryDeck 路径不具备有效发送配置。没有开启统计或发送测试事件。
- 全球搜索默认入口为 `https://wloc-pages.pages.dev/api/search`。程序可派生 `/api/reverse`，用 `lat`、`lon` 构造请求并经 URLSession 发出。这些功能请求不由匿名统计开关统一控制。
- 公开 Worker 参考代码来自 `ios151/wloc` 固定提交 `264641e856e5006cb1219777ec5f337d55d73a0c`，其中搜索/反查会转发给 Nominatim。该仓库不是这份 iPhone IPA 的完整应用源码。
- 当时仅从 Mac 对公开地名做过一次合成请求；没有捕获手机上传某个具体坐标的完整参数，也没有验证服务端部署与公开代码完全相同或其日志保存政策。
- 未发现配对私钥、Apple ID 或密码外传的证据；有限静态审查不能证明闭源包绝对安全。此次移除隧道扩展没有改变隐私相关代码。

关键地址：统计配置 `0x10015a970` / `0x100157078`；统计发送 `0x10015782c`；默认搜索 `0x10014b748`；反查 URL `0x10014b8c0`；参数/发送 `0x10014bb38` 至 `0x10014bef4`。后续优先核查自建源码的实际网络边界，不能把 wloc 的观察直接套用到当前 fork。

## Evidence → Finding → Path

| Evidence | 观察 | 可复核来源 |
|---|---|---|
| E-01 | 包版本、原/改包哈希、只删除三个扩展条目 | [包清单](evidence/package-manifest.json) |
| E-02 | 配对有效、LocalDevVPN 可达、会话未激活 | [原始成功诊断](evidence/standalone-success-diagnostic.txt) |
| E-03 | 用户报告容器版正常使用，未提供逐项测试明细 | [验证时间线](evidence/verification.json) |
| E-04 | NE 权限错误、分流逻辑及隐私地址的原报告/函数摘录 | [历史资料索引](artifacts.md) |

- **F-01**：内置隧道权限失败，外部路径已可用；status=validated，confidence=high，evidence=[E-01,E-02,E-03,E-04]。适用范围是已标识的包和记录中的环境。
- **F-02**：用户认可容器版正常使用；status=validated（用户报告），confidence=high，evidence=[E-03]。全部功能覆盖和长时间稳定性仍未知。
- **F-03**：存在独立于统计开关的第三方搜索/反查代码路径；status=validated（代码能力），confidence=high，evidence=[E-04]。完整运行时请求与服务端行为未知。

**P-01（callflow）**：移除内置扩展 [E-01] → 原程序选择外部路径 [E-04] → LocalDevVPN 与本地网络访问可用 [E-02] → 配对/连接通过 [E-02] → 迁入容器后用户确认正常使用 [E-03]。

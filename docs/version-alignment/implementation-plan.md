# 完整功能对齐实施计划

2026-11-18：用户已将范围从“先P0”扩大为完整对齐，并指定gpt-6.2-sol并发编码。此前报告保留为原始审查快照，本文件是当前实施范围。工作区与分支沿用本轮独立工作区，不编辑主工作区、不提交推送、不操作手机。

## 完成定义

实现公开0.9.9的用户功能：固定位置、三种路线运动、自定义速度/单位、点绘/手绘、GPX导入导出、摇杆、地图跟随、收藏历史、备份恢复、中断恢复、十语言/系统默认/RTL、坐标兼容模式、配对/外部VPN、诊断预览分享、手动/可选自动更新检查、构包元数据与无障碍。保持iOS26.5.2、无会员、LiveContainer + LocalDevVPN。

功能等价基于公开行为独立实现；未知闭源算法、官方备份私有格式和wloc未核验功能不能宣称完全相同。官方安装国家计数/自托管遥测及诊断上传服务不属于需要复制的用户功能：保留当前默认关闭统计；诊断本地预览分享；更新只查fork仓库并由用户控制，不自动下载安装官方iOS27包。wloc特有第三方搜索不默认接入。

交付：设备Release unsigned IPA（独立App ID，与可用wloc并存）及哈希/构建清单、Simulator构建、本地算法/文件格式/状态测试结果、功能覆盖矩阵和用户手机验收步骤。实机兼容和外部地图位置依然待用户验收，不用编译代替。

## 模块与并行所有权

| 模块 | 编码者 | 文件所有权 | 交付 |
|---|---|---|---|
| R 运行时兼容 | gpt-6.2-sol | Services/Pairing、Services/Tunnel、BackgroundTaskIdentifier、Native、Frameworks、scripts/build-pairing-engine.sh、项目/Info.plist | iOS26 API、外部回调隔离、前台降级、恢复错误回传、配对验证、原生库重建 |
| M 运动与文件核心 | gpt-6.2-sol | 新Models/Movement*、Services/Movement/、Services/Routes/；新Features/Map/RoutePlanner.swift与MovementController.swift | 三模式、速度模型、5Hz更新、GPX、坐标转换、恢复快照、算法验证 |
| U 地图交互 | gpt-6.2-sol | Features/Home/HomeView.swift；新Features/Movement/；MapViewModel.swift；SessionRecoveryView.swift | 统一路线/手绘/摇杆UI、跟随、GPX入口、运动和恢复状态 |
| I 集成与数据设置 | 主会话 | AppModel、AppPreferences、SessionRecoveryRecord、Services/Backup、FeaturePreferences、Settings、测试/文档/构包脚本 | 数据迁移、备份设置、连接公共接口、整体构建 |
| L 本地化与补充界面 | 后续gpt-6.2-sol | 待前三模块稳定后分配Resources/Localization、语言UI、说明/诊断/更新 | 十语言覆盖、RTL、诊断审核、版本检查 |

不同模块不改同一文件。遇公共接口变更先报告主会话。源码全在本任务隔离工作区，禁止其他工作区/提交/推送/设备操作。主会话负责合并文件级结果与修复编译；各代理不得在并发阶段运行全项目构建或覆盖他人文件。

## 公共接口（先按此实现）

运动核心由M提供，Foundation/CoreLocation/MapKit可用：

```swift
enum MovementMode: String, Codable, CaseIterable, Identifiable { case walking, cycling, driving }
// title, symbol, defaultSpeedMetresPerSecond, speedRange: ClosedRange<Double>
enum RouteSource: String, Codable { case appleMaps, points, freehand, gpx }
struct RouteCoordinate: Codable, Equatable, Sendable {
    var latitude: Double; var longitude: Double
    var coordinate: CLLocationCoordinate2D { get }
    init(latitude: Double, longitude: Double)
}
struct MovementRoute: Codable, Equatable, Identifiable {
    var id: UUID; var name: String; var points: [RouteCoordinate]
    var source: RouteSource; var mode: MovementMode
    // init(name:points:source:mode:) throws validates finite legal coordinates, >=2 distinct points
    var distanceMetres: Double { get }
    var start: LocationTarget { get }; var destination: LocationTarget { get }
    var polyline: MKPolyline { get }
    func reversed() throws -> MovementRoute
}
struct MovementSnapshot: Codable, Equatable {
    var route: MovementRoute?; var mode: MovementMode
    var speedMetresPerSecond: Double; var distanceTravelled: Double
    var isPaused: Bool; var isJoystick: Bool
    // init with all above fields
}
enum MovementPhase: Equatable { case idle, preparing, moving, paused, arrived, stopping, failed(String) }
@MainActor @Observable final class MovementController {
    private(set) var phase: MovementPhase
    private(set) var route: MovementRoute?
    private(set) var currentCoordinate: CLLocationCoordinate2D?
    private(set) var distanceTravelled: Double
    private(set) var currentSpeedMetresPerSecond: Double
    var mode: MovementMode; var speedMetresPerSecond: Double
    var progress: Double { get }; var remainingDistance: Double { get }; var remainingDuration: TimeInterval { get }
    var isJoystick: Bool { get }; var locksDestination: Bool { get }
    func prepare(_ route: MovementRoute)
    func start(using appModel: AppModel) async
    func startJoystick(at: LocationTarget, using: AppModel) async
    func setJoystick(x: Double, y: Double) // normalized; x east, y north; zero releases
    func togglePause(); func reverseRoute() throws
    func restore(_ snapshot: MovementSnapshot, at: LocationTarget)
    func handleSessionPhase(_ phase: DeviceSessionPhase)
    func stop(using: AppModel); func reset()
}
@MainActor @Observable final class RoutePlanner {
    private(set) var route: MovementRoute?; private(set) var isLoading: Bool; private(set) var errorMessage: String?
    func preview(to: LocationTarget, from: LocationTarget?, mode: MovementMode) async -> MovementRoute?
    func clear()
}
enum GPXService {
    static func decode(_ data: Data, name: String, mode: MovementMode) throws -> MovementRoute
    static func encode(_ route: MovementRoute) throws -> Data
}
enum CoordinateCompatibility: String, Codable, CaseIterable, Identifiable { case off, automatic, force }
// CoordinateTransform.deviceTarget(_:compatibility:) -> LocationTarget; origin-aware; final output only
```

I模块向AppModel增加接口，M/U无需编辑AppModel：

```swift
let featurePreferences: FeaturePreferences // @Observable, UserDefaults-backed
// .movementMode, .units (RouteUnits.metric/.imperial), .compatibility
// .languageCode String ("system" or BCP47), .automaticUpdateChecks Bool
// .speed(for: MovementMode) -> Double; .setSpeed(_:for:)
func startMovementSession(at: LocationTarget, snapshot: MovementSnapshot) async
func updateMovementLocation(_ target: LocationTarget, snapshot: MovementSnapshot) -> ActiveLocationUpdateResult
func saveMovementRecovery(at: LocationTarget, snapshot: MovementSnapshot)
// SessionRecoveryRecord.movement: MovementSnapshot?; legacy fields kept; absent decodes nil
```

`LocationTarget`增加可选来源`origin: LocationOrigin?`（map/search/manualCoordinate/route），旧数据缺失可解码。手工坐标automatic不转换；GPX以WGS84为准；map/search点只在最终device写入时转换，不能修改地图点/备份原坐标。枚举声明由I提供，转换实现M提供；停止后的真实位置不转换。RouteUnits提供`distance(_:)`、`speed(_:)`和速度输入换算。

R模块保持DeviceSessionPhase现有case，增加独立`restorationStatus`和执行方式属性，不让各UI switch变成冲突。停止失败走`.failed`，成功只能在原生clear有结果后进入idle；若foreground fallback被系统挂起，保留恢复记录并明确限制。独立callback scheme `roamcontrol-pandy`，bundleID `com.ppanphper.roamcontrol`，显示名`Roam Control Dev`，marketing `0.9.9`、首包build `30`，不冒充官方Build105。

## 算法与状态约束

- 一个设备会话、一个运动控制器；换模式先停止运动计时器，避免不同任务同时写位置。方向/路线5Hz，采用真实单调时间增量且限制恢复后的大delta；非有限数值拒绝。
- 驾车加减速/目的地制动/转弯降速，骑行转弯降速；自定义速度为目标上限；路线估时使用所选速度，UI显示实际模拟速度。模式通过MapKit正确transportType，服务拒绝骑行时明确报错或使用手绘/GPX，不伪装成骑行路线。
- GPX1.1读取trk/trkseg或rte，拒绝多个不相连segment，限制输入大小/点数，禁止外部实体解析，剔除重复点，非法坐标报错。导出再读几何保持。
- 点绘支持起点/中间点/终点与撤销，freehand按stroke撤销；不连接跨越大段空白的无意笔划。已有活动位置可作起点。
- recovery保存模式、速度、原路线/进度、暂停/摇杆位置，兼容旧fixed/walking数据；失败保留线索。恢复不自动开始新位置会话，用户选择继续或清除。
- backup版本化JSON，仅收藏/历史/外观/地图/语言/单位/速度/坐标偏好；排除pairing、active recovery、consent/identity；验证全部内容再原子应用，限制输入大小，导入失败不覆盖。
- 自动更新默认关闭，手动查fork releases，忽略draft/prerelease，SemVer优先；无发布是正常状态，不建议安装不兼容官方包。不上传诊断，分享前展示实际脱敏内容。
- 十语言完整UI资源以及权限文本；英语fallback不等于完整翻译，最终核对key覆盖。技术字符串、地点名与PIN不翻译。

## 验证与停止条件

每模块提供必要的可执行验证；主会话完成device/simulator构建、核心算法/GPX/备份/恢复边界验证和可行的模拟器UI检查。Release构包检查主程序最低iOS、bundle/版本、无NE、统计配置空、哈希；输出到outputs/带可读本地时间的IPA与清单。没有实机结果的项标待用户验证；任何实际技术阻塞记录具体影响，不把完整对齐当作已确认实机等价。

设计见根目录DESIGN.md；原始证据和逐项手机测试见同目录2026-11-18-version-and-feature-alignment.md。实施过程中按功能表记录implemented/local-verified/device-pending，不能以文件已产生替代完成。

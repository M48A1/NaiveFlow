# NaiveFlow 开发排期

更新日期：2026-11-07

本文件按当前源码跟踪实现和待验收事项，详细规范见 [配置说明](Documentations/Configuration.md)与[配置架构](Documentations/ConfigurationArchitecture.md)。下方历史记录仅反映当时状态；当前进度以本文前半部分为准。[DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) 中的早期估算和架构描述需要结合当前实现阅读。

> 勾选表示代码或文档已存在，不代表当前版本已通过构建、自动化测试或真机验收。本次更新仅核对源码与文档，未执行构建、测试、抓包或性能基准；历史构建结果不用于确认当前代码可用。

## 当前范围与架构

- 当前优先完成 iOS/iPadOS；保留 tvOS target，涉及共享代码时需要回归。macOS 尚无 target，待 iOS/iPadOS 完成后另行实施。
- 首版为 IPv4-only，IPv6、完整双栈与 NAT64 支持不列为待交付功能。Watch 客户端已移除。
- 配置为 NaiveFlow 原生分节文本，参考其他客户端的组织形式；不承诺完整配置或脚本兼容。
- `RuleManager` 负责文档、草稿及历史；`ConfigurationCoordinator` 负责校验、编译和模块变更；`ConfigurationPublisher` 发布不可变运行包，扩展通过 `RuntimeCoordinator` 与版本安装流程加载、确认和恢复。
- 活动文本版本控制实际流量；手工节点、分组和规则库独立保留。应用文档不再通过逐个 Store 写入的旧安装路径执行，`ConfigurationInstaller` 仅保留报告类型。
- 通用 MITM、改写和脚本继续保留。应用内 DoH/DoH3 走普通路由，专用 DoH 解密、重查与合成回包已移出范围。

## 01：工程基线与平台验收

- [x] 完成工作工程重命名，保留 `Reference/Anywhere` 对照。
- [x] 移除继承的 StoreKit 付费、会员门禁与 Telegram 群组入口。
- [x] 依赖收敛为仓库内 `NaiveFlowIP`、`NaiveFlowQUIC`、`BLAKE`、`YAML` 四个组件包。
- [x] 保留历史 iOS/tvOS 无签名构建与模拟器测试记录，见 [BASELINE_CHECK.md](BASELINE_CHECK.md)。
- [ ] 对当前代码重新构建 iOS 主应用、Network Extension、Widget 与 tvOS target。
- [ ] 运行当前自动化测试，单独记录通过、失败与因缺少受控服务而跳过的用例。
- [ ] 核对开发者账号、Bundle ID、App Group、CloudKit、Network Extension 能力与签名。
- [ ] 真机验证导入节点、VPN 启停、访问和断开。
- [ ] 确认真实图标和品牌资源，完成发布资源检查。

验收：当前代码可构建、可签名安装，真机基本连接可用；历史验证与本次验证能够区分。

## 02：配置编辑与版本发布

- [x] 文档解析、原文与注释保留、诊断、能力校验和编译。
- [x] 文件导入、文本编辑、草稿保存、预览、应用、历史载入与丢弃修改；入口为 `ProfileView` / `ProfileEditorModel`。
- [x] `ConfigurationImport` 限制 UTF-8、16 MiB，支持 BOM 与换行归一、安全作用域访问。
- [x] `ConfigurationDocumentOperations.apply` 统一调用 `ConfigurationPublisher.publish`。
- [x] 节点、规则、Geo、DNS/Host、偏好及 MITM/脚本资源固定到 `RuntimeConfigurationBundle`。
- [x] 发布锁、原子 head、完整性校验、精确版本 receipt、失败恢复及待发布事务恢复代码。
- [x] 恢复上一运行版本，以及载入历史文本后重新应用这两种独立操作。
- [x] 配置文本手动 iCloud 上传与下载；下载内容需在本机单独应用。
- [ ] 验证错误配置不覆盖可用版本、过期确认不误报成功、宿主退出后恢复、连续发布和回滚。
- [ ] 真机验证一般更新重建数据平面、关闭旧连接，以及连接级偏好变更触发重连的行为。

验收：应用状态必须对应实际运行版本。停止状态下保存的版本需等待启动确认，不能仅凭保存成功宣称扩展已生效。历史文本重新应用会重新获取远程资源；恢复不可变运行版本使用已保存资源。

## 03：有序路由、规则集与 Geo

- [x] `ConfigurationCompiler.compileOrderedRules` 编译原文顺序、逐规则策略和 FINAL。
- [x] `DomainRouter.installNative` 从运行包安装 `OrderedRouteMatcher` 和 Geo 数据，已进入扩展执行路径。
- [x] 域名、IPv4 CIDR、端口、协议、逻辑表达式、Geo 与 RULE-SET 的解析/编译基础。
- [x] 外部规则集展开、校验并随版本固定，见 [RuleSets.md](Documentations/RuleSets.md)。
- [x] GeoIP/GeoSite 外部数据导入、SHA-256 校验、版本固定、索引和离线恢复，见 [GeoDatabases.md](Documentations/GeoDatabases.md)。
- [x] `[Chain]` 解析、校验、编译、导出与 composite 节点引用。
- [ ] 验证首条命中、逻辑短路、逐规则 no-resolve、DNS 等待与失败语义。
- [ ] 验证旧手工基线读取和原生版本切换；旧 `routing.bin` 不需承担原生有序规则载荷。
- [ ] 核对规则能力声明与实际元数据来源，特别是 URL-REGEX、PROCESS-NAME、USER-AGENT；不能仅凭解析/编译支持认定运行有效。
- [ ] 验证 `url-test` / `fallback` / `load-balance` 的真实选择行为；不能将退化为 select 计作自动策略完成。
- [ ] 测试重叠规则、顺序调整、真实 IP、坏库拒绝、缺库、更新和回滚；补充容量与性能基准。

Geo 更新由用户重新应用触发，不含后台定时刷新。可选 `Rules.db` 预设库与原生 Geo 资源是不同来源，不应混为同一条未完成依赖。

## 04：Fake-IP、解析通道与普通 DNS 接管

- [x] SyntheticAddressPool 的并发保护、LRU、代次、TTL 和映射缺失处理代码。
- [x] DNS 解析目的与 Local / Proxy / Bootstrap 策略模型、缓存隔离及 Bootstrap 防循环代码。
- [x] TCP/UDP 调度中恢复原域名、DIRECT 按需解析、代理保留域名目标的路径。
- [x] UDP/53、TCP/53 查询处理与 `dns-exempt-servers` 配置入口。
- [x] A 查询 Fake-IP、AAAA/HTTPS(type 65) 抑制、拒绝和例外域名处理，详见 [DNSConfiguration.md](Documentations/DNSConfiguration.md)。
- [ ] 使用可计数 DNS 服务验证 no-resolve 不主动解析、代理收到原域名、真实 IP 不反查。
- [ ] 验证映射过期、回收、耗尽、重启和并发连接不存在跨域名误映射。
- [ ] 验证 TCP DNS 分段、多请求、上游故障切换、豁免和无递归。
- [ ] 用日志与抓包核实各解析通道、代理节点 Bootstrap 和实际出站。

验收：Fake-IP 不进入 GeoIP 或公网出站；缺失映射明确失败；节点与 DNS 上游不存在自依赖循环。

## 05：应用内 DoH / DoH3 分流验收

- [x] 现有 HTTPS SNI 与 QUIC 嗅探、普通路由和 QUIC 策略代码可供此阶段复用。
- [ ] 验证 DoH 服务端域名/IP 的 DIRECT、PROXY、REJECT。
- [ ] 验证 DoH3 UDP/QUIC 出口与 QUIC 策略，不承诺客户端必然回退。
- [ ] 分别验证 DNS 服务端连接和业务连接的命中规则与出口。
- [ ] 验证域名不可见时的 IP 规则与 FINAL。
- [ ] 确认普通 DNS/Fake-IP 和内核自身 DoH 上游仍独立正常工作。

验收：不要求安装 CA，不宣称能够控制加密查询内部的域名；DoH 出口不会自动决定业务连接出口。

## 06：MITM、改写与脚本

- [x] 已有原生 MITM 引擎和 `TextMITMCompiler`，支持文本编译及随版本固定资源。
- [x] 已有 `ForeignMITMImporter` 的 Surge / Quantumult X 部分导入代码。
- [ ] 核对外部格式导入的调用入口、未支持项诊断，以及导入结果的实际执行。
- [ ] 对照选定版本的官方样例建立脚本兼容矩阵，分别记录支持、部分支持、不支持和未验证。
- [ ] 验证请求/响应上下文、完成语义、主动 HTTP 请求、持久存储、通知、文本/二进制及压缩 body。
- [ ] 验证 CA 未信任、脚本下载失败、固定字节回滚、超时、并发与自触发循环。

原生脚本 ABI 与外部脚本 API 分开验收；有导入器或能解析脚本声明，不能代表 Surge / Quantumult X 脚本已经兼容。定时、事件、DNS 脚本等扩展能力另行评估。

## 07：UI 与诊断完善

配置文本编辑入口已存在，本阶段继续统一页面和交互。

- [ ] 核对首页运行版本、活动节点、应用结果和恢复入口是否与扩展状态一致。
- [ ] 完善规则排序、Geo/规则集版本与更新状态展示。
- [ ] 诊断展示原始目标、命中规则、解析目的/通道、最终出口及失败原因。
- [ ] 完善 MITM/脚本来源、作用域、兼容提示与运行日志。
- [ ] 验证深色模式、动态字体、长列表、iPad 布局和 tvOS 共享代码影响。

## 08：IPv4-only 发布前回归

- [ ] 验证 IPv4 节点、域名 A 记录和各承诺协议的 TCP/UDP。
- [ ] 验证不支持的地址/规则诊断、AAAA NODATA 和 TUN 防绕行。
- [ ] 验证 Wi-Fi/蜂窝切换、前后台、睡眠/唤醒、隧道重启、配置恢复和资源更新。
- [ ] 测量内存峰值、吞吐、连接数与长时间运行。
- [ ] 整理当前构建产物、测试记录、受控服务条件和已知限制。

## 下一步

1. 先完成当前提交的 iOS/tvOS 构建与自动化测试，记录跳过的连通性用例。
2. 优先核实能力声明、编译产物与运行路径的一致性，处理规则元数据和策略组语义的差异。
3. 使用最小原生配置验证「导入 → 预览 → 发布 → 扩展确认 → DNS/Fake-IP → 有序路由 → 出站」。
4. 以受控服务验证发布失败、回滚、进程退出恢复和 DNS 无循环，再进行签名真机回归。
5. 核心闭环通过后完善 UI 与脚本兼容；macOS 保持后续独立阶段。

## 历史进度记录

以下保留原始记录；旧 API、阶段编号、能力声明、环境说明和测试数量不代表当前代码状态。

### 2026-11-05

- 配置热重载收敛成一张“主机说了什么 → 扩展做什么”的表（**未编译、未测试**：本机没有 `swiftc`/`xcodebuild`，只能由 CI 验证）：
  - 新增 `Shared/Configuration/RuntimeCoordinator.swift`：扩展与主应用共用的纯数据层，不做 IO。`Event`（`activeConfiguration` / `settings` / `routing` / `mitm`）带 `notificationName`、`init?(notificationName:)` 与 `notificationNames`——注册名单和解码来自同一个 `allCases`，所以“监听了却解不出来”的通知不可能存在；`Action`（`reloadHostMappings` / `reloadSettings` / `reloadRouting` / `reloadMITM` / `reloadActiveConfiguration` / `revalidateQUIC`）带 `requiresRunningPhase`；`Plan` 是有序动作表；`plan(for:)` 是唯一把事件翻成动作的地方。
  - 新增 `Shared/Configuration/ConfigurationCoordinator.swift`（只进主应用）：`ConfigurationModule`（rule / dns / mitm / outbound，含 `settingOwners`、`owning(section:)`、`owning(setting:)`）、`prepare(...)` 按模块报告一份文档（`ModuleReport` + 文档级诊断）、`plan(from:to:running:)` 借 `ConfigurationReloadPlan` 算出逐模块 `Change`（含 `payloadChanged`），以及 `announcements(for:)`——现在只有这一处决定“装完要发哪些通知”（改到 `[General]` 发 `settings`，改到 MITM 的键再补一个 `mitm`）。
  - 同一文件用 `nonisolated extension RuntimeCoordinator` 放主机侧桥：`Event(announcement)` 与 `plan(forAnnouncement:)`（名字避开 `plan(for: Event)` 的重载歧义）。扩展 target 不编译这个文件，因此全部 `Announcement` → `Event` 的转换只出现在这一处。
  - `ConfigurationInstaller` 不再自己挑通知，一律走 `ConfigurationCoordinator.announcements(for:)`；扩展侧按 `Event.notificationNames` 注册、按 `plan(for:)` 执行。
  - 扩展侧删除旧的 `RuntimeCoordinator.swift`，四个 `handleXChanged()` 拆进 `NaiveFlow Network Extension/Tunnel/TunnelStack+Runtime.swift`：`runSettingsObserver()` + `apply(_ plan:)`（按 `requiresRunningPhase` 过滤）+ 每个动作一个方法。逐条对齐旧实现：`reloadHostMappings` = 旧的 `DNSHosts.shared.invalidate()`（唯一在非 running 阶段也执行的一步，避免陈旧的 `[Host]` 覆盖活到下一次启动）；`reloadSettings` = 旧的 `handleSettingsChanged` 全部后续（`publishUDPConfig`、QUIC 重校验、`preventDNSLeak` 存储、reflection 重发布、`requestReapplyTunnelSettings`、代理模式变化时 `restartStack`）；`reloadRouting` = 旧的 `handleRoutingChanged`（编译 → 再次确认仍在 running 且为 rule → `install` + `clearRejectMarks` + 记录引擎确认）；`reloadMITM` + `revalidateQUIC` = 旧的 `handleMITMChanged`（顺序不变）；`reloadActiveConfiguration` = 旧的 `handleActiveConfigurationChanged`。
  - `TunnelStack+Lifecycle` 只剩启动时的一次 `runSettingsObserver()`（全仓唯一调用点），`restartStack` 从 `private` 放宽到 internal 供重载路径复用，`recordEngineConfirmation()` 保留；规则热重载后的确认写入移进 `reloadRouting`。
  - `NaiveFlow.xcodeproj`：`Shared` 文件夹在扩展 target 的例外集合新增 `Configuration/RuntimeCoordinator.swift`（`Configuration/EngineConfirmation.swift` 本就在其中），`ConfigurationCoordinator.swift` 继续不参与扩展编译。
  - 新增 `NaiveFlow Tests/ConfigurationCoordinatorTests.swift`：把两张表钉在一起——每个 `applies: true` 的键必须有归属模块、未生效的键不许有归属、每个键只出现在一个模块、节名到模块的映射、`prepare` 的逐模块报告与未认领诊断留在文档上、`plan` 的逐模块变更、`Announcement` ↔ `Event` 一一对应（主机能发而扩展不认识时判失败，而不是静默丢弃）、每个 `Announcement` 都规划出非空动作、动作顺序、只有 `reloadHostMappings` 允许在非 running 阶段执行。
  - 文档：`Documentations/Configuration.md` 的 `live` 一行改指 `ConfigurationCoordinator` / `RuntimeCoordinator` / `TunnelStack+Runtime.reloadSettings()`，并新增 “Announcements” 一节说明这套契约。
  - 未验证（等 CI）：上述新文件的编译、target 成员（`RuntimeCoordinator.swift` 进扩展、`ConfigurationCoordinatorTests.swift` 进测试 target）、`ConfigurationDiagnostic` 的初始化形状、`ConfigurationReloadPlan.change(for:)` / `payloadChanged`、`CompiledSettings` 下标、`DomainRouter.compileRoutingConfiguration`、`EngineConfirmationStore.recordRunningSnapshot` 的可见性；`ConfigurationSettingsTests` / `ProfileEditorModelTests` / `ConfigurationTextTests` 是否因 API 迁移需要同步修改。


### 2026-11-04

- 移除从上游继承的 Anywhere/Voyager 付费与 Telegram 群组功能：删除 StoreKit 内购层（`NaiveFlow/Stores/VoyagerStore.swift`）、付费墙与公开测试页（`VoyagerNotice`、`JoinVoyagerButton`、`JoinBetaView`），移除会员卡片与 `isMember` 门禁，`AWCore`/`AppSettings` 删除会员相关 UserDefaults 键，`AboutView` 移除 Telegram 群组链接，`Localizable.xcstrings` 删除 22 个失效键（478 → 456）。
- 依赖收敛：核对 5 个 SwiftPM 依赖，确认 `NaiveFlowIP`、`NaiveFlowQUIC`、`BLAKE`、`YAML` 为仓库内核心组件且无远程依赖；`NaiveFlowRules`（上游 `AnywhereRules`）为私有仓库（匿名 404、搜索 0 命中、上游公开仓库同地址），已从工程移除，改为 `RoutingRulesDatabase` 在 `Bundle.main` 读取可选 `Rules.db`。工程现无远程依赖，`Package.resolved` 随之为空。
- 补齐编译所需占位资源 `Shared/Assets.xcassets`（9 个中性色板 + 空 `AppIcon.appiconset`）：本仓库与上游公开仓库都没有 `.xcassets`，源码依赖资源符号，缺资源无法编译。
- 编译验证（Xcode 27.2，无签名）：
  - `NaiveFlow`（iOS，含 Network Extension、Widget）→ BUILD SUCCEEDED，0 error。
  - `NaiveFlow TV`（tvOS）→ BUILD SUCCEEDED，0 error。
- 记录：构建明细见 [BASELINE_CHECK.md](BASELINE_CHECK.md) 的“构建验证”一节；依赖与恢复步骤见 [Reference/Dependencies.md](Reference/Dependencies.md)。
- 未完成：签名与真机连接验证、真实品牌资源替换、`NaiveFlow Tests` 单元测试、内置路由预设（需自备 `Rules.db`）。

- 02 阶段文本配置落地（只加功能，未编译、未运行测试）：
  - 新增 `Shared/Configuration/`：`ConfigurationDocument`（无损原文/注释/顺序）、`SurgeConfigurationParser`、`ParsedConfiguration`、`ConfigurationValidator`、`ConfigurationCompiler`、`ConfigurationSnapshotStore`、`TextConfigurationPipeline`、`ConfigurationDiagnostics`、`ConfigurationDocumentEditing`（编辑返回重新解析的文档）。
  - `ConfigurationValidator.Capabilities.current` 固定当前引擎能力（4 种规则、无 FINAL、无逻辑/Geo、组仅 `select`），不支持项按 `info`/`warning` 报出；新增 `notApplied` 代码，`[General]` 已识别未生效键、`[MITM]` 证书字段、`[Script]` 声明、字段式节点被丢弃的选项都会显式告警，不再静默忽略。
  - 新增 `ConfigurationInstaller`：把编译结果写入既有存储层（节点/分组/规则集/`[Host]`/`AWCore` 设置），按 `installation.json` 记录归属，重复激活原地更新并清理文档已删条目，不触碰手建节点；`activate(text:)` 在安装失败时回滚 manifest 并重新安装旧快照。
  - 新增 `ConfigurationReloadPlan`（`live` / `stackRestart` / `reconnect` 分级）与 `EngineConfirmation.swift`（扩展侧写入 `engine-confirmation.json`，`isActiveSnapshotConfirmed()` 区分“已激活”与“已在运行”）；`TunnelStack+Lifecycle` 在启动与规则热重载后各写一次确认。
  - 新增 `OrderedRouteMatcher`（按原文顺序首条命中，GeoIP/GeoSite 可注入），`TextConfigurationPipeline.Result.route(host:ip:port:)` 与编辑器预览共用同一匹配器。
  - 新增 `Documentations/Configuration.md`：节/字段支持状态表、诊断代码表、重载分级、限制与已知缺口（有序载荷、Geo 数据、脚本、MITM 主机表、`loglevel`、macOS）。
  - 待办：`NaiveFlow Tests` 中 `ConfigurationTextTests`、`OrderedRouteMatcherTests` 尚未编译运行；`[General]` 键级告警暂无行号；编辑器 UI 入口（07）；有序规则尚未进入 `routing.bin`。
  - `ConfigurationValidator` 新增 `ruleValueTooLong`：路由载荷把规则值长度存为 `UInt16`，超长值原本在写 `routing.bin` 时被静默跳过，现在按 error 在校验阶段拒绝，符合“未知/不支持不能静默忽略”的约束。
  - 文档同步（2026-11-04）：新增 `Documentations/Configuration.md` 并加入 README 的 Documentation 列表；`DEVELOPMENT_PLAN.md` 的 4.6 增加实现状态表、§7 的 P1 两项勾选并补充下一步顺序；本文件补 02 服务层/验收状态、03 参考实现状态并重写“下一步”。
  - 新增反向导出（存储层 → 文本）：`Shared/Configuration/ConfigurationExporter.swift` 是纯渲染（`ConfigurationExportSource` → Surge 风格 INI），`ConfigurationExporter+Stores.swift` 读取节点/链/分组/规则集/MITM/`[Host]`/`AWCore` 设置，并优先于 `TextConfigurationPipeline.template` 作为“从当前设置生成初始文档”的入口。无法表达的项目（链、链分组、模块规则集、未分配策略的规则集、无分享链接的节点、无主机的 `[MITM]`）只写进 `notes`，不臆造策略；名称按 `=`/`,`/`#` 净化并去重（重复名在解析侧是 error）；生成的 `FINAL` 用 `PROXY`（内核的终止动作）。新增 `NaiveFlow Tests/ConfigurationExporterTests.swift`：每个样例都要求 `TextConfigurationPipeline.process` 零 error，保证导出与解析不漂移。
  - 未做：导出只覆盖导出方向，导入侧“保节 + 告警”的 `[Script]`、`[URL Rewrite]`、`[Header Rewrite]` 不生成；导出目标只限本应用能读回的 Surge 风格语法，不针对其他客户端的方言。（导出器已于 2026-11-04 编译通过并跑通测试，见下方“编译与测试验证”。）
  - 配置文件在应用内双向出入值（07 的第一个入口，未编译未运行）：
    - 新增 `Shared/Operations/ConfigurationDocumentOperations.swift`：存储 → 文本走 `ConfigurationExporter.exportCurrentConfiguration`，文本 → 存储走 `ConfigurationInstaller.activate(text:)`；`draft()` / `saveDraft()` / `preview()` / `appliedAt()` / `history()` 全部复用现有 `ConfigurationActivation`，没有第二条解析路径。
    - 新增 `NaiveFlow/Views/Pages/Configuration/ConfigurationView.swift`：`TextEditor` 编辑文档，输入后 250 ms 重编译（`TextConfigurationPipeline.process`）并自动保存 `draft.txt`；显示节点/分组/规则集/规则/`[Host]` 计数与逐条诊断（错误/警告/信息）；`Apply to App` 在有 error 时禁用，成功后显示 `Outcome.summary` 与已应用快照列表；`Load from Current Setup` 用导出器把现有设置灌进缓冲区并展示 `notes`；`Import File`（UTF-8、1 MB 上限）只载入不应用；`Export File` 走系统分享。
    - 入口：`Page.configuration`（侧边栏与 `TabView` 的 `VPN` 分区）+ `ToolboxView` 的 `Configuration` 行；`NaiveFlow/` 目录不参与 TV target（TV 的同步组只有 `NaiveFlow TV` 与 `Shared`），因此没有在 tvOS 上引入 `fileImporter`/`TextEditor` 这类 tvOS 不可用 API。
    - 明确不做的：不做自动应用、不监听外部文件、`LSSupportsOpeningDocumentsInPlace` 保持 `NO`（`draft.txt` 不是 `open-in-place` 文档，编辑器是唯一写入方）；存储仍是唯一真相源。
    - 未验证：`ConfigurationView` 与 `ConfigurationDocumentOperations` 尚未编译；`ConfigurationInstaller.activate(text:)` 首次真实调用未在设备上跑过。
  - 编译与测试验证（2026-11-04，Xcode 27.2，`CODE_SIGNING_ALLOWED=NO`）：
    - `NaiveFlow`（含 Network Extension、Widget）→ **BUILD SUCCEEDED**，0 error；`ConfigurationView.swift`、`ConfigurationDocumentOperations.swift` 均参与编译（日志 `/tmp/naiveflow_build.log`）。
    - `NaiveFlow Tests` 在 iPhone 17 模拟器 → **TEST SUCCEEDED**，40 个用例全部通过、0 失败（`ConfigurationTextTests` / `ConfigurationExporterTests` / `OrderedRouteMatcherTests` / `DeterministicBytesTests`，日志 `/tmp/t3.log`）。此前 02 的“测试未运行”状态到此结束。
    - 首次测试运行前，应用在无签名模拟器上启动即崩溃：`AWCore.routingDataURL`/`mitmDataURL` 强制解包 App Group 容器（`SIGTRAP` 于 `AWCore.mitmDataURL` 的一次性初始化）。改为与 `ConfigurationSnapshotStore` 相同的兜底（容器不可用 → `URL.temporaryDirectory`），启动不再崩溃；该环境下主应用与扩展自然无法共享 `routing.bin`/`mitm.bin`。
    - 同时修正一个语义陷阱：`Policy(token:)` 先大写再匹配，名为 `Proxy` / `Direct` 的节点或分组永远无法被规则引用。新增诊断 `reservedPolicyName`（warning，节点与分组都检查），导出器对这类名称追加 `_` 并写 `notes`，模板示例节点 `Proxy` → `Node`；新增用例 `warnsWhenANodeNameIsABuiltInPolicy`、`renamesNodesThatShadowAPolicyToken`。
    - 仍未验证：真机与签名、VPN 启停、`Apply to App` 在真实隧道上的重载行为、编辑器在大量规则（10 万级）下的输入延迟。
  - `[General]` 改为“设置目录”（settings catalog）驱动，目标是“加一个功能只加一个参数”：
    - 新增 `Shared/Configuration/ConfigurationSettings.swift`：`ConfigurationSettingKey` 用一张表声明每个键的名称、取值形状（`flag`/`text`/`enumeration`/`countryCode`/`list`/`plainServer`/`dohURL`）、重载级别与是否生效；`ConfigurationSettingsBindings.all` 声明该键在 `AWCore` 的读写位置。解析、校验、编译、安装、导出、重载分级、诊断文案全部从这两张表读取，不再各写一份键列表。
    - `[General]` 覆盖从 17 个键扩到 54 个：新增 `dns-mode` 与另外四个 DNS 通道的模式键、`proxy-dns-server`/`proxy-encrypted-dns-server`、`subscription-dns-*`、`fallback-dns-mode`/`fallback-dns-server`、`ech-dns-*`、`synthetic-address-excluded-suffix`、`exclude-device-communication`、`always-on`、`allow-insecure`、`trusted-certificate`、`trusted-ssid`、`always-trust-cellular`、`always-untrust-cellular`、`reflection`、`experimental`；仍标记为“已识别未生效”的 Surge 键单独保留并逐个告警。
    - `CompiledSettings` 由“每字段一个可选属性”改为按名称存值（`[String: ConfigurationSettingValue]`），`ConfigurationReloadPlan.make` 改为按目录顺序遍历并取该键声明的重载级别；`ConfigurationInstaller.apply`、`ConfigurationExporter.exportSettings` 同样改为遍历目录，三者不会再漏掉新键。
    - `ConfigurationValidator.knownGeneralKeys` / `acceptedGeneralKeys` 由目录派生，`validateGeneral` 按键声明的形状校验，报错文案会写出该键接受的取值（如 `must be one of rule, global, direct`）。
    - 新增 `NaiveFlow Tests/ConfigurationSettingsTests.swift`（19 个用例）：目录与绑定表互为子集（防止“声明了却生效不了”或“绑定了却没声明”）、`applies: false` 不允许有绑定、键名唯一且为小写 kebab-case、每种形状的解析、编译只取文档写到的键、`[MITM] enable` 优先、未识别/未生效诊断、导出值与解析值互逆、重载分级来自目录。
    - 验证（2026-11-04，Xcode 27.2，`CODE_SIGNING_ALLOWED=NO`）：`NaiveFlow` → **BUILD SUCCEEDED**，0 error；`NaiveFlow Tests` → **TEST EXECUTE SUCCEEDED**，66 个用例 / 6 个 suite 全部通过、0 失败（日志 `/tmp/tB.log`）。
    - 文档：`Documentations/Configuration.md` 的 `[General]` 表换成完整 54 键表（含取值、重载级别、状态），新增「Adding a setting」一节说明两步扩展法与 `applies: false` 的用法。
    - 仍未做：`[Proxy Group]` 组类型、`[Rule]` 有序规则与 `FINAL` 载荷、`[MITM] hostname`、`[Script]` 执行、`[URL Rewrite]`/`[Header Rewrite]`/`[Map Local]`、`[Module]`/`[Subscription]`/`[Chain]` 等节；选择状态与外观设置不在 profile 内（仍由页面管理）。

  - 编辑器会话层独立（`ProfileEditorModel`），为“配置文件取代页面设置”铺路：
    - 新增 `Shared/ViewModels/ProfileEditorModel.swift`：把原先散在 `ConfigurationView` 里的会话逻辑收进一个 `@MainActor @Observable` 状态机——`text` / `preview` / `baseline` / `history` / `notes` / `lastAppliedAt` / `lastOutcome` / `statusMessage` / `errorMessage` / `isApplying` / `isLoaded`，动作 `load()`、`edit(_:)`、`refreshPreview()`、`apply()`、`reloadFromCurrentSetup()`、`importFile(at:)`、`revert(to:)`、`discardChanges()`、`report(_:)`、`dismissError()`、`dismissMessages()`。250 ms 去抖由模型持有（`previewDelay` 可注入），`text` 对外只读，视图无法绕过预览与草稿写入。
    - 新增 `ProfileEditing` 协议作为流水线与 UI 之间的缝：`ConfigurationDocumentOperations` 提供实现（`loadDraft` / `persistDraft` / `previewDocument` / `applyDocument` / `exportDocument` / `readDocument(at:)` / `lastAppliedAt` / `appliedHistory`），测试用桩件替代，不需要 App Group 容器或隧道。`applyDocument` 只回传 `ProfileApplyOutcome`（summary / notes / plan），页面不再依赖 `ConfigurationInstaller.Outcome` 全量结构。
    - 页面改名并瘦身：`NaiveFlow/Views/Pages/Configuration/ConfigurationView.swift` → `NaiveFlow/Views/Pages/Profile/ProfileView.swift`（只渲染），侧边栏与 `Toolbox` 三处引用同步；`Page.configuration` 文案与 `navigationTitle` 仍是 “Configuration”，用户可见名称不变。命名理由：本工程 `Configuration…` 已指“节点”（`ProxyConfiguration` / `ConfigurationStore`），profile 指整份文本配置。
    - 补上原来算出来却没展示的信息：`ConfigurationReloadPlan` 的逐项变更与分级（`Applies immediately` / `Restarts the tunnel data plane` / `Requires reconnect`）进入「Last Apply」区并给出对应操作提示；`isDirty` 在表头（Unsaved）与 footer 双重呈现，新增 `Discard Changes`；历史行可把旧快照文本放回编辑器复核。
    - 新增 `NaiveFlow Tests/ProfileEditorModelTests.swift`（14 例）：`load()` 幂等且不丢输入、编辑即脏并立即重编译与写草稿、去抖合并连续输入（只编译一次）、有 error 时 `canApply == false`、被拒绝的 apply 不动缓冲区且保留错误、成功 apply 刷新 baseline / 历史 / `appliedAt` / reload 提示、live-only 变更不要求重连、导入失败保留原文本、导入成功仍为脏、`revert(to:)` 把旧快照放回缓冲区、`discardChanges()` 恢复已应用文本且无改动时不写盘、`reloadFromCurrentSetup()` 带回导出 notes。
    - 文档：`Documentations/Configuration.md` 重写「Editing inside the app」并新增「Where this is heading」——配置文件作为写入入口，页面按“文本能否完整表达 + 能否经 `Load from Current Setup` → `Apply` 往返”逐项收缩；`[Proxy Group]` 类型、有序规则 / `FINAL` 载荷、`[MITM] hostname`、`[Script]` 被明确列为“删页面前的前置条件”，而不是后续优化。
    - 验证（2026-11-04，Xcode 27.2，`CODE_SIGNING_ALLOWED=NO`）：`NaiveFlow` → **BUILD SUCCEEDED**，0 error（日志 `/tmp/pB.log`，改动收敛后再增量构建一次 `/tmp/pD.log`）；`NaiveFlow Tests` → **TEST SUCCEEDED**，7 个 suite、73 个用例通过、0 失败（日志 `/tmp/tG.log`，最后一次全量复跑 `/tmp/tH.log`；`ConfigurationConnectivityTests` 7 例按 `TestEnvironment` 未配置跳过）。首轮 2 例失败是样例文档问题（与桩件默认草稿同文本导致 `edit()` 提前返回、样例用了当前引擎不支持的 `FINAL`），已修正并附说明于 `BASELINE_CHECK.md`。



### 2026-11-03

- 复制工作工程并保留 `Reference/Anywhere` 原始对照；将 Anywhere 命名批量替换为 NaiveFlow。
- 删除 Watch 客户端、scheme、配对通信与桥接，清理本地包 watchOS 声明；移除仓库中不存在的 StoreKit 配置引用。
- 工程静态检查：pbxproj 格式、同步目录、本地包、Info.plist、entitlements、scheme 引用；结论见 [BASELINE_CHECK.md](BASELINE_CHECK.md)。


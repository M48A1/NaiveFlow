# RuleProxy 开发排期

更新日期：2026-11-05

本文件用于逐项执行和跟踪进度，详细设计见 [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md)。按阶段验收后推进，不预设固定完成日期；工期在工程能够构建、首批配置样例确定后复核。

## 当前状态

- [x] 整理开发计划。
- [x] 复制工作工程，保留 `Reference/Anywhere` 原始对照。
- [x] 工作副本的 Anywhere 命名替换为 RuleProxy。
- [x] 工程及相关配置文件静态格式检查。
- [x] 移除从上游继承的 Anywhere/Voyager 付费（StoreKit 内购）与 Telegram 群组功能。
- [x] 依赖收敛：只保留 4 个仓库内核心组件包，移除无法获取的私有预设包，工程已无远程依赖。
- [x] 无签名工程编译：主应用（含 Network Extension、Widget）与 TV scheme 均构建通过。
- [ ] 签名安装、真机连接与 VPN 启停验证。

后续修改根目录的 `RuleProxy.xcodeproj` 及对应源码，参考目录保持原样。Xcode 27.2 已启用；原先阻塞编译的 `RuleProxyRules` 私有仓库依赖已移除，`xcodebuild` 现在可离线构建 iOS 与 tvOS scheme。详见 [BASELINE_CHECK.md](BASELINE_CHECK.md) 与 [Reference/Dependencies.md](Reference/Dependencies.md)。

## 01：验证现有工程

目标：建立可构建、可运行的修改基线。

- [x] 核对重命名后的 target、scheme、本地包和文件引用；移除缺失 StoreKit 配置引用。
- [ ] 核对 Bundle ID、App Group、CloudKit、扩展通信及签名能力。（本地声明一致性已检查；账号能力与真机通信待验证。）
- [x] 检查批量替换涉及的远程链接并记录待配置项，见 [BASELINE_CHECK.md](BASELINE_CHECK.md)。
- [x] 使用完整 Xcode 构建主应用和 Network Extension，并检查其他现有 target。（2026-11-04：iOS `RuleProxy` 与 tvOS `RuleProxy TV` 无签名构建通过，Network Extension、Widget 随主应用一起构建；未签名、未运行。）
- [ ] 真机验证导入节点、连接、访问和断开。
- [x] 记录系统、工具链、测试配置及已知问题，建立版本基线。（系统/工具链/已知问题记录见 [BASELINE_CHECK.md](BASELINE_CHECK.md)；工作副本尚未纳入版本控制，版本基线待建立。）

验收：核心应用与扩展构建通过，真机基本连接可用；已有缺陷与新增问题可区分。

## 02：统一配置文件入口（第一个功能里程碑）

目标：使用 Surge 风格文本配置管理节点、DNS 与规则。

**服务层状态（2026-11-04）**：解析、校验、编译、快照、安装、扩展确认、重载分级、文件导入与反向导出均已完成；本阶段按要求只加功能，未编译、未运行测试；编辑器 UI 入口留到 07。

- [x] 确定首批配置样例与字段支持表。（样例：`TextConfigurationPipeline.template`；字段表：`Documentations/Configuration.md` 的 `[General]` / `[Proxy]` / `[Proxy Group]` / `[Rule]` 支持状态表。）
- [x] 实现配置文档模型，保留注释、顺序和原文。（`ConfigurationDocument` 524 行，`text` 原样回写；`ConfigurationDocumentEditing` 提供行/规则/设置编辑。）
- [x] 首批解析 `[General]`、`[Proxy]`、`[Proxy Group]`、`[Rule]`。（另含 `[Host]`、`[MITM]`、`[Script]` 与未知节保留。）
- [x] 明确每个字段的默认值和支持状态；未知关键配置不能静默忽略。（`ConfigurationValidator.Capabilities.current` 固定当前引擎能力；`unknownGeneralKey`、`notApplied`、`unsupportedRuleType`、`unknownProxyType` 均显式报出；`loglevel`、`[Script]`、`[MITM]` 证书字段按“已识别未生效”告警。）
- [x] 校验语法、行列位置、节点与策略组引用、循环引用及 FINAL。（`ConfigurationValidator`：`malformedRule`、`missingEquals`、`unknownPolicy`、`unresolvedPolicy`、`groupCycle`、`duplicateFinal`、`finalNotLast`。注意：`[General]` 键级告警暂不带行号，见进度记录。）
- [x] 接入现有节点、分组、设置与操作层，避免产生两套配置来源。（`ConfigurationInstaller`：节点→`ConfigurationStore`、分组→`GroupStore`、规则→`RoutingRuleSetStore`（按策略生成 `Config · POLICY` 并写 assignment）、`[Host]`→`HostMapping`、设置→`AWCore`；`installation.json` 记录归属，重复激活原地更新，手建节点不受影响。）
- [ ] 实现文件/文本导入、编辑、保存和激活入口。（服务层已完成：`ConfigurationImport.read(from:)` 文件导入，`ConfigurationActivation` 草稿/保存/激活/回滚/历史，`ConfigurationInstaller.activate(text:)` / `activate(contentsOf:)` 激活并落库且失败回滚；编辑器 UI 入口留到 07。）
- [x] 实现配置版本快照、扩展确认及失败恢复；区分热重载和需要重连的设置。（快照+manifest；`engine-confirmation.json` 由扩展在启动/规则热重载后写入；`ConfigurationReloadPlan` 分 `live` / `stackRestart` / `reconnect`。）
- [x] 为后续 `[Host]`、`[MITM]`、`[Script]` 和重写配置预留扩展结构。（解析、校验、诊断已覆盖；编译输出与安装步骤按字段留位。）
- [x] 反向导出当前配置为文本，作为文本配置的初始文档。（`ConfigurationExporter` 纯渲染 + `ConfigurationExporter+Stores` 读存储层；无法表达的项目——链、链分组、模块规则集、未分配策略的规则集、无分享链接的节点——写入 `notes`，名称按 `=`/`,`/`#` 净化并去重，`[MITM]` 只在有主机时输出。导出结果必须被 `TextConfigurationPipeline.process` 无错误读回，由 `ConfigurationExporterTests` 保证。）
- [ ] 验证正常导入、错误定位、引用失败、重载失败和应用重启恢复。（`RuleProxy Tests/ConfigurationTextTests.swift`、`OrderedRouteMatcherTests.swift`、`ConfigurationExporterTests.swift` 已写；本阶段按要求只加功能，尚未编译与运行。）

验收：一份最小配置可以加载节点和规则；错误配置不覆盖当前可用配置；页面设置与文本配置保持一致。尚未实现的规则类型明确提示，不伪装成已生效。

**验收状态（2026-11-04）**：前三项的服务层已具备（安装层写入既有存储、失败回滚、设置统一走 `AWCore`）；第五项由 `ConfigurationValidator` 的 `notApplied`/`unsupportedRuleType`/`unknownPolicy` 显式报出。整体验收待构建、测试与编辑器入口完成后再判定。

## 03：有序规则、GeoSite 与 GeoIP

目标：严格按配置顺序首条命中，FINAL 兜底。

**已有参考实现（2026-11-04）**：`Shared/Networking/Routing/OrderedRouteMatcher.swift` 已按原文顺序首条命中并支持 `FINAL`，GeoIP/GeoSite 通过 `GeoIPLookup` / `GeoSiteLookup` 注入（当前为空实现）；`TextConfigurationPipeline.Result.route(...)` 与 `CompiledConfiguration.orderedRules` / `finalAction` 已在用。待办是把这份语义接入 `routing.bin` 载荷与隧道执行路径，并确定 Geo 数据来源。

- [ ] 扩展现有规则模型和载荷，保留旧配置读取能力。
- [ ] 实现有序规则执行，索引加速不能改变原文顺序。
- [ ] 加入 GeoSite 域名匹配和 GeoIP IPv4/IPv6 匹配。
- [ ] 确定 Geo 数据格式、来源、随包基线、容量及更新方式。
- [ ] 实现数据库校验、原子更新、失败回滚和版本化缓存失效。
- [ ] 实现逐规则 `no-resolve`、唯一末尾 FINAL 和明确的 DNS 失败语义。
- [ ] 测试重叠规则、顺序调整、真实 IP、缺失数据库及不支持规则。

验收：支持 `GEOSITE,CN,DIRECT`、`GEOIP,CN,DIRECT,no-resolve`、`FINAL,PROXY`；首条命中后停止，不强制所有连接同时运行 GeoSite 和 GeoIP。

## 04：Fake-IP 与 DNS 解析

目标：恢复原始域名后分流，直连按需解析，代理优先保留域名。

- [ ] 复用并补齐 SyntheticAddressPool 的生命周期、回收、并发与耗尽处理。
- [ ] 映射缺失明确不可达，Fake-IP 不进入 GeoIP 或公网出站。
- [ ] 为现有 DNSResolver 增加解析目的及 Local / Proxy / Bootstrap 策略。
- [ ] 明确系统 DNS、第三方 DNS 的优先级、故障切换与缓存隔离。
- [ ] 检查节点、DoH 端点、订阅与 ECH 解析的依赖，避免循环。
- [ ] 接入 TCP/UDP 调度；DIRECT 域名决定路由后才真实解析。
- [ ] 核对各出站的域名目标能力；仅接受 IP 时使用显式解析策略。
- [ ] 验证 no-resolve 不产生主动 DNS、代理收到原域名、真实 IP 不反查。

验收：默认域名代理路径不产生本地真实目标解析；真实 IP 正确分流；解析失败和映射失败可诊断。

## 05：普通 DNS 拦截

目标：将受管 DNS 查询送入统一 DNS/Fake-IP 处理链。

- [ ] 将拦截目标和豁免范围改为可配置。
- [ ] 支持 UDP/53 与 TCP/53，包括 TCP 分段及连续查询。
- [ ] 处理 A、AAAA、其他查询类型、拒绝和例外域名。
- [ ] 明确 HTTPS/SVCB 及地址提示策略。
- [ ] 豁免内核自身上游、Bootstrap 和 Proxy Resolver，避免重新进入隧道。
- [ ] 用受控 DNS 服务、日志与抓包验证实际路径及无循环。

验收：不同 DNS 入口执行同一策略；上游故障可恢复；内核自身 DNS 不被重复截获。

## 06：DoH MITM 接管

目标：通过现有 MITM 接管指定 DoH 端点，复用统一 DNS 处理链。

- [ ] 接入 `[MITM]` 及有文档的 DoH 端点配置。
- [ ] 增加原生 DoH handler，支持 HTTP/1.1、HTTP/2 的标准 GET/POST。
- [ ] 解析 DNS wire format，正确合成 HTTP 与 DNS 响应。
- [ ] 验证 HTTP/2 多流、二进制、响应长度、缓存与大小限制。
- [ ] CA 安装、信任状态及指定主机启用流程可见。
- [ ] 明确证书固定、未知端点、QUIC 不回退等情况的拒绝或放行策略。
- [ ] DoT / DoQ 与 DoH 分开标记，不能误报已解密接管。
- [ ] 排除内核自身 DoH；原生 DNS handler 与后续第三方脚本执行顺序明确。

验收：被接管 DoH 与普通 DNS 的 Fake-IP、拒绝、例外行为一致；无法接管时明确反馈，不声称所有加密 DNS 均已覆盖。

## 07：后续 UI 改版

前面阶段先增加必要功能入口，本阶段统一页面与交互。

- [ ] 确认首页、配置、规则、DNS、MITM、脚本及诊断页面草案。
- [ ] 展示当前配置版本、激活状态、重载失败和恢复入口。
- [ ] 支持规则排序、数据库更新状态及脚本兼容提示。
- [ ] 诊断展示命中规则、解析通道、出站、MITM 与脚本结果。
- [ ] 验证深色模式、动态字体、长列表及现有平台布局。

验收：常用任务有清晰入口，文本与可视化编辑一致，状态真实且错误可操作。

## 08：Surge / Quantumult X 脚本兼容

- [ ] 对照官方文档与样例建立版本化兼容矩阵。
- [ ] 复用现有运行时，分别提供 Surge / Quantumult X 方言适配。
- [ ] 支持请求/响应上下文、`$done`、日志与参数。
- [ ] 支持请求/响应文本及二进制改写、合成响应与中止。
- [ ] 适配 `$httpClient`、`$task.fetch`、持久存储与通知 API。
- [ ] 支持相关脚本与 rewrite 配置子集导入，明确未支持项。
- [ ] 验证主动请求的 DNS/路由、自触发循环、超时、内存和并发限制。
- [ ] 使用实际脚本验证行为，不以导入成功代替运行兼容。
- [ ] 后续分别评估手动、定时、事件、DNS 脚本及策略控制。

验收：选定样例与实际脚本按预期运行；公布支持、部分支持、不支持及未验证清单。

## 09：双栈增强与发布前回归

完整 Fake-IPv6 单独推进；前面各阶段仍须回归现有 IPv6 行为。

- [ ] 实现 Fake-IPv6、AAAA 映射与 IPv6 TUN 接管。
- [ ] 验证 GeoIP IPv6、双栈候选选择、代理 IPv6 目标及 NAT64。
- [ ] 回归网络切换、前后台、隧道重启、配置恢复和数据库更新。
- [ ] 对比基线检查内存峰值、吞吐、连接数与长时间运行。
- [ ] 整理构建产物、配置示例、兼容矩阵和已知限制。

验收：约定支持范围均有测试记录，无阻断性缺陷；能力声明与实际验证范围一致。

## 下一步

**01 阶段：静态检查与无签名编译已完成，签名与真机验收未做，阶段尚未整体验收通过。** 具体结果见 [BASELINE_CHECK.md](BASELINE_CHECK.md)。

**02 阶段：服务层完成并通过构建与测试（66 个用例全通过），配置文件的应用内编辑页已落地；真机验收未做，阶段尚未整体验收。** 代码位于 `Shared/Configuration/` 与 `Shared/Operations/ConfigurationDocumentOperations.swift`，说明见 [Documentations/Configuration.md](Documentations/Configuration.md) 的「Editing inside the app」。

1. **[已完成 2026-11-04]** 构建 iOS 主应用与 Network Extension（0 error），并在 iPhone 17 模拟器跑通 `RuleProxy Tests`（66 个用例全通过）；下一步转为真机验收。
2. 在开发者账号中核对团队、Bundle ID、App Group、CloudKit、Network Extension 能力，配置签名后真机验证导入节点、连接、访问与断开。
3. 用真实品牌资源替换占位内容（`Shared/Assets.xcassets` 目前只有中性占位色板与空 `AppIcon.appiconset`，仅为通过编译）。
4. 如需内置服务/国家预设，把自备且符合表结构的 `Rules.db`（`rules(type,value,source)`、`metadata(key,value)`）加入主应用资源即可自动加载。
5. 真机验证配置页的四个动作：`Load from Current Setup` → 编辑 → `Apply to App` → 隧道按 `ConfigurationReloadPlan` 重载；节点、分组、规则的表单化编辑与设计稿仍属 07，进入 **03** 前先确定有序规则载荷格式与 Geo 数据来源。后续每完成一项更新本文件，并记录验证结果及未解决问题。
6. **让 profile 成为唯一真相源（按 Surge 语义逐节补齐）**，顺序按投入产出排：
   - [x] `[General]` 全量目录化：54 个键，加参数只需在 `ConfigurationSettings.catalog` 与 `ConfigurationSettingsBindings.all` 各加一条（2026-11-04 完成）。
   - [ ] `routing.bin` 有序规则 + `FINAL`：`CompiledConfiguration.orderedRules` / `finalAction` 已存在，缺的是载荷格式；这是「规则完全等同 Surge」的唯一硬缺口。
   - [ ] 补齐可编译规则类型：`DOMAIN`、`DOMAIN-WILDCARD`、`DOMAIN-REGEX`、`URL-REGEX`（匹配器已在 `OrderedRouteMatcher`），再谈 `RULE-SET`/`GEOIP`/`PROCESS-NAME`/逻辑规则。
   - [ ] `[Proxy Group]` 增加 `url-test` / `fallback` / `load-balance`，并把 `interval`、`tolerance`、`url` 变成参数。
   - [ ] `[MITM] hostname` 接进拦截列表（当前只应用 `enable`），`[Script]` 从“仅解析”到可执行。
   - [ ] `[Host]` 通配符、`[URL Rewrite]`/`[Header Rewrite]`/`[Map Local]`、`[SSID Setting]`、`[Module]`/`[Subscription]`/`[Chain]` 各节。
   - [ ] 语义待定：profile 是否完全取代页面（页面改动回写文本），或维持“文本 = 全量投影 + 页面保留选择状态/外观”。



## 平台范围更新

仅面向 macOS、iPadOS、iOS、tvOS。已删除 Watch 客户端、scheme、配对通信模型及桥接，清除本地包 watchOS 平台声明；保留服务于目标平台的 Widget、Network Extension 与测试。Reference 原始目录保持不变。

- [x] 清理 watchOS 客户端与配对通信；工程对象无悬空引用。
- [x] 解决 `https://github.com/hiDandelion/RuleProxyRules.git` 访问问题。（2026-11-04：该包为私有仓库，匿名访问 404，上游公开仓库也依赖同一私有地址；按“只参考核心组件”的要求已从工程移除，改为在 `Bundle.main` 读取可选的 `Rules.db`，详见 [Reference/Dependencies.md](Reference/Dependencies.md)。）
- [ ] 新增并验证 macOS 客户端。现有工程没有 macOS target，尚未启用 Mac Catalyst；不可将当前客户端声明为已经支持 macOS。
- [ ] 确定 macOS 原生或 Catalyst 实现路径，核对 UI、VPN 扩展、沙箱、签名与系统 API 差异后实施。
- [ ] iOS/iPadOS、tvOS 及 macOS 分别执行构建与运行验收。

## 进度记录

### 2026-11-05

- 配置热重载收敛成一张“主机说了什么 → 扩展做什么”的表（**未编译、未测试**：本机没有 `swiftc`/`xcodebuild`，只能由 CI 验证）：
  - 新增 `Shared/Configuration/RuntimeCoordinator.swift`：扩展与主应用共用的纯数据层，不做 IO。`Event`（`activeConfiguration` / `settings` / `routing` / `mitm`）带 `notificationName`、`init?(notificationName:)` 与 `notificationNames`——注册名单和解码来自同一个 `allCases`，所以“监听了却解不出来”的通知不可能存在；`Action`（`reloadHostMappings` / `reloadSettings` / `reloadRouting` / `reloadMITM` / `reloadActiveConfiguration` / `revalidateQUIC`）带 `requiresRunningPhase`；`Plan` 是有序动作表；`plan(for:)` 是唯一把事件翻成动作的地方。
  - 新增 `Shared/Configuration/ConfigurationCoordinator.swift`（只进主应用）：`ConfigurationModule`（rule / dns / mitm / outbound，含 `settingOwners`、`owning(section:)`、`owning(setting:)`）、`prepare(...)` 按模块报告一份文档（`ModuleReport` + 文档级诊断）、`plan(from:to:running:)` 借 `ConfigurationReloadPlan` 算出逐模块 `Change`（含 `payloadChanged`），以及 `announcements(for:)`——现在只有这一处决定“装完要发哪些通知”（改到 `[General]` 发 `settings`，改到 MITM 的键再补一个 `mitm`）。
  - 同一文件用 `nonisolated extension RuntimeCoordinator` 放主机侧桥：`Event(announcement)` 与 `plan(forAnnouncement:)`（名字避开 `plan(for: Event)` 的重载歧义）。扩展 target 不编译这个文件，因此全部 `Announcement` → `Event` 的转换只出现在这一处。
  - `ConfigurationInstaller` 不再自己挑通知，一律走 `ConfigurationCoordinator.announcements(for:)`；扩展侧按 `Event.notificationNames` 注册、按 `plan(for:)` 执行。
  - 扩展侧删除旧的 `RuntimeCoordinator.swift`，四个 `handleXChanged()` 拆进 `RuleProxy Network Extension/Tunnel/TunnelStack+Runtime.swift`：`runSettingsObserver()` + `apply(_ plan:)`（按 `requiresRunningPhase` 过滤）+ 每个动作一个方法。逐条对齐旧实现：`reloadHostMappings` = 旧的 `DNSHosts.shared.invalidate()`（唯一在非 running 阶段也执行的一步，避免陈旧的 `[Host]` 覆盖活到下一次启动）；`reloadSettings` = 旧的 `handleSettingsChanged` 全部后续（`publishUDPConfig`、QUIC 重校验、`preventDNSLeak` 存储、reflection 重发布、`requestReapplyTunnelSettings`、代理模式变化时 `restartStack`）；`reloadRouting` = 旧的 `handleRoutingChanged`（编译 → 再次确认仍在 running 且为 rule → `install` + `clearRejectMarks` + 记录引擎确认）；`reloadMITM` + `revalidateQUIC` = 旧的 `handleMITMChanged`（顺序不变）；`reloadActiveConfiguration` = 旧的 `handleActiveConfigurationChanged`。
  - `TunnelStack+Lifecycle` 只剩启动时的一次 `runSettingsObserver()`（全仓唯一调用点），`restartStack` 从 `private` 放宽到 internal 供重载路径复用，`recordEngineConfirmation()` 保留；规则热重载后的确认写入移进 `reloadRouting`。
  - `RuleProxy.xcodeproj`：`Shared` 文件夹在扩展 target 的例外集合新增 `Configuration/RuntimeCoordinator.swift`（`Configuration/EngineConfirmation.swift` 本就在其中），`ConfigurationCoordinator.swift` 继续不参与扩展编译。
  - 新增 `RuleProxy Tests/ConfigurationCoordinatorTests.swift`：把两张表钉在一起——每个 `applies: true` 的键必须有归属模块、未生效的键不许有归属、每个键只出现在一个模块、节名到模块的映射、`prepare` 的逐模块报告与未认领诊断留在文档上、`plan` 的逐模块变更、`Announcement` ↔ `Event` 一一对应（主机能发而扩展不认识时判失败，而不是静默丢弃）、每个 `Announcement` 都规划出非空动作、动作顺序、只有 `reloadHostMappings` 允许在非 running 阶段执行。
  - 文档：`Documentations/Configuration.md` 的 `live` 一行改指 `ConfigurationCoordinator` / `RuntimeCoordinator` / `TunnelStack+Runtime.reloadSettings()`，并新增 “Announcements” 一节说明这套契约。
  - 未验证（等 CI）：上述新文件的编译、target 成员（`RuntimeCoordinator.swift` 进扩展、`ConfigurationCoordinatorTests.swift` 进测试 target）、`ConfigurationDiagnostic` 的初始化形状、`ConfigurationReloadPlan.change(for:)` / `payloadChanged`、`CompiledSettings` 下标、`DomainRouter.compileRoutingConfiguration`、`EngineConfirmationStore.recordRunningSnapshot` 的可见性；`ConfigurationSettingsTests` / `ProfileEditorModelTests` / `ConfigurationTextTests` 是否因 API 迁移需要同步修改。


### 2026-11-04

- 移除从上游继承的 Anywhere/Voyager 付费与 Telegram 群组功能：删除 StoreKit 内购层（`RuleProxy/Stores/VoyagerStore.swift`）、付费墙与公开测试页（`VoyagerNotice`、`JoinVoyagerButton`、`JoinBetaView`），移除会员卡片与 `isMember` 门禁，`AWCore`/`AppSettings` 删除会员相关 UserDefaults 键，`AboutView` 移除 Telegram 群组链接，`Localizable.xcstrings` 删除 22 个失效键（478 → 456）。
- 依赖收敛：核对 5 个 SwiftPM 依赖，确认 `RuleProxyIP`、`RuleProxyQUIC`、`BLAKE`、`YAML` 为仓库内核心组件且无远程依赖；`RuleProxyRules`（上游 `AnywhereRules`）为私有仓库（匿名 404、搜索 0 命中、上游公开仓库同地址），已从工程移除，改为 `RoutingRulesDatabase` 在 `Bundle.main` 读取可选 `Rules.db`。工程现无远程依赖，`Package.resolved` 随之为空。
- 补齐编译所需占位资源 `Shared/Assets.xcassets`（9 个中性色板 + 空 `AppIcon.appiconset`）：本仓库与上游公开仓库都没有 `.xcassets`，源码依赖资源符号，缺资源无法编译。
- 编译验证（Xcode 27.2，无签名）：
  - `RuleProxy`（iOS，含 Network Extension、Widget）→ BUILD SUCCEEDED，0 error。
  - `RuleProxy TV`（tvOS）→ BUILD SUCCEEDED，0 error。
- 记录：构建明细见 [BASELINE_CHECK.md](BASELINE_CHECK.md) 的“构建验证”一节；依赖与恢复步骤见 [Reference/Dependencies.md](Reference/Dependencies.md)。
- 未完成：签名与真机连接验证、真实品牌资源替换、`RuleProxy Tests` 单元测试、内置路由预设（需自备 `Rules.db`）。

- 02 阶段文本配置落地（只加功能，未编译、未运行测试）：
  - 新增 `Shared/Configuration/`：`ConfigurationDocument`（无损原文/注释/顺序）、`SurgeConfigurationParser`、`ParsedConfiguration`、`ConfigurationValidator`、`ConfigurationCompiler`、`ConfigurationSnapshotStore`、`TextConfigurationPipeline`、`ConfigurationDiagnostics`、`ConfigurationDocumentEditing`（编辑返回重新解析的文档）。
  - `ConfigurationValidator.Capabilities.current` 固定当前引擎能力（4 种规则、无 FINAL、无逻辑/Geo、组仅 `select`），不支持项按 `info`/`warning` 报出；新增 `notApplied` 代码，`[General]` 已识别未生效键、`[MITM]` 证书字段、`[Script]` 声明、字段式节点被丢弃的选项都会显式告警，不再静默忽略。
  - 新增 `ConfigurationInstaller`：把编译结果写入既有存储层（节点/分组/规则集/`[Host]`/`AWCore` 设置），按 `installation.json` 记录归属，重复激活原地更新并清理文档已删条目，不触碰手建节点；`activate(text:)` 在安装失败时回滚 manifest 并重新安装旧快照。
  - 新增 `ConfigurationReloadPlan`（`live` / `stackRestart` / `reconnect` 分级）与 `EngineConfirmation.swift`（扩展侧写入 `engine-confirmation.json`，`isActiveSnapshotConfirmed()` 区分“已激活”与“已在运行”）；`TunnelStack+Lifecycle` 在启动与规则热重载后各写一次确认。
  - 新增 `OrderedRouteMatcher`（按原文顺序首条命中，GeoIP/GeoSite 可注入），`TextConfigurationPipeline.Result.route(host:ip:port:)` 与编辑器预览共用同一匹配器。
  - 新增 `Documentations/Configuration.md`：节/字段支持状态表、诊断代码表、重载分级、限制与已知缺口（有序载荷、Geo 数据、脚本、MITM 主机表、`loglevel`、macOS）。
  - 待办：`RuleProxy Tests` 中 `ConfigurationTextTests`、`OrderedRouteMatcherTests` 尚未编译运行；`[General]` 键级告警暂无行号；编辑器 UI 入口（07）；有序规则尚未进入 `routing.bin`。
  - `ConfigurationValidator` 新增 `ruleValueTooLong`：路由载荷把规则值长度存为 `UInt16`，超长值原本在写 `routing.bin` 时被静默跳过，现在按 error 在校验阶段拒绝，符合“未知/不支持不能静默忽略”的约束。
  - 文档同步（2026-11-04）：新增 `Documentations/Configuration.md` 并加入 README 的 Documentation 列表；`DEVELOPMENT_PLAN.md` 的 4.6 增加实现状态表、§7 的 P1 两项勾选并补充下一步顺序；本文件补 02 服务层/验收状态、03 参考实现状态并重写“下一步”。
  - 新增反向导出（存储层 → 文本）：`Shared/Configuration/ConfigurationExporter.swift` 是纯渲染（`ConfigurationExportSource` → Surge 风格 INI），`ConfigurationExporter+Stores.swift` 读取节点/链/分组/规则集/MITM/`[Host]`/`AWCore` 设置，并优先于 `TextConfigurationPipeline.template` 作为“从当前设置生成初始文档”的入口。无法表达的项目（链、链分组、模块规则集、未分配策略的规则集、无分享链接的节点、无主机的 `[MITM]`）只写进 `notes`，不臆造策略；名称按 `=`/`,`/`#` 净化并去重（重复名在解析侧是 error）；生成的 `FINAL` 用 `PROXY`（内核的终止动作）。新增 `RuleProxy Tests/ConfigurationExporterTests.swift`：每个样例都要求 `TextConfigurationPipeline.process` 零 error，保证导出与解析不漂移。
  - 未做：导出只覆盖导出方向，导入侧“保节 + 告警”的 `[Script]`、`[URL Rewrite]`、`[Header Rewrite]` 不生成；导出目标只限本应用能读回的 Surge 风格语法，不针对其他客户端的方言。（导出器已于 2026-11-04 编译通过并跑通测试，见下方“编译与测试验证”。）
  - 配置文件在应用内双向出入值（07 的第一个入口，未编译未运行）：
    - 新增 `Shared/Operations/ConfigurationDocumentOperations.swift`：存储 → 文本走 `ConfigurationExporter.exportCurrentConfiguration`，文本 → 存储走 `ConfigurationInstaller.activate(text:)`；`draft()` / `saveDraft()` / `preview()` / `appliedAt()` / `history()` 全部复用现有 `ConfigurationActivation`，没有第二条解析路径。
    - 新增 `RuleProxy/Views/Pages/Configuration/ConfigurationView.swift`：`TextEditor` 编辑文档，输入后 250 ms 重编译（`TextConfigurationPipeline.process`）并自动保存 `draft.txt`；显示节点/分组/规则集/规则/`[Host]` 计数与逐条诊断（错误/警告/信息）；`Apply to App` 在有 error 时禁用，成功后显示 `Outcome.summary` 与已应用快照列表；`Load from Current Setup` 用导出器把现有设置灌进缓冲区并展示 `notes`；`Import File`（UTF-8、1 MB 上限）只载入不应用；`Export File` 走系统分享。
    - 入口：`Page.configuration`（侧边栏与 `TabView` 的 `VPN` 分区）+ `ToolboxView` 的 `Configuration` 行；`RuleProxy/` 目录不参与 TV target（TV 的同步组只有 `RuleProxy TV` 与 `Shared`），因此没有在 tvOS 上引入 `fileImporter`/`TextEditor` 这类 tvOS 不可用 API。
    - 明确不做的：不做自动应用、不监听外部文件、`LSSupportsOpeningDocumentsInPlace` 保持 `NO`（`draft.txt` 不是 `open-in-place` 文档，编辑器是唯一写入方）；存储仍是唯一真相源。
    - 未验证：`ConfigurationView` 与 `ConfigurationDocumentOperations` 尚未编译；`ConfigurationInstaller.activate(text:)` 首次真实调用未在设备上跑过。
  - 编译与测试验证（2026-11-04，Xcode 27.2，`CODE_SIGNING_ALLOWED=NO`）：
    - `RuleProxy`（含 Network Extension、Widget）→ **BUILD SUCCEEDED**，0 error；`ConfigurationView.swift`、`ConfigurationDocumentOperations.swift` 均参与编译（日志 `/tmp/ruleproxy_build.log`）。
    - `RuleProxy Tests` 在 iPhone 17 模拟器 → **TEST SUCCEEDED**，40 个用例全部通过、0 失败（`ConfigurationTextTests` / `ConfigurationExporterTests` / `OrderedRouteMatcherTests` / `DeterministicBytesTests`，日志 `/tmp/t3.log`）。此前 02 的“测试未运行”状态到此结束。
    - 首次测试运行前，应用在无签名模拟器上启动即崩溃：`AWCore.routingDataURL`/`mitmDataURL` 强制解包 App Group 容器（`SIGTRAP` 于 `AWCore.mitmDataURL` 的一次性初始化）。改为与 `ConfigurationSnapshotStore` 相同的兜底（容器不可用 → `URL.temporaryDirectory`），启动不再崩溃；该环境下主应用与扩展自然无法共享 `routing.bin`/`mitm.bin`。
    - 同时修正一个语义陷阱：`Policy(token:)` 先大写再匹配，名为 `Proxy` / `Direct` 的节点或分组永远无法被规则引用。新增诊断 `reservedPolicyName`（warning，节点与分组都检查），导出器对这类名称追加 `_` 并写 `notes`，模板示例节点 `Proxy` → `Node`；新增用例 `warnsWhenANodeNameIsABuiltInPolicy`、`renamesNodesThatShadowAPolicyToken`。
    - 仍未验证：真机与签名、VPN 启停、`Apply to App` 在真实隧道上的重载行为、编辑器在大量规则（10 万级）下的输入延迟。
  - `[General]` 改为“设置目录”（settings catalog）驱动，目标是“加一个功能只加一个参数”：
    - 新增 `Shared/Configuration/ConfigurationSettings.swift`：`ConfigurationSettingKey` 用一张表声明每个键的名称、取值形状（`flag`/`text`/`enumeration`/`countryCode`/`list`/`plainServer`/`dohURL`）、重载级别与是否生效；`ConfigurationSettingsBindings.all` 声明该键在 `AWCore` 的读写位置。解析、校验、编译、安装、导出、重载分级、诊断文案全部从这两张表读取，不再各写一份键列表。
    - `[General]` 覆盖从 17 个键扩到 54 个：新增 `dns-mode` 与另外四个 DNS 通道的模式键、`proxy-dns-server`/`proxy-encrypted-dns-server`、`subscription-dns-*`、`fallback-dns-mode`/`fallback-dns-server`、`ech-dns-*`、`synthetic-address-excluded-suffix`、`exclude-device-communication`、`always-on`、`allow-insecure`、`trusted-certificate`、`trusted-ssid`、`always-trust-cellular`、`always-untrust-cellular`、`reflection`、`experimental`；仍标记为“已识别未生效”的 Surge 键单独保留并逐个告警。
    - `CompiledSettings` 由“每字段一个可选属性”改为按名称存值（`[String: ConfigurationSettingValue]`），`ConfigurationReloadPlan.make` 改为按目录顺序遍历并取该键声明的重载级别；`ConfigurationInstaller.apply`、`ConfigurationExporter.exportSettings` 同样改为遍历目录，三者不会再漏掉新键。
    - `ConfigurationValidator.knownGeneralKeys` / `acceptedGeneralKeys` 由目录派生，`validateGeneral` 按键声明的形状校验，报错文案会写出该键接受的取值（如 `must be one of rule, global, direct`）。
    - 新增 `RuleProxy Tests/ConfigurationSettingsTests.swift`（19 个用例）：目录与绑定表互为子集（防止“声明了却生效不了”或“绑定了却没声明”）、`applies: false` 不允许有绑定、键名唯一且为小写 kebab-case、每种形状的解析、编译只取文档写到的键、`[MITM] enable` 优先、未识别/未生效诊断、导出值与解析值互逆、重载分级来自目录。
    - 验证（2026-11-04，Xcode 27.2，`CODE_SIGNING_ALLOWED=NO`）：`RuleProxy` → **BUILD SUCCEEDED**，0 error；`RuleProxy Tests` → **TEST EXECUTE SUCCEEDED**，66 个用例 / 6 个 suite 全部通过、0 失败（日志 `/tmp/tB.log`）。
    - 文档：`Documentations/Configuration.md` 的 `[General]` 表换成完整 54 键表（含取值、重载级别、状态），新增「Adding a setting」一节说明两步扩展法与 `applies: false` 的用法。
    - 仍未做：`[Proxy Group]` 组类型、`[Rule]` 有序规则与 `FINAL` 载荷、`[MITM] hostname`、`[Script]` 执行、`[URL Rewrite]`/`[Header Rewrite]`/`[Map Local]`、`[Module]`/`[Subscription]`/`[Chain]` 等节；选择状态与外观设置不在 profile 内（仍由页面管理）。

  - 编辑器会话层独立（`ProfileEditorModel`），为“配置文件取代页面设置”铺路：
    - 新增 `Shared/ViewModels/ProfileEditorModel.swift`：把原先散在 `ConfigurationView` 里的会话逻辑收进一个 `@MainActor @Observable` 状态机——`text` / `preview` / `baseline` / `history` / `notes` / `lastAppliedAt` / `lastOutcome` / `statusMessage` / `errorMessage` / `isApplying` / `isLoaded`，动作 `load()`、`edit(_:)`、`refreshPreview()`、`apply()`、`reloadFromCurrentSetup()`、`importFile(at:)`、`revert(to:)`、`discardChanges()`、`report(_:)`、`dismissError()`、`dismissMessages()`。250 ms 去抖由模型持有（`previewDelay` 可注入），`text` 对外只读，视图无法绕过预览与草稿写入。
    - 新增 `ProfileEditing` 协议作为流水线与 UI 之间的缝：`ConfigurationDocumentOperations` 提供实现（`loadDraft` / `persistDraft` / `previewDocument` / `applyDocument` / `exportDocument` / `readDocument(at:)` / `lastAppliedAt` / `appliedHistory`），测试用桩件替代，不需要 App Group 容器或隧道。`applyDocument` 只回传 `ProfileApplyOutcome`（summary / notes / plan），页面不再依赖 `ConfigurationInstaller.Outcome` 全量结构。
    - 页面改名并瘦身：`RuleProxy/Views/Pages/Configuration/ConfigurationView.swift` → `RuleProxy/Views/Pages/Profile/ProfileView.swift`（只渲染），侧边栏与 `Toolbox` 三处引用同步；`Page.configuration` 文案与 `navigationTitle` 仍是 “Configuration”，用户可见名称不变。命名理由：本工程 `Configuration…` 已指“节点”（`ProxyConfiguration` / `ConfigurationStore`），profile 指整份文本配置。
    - 补上原来算出来却没展示的信息：`ConfigurationReloadPlan` 的逐项变更与分级（`Applies immediately` / `Restarts the tunnel data plane` / `Requires reconnect`）进入「Last Apply」区并给出对应操作提示；`isDirty` 在表头（Unsaved）与 footer 双重呈现，新增 `Discard Changes`；历史行可把旧快照文本放回编辑器复核。
    - 新增 `RuleProxy Tests/ProfileEditorModelTests.swift`（14 例）：`load()` 幂等且不丢输入、编辑即脏并立即重编译与写草稿、去抖合并连续输入（只编译一次）、有 error 时 `canApply == false`、被拒绝的 apply 不动缓冲区且保留错误、成功 apply 刷新 baseline / 历史 / `appliedAt` / reload 提示、live-only 变更不要求重连、导入失败保留原文本、导入成功仍为脏、`revert(to:)` 把旧快照放回缓冲区、`discardChanges()` 恢复已应用文本且无改动时不写盘、`reloadFromCurrentSetup()` 带回导出 notes。
    - 文档：`Documentations/Configuration.md` 重写「Editing inside the app」并新增「Where this is heading」——配置文件作为写入入口，页面按“文本能否完整表达 + 能否经 `Load from Current Setup` → `Apply` 往返”逐项收缩；`[Proxy Group]` 类型、有序规则 / `FINAL` 载荷、`[MITM] hostname`、`[Script]` 被明确列为“删页面前的前置条件”，而不是后续优化。
    - 验证（2026-11-04，Xcode 27.2，`CODE_SIGNING_ALLOWED=NO`）：`RuleProxy` → **BUILD SUCCEEDED**，0 error（日志 `/tmp/pB.log`，改动收敛后再增量构建一次 `/tmp/pD.log`）；`RuleProxy Tests` → **TEST SUCCEEDED**，7 个 suite、73 个用例通过、0 失败（日志 `/tmp/tG.log`，最后一次全量复跑 `/tmp/tH.log`；`ConfigurationConnectivityTests` 7 例按 `TestEnvironment` 未配置跳过）。首轮 2 例失败是样例文档问题（与桩件默认草稿同文本导致 `edit()` 提前返回、样例用了当前引擎不支持的 `FINAL`），已修正并附说明于 `BASELINE_CHECK.md`。



### 2026-11-03

- 复制工作工程并保留 `Reference/Anywhere` 原始对照；将 Anywhere 命名批量替换为 RuleProxy。
- 删除 Watch 客户端、scheme、配对通信与桥接，清理本地包 watchOS 声明；移除仓库中不存在的 StoreKit 配置引用。
- 工程静态检查：pbxproj 格式、同步目录、本地包、Info.plist、entitlements、scheme 引用；结论见 [BASELINE_CHECK.md](BASELINE_CHECK.md)。


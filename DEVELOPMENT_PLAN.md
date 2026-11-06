# NaiveFlow / NaiveFlowS 开发计划

> 当前范围更新（2026-11-06）：首版只支持 IPv4。IPv6 地址、规则、解析、协议地址编码及 IP 栈处理已移除；IPv6 后续规划不再属于本版范围。仅保留 TUN 捕获并丢弃非 IPv4 流量的防绕行处理。以下旧排期中的 IPv6 条目不代表当前能力，最新边界见 Documentations/IPv4Only.md。


更新日期：2026-11-06

## 1. 目标与依据

本任务是在现有 NaiveFlow 项目上增量增加功能。直接沿用现有 Xcode 工程、应用结构、协议栈、隧道和数据存储，不新建应用工程，不安排品牌替换、Bundle ID、签名或 App Group 调整，也不额外拆分独立网络内核。NaiveFlow / NaiveFlowS 沿用讨论中的称呼。按用户说明的授权前提开展开发，不增加项目内授权声明任务。

本计划已融合用户粘贴的 ChatGPT 建议。现有项目位于 `Reference/Anywhere`，基线提交为 `9e3790af`（2.5(414) RC）；现已将工程复制到工作区根目录，工作入口为 `NaiveFlow.xcodeproj`；后续只修改根目录副本，`Reference/Anywhere` 保留对照。复制排除 `.git`、用户设置和构建缓存，源码已校验一致。对话中提到的“配置解析、正则加载校验和独立匹配器已完成”尚需核实，不据此重复实现或认定已完成。

首版技术目标：

- 使用统一文本配置作为节点、DNS、规则和 DNS 拦截策略的配置入口，支持导入、编辑与重载。
- 接管普通 UDP/TCP DNS，统一进入 Fake-IP / DNS 策略处理。应用内 DoH/DoH3 作为普通 HTTPS/QUIC 流量分流，不进行专用 MITM 解密、重新查询或响应合成。

- 同时支持 GeoSite 域名判断与 GeoIP 真实 IP 判断。
- 严格按配置顺序匹配，首条命中生效；命中后停止，不要求每个连接强制执行全部规则。
- Fake-IP 恢复原始域名，规则决定路由，DNS 按需要解析，出站负责实际连接。
- 推荐默认 FINAL 指向境外代理，但保持用户可配置。
- 国内域名命中 DIRECT 后本地解析；代理域名优先保留域名交给远端解析。
- 真实 IP 按 IP 规则处理，不反向解析域名；Fake-IP 不能送给公网或 GeoIP 数据库。

沿用项目现有平台和最低系统版本，优先以 iPhone/iPad 验证新增网络行为，并检查共享代码改动对其他现有 target 的构建影响。首版不承诺完整 Surge 配置兼容，不把新增 GEOSITE 语法描述为 Surge 原生能力。

## 2. 与 NaiveFlow 的实际差异

| 模块 | 已检查的现状 | 计划改动 |
| --- | --- | --- |
| 规则模型 | `Shared/Models/RoutingRule.swift` 只有后缀、关键词、IPv4/IPv6 CIDR；动作按规则集分配 | 新增有序规则、单条动作、GeoSite、GeoIP、FINAL、no-resolve，必要时补域名精确匹配 |
| 匹配与载荷 | ARB2 包含五层来源优先级；与配置首条命中语义不同 | 引入有序中间表示与新版载荷；索引命中保留原规则序号，不允许索引改变优先级 |
| 路由 | `ConnectionRouter.swift` 对未命中域名可能预热 IPv4 DNS 后尝试 IP 规则；由全局 preventDNSLeak 控制 | 改为规则级按需解析，严格执行 no-resolve，异步完成后从原位置继续判断 |
| Fake-IP | 已有 `SyntheticAddressPool`，映射缺失返回 unreachable | 复用并验证生命周期、地址回收、并发、规则版本失效；沿用现有类名，按需补齐能力 |
| IPv6 DNS | 检查到的 `UDPPlane.swift` 合成 DNS 路径对 AAAA 返回 NODATA | 分阶段实现 Fake-IPv6 与 IPv6 接管；不能仅打开 ipv6 开关声称已完整支持 |
| DNS | 已有 `Shared/Networking/DNS/DNSResolver.swift` 和用途相关配置 | 统一解析目的、出站策略、Bootstrap 依赖与缓存隔离 |
| 出站 | 已有多个协议的 ProxyClient 实现 | 逐协议核对 TCP/UDP 域名目标支持，建立能力表，禁止隐式本地解析回退 |

核心变化涉及执行语义，不能只新增两个枚举或改几个页面。优先在现有路由模块内增加有序规则执行能力，保留旧配置读取与原有规则行为。新有序规则入口明确使用首条命中语义；旧规则只有在能够等价转换或经用户主动转换后才进入新语义，避免全量替换引擎。

## 3. 默认规则与行为契约

以下为目标配置语义，不代表当前解析器已支持：

```ini
[Rule]
# 用户例外规则放在需要的位置
# 私有网络使用完整、可审查的 IPv4/IPv6 CIDR 规则集
GEOSITE,CN,DIRECT
GEOIP,CN,DIRECT,no-resolve
FINAL,PROXY
```

私有网络规则应独立于 GeoIP CN；回环、链路本地、ULA、组播、保留地址分别制定策略，不能笼统全部当成局域网直连。Fake-IP 地址范围先识别恢复，不能被普通保留地址规则提前放行。

| 输入 | 判断与结果 | 允许的目标 DNS |
| --- | --- | --- |
| Fake-IP 映射域名命中 GeoSite CN | DIRECT，随后真实解析连接 | 指定 Local Resolver |
| 域名未命中，只有 GeoIP no-resolve，且没有可用真实 IP | 跳过该 IP 规则，FINAL PROXY，传域名 | 不主动发送目标本地 DNS |
| 未收录的国内域名 | 默认也可能 FINAL PROXY | 代理远端解析 |
| 真实 CN IP | 跳过域名规则，GeoIP 命中后 DIRECT | 不需要 DNS |
| 真实非 CN IP | 未命中后 FINAL PROXY，传原始 IP | 不需要 DNS，不做反查 |
| Fake-IP 映射缺失 | 返回明确不可达并记录原因 | 不猜域名、不连接 Fake-IP |
| 不带 no-resolve 的 IP 规则遇到域名 | 按策略解析真实 IP，再执行当前规则 | 明确指定的规则解析通道 |
| DIRECT 域名解析失败 | 连接失败并报告错误 | 不暗中切换代理或未知 DNS |

no-resolve 只限制该规则为匹配主动解析，不限制后续 DIRECT 建连解析。已有真实 IP 必须来源明确、未过期且符合解析上下文；不能无条件使用其他 DNS 策略留下的缓存。Fake-IP 从不算已有真实 IP。

DNS 失败不是 GeoIP 非 CN。首版将其作为独立结果，按显式失败策略继续后续规则或终止；推荐继续至后续规则及 FINAL，同时保留失败诊断。配置加载必须要求唯一且位于末尾的 FINAL，错误配置在激活前拒绝。

## 4. 内核模块设计

### 4.1 扩展现有 SyntheticAddressPool

优先复用 SyntheticAddressPool，提供 domain ↔ fake address 查询、A/AAAA、TTL、映射代次和规则版本。域名大小写、尾点、IDNA 采用统一规范化。明确缓存淘汰、池耗尽和重启行为。

映射不能因 DNS TTL 到期立即复用给另一个仍可能被连接的域名；设计活跃连接引用、保留窗口和容量上限。映射变化后不允许旧连接误路由至新域名。规则决策缓存须随规则与数据库版本失效。

### 4.2 扩展现有 DNSResolver

定义解析目的：directConnection、ruleEvaluation、proxyBootstrap、explicitDNSQuery；传输策略：system、local、proxy、automatic。automatic 根据目的与显式策略执行，不直接继承 FINAL。

- Local Resolver：系统 DNS 和用户第三方 DNS，用于直连及允许的规则解析。明确顺序、超时、故障切换；不默认把所有上游并发竞速。
- Proxy Resolver：明确需要客户端解析时经指定代理访问 DoH 等上游。DoT 作为后续独立能力，首版优先复用现有 UDP/DoH。
- Bootstrap Resolver：解析节点及加密 DNS 主机，建立可验证的依赖图。指定可直达种子或本地上游，拒绝循环配置。
- 系统 DNS 来源在隧道外发现，并验证套接字不会被重新截获；网络切换后更新来源与缓存。不能假定系统解析 API 自动绕过 TUN。
- 缓存按域名、类型、解析目的、上游策略及配置代次隔离，支持正负缓存与失败区分。
- 主应用订阅、节点、ECH 和回退解析也纳入用途清单，避免仅约束目标域名却遗留旁路。

首版默认隐私目标是：支持域名出站且无主动 IP 解析规则时，FINAL 代理目标不产生本地真实解析。Bootstrap 或用户显式允许的本地规则解析应可观察。应用自带 DoH/DoH3 按普通流量规则选择出口；不解密其 DNS 内容，也不将其查询重新送入 Fake-IP 引擎。

### 4.3 Geo 数据与规则引擎

GeoSite 与 DNSResolver 独立，GeoIP 只接收真实 IPv4。2026-11-06 已完成外部 V2Ray geoip.dat/geosite.dat、CIDR/域名文本导入；按分类选择、属性筛选和原生匹配条件固定到运行版本。没有随包默认数据库，不支持任意数据库格式。详见 [GeoDatabases.md](Documentations/GeoDatabases.md)。

更新由用户重新应用配置触发；下载、大小、可选摘要及内容检查在发布前完成，失败保留旧版本，恢复上一运行版本不重新下载。前缀桶、域名集合/标签及关键字自动机加速查询，正则预编译。主配置首条命中和 no-resolve 的语义不变。

本阶段按要求只交付代码，未运行测试、性能基准或真机验收；容量上限不能当作性能保证。

### 4.4 接入现有连接调度与 ProxyClient

DIRECT：真实 IP 原样连接；域名在决定路由后按 Local Resolver 解析。PROXY：域名能力可用时传域名，真实 IP 原样传递。仅接受 IP 的出站必须使用显式 Proxy Resolver 等策略，否则报告不支持，不能暗中走运营商 DNS。

TCP 和 UDP 使用相同路由上下文。UDP 首包等待异步决策须有容量与时间限制。SNI/QUIC 嗅探作为补充信息，不能随意覆盖 Fake-IP 恢复的原始域名或已执行的出站；确定重判窗口、信任优先级和审计字段。

### 4.5 IPv4-only 范围

首版仅处理 IPv4 数据包、A 记录、IPv4 上游和 IPv4 CIDR；IPv6 不在开发范围。系统级防绕行仍须真机验证。

### 4.6 统一文本配置：导入、编辑、校验、重载

用户已确认：统一文本配置是节点、DNS、规则的配置入口，支持导入、编辑和重载。沿用现有工程，增加配置文档及编译层，不另建应用。

用户进一步确认：配置文件采用 **Surge 风格的 INI 分节与配置语法**，不是仅使用类似的分节名称。以单文件 profile 为核心入口，尽量沿用常见节名、`key = value` 参数、逗号分隔规则及脚本声明方式。自有扩展如 GEOSITE 需明确标注；相似语法不等于完整 Surge 行为兼容。

配置范围按功能分批覆盖：

| 节 | 计划用途 |
| --- | --- |
| `[General]` | DNS、Fake-IP、IPv6 等全局设置，优先采用对应的 Surge 风格字段；自有字段单独说明 |
| `[Proxy]` | 节点声明；仅接受现有协议实现及明确适配的参数 |
| `[Proxy Group]` | 策略组、成员与选择；先适配现有分组能力，缺少的策略类型单列实现 |
| `[Rule]` | 按原文顺序执行的规则、策略目标、no-resolve 与 FINAL；包含自有 GEOSITE 扩展 |
| `[Host]` | 静态域名映射及其与 Fake-IP、真实解析的优先关系 |
| `[MITM]` | 主机范围、证书相关引用与开关；不默认明文导出 CA 私钥 |
| `[Script]` | Surge 风格脚本声明，接入后续脚本兼容阶段 |
| `[URL Rewrite]`、`[Header Rewrite]` | 后续重写能力与现有 MITM 的映射，按兼容矩阵逐步实现 |

原生 `[DNS]` 节集中设置传统 DNS、DoH 和 bootstrap；保留已支持的 `[General]` 字段别名，重复定义会报错。额外解析用途使用有文档的自有配置字段；不增加 DoH MITM 接管字段。

示意轮廓（省略节点定义，PROXY 为待定义的节点或策略组名，不可直接作为可运行配置）：

```ini
[General]
dns-server = system, 223.5.5.5

[Proxy]
# 使用现有内核支持的协议和已适配参数定义节点

[Proxy Group]
# 定义名为 PROXY 的策略组并引用实际节点

[Rule]
GEOSITE,CN,DIRECT
GEOIP,CN,DIRECT,no-resolve
FINAL,PROXY

[MITM]
# 按已实现的字段配置证书与主机范围

[Script]
# 后续按 Surge 风格声明请求/响应脚本
```

P0 输出字段级兼容表：字段、默认值、取值、支持状态、运行语义及错误信息。导入 Surge profile 时预览可用项、自有扩展和不支持项；不得静默丢弃会改变路由或 DNS 的配置。Quantumult X 配置作为独立导入适配器转换到同一模型，不将两种配置语法混在同一文件中。

解析器覆盖注释、空白、重复项、值中的逗号/等号/URL、规则与脚本参数，并以固定版本的官方配置示例建立语法测试。配置语法的具体支持项随实现公布，不能视为当前解析器已经支持。

处理链路：文件/文本导入 → 原文保存 → 解析并定位行列错误 → 语义校验 → 编译规则、DNS、节点和 MITM 配置 → 生成同一版本快照 → 扩展准备并确认 → 激活。

- 统一原文为配置来源；现有设置页改为对同一配置模型的编辑入口，避免设置页和文本各保存一套互相覆盖。
- 编辑采用保留注释、规则顺序及未知字段的文档表示。未知能力可保存原文，但激活时必须明确告警或拒绝，禁止静默忽略关键字段。
- 校验节点引用、FINAL、Geo 数据、DNS 依赖、地址范围、MITM 主机与证书状态；错误显示行号和原因。
- 重载采用 prepare/commit 确认机制；解析、编译或扩展准备失败时继续使用旧快照。配置、Geo 数据及 DNS/MITM 策略必须形成一致版本。
- 明确哪些项热生效、哪些需要重建隧道；现有连接原则上保持原快照，新连接使用新版本。不能热更新的项目应提示并执行受控重连。
- 配置含节点密码、订阅令牌等敏感值，日志与错误展示脱敏；导出时明确是否包含凭据。

**实现状态（2026-11-04，02 阶段服务层完成，构建与测试通过）**：上述链路已在 `Shared/Configuration/` 落地，字段级支持表见 [Documentations/Configuration.md](Documentations/Configuration.md)，逐项勾选与进度见 [SCHEDULE.md](SCHEDULE.md) 的“02”一节与“进度记录”。

| 环节 | 落地形态 | 现状 |
| --- | --- | --- |
| 文件/文本导入 | `ConfigurationImport.read(from:)`（仅 UTF-8、1 MB 上限、BOM 与 CRLF 归一、安全作用域访问） | 完成 |
| 原文保存 | `ConfigurationDocument`（注释、空行、顺序与原文无损回写）+ `draft.txt` | 完成 |
| 解析与定位 | `SurgeConfigurationParser`、`ParsedConfiguration`、`ConfigurationDiagnostics`（行号、列号、原文行） | 完成 |
| 语义校验 | `ConfigurationValidator`（能力门控、引用、FINAL、组循环、`notApplied`） | 完成 |
| 编译 | `ConfigurationCompiler`（节点、分组、按策略分组的规则集、设置） | 完成 |
| `[General]` 设置目录 | `ConfigurationSettings.catalog`（54 个键：名称、取值形状、重载级别、是否生效）+ `ConfigurationSettingsBindings.all`（`AWCore` 读写）；解析、校验、编译、安装、导出、重载分级、诊断文案全部由这两张表驱动，加参数只需各加一条 | 完成（2026-11-04）；由 `ConfigurationSettingsTests` 保证目录与绑定不脱节 |
| 快照与激活 | `ConfigurationSnapshotStore`（`manifest.json`、`snapshots/`、`appliedAt`）+ `ConfigurationActivation` | 完成 |
| 安装 | `ConfigurationInstaller`（写入既有存储层，`installation.json` 记录归属，失败回滚） | 完成 |
| 扩展确认 | `EngineConfirmationStore`（扩展写 `engine-confirmation.json`，主应用比对） | 完成 |
| 重载分级 | `ConfigurationReloadPlan`（`live` / `stackRestart` / `reconnect`） | 完成 |
| 有序规则与 FINAL | `OrderedRouteMatcher` 作为语义参考实现，编辑器预览与内核将共用 | 匹配器完成，`routing.bin` 载荷未接入 |
| 导出当前配置 | `ConfigurationExporter`（纯渲染）+ `ConfigurationExporter+Stores`（存储层 → Surge 风格文本，无法表达的项目写入 `notes`） | 完成 |
| 编辑器 | `Shared/ViewModels/ProfileEditorModel.swift`（会话状态机：缓冲区 / 预览 / 草稿 / `isDirty` / `apply` / `import` / `revert` / `discard` / 状态与错误；经 `ProfileEditing` 协议与流水线解耦，可脱离 SwiftUI 测试）+ `NaiveFlow/Views/Pages/Profile/ProfileView.swift`（只负责渲染）+ `ConfigurationDocumentOperations`（存储 ↔ 文本双向） | 完成（2026-11-04）：状态机与页面分离，`ProfileEditorModelTests` 14 例全绿；`ConfigurationReloadPlan` 的分级结果已在「Last Apply」区展示，未保存改动可丢弃/回滚；节点、分组、规则的表单化编辑仍待 07 阶段 |

仍未完成的部分不影响结论的准确性：`[General]` 键级告警不带行号；`[Script]`、`[MITM]` 证书字段、`loglevel`、`[URL Rewrite]`/`[Header Rewrite]` 属于“已识别未生效”，一律显式告警；有序规则与 FINAL 尚未进入扩展实际执行的载荷；Geo 数据按“自备 `Rules.db` + 可选随包资源”重新确定来源（见“范围与依赖更新记录”）。

### 4.7 普通 DNS 接管与加密 DNS 分流

普通 DNS 的 UDP/53 和 TCP/53 共用规则拒绝、Fake-IP、例外域名与失败响应。当前实现覆盖进入 TUN 的 IPv4 53 端口流量，保留内核上游及 Bootstrap 地址豁免；实现与限制见 [DNSConfiguration.md](Documentations/DNSConfiguration.md)，构建和真机验收仍待完成。

应用内 DoH 作为普通 HTTPS 流量、DoH3 作为普通 QUIC/UDP 流量，通过服务端域名（能够恢复或嗅探时）、IP、端口及 FINAL 等规则选择直连、代理或拒绝。不解析其加密 DNS 内容，不增加专用 MITM DNS handler，不重新查询并合成 DoH 响应。此功能已从开发范围移除，不再列为待实现项；通用 MITM 改写能力保留。

需要解析位置与业务出口尽量一致时，分别配置 DoH/DoH3 服务端和业务连接走同一出口。DNS 服务商的缓存、ECS 和调度仍可能影响结果；DoH 出口不会自动决定业务连接的出口。业务连接绕过本地 Fake-IP 时，域名规则依赖可用的域名嗅探；不可识别时依靠 IP 规则或 FINAL。DoH3 仍受现有 QUIC 策略约束，不承诺 HTTP/3 解密或客户端必然回退。

内核自身使用配置的 DoH 上游查询真实地址是独立能力，继续保留；它不等于接管应用内 DoH。

## 5. 开发阶段与交付

以下按现有项目增量开发估算，不包含独立工程、品牌调整、发布工程建设或协议重写。P0 完成后根据实际复用程度重新评估。

| 阶段 | 工作量 | 工作与交付 | 验收门槛 |
| --- | --- | --- | --- |
| P0 基线与设计 | 1–2 天 | 验证现有工程；审计 DNS/出站；确定最小改动点与规则语义 | 构建记录、能力表、旧新语义对照与可执行验收用例 |
| P1 统一配置与规则模型 | 4–7 天 | 文本导入/编辑/校验/重载；Geo 类型、顺序、no-resolve、FINAL；兼容旧模型 | 主应用与扩展通信；顺序不丢失；坏配置不激活 |
| P2 GeoSite / GeoIP | 3–5 天 | 数据构建工具、索引、IPv4/IPv6 查询、离线基线与原子更新 | 确定性样本、重叠优先级、坏库拒绝与回滚通过 |
| P3 Fake-IP、DNS 与普通 DNS 拦截 | 4–7 天 | 复用地址池；用途/策略隔离；Bootstrap；UDP/TCP DNS 拦截；缓存与循环控制 | 映射安全、DNS 调用计数、故障切换和依赖循环用例通过 |
| P4 路由与调度集成 | 3–5 天 | 按序异步规则；no-resolve；FINAL；TCP/UDP 域名出站；嗅探约束 | 两条目标路径全链路通过；无隐式本地解析 |
| P5 后续双栈增强 | 4–7 天 | Fake-IPv6、IPv6 接管、双栈候选、NAT64 验证 | A/AAAA、IPv6 直连和代理均真机验证 |
| P6 最小界面接入与回归 | 2–4 天 | 规则编辑/排序、DNS 设置、生效状态、诊断；恢复、资源与长稳回归 | 可安装构建、回归记录、已知限制及配置说明 |

原估算包含现已移除的 DoH MITM 接管任务，已不再适用。剩余工作量以当前实现、构建结果和真机验收重新评估。

核心交付顺序为 P0 → P1 → P2 → P3 → P4 → P6。普通 DNS 接管与加密 DNS 分流分别验收；通用 MITM 保持独立，不依赖专用 DoH 解密功能。IPv6 不属于当前版本范围。

## 6. 关键集成测试

使用本地固定 Geo 数据、可计数 DNS 假服务、可记录目标类型的代理假服务做自动化测试，再使用真机与受控服务验证实际网络路径。

| 用例 | 必须断言 |
| 统一配置导入与重载 | 行号错误准确；引用校验；编辑保留顺序；坏版本不激活；扩展失败继续使用旧版本 |
| UDP/TCP DNS 拦截 | 任意配置目标、TCP 分段/多查询、上游豁免、无循环 |
| 应用内 DoH/DoH3 分流 | 服务端按普通规则选择出口；不解密、重新查询或合成 DNS 响应 |
| 加密 DNS 与业务出口 | 分别验证两类连接命中规则和最终出口；QUIC 策略、域名不可见及 FINAL 行为可解释 |
| --- | --- |
| GeoSite CN 域名 | DIRECT；路由决定后才调用 Local Resolver |
| 未命中域名 + GeoIP no-resolve + FINAL | 目标本地 DNS 调用为 0；代理收到域名和端口 |
| 真实 CN / 非 CN IPv4 与 IPv6 | GeoIP 正确；原 IP 传递；无目标 DNS 与反查 |
| Fake-IP 映射存在/缺失 | 恢复原域名；缺失不可达；虚拟地址不传至 GeoIP/公网 |
| GeoIP 不带 no-resolve | 到达该规则才解析；失败不同于非 CN；遵守失败策略 |
| 自定义规则与 GeoSite 重叠 | 调换规则顺序能改变结果；不受旧五层优先级覆盖 |
| IP 规则在域名规则之前 | 按序挂起与恢复；不被后面的域名命中提前越过 |
| 多 A/AAAA 答案 | 路由与实际连接地址符合约定的候选策略 |
| 地址池回收/耗尽/重启 | 不发生跨域名误映射；错误明确且有容量边界 |
| DNS/节点循环依赖 | 配置预检拒绝；运行时有超时、无无限递归 |
| 数据库/规则热更新 | 新流使用一致快照；坏版本不生效；缓存正确失效 |
| IPv6-only/NAT64 与网络切换 | 不旁路；Bootstrap 可达；旧策略缓存不串用 |
| 仅 IP 出站、UDP、SNI 重判 | 显式解析策略；首包有界等待；不覆盖原域名 |

真机检查包含 VPN 启停、前后台、Wi-Fi/蜂窝切换、隧道重启、订阅失败、配置恢复、内存峰值与长时间运行。DNS 路径由查询日志和受控抓包共同验证；具体资源阈值在 P0 建立基线后确定。

## 7. 实施检查清单

- [ ] P0：在现有工程中核实配置解析、规则匹配及 DNS 的复用点。
- [ ] P0：核对 Xcode/SDK、各 target 部署版本、签名及测试服务器。
- [ ] P0：冻结规则顺序、no-resolve、DNS 失败、多 IP 与 FINAL 的语义。
- [x] P1：直接修改现有工程，记录基线，控制新增文件与改动范围。（2026-11-04：新增集中在 `Shared/Configuration/`，其余改动见 [SCHEDULE.md](SCHEDULE.md) 进度记录。）
- [x] P1：统一文本配置导入、编辑、校验、重载；有序规则、版本化快照与失败恢复。（服务层完成：导入、文档模型、解析、校验、编译、快照、安装、扩展确认、重载分级；有序规则目前只有 `OrderedRouteMatcher` 参考实现，`routing.bin` 载荷未接入。尚未编译与运行测试，见 4.6 实现状态。）
- [x] P2 代码：外部 Geo 数据导入、下载校验、版本固定、失败恢复与索引；未运行测试/性能基准，验收另计。
- [ ] P3：Fake-IP 生命周期与 DNS 三通道实现。
- [ ] P4：TCP/UDP 调度闭环和逐协议目标能力核对。
- [ ] P5：完整双栈实现与真机验证。
- [ ] P6：规则排序、数据库版本、命中规则、解析目的、最终目标及失败原因可查看；日志脱敏且容量受限。
- [ ] 交付：确定性测试、真机回归、构建产物和已知限制齐全。

本次交付仅为开发计划，未修改应用源码，未执行编译或真机测试。（2026-11-04 更新：工作副本已完成付费/社群功能清理与依赖收敛，iOS 与 tvOS 无签名构建通过，见 [BASELINE_CHECK.md](BASELINE_CHECK.md) 与 [SCHEDULE.md](SCHEDULE.md)。）

下一步实施顺序（2026-11-04）：先构建并修正 02 新增代码的编译问题、运行 `NaiveFlow Tests`，再完成 02 的编辑器入口与验收；随后进入 03，以 Fake-IP → 原始域名 → 有序规则 → DIRECT/PROXY 的可验证闭环为首个核心成果。


## 8. 后续 UI 改版与 Surge / Quantumult X 脚本兼容

用户补充范围：核心网络功能之后继续调整 UI，并支持 Surge、Quantumult X 的 MITM 脚本。此处按这两个产品名称理解前文拼写，兼容作为正式开发目标；按功能清单逐项验收，不以“能导入文件”代表“脚本行为兼容”。

### 8.1 UI 改版

在现有 SwiftUI 页面上调整，优先复用组件和操作层。先完成功能入口，再集中统一布局、视觉和交互。

| 页面 | 改动内容 |
| --- | --- |
| 首页 | VPN 状态、当前配置、选中节点、路由模式、最近一次重载结果 |
| 配置管理 | 文件导入、文本编辑、错误行定位、版本比较、激活与回滚；与可视化设置共用同一配置模型 |
| 规则管理 | 有序规则编辑、GeoSite/GeoIP 标签、no-resolve、FINAL、规则集与数据库更新状态 |
| DNS | 上游和解析用途、普通 DNS 接管范围与 DoH/DoH3 流量分流、豁免、缓存及失败行为 |
| MITM | CA 安装与信任说明、主机列表、握手与证书错误 |
| 脚本与模块 | 导入来源、运行方言、触发阶段、参数、启停、更新、兼容提示和运行日志 |
| 诊断 | 原始目标、命中规则、解析通道、出站、MITM 和脚本执行结果；日志脱敏与容量限制 |

验收包括配置文本与页面编辑一致、重载失败可见、长规则列表性能、深色模式、动态字体和现有平台布局回归。UI 不显示未经核实的“全部兼容”状态。

### 8.2 脚本兼容层

保留现有 NaiveFlow 的 `process(ctx)` 与原生 API，在当前脚本运行时上增加显式的 Surge / Quantumult X 方言适配器。每次执行仅注入选定方言，避免同时暴露全部全局变量导致脚本错误识别环境。

Surge 的 API 与触发方式以 [官方脚本概览](https://manual.nssurge.com/scripting/overview.html)、[API 参考](https://manual.nssurge.com/scripting/api.html) 和 [HTTP 请求脚本](https://manual.nssurge.com/scripting/http-request.html) 为核对依据；Quantumult X 以 [官方改写示例](https://github.com/crossutility/Quantumult-X/blob/master/sample-rewrite-with-script.js)、[二进制改写示例](https://github.com/crossutility/Quantumult-X/blob/master/sample-bytes-rewrite.js) 及官方仓库其他样例为依据。实施时固定样例版本，形成可回归的兼容矩阵。

以下是计划支持的目标，不是对现有实现的声明：

| 范围 | 首批实现目标 | 验证重点 |
| --- | --- | --- |
| 执行上下文 | `$request`、`$response`、`$done`、日志与脚本参数 | 字段、阶段差异；done 只完成一次；异常与超时 |
| 请求/响应改写 | URL、方法、头、状态、文本 body；二进制 body 单列实现 | 编码、压缩、重复头、大小限制、Content-Length、HTTP/2 |
| 主动 HTTP 请求 | Surge `$httpClient`；Quantumult X `$task.fetch` | 回调与 Promise 语义、错误、超时、返回结构和路由 |
| 持久存储 | Surge `$persistentStore`；Quantumult X `$prefs` | 作用域、并发、原子更新及迁移；不引入专用 DoH 原生处理器 |
| 通知 | Surge `$notification`；Quantumult X `$notify` | 权限、去重、后台行为与不支持参数提示 |
| 合成响应与中止 | 按方言解释 `$done` 返回值 | 未修改、直接响应、终止连接分别验证；不直接混用两端返回结构 |
| 配置导入 | Surge MITM / Script 相关子集、Quantumult X rewrite / 脚本相关子集 | 解析为统一内部模型；未知字段与不支持项明确报告 |

脚本主动 HTTP 请求继续使用内核路由、DNS 和 Bootstrap，携带脚本来源标识，避免脚本请求再次触发自身形成递归。并发、执行时间、body 大小、存储容量均设上限；重载和停用时取消未完成任务。不增加 DoH 专用原生处理器及其脚本优先级；通用 MITM/脚本沿用自身显式配置。

API 适配不依赖给所有脚本统一套一个简单包装器。需要分别映射请求/响应对象、文本/字节表示、异步完成及 HTTP 返回值。二进制与压缩 body 必须往返无损；不支持流式修改的场景显式提示。

### 8.3 后续扩展与验收边界

定时任务、手动任务、DNS 脚本、事件脚本、策略控制与完整配置互导分批评估，在支持矩阵中明确状态。尤其不能把 Surge 所有脚本触发类型或 Quantumult X 的配置控制能力视为已有等价实现。iOS 后台定时能力需要单独验证，不能承诺任意时间准点执行。

建立官方样例、最小语义测试和用户实际脚本三个层次的测试集；对同一输入验证输出、主动请求、持久化副作用与失败行为。记录脚本版本及方言，发布“支持/部分支持/不支持/未验证”矩阵。导入第三方脚本时展示主机范围、来源和不兼容项，远程更新先验证后原子替换，失败保留旧版。

### 8.4 后续阶段安排

| 阶段 | 内容 | 交付 |
| --- | --- | --- |
| P7 UI 改版 | 页面与交互草案 → 实现 → 真机验证 | 首页、配置、规则、DNS、MITM、脚本和诊断入口一致 |
| P8a 兼容基础 | 方言适配、请求/响应改写、done、日志 | 最小脚本和官方样例通过，兼容矩阵首版 |
| P8b 常用 API | 网络、存储、通知、二进制、配置子集导入 | 选定实际脚本无需改写即可按预期运行 |
| P8c 扩展能力 | 定时/手动/事件等任务及更多配置/API | 按逐项评估结果扩大支持范围 |

P1 的统一配置模型需预留脚本方言、来源、参数、触发条件及 MITM 主机等字段；P8 不再依赖已取消的 DoH 解密接管任务。P7/P8 的工作量待 UI 草案及兼容样例集确定后单独估算，避免用不明确的“完全兼容”推算工期。


## 命名更新记录

按用户后续要求，工作副本内 Anywhere / anywhere / ANYWHERE 已分别替换为 NaiveFlow / naiveflow / NAIVEFLOW，包括工程、包、类型、文件路径、URL Scheme 与应用标识。Reference/Anywhere 保持原样。重命名不代表同名远程域名、下载地址或签名资源已经创建，相关外部资源需在后续接入时核对。此前关于不调整命名与应用标识的范围说明以本次要求为准。（2026-11-04 更新：Xcode 27.2 下 iOS 与 tvOS scheme 已无签名构建通过，静态校验与编译结果见 [BASELINE_CHECK.md](BASELINE_CHECK.md)。）


## 平台范围最终约束

开发顺序（2026-11-06）：先完成 iOS/iPadOS 的功能闭环与验收，再启动 macOS 客户端。macOS 的 target、UI、VPN 适配及独立验收放在后续阶段，不属于当前 iOS/iPadOS 交付条件。现有 tvOS target 保留。

按用户最新要求，客户端仅支持 macOS、iPadOS、iOS、tvOS，覆盖此前关于 Watch 平台保留的规划。工作副本已清除 Watch 客户端及配对通信，保留目标平台相关控件、VPN 扩展与测试。macOS 客户端尚未存在，需要后续补齐 target、UI 与 VPN 平台适配，不以简单设置平台标记代替实现。


## 范围与依赖更新记录

更新于 2026-11-04。本工程只参考上游的核心组件，同时按用户要求移除继承自 Anywhere 的商业化与社群入口：

- **移除付费与会员体系**：删除 StoreKit 内购层（`NaiveFlow/Stores/VoyagerStore.swift`）、付费墙与公开测试页面（`VoyagerNotice`、`JoinVoyagerButton`、`JoinBetaView`）、会员卡片与 `isMember` 门禁，以及 `AWCore`/`AppSettings` 中的会员相关 UserDefaults 键；`Localizable.xcstrings` 删除 22 个失效键（478 → 456）。后续阶段的会员、内购与 Telegram 群组入口不在规划范围内，若需要请另立需求。
- **不再依赖预设路由数据库**：上游私有包 `AnywhereRules`（改名后 `NaiveFlowRules`）无法公开获取（匿名 404，上游公开仓库依赖同一私有地址），已从工程移除。工程只保留 `NaiveFlowIP`、`NaiveFlowQUIC`、`BLAKE`、`YAML` 四个仓库内核心组件包，无远程依赖；`RoutingRulesDatabase` 改为读取 `Bundle.main` 中可选的 `Rules.db`，缺失时预设为空、路由内核不受影响。因此 **03 阶段的 Geo 数据来源、随包基线与更新方式需按“自备数据库 + 可选随包资源”重新确定**，不再假定上游预设库存在。
- **占位资源**：工作副本与上游公开仓库都没有 `.xcassets`，而源码依赖 `Color.homeBackgroundStart` 等资源生成符号，因此在 `Shared/Assets.xcassets` 补了仅用于编译验证的中性占位色板与空 `AppIcon.appiconset`。**07 UI 改版前必须先确定真实品牌资源**，不得把占位视觉当作设计稿。
- **页面范围变化**：`AboutView` 不再有 Telegram 群组入口；`PersonalizationView` 不再有会员卡片开关；`CustomizeAppIconView`、`CustomizeThemeView` 取消会员门禁，所有用户均可使用。07 的 UI 草案按此范围编写。
- 验证记录：iOS 主应用（含 Network Extension、Widget）与 tvOS 客户端无签名构建通过，签名与真机验收未做。明细见 [BASELINE_CHECK.md](BASELINE_CHECK.md)，依赖说明见 [Reference/Dependencies.md](Reference/Dependencies.md)。

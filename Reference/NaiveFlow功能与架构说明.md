# NaiveFlow 功能与软件架构说明

更新日期：2026-11-08

本文记录当前工作副本的功能范围、主要模块、数据流、运行限制和验证状态。它描述的是当前源码，而不是完整 Surge、Quantumult X 或其他客户端的兼容承诺。

## 1. 项目定位与范围

NaiveFlow 是一个基于 Apple Network Extension 的 IPv4 网络代理和流量路由工具。它接管进入 TUN 的 IPv4 TCP/UDP 流量，按配置规则决定直连、代理或拒绝，并提供 DNS、Fake-IP、MITM、脚本、配置版本、回滚和诊断能力。

当前平台范围：

- iOS/iPadOS：当前主要客户端和验收目标。
- tvOS：保留 target，并复用共享代码。
- macOS：尚无客户端 target，属于后续阶段。
- watchOS：客户端已移除。
- 首版为 IPv4-only，不承诺完整 IPv6、双栈或 NAT64 行为。

tvOS 不提供长文本配置、节点 URL、DNS 或 MITM 规则编辑器，但保留 MITM 数据平面和模块/脚本运行能力。配置、MITM 规则和脚本由 iPhone、iPad 或 macOS 编辑并发布，tvOS 通过 iCloud 或已确认的运行包下载、校验后执行。

## 2. 总体架构

```text
SwiftUI 主应用
  ├─ VPN 控制、节点、策略组、规则、DNS、MITM、配置和诊断页面
  ├─ ProfileEditorModel / ConfigurationDocumentOperations
  └─ TunnelController / LiveTunnelProvider
          │ provider message
          ▼
Shared 共享层
  ├─ 配置解析、校验、编译和版本发布
  ├─ 节点、代理组、路由、DNS、MITM 和脚本模型
  ├─ 持久化、CloudKit 文本同步、订阅刷新
  ├─ IPC、日志、统计和并发桥接
  └─ ProxyConfiguration / TunnelMessage 等跨进程协议
          │
          ▼
Network Extension
  ├─ PacketTunnelProvider：系统 VPN 生命周期和 TUN
  ├─ TunnelStack：数据平面、连接表、配置和统计
  ├─ TCPConnection / UDPPlane / UDPFlow：TCP/UDP 流处理
  ├─ DomainRouter / ConnectionRouter：规则和出口选择
  ├─ DNSResolver / SyntheticAddressPool：DNS 和 Fake-IP
  ├─ ProxyClient：各代理协议出站
  └─ MITMSession / ScriptEngine：解密、改写和脚本
          │
          ▼
     本地网络与远程代理节点
```

工程 target：

- `NaiveFlow`：主应用。
- `NaiveFlow Network Extension`：VPN 数据平面。
- `NaiveFlow Widget`：VPN 状态和控制组件。
- `NaiveFlow Tests`：自动化测试。
- `NaiveFlow TV`：tvOS 客户端。

当前使用的本地 Swift Package：`NaiveFlowIP`、`NaiveFlowQUIC`、`BLAKE`、`YAML`。工程没有必须从远程仓库下载的依赖。

## 3. 主应用功能

### 3.1 VPN 和运行状态

主应用通过 `TunnelController` 和 `LiveTunnelProvider` 管理 VPN：

- 启动、停止和重连 VPN。
- 监听连接中、已连接、断开、重连和停止状态。
- 避免重复启动和停止竞态。
- 请求扩展返回日志、统计、请求记录、活动连接和运行版本状态。
- 显示当前运行版本、默认出口、连接数和流量。
- 启动失败时尝试恢复上一个可用配置版本。

### 3.2 节点和代理协议

节点由统一的 `ProxyConfiguration` 表达，当前协议类型包括：

- Direct
- SOCKS5
- Shadowsocks 2022
- Trojan
- VLESS
- Hysteria
- AnyTLS
- Nowhere

节点页面支持新增、编辑、删除、排序、导入、订阅刷新、延迟测试和分组。协议实现位于 `Shared/Networking/Protocols`，由统一的 `ProxyClient` 负责拨号和连接生命周期。

### 3.3 策略组

运行时代理组支持：

- `select`：手动选择成员。
- `url-test`：按探测 URL 的最低延迟选择成员。
- `fallback`：按声明顺序选择第一个健康成员。
- `load-balance`：在健康成员之间轮询。

每个自动组独立探测并保存延迟结果。共享节点在不同组中使用不同探测 URL。运行版本切换导致某个成员不存在时，路由器会尝试组内剩余成员，不会把明确的代理策略静默变成直连。自动组不能直接嵌套自动组，但可以引用或展开 `select` 组。

### 3.4 配置编辑器

Profile 编辑器提供：

- 原文编辑。
- 注释、空行和规则顺序保留。
- 草稿保存。
- 预览和去抖编译。
- 行号、列号和原文行诊断。
- 导入、导出、历史版本、回滚和丢弃修改。
- 未保存状态和最近一次应用结果。
- 按配置变更类型提示立即生效、重启数据平面或需要重连。

配置文本是运行配置的主要写入入口。节点库、分组库和规则库不会绕过 Profile 发布流程偷偷覆盖当前运行版本。

## 4. 配置、编译和版本发布

配置处理链路为：

```text
文本/文件导入
  → 文档保存
  → 语法解析
  → 语义校验
  → 节点、分组、规则、DNS、MITM、脚本编译
  → 外部资源下载和固定
  → 生成不可变运行包
  → SHA-256 和 manifest
  → 原子更新当前 head
  → Network Extension 加载
  → receipt 确认
```

主要组件：

- `SurgeConfigurationParser` / 原生文本解析器。
- `ConfigurationValidator`。
- `ConfigurationCompiler`。
- `ConfigurationCoordinator`。
- `ConfigurationSnapshotStore`。
- `ConfigurationPublisher`。
- `ConfigurationActivation`。
- `RuntimeConfigurationBundle`。
- `RuntimeCoordinator`。
- `EngineConfirmationStore`。

支持：

- 并发发布锁。
- compare-and-swap head。
- 运行版本 ID 和 request ID。
- 内容完整性校验。
- 失败恢复。
- 上一版本恢复。
- 过期 receipt 拒绝。
- 应用进程退出后的待发布事务恢复。
- 旧版本资源复用。
- 版本数量和磁盘空间限制。

一般运行版本更新会重建数据平面并关闭旧连接，让新连接使用新版本；不承诺无损连接迁移。

## 5. 路由引擎

路由目标包括 Direct、Reject、Default、Default Proxy、指定代理节点和代理组。规则使用有序首条命中语义：从上到下检查，第一条命中后停止。

规则模型支持或编译支持：

- 精确域名。
- 域名后缀。
- 域名关键词。
- 通配符域名。
- 域名正则。
- IPv4 CIDR。
- 源 IP 和源端口。
- 目标端口。
- TCP/UDP 协议。
- GeoIP、GeoASN、GeoSite。
- AND、OR、NOT 逻辑。
- RULE-SET。
- FINAL。
- no-resolve。

路由组件包括 `OrderedRouteMatcher`、`DomainRouter`、`ConnectionRouter`、`RouteQuery`、`TieredRouteMatcher` 和规则集索引。

路由记录会保存原始目标、端口、协议、规则集、出口、阻断原因、活动连接 ID，以及规则评估期间得到的 IPv4 和解析用途。

规则正则在安装时预编译，并受执行预算限制。匹配超时会被当作错误处理，避免异常落入 DIRECT 或 FINAL。

依赖进程名、User-Agent 或应用层 URL 的规则，需要当前数据平面能够取得对应元数据；无法可靠取得的类型会在配置校验阶段明确拒绝或告警，不会静默接受后失效。

## 6. DNS 和 Fake-IP

### 6.1 DNS 解析用途

DNS 解析按用途隔离：

- `directConnection`：直连建连解析。
- `ruleEvaluation`：规则和 GeoIP 判断。
- `proxyBootstrap`：节点或 DNS 上游 bootstrap。
- `explicitDNSQuery`：显式 DNS 请求。

不同用途会隔离缓存、上游策略、失败行为和 Bootstrap 依赖。

### 6.2 普通 DNS 接管

TUN 中的 IPv4 UDP/53 和 TCP/53 支持：

- 规则拒绝。
- Fake-IP A 记录。
- AAAA 和 HTTPS 类型抑制或 NODATA。
- Host 静态映射。
- DNS 例外服务器。
- Bootstrap 豁免。
- TCP 分段和多请求。
- 上游失败和无递归保护。

### 6.3 Fake-IP 地址池

`SyntheticAddressPool` 负责：

- 域名到 Fake-IP 映射。
- Fake-IP 到域名恢复。
- TTL、LRU 和容量限制。
- 并发访问保护。
- 映射代次和规则版本。
- 映射缺失处理。
- 地址回收和池耗尽。
- 旧连接和新域名之间的隔离。

Fake-IP 不会送入公网，也不会被当作真实 IP 参与 GeoIP 判断。映射不存在时不会猜测域名。

当前 DoH 上游使用 HTTP/1.1；DoT、DoQ、显式 DoH3 和 HTTP/2-only DoH 上游不属于当前完整支持范围。应用自身的 DoH/DoH3 按普通 HTTPS/QUIC 流量路由，不做专用 DNS MITM 解密、重查或合成响应。

## 7. Network Extension 数据平面

### 7.1 PacketTunnelProvider

`PacketTunnelProvider` 负责：

- Network Extension 生命周期。
- TUN 包流读取和写回。
- IPv4 隧道地址和路由。
- DNS 设置。
- MTU 探测。
- 启动版本准备和确认。
- 统计采样。
- 隧道停止和恢复。

### 7.2 TunnelStack

`TunnelStack` 是扩展内的运行容器，管理：

- IP 栈。
- TCP 和 UDP 连接表。
- TCP/UDP ActivityPool。
- DomainRouter 和 ConnectionRouter。
- 当前配置。
- 数据平面 generation。
- 默认路由。
- DNS 组件。
- 流量账本。
- 版本加载和恢复。

### 7.3 TCP

`TCPConnection` 处理：

- 目标地址和端口解析。
- 初始数据缓冲。
- TLS ClientHello/SNI 嗅探。
- HTTP Host 嗅探。
- 规则评估。
- DNS 等待。
- 直连或代理拨号。
- 上下行转发。
- 空闲超时。
- 活动记录、流量和失败原因。

### 7.4 UDP/QUIC

`UDPPlane` 和 `UDPFlow` 处理：

- UDP flow 创建和回收。
- DNS 流量。
- QUIC 识别。
- UDP 直连或代理。
- QUIC 策略拒绝。
- UDP 超时和资源限制。
- 上下行计量。
- TUN 回写。

## 8. 代理协议层

代理协议由统一的 `ProxyClient` 接口调度，协议配置和连接实现分开。每个协议通常包含配置、握手、认证、目标地址编码、TLS/加密层、UDP 支持、取消和错误转换。

当前协议代码位于：

```text
Shared/Networking/Protocols/
```

包含 Core、Direct、SOCKS5、Shadowsocks 2022、Trojan、VLESS、Hysteria、AnyTLS、Nowhere、TLS 和 QUIC 相关实现。

显式代理路由如果找不到可用节点，会报告代理不可用，不会偷偷走运营商直连。

## 9. MITM、HTTP 改写和脚本

MITM 子系统包括：

- CA 和证书存储。
- X.509 证书生成。
- 叶子证书缓存。
- HTTP/1.1 会话。
- HTTP/2 上游。
- 请求/响应桥接。
- URL、Header、Body 和 JSON 改写。
- Map Local。
- MITM 规则集导出。

使用 MITM 需要设备安装并信任 CA。CA 未信任、证书生成失败或规则准备失败时，配置发布会失败或回滚。

脚本当前方向包括：

- http-request。
- http-response。
- 原生 `process(ctx)`。
- 逐帧处理。
- HTTPS 或 Base64 脚本源。
- 固定脚本字节。
- `$argument`。
- 主动 HTTP 请求。
- watchdog、大小、超时和并发限制。

不承诺完整 Surge/Quantumult X API，也不承诺定时脚本、DNS 脚本和全部事件脚本。

## 10. 实时诊断、日志和统计

请求记录字段包括：

- 请求 ID和时间。
- TCP/UDP。
- host 和 port。
- 路由目标。
- 默认路由。
- 规则集名称。
- 出站节点。
- 阻断原因。
- QUIC 标识。
- 活动连接 ID。
- 解析出的 IPv4。
- 解析用途。

实时请求页面支持：

- 自动刷新。
- 暂停和恢复。
- 自动跟随最新记录。
- 搜索和筛选。
- Active、Failed、Rejected 状态过滤。
- 请求详情。
- 连接流量和耗时。
- 失败原因。
- 复制和导出。

请求记录默认保留最近 5 分钟，最多 500 条。活动连接按唯一连接 ID 关联，避免同域名并发连接串数据。

流量统计按路由目标记录上传、下载、TCP/UDP 数量、活动连接、内存、唤醒/休眠和拨号/握手耗时。

tvOS 上的请求查询以查看为主，保留状态、规则、出口、失败原因、流量和耗时；复杂筛选、文本编辑和规则修改放在 iOS/iPadOS/macOS。

## 11. 持久化、同步和外部资源

项目存储包括：

- 节点。
- 分组。
- 链路。
- 规则集。
- MITM 规则集。
- 证书。
- 模块。
- 订阅。
- Host/DNS 设置。
- 配置草稿和历史。
- 不可变运行版本。
- 运行 receipt。

CloudKit 当前用于配置文本的手动上传和下载。下载内容需要用户在本机单独确认并应用，不会自动覆盖正在运行的配置。

外部资源支持规则集、GeoIP、GeoSite 和脚本下载，并在发布前执行大小、编码、格式、摘要和版本固定。下载或校验失败时保留旧版本。

当前没有私有预设路由数据库；如需默认 `Rules.db`，需要由应用资源或明确的数据源提供。

模块资源和脚本资源在发布时固定进运行包。tvOS 不编辑这些资源，但会执行已校验并确认的 MITM 规则、模块和脚本；下载失败、脚本语法错误、CA 状态不满足或运行包完整性失败时，沿用旧版本并报告错误。

## 12. IPC、并发和可靠性

主应用与扩展通过 `NETunnelProviderSession.sendProviderMessage` 通信，消息包括：

- 获取/重置统计。
- 获取日志。
- 获取请求记录。
- 获取活动连接。
- 获取运行版本状态。
- 应用和恢复运行版本。
- 延迟测试。

IPC 具备超时、取消、异常捕获、重复回调保护和晚到回调忽略。DNS、配置发布、VPN 启停和策略组探测使用 task cancellation、Mutex、Atomic、actor 和 generation token，避免旧任务覆盖新状态。

## 13. 测试和当前状态

当前模拟器全量 `NaiveFlow Tests` 为 **318 项通过**。覆盖配置、规则、DNS、Fake-IP、策略组、代理协议边界、MITM、脚本、版本发布、回滚、并发、实时记录和 IPC。

已完成代码和模拟器验证的部分包括：

- 配置解析、编译和发布。
- 有序规则和 FINAL。
- no-resolve 和 DNS 用途隔离。
- Geo 和规则集固定。
- Fake-IP 生命周期。
- 策略组选择和探测计划。
- 实时请求记录。
- 清空、暂停、恢复和并发连接关联。
- IPC 超时和取消。
- 配置回滚和过期确认。

仍需外部环境验证：

- Apple Developer 账号、签名和 provisioning profile。
- App Group 和 Network Extension entitlement。
- 真机 VPN 启停。
- 真实代理节点 TCP/UDP 连通性。
- DNS 抓包和防泄漏。
- Wi-Fi/蜂窝切换、睡眠唤醒和后台行为。
- 长时间运行、吞吐、内存峰值和大量规则性能。
- MITM CA 在真实设备上的信任行为。

## 14. 当前明确限制

- IPv6、完整双栈和 NAT64 不在当前首版范围。
- 暂无 macOS 客户端。
- DoT、DoQ 和显式 DoH3 不在当前 DNS 完整支持范围。
- 不对应用内 DoH/DoH3 内容做专用 MITM 解密和响应合成。
- 不承诺完整 Surge 或 Quantumult X 配置/脚本兼容。
- PROCESS-NAME、USER-AGENT、URL 路由等依赖应用层元数据的能力会被拒绝、告警或要求 MITM 上下文。
- 自动策略组不能直接嵌套自动策略组。
- 真实设备上的系统防绕行、性能和网络切换尚未验收。


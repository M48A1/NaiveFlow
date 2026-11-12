# 原生 DNS 配置

DNS 设置可集中写在 `[DNS]`：

```ini
[DNS]
mode = doh
server = 223.5.5.5
doh = https://dns.google/dns-query
bootstrap-dns = 223.5.5.5, 119.29.29.29
```

| 字段 | 含义 |
| --- | --- |
| mode | `system`（也接受 `default`）、`plain` 或 `doh`，选择当前解析方式 |
| server | 传统 UDP DNS，单个 IPv4，可带端口，例如 `223.5.5.5:53` |
| doh | 完整 HTTPS DoH URL；不支持用户名、密码、fragment 或无效端口 |
| bootstrap-dns | `system`，或最多八个纯 IPv4 地址，按顺序尝试；固定 UDP/53，不接受域名或加密 DNS URL |

`mode`、`server`、`doh` 分别对应既有规范名 `dns-mode`、`dns-server`、`encrypted-dns-server`；两种写法不能重复定义。传统地址与 DoH 地址可同时保存，但必须写明 mode；显式 mode 最后应用，结果不受字典遍历顺序影响。仅填写 server 或 doh 时沿用既有自动选择对应传输的行为。mode=system 时这两个地址不参与普通查询。

这两个地址不是自动主备：不会因为配置了 server，就在 DoH 失败时暗中使用它。`fallback-dns-mode` / `fallback-dns-server` 仍按现有回退通道的行为工作，本次没有重新设计 DNS 故障策略。

## Bootstrap 的边界

Bootstrap **只解析域名形式的 DNS 上游端点**，不用于普通业务域名，也不用于节点域名。传统 DNS 已要求 IP；IP 形式 DoH（IPv4）直接连接并跳过 bootstrap。

- `bootstrap-dns = system`：仅用系统的 A 记录解析得到 IPv4，再连接这个数值地址。
- 指定 IP 列表：通过这些数值地址发出端点域名的 A 查询，再直接连接返回的 IP。保留原 URL 主机用于 HTTP Host、SNI 和证书验证，使用系统 TLS 验证，不继承代理节点的 allow-insecure。
- 种子按顺序查询，取得地址后依次尝试连接。失败不会偷偷改用系统解析；DNSResolver 的 DoH 系统回退也在显式 bootstrap 模式下禁用。
- 上游重定向会拒绝，避免引入未配置的第二个端点依赖。DNS 响应最多 65,535 字节。

IPv4-only 版本统一使用数值 IPv4 连接和 HTTP/1.1 POST，支持 Content-Length、chunked 和关闭连接结束的响应。仅支持 HTTP/2 的 DoH 上游暂不支持。DoT、DoQ、显式 DoH3 未在本次增加；本功能也不是对应用内 DoH 的 MITM 接管。

## 其他通道

以下既有规范名可以写入 `[DNS]`：

```ini
proxy-dns-mode = plain
proxy-dns-server = 223.5.5.5
subscription-dns-mode = doh
subscription-encrypted-dns-server = https://dns.google/dns-query
ech-dns-mode = doh
ech-encrypted-dns-server = https://dns.google/dns-query
fallback-dns-mode = plain
fallback-dns-server = 119.29.29.29
```

它们分别沿用现有节点/代理相关、订阅、ECH 和回退解析通道，不代表 DNS 请求已新增“经所选代理发送”的路由能力。所有经过 DNSUpstreamClient 的域名 DoH 上游统一使用 bootstrap-dns，所有业务解析、节点解析及系统解析均只接受 IPv4 地址。

已有 `[General]` DNS 规范字段仍可读取；同一字段同时出现在 `[General]` 与 `[DNS]` 会报错，不猜测优先级。按原文导出仍保留 DNS 段；从手工设置生成新文档时仍可使用原有 General 规范字段。

## 版本和验证

Bootstrap 保存于完整运行版本中，参与切换和回滚；旧版本缺少新字段时按 system 处理。普通 DNS 与 ECH 缓存键包含 bootstrap 策略，避免切换后复用其他种子上下文的缓存。内置公共 DNS 拦截名单对 bootstrap 种子作豁免。

新增测试覆盖配置段、别名、模式选择、错误与重复字段、种子校验及顺序、IP-literal 跳过、失败不回退、HTTP 响应分帧/大小/错误、旧版本读取和整包回滚。当前环境没有 Swift/Xcode，未运行构建、测试或真实 DNS/TLS 验收。

参考系统 TLS API：[sec_protocol_options_set_tls_server_name](https://developer.apple.com/documentation/security/sec_protocol_options_set_tls_server_name(_:_:))。

## TUN 内普通 DNS 接管

进入 TUN 的 IPv4 UDP/53 和 TCP/53 共用 DNS 规则与 Fake-IP 处理。内置 DNS 地址始终接管；其他 IPv4 地址默认接管。为避免上游递归，当前配置的明文 DNS 上游及 bootstrap 地址免接管（地址级豁免，不是应用身份识别），因此并非不可绕过的 DNS 防泄漏策略。未进入 TUN 的系统例外流量不在此范围内。

单问题、IN 类、标准 QUERY 才受理。畸形 UDP 查询丢弃，畸形 TCP 查询关闭连接，不进入普通路由。规则拒绝、AAAA/HTTPS 查询抑制和 Fake-IP 回答在两种传输保持一致。Fake-IP 排除域名和其他记录类型交给 `fallback-dns-*` 对应上游；system 模式使用内置 `1.1.1.1:53`。这条解析通道直接访问配置上游，不经过业务代理规则；配置 DoH 时保留 TLS 校验和 bootstrap 策略。此变化也修正原 UDP 转发忽略 DoH 和自定义端口的问题。

TCP 支持两字节长度前缀、拆包、粘包和连续请求，单连接按序处理。每条 TCP 连接缓冲最多 131,074 字节，纳入 TCP 缓冲账本；UDP 上游查询最多同时 64 个，超额返回 SERVFAIL，异步查询不阻塞普通 UDP。上游 UDP 截断时重试 TCP；返回客户端的 UDP 答案保守限制为 512 字节，超过则返回 TC 供客户端用 TCP 重试（暂不按 EDNS 增大 UDP 限额）。上游事务 ID 和完整 question 必须吻合；失败返回 SERVFAIL。热更新取消待处理 UDP 查询，并拒绝跨数据平面代次的回答。

应用内 DoH 的专用 MITM 解密、重新查询及响应合成已从开发范围移除，不再属于待实现项。DoT/DoQ 协议接管、用户自定义普通 DNS 接管/豁免列表目前未包含。以上代码仍需 Xcode 构建、测试和真机流量验收。

## 应用内 DoH / DoH3

应用自行发起的 DoH 作为普通 HTTPS 连接、DoH3 作为 QUIC/UDP 连接，按服务端域名（可恢复或嗅探时）、IP、端口和 FINAL 等规则选择直连、代理或拒绝。无需为了 DNS 分流安装 MITM CA；项目不增加专用 DNS 解密处理器，不提取其中查询域名、重新解析或合成 DoH 响应。通用 MITM 仍由用户自己的主机列表和改写规则控制，不因 DNS 分流自动启用。

DoH/DoH3 和业务流量必须分别配置同一出口，才可能使解析视角与访问出口尽量一致；DoH 的路由不会自动传递到后续业务连接。服务商缓存、ECS 和节点调度仍影响结果。应用内 DNS 绕过本地 Fake-IP 后，业务域名匹配依赖嗅探，无法取得域名时使用 IP 规则或 FINAL。DoH3 受现有 QUIC 策略限制，不承诺解密 HTTP/3 或必然回退。

配置内核自身的 DoH 上游继续受支持；它与应用内加密 DNS 的普通流量分流是两个独立路径。


## 解析任务内存限制（2026-11-12）

每个 `DNSLookupCache` 最多保留 64 个尚未完成的不同键解析任务（键包含域名、用途、bootstrap 等上下文），同键请求继续合并，每个任务最多挂起 64 个等待者。超限返回解析失败，不启动额外任务，也不把过载结果缓存为 DNS 答案。已完成缓存仍限制为每个解析器 1,024 项。

调用方超时或取消不代表底层系统调用已经结束：未完成任务仍占用额度。刷新/更换上游会取消旧异步任务、唤醒等待者，并以代次拒绝旧结果；额度直到底层工作实际结束才归还，避免连续刷新绕过上限。系统 DNS 桥接器的所有默认实例合计最多执行 16 个阻塞调用，不另建等待队列；超额立即返回失败。已经进入 `getaddrinfo` 的调用不能被安全强制中断。

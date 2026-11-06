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
| server | 传统 UDP DNS，单个 IPv4/IPv6，可带端口，例如 `223.5.5.5:53`、`[2001:db8::53]:5353` |
| doh | 完整 HTTPS DoH URL；不支持用户名、密码、fragment 或无效端口 |
| bootstrap-dns | `system`，或最多八个纯 IPv4/IPv6 地址，按顺序尝试；固定 UDP/53，不接受域名或加密 DNS URL |

`mode`、`server`、`doh` 分别对应既有规范名 `dns-mode`、`dns-server`、`encrypted-dns-server`；两种写法不能重复定义。传统地址与 DoH 地址可同时保存，但必须写明 mode；显式 mode 最后应用，结果不受字典遍历顺序影响。仅填写 server 或 doh 时沿用既有自动选择对应传输的行为。mode=system 时这两个地址不参与普通查询。

这两个地址不是自动主备：不会因为配置了 server，就在 DoH 失败时暗中使用它。`fallback-dns-mode` / `fallback-dns-server` 仍按现有回退通道的行为工作，本次没有重新设计 DNS 故障策略。

## Bootstrap 的边界

Bootstrap **只解析域名形式的 DNS 上游端点**，不用于普通业务域名，也不用于节点域名。传统 DNS 已要求 IP；IP 形式 DoH（IPv4/IPv6）直接连接并跳过 bootstrap。

- `bootstrap-dns = system`：DoH 使用系统 URLSession 的解析和 TLS 路径。
- 指定 IP 列表：通过这些数值地址发出端点域名的 A/AAAA 查询，再直接连接返回的 IP。保留原 URL 主机用于 HTTP Host、SNI 和证书验证，使用系统 TLS 验证，不继承代理节点的 allow-insecure。
- 种子按顺序查询，取得地址后依次尝试连接。失败不会偷偷改用系统解析；DNSResolver 的 DoH 系统回退也在显式 bootstrap 模式下禁用。
- 上游重定向会拒绝，避免引入未配置的第二个端点依赖。DNS 响应最多 65,535 字节。

第一版自定义 IP bootstrap 的 HTTPS 连接使用 HTTP/1.1 POST，支持 Content-Length、chunked 和关闭连接结束的响应。**仅支持 HTTP/2 的 DoH 服务不适用于这条路径**。system 或 IP-literal URL 仍使用 URLSession。DoT、DoQ、显式 DoH3 未在本次增加；本功能也不是对应用内 DoH 的 MITM 接管。

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

它们分别沿用现有节点/代理相关、订阅、ECH 和回退解析通道，不代表 DNS 请求已新增“经所选代理发送”的路由能力。所有经过 DNSUpstreamClient 的域名 DoH 上游统一使用 bootstrap-dns。

已有 `[General]` DNS 规范字段仍可读取；同一字段同时出现在 `[General]` 与 `[DNS]` 会报错，不猜测优先级。按原文导出仍保留 DNS 段；从手工设置生成新文档时仍可使用原有 General 规范字段。

## 版本和验证

Bootstrap 保存于完整运行版本中，参与切换和回滚；旧版本缺少新字段时按 system 处理。普通 DNS 与 ECH 缓存键包含 bootstrap 策略，避免切换后复用其他种子上下文的缓存。内置公共 DNS 拦截名单对 bootstrap 种子作豁免。

新增测试覆盖配置段、别名、模式选择、错误与重复字段、种子校验及顺序、IP-literal 跳过、失败不回退、HTTP 响应分帧/大小/错误、旧版本读取和整包回滚。当前环境没有 Swift/Xcode，未运行构建、测试或真实 DNS/TLS 验收。

参考系统 TLS API：[sec_protocol_options_set_tls_server_name](https://developer.apple.com/documentation/security/sec_protocol_options_set_tls_server_name(_:_:))。

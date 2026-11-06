# IPv4-only 首版范围

当前版本只支持本机 IPv4 网络内核。已删除 IPv6 地址解析、AAAA 主动查询与地址返回、CIDR 匹配索引、协议地址编码、IP 栈包头/收发/ICMP 支持及 QUIC 地址与迁移支持。IPv6 配置选项和编辑器选项也已移除；地址/规则输入不被当作域名继续发送。

## 行为

- 节点接受 IPv4 或域名；域名的本机解析只使用 A 记录。纯 IPv6 节点与 IPv6 字面量拒绝连接。
- 普通 DNS、DoH、Bootstrap、Host、Geo 前缀及路由仅接受 IPv4。`IP-CIDR6`、`ipv6`、`ipv6-vif` 不再是有效配置项。
- Fake-IP 仍使用 IPv4 池。受拦截的 AAAA 查询返回 NODATA，这是拒绝行为，不是 IPv6 支持。
- TCP/UDP 底层连接统一使用数值 IPv4 目的地址，不再让 Network.framework 通过域名自动选择 IPv6。
- 为约束 DoH 拨号地址，system/bootstrap/IP-literal 三种情形都使用数值 IPv4 + 原始 Host/SNI/系统 TLS 校验。当前 DoH 上游传输为 HTTP/1.1；HTTP/2-only 服务暂不支持。
- 域名目标仍可交给远端代理解析；远端代理自行选择的网络地址族不由本机控制。本机到代理的传输及进入本机内核的数据包仍只走 IPv4。

## 唯一保留的系统级阻断

Network Extension 保留一条 IPv6 默认捕获路由和一个仅供捕获的接口地址。收到非 IPv4 包后直接丢弃，不创建 TCP/UDP 流、不反射、不输出该地址族的数据包。否则仅取消 IPv6 设置会让应用流量沿物理网卡直接绕过 IPv4 隧道。

这三处系统 API 声明是防绕行用途，不提供 IPv6 服务。操作系统自身的网络例外、排除本地网络/APNs 等连接偏好以及 IPv6-only/NAT64 环境仍需真机测试；不能仅凭静态检查声称完全无绕行。iCloud、URLSession 资源下载等系统服务的内部网络行为也不属于自研 IP 栈的能力声明。

## 协议线格式与历史资料

QUIC Preferred Address 固定线格式仍需跳过/填零一个 18 字节的未支持地址槽，不能直接删除字节破坏后续字段偏移。模型不再暴露可用的 IPv6 地址。SOCKS/Shadowsocks/Trojan 中对应地址类型只用于拒绝，不进行解码转发。

路由二进制的旧类型值 1 已停用，其他类型原始值保持不变，避免域名类型错位。旧载荷含已停用类型时拒绝加载。旧运行包、规则集或配置若含 IPv6，需要先移除相关内容后重新应用；不会自动改写用户保存的原文件。

历史开发计划中的 IPv6 里程碑不再属于首版范围。版权、许可证和依赖说明不因此删除。

## 验证状态

新增回归用例覆盖所有配置入口拒绝、协议编码不误用域名、IPv4 DNS/Bootstrap、IPv4 UDP 包往返、IPv4 TCP 包布局及头校验和、非 IPv4 包丢弃。旧 IPv6 正向用例已改为拒绝用例。

本环境没有 Swift/Xcode，只完成语法树、符号引用、工程/清单及 diff 静态检查。合入代码不等于测试通过。需要在 Mac 构建所有 target、运行应用测试和 `swift test --package-path Packages/NaiveFlowIP`，并真机验证 VPN、IPv4 TCP/UDP、所有承诺协议、DNS、版本切换与防绕行。

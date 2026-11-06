# NaiveFlow

Apple 平台的 Swift 代理客户端与网络内核，当前版本以 IPv4 为范围。配置采用原生分节文本形式，参考 Surge/Loon 的组织方式，不以兼容其配置文件为目标。

## 配置与运行架构

- **Rule Manager**：配置文档维护与规则解析。
- **Configuration Coordinator**：配置编译、校验与模块适配。
- **Runtime Coordinator**：协调 DNS、Rule、MITM、Outbound 等模块的配置下发、生命周期、版本切换与失败恢复。

配置包含有序规则、RULE-SET、节点、DNS、Host 及 MITM/脚本设置。配置文件的 iCloud 上传与下载由用户手动触发。实现细节与限制见下方文档。

## DNS 范围

| 场景 | 处理方式 |
| --- | --- |
| 进入 TUN 的普通 IPv4 DNS | UDP/53、TCP/53 共用规则拒绝和 Fake-IP；保留上游及 bootstrap 地址豁免 |
| 内核自身查询真实地址 | 使用相应解析通道的系统、传统 DNS 或 DoH 上游；支持配置 bootstrap |
| 应用内 DoH | 作为普通 HTTPS 流量，按服务端域名（可识别时）、IP、端口及 FINAL 分流 |
| 应用内 DoH3 | 作为普通 QUIC/UDP 流量分流，并受现有 QUIC 策略约束 |
| DoH 专用 MITM 解密、重查与回包 | 已从开发范围移除，不列为待实现功能 |

DoH/DoH3 请求与业务连接需分别配置相同出口，才能让解析视角与访问出口尽量一致；DNS 服务商的缓存、ECS 和调度仍可能影响结果。应用内加密 DNS 不经过本地 Fake-IP，后续业务域名规则依赖可用的域名嗅探；不可识别时使用 IP 规则或 FINAL。

DNS 分流无需安装 MITM CA，也不会自动启用 MITM。通用 HTTPS 解密、改写与脚本功能仍保留，由显式 MITM 配置控制。当前不提供 HTTP/3 MITM 解密，也不保证阻断 QUIC 后应用一定回退。

## 文档

- [DNS 配置与接管边界](Documentations/DNSConfiguration.md)
- [配置规范](Documentations/Configuration.md)与[配置架构](Documentations/ConfigurationArchitecture.md)
- [RULE-SET](Documentations/RuleSets.md)
- [iCloud 手动同步](Documentations/ConfigurationCloudSync.md)
- [MITM 改写与脚本](Documentations/MITM.md)
- [IPv4 范围](Documentations/IPv4Only.md)
- [开发计划](DEVELOPMENT_PLAN.md)与[排期及历史记录](SCHEDULE.md)

## 验证状态

代码实现与可用性验收分别记录。近期 DNS 和 IPv4 改动做过静态检查，尚需在 Xcode 中完成构建、测试及真机流量验证；文档中的历史测试结果不能替代当前提交的验收。

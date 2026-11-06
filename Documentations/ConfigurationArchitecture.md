# NaiveFlow 原生配置与版本发布

当前首版为 IPv4-only；范围与阻断说明见 [IPv4Only.md](IPv4Only.md)。


配置形式参考分段、键值与规则列表；字段和运行语义属于 NaiveFlow。本文描述原生 v1，不承诺导入其他客户端配置。

## 三层职责

| 层 | 职责 |
| --- | --- |
| RuleManager | 文档读取、草稿、结构解析、快照、历史 |
| ConfigurationCoordinator | 语义校验、编译、模块归属和变更计划 |
| ConfigurationPublisher / RuntimeCoordinator | 不可变版本发布；DNS、Rule、MITM、Outbound 的加载、确认、切换与恢复 |

编辑器通过唯一的 ConfigurationPublisher 应用文档。旧的逐 Store 写入安装路径已经移除。手工节点、分组和规则库作为独立资料保留，文本版本控制实际流量；首页显示版本中的默认出站节点。节点库页面提示当前由文本版本控制，不能用库里的选中动作悄悄覆盖运行版本。需要修改活动路由时编辑配置并应用。

## DNS 配置

`[DNS]` 集中配置传统 DNS、DoH 及 bootstrap-dns；见 [DNSConfiguration.md](DNSConfiguration.md)。Bootstrap 随运行版本切换，显式 mode 优先于端点字段。

## iCloud 文本同步

配置页仅在点击上传或下载时传输配置文本；编辑、应用和启动不自动传输。上传新增云端副本，下载后需确认载入并在本机单独应用；详见 [ConfigurationCloudSync.md](ConfigurationCloudSync.md)。

## 版本切换协议

1. 合并结构解析与语义诊断；错误文档可以存草稿，不能应用。
2. 下载脚本、检查大小/编码/语法，固定脚本字节。同步捕获 DNS/TUN/TLS 设置、Host、节点、规则、Geo 数据及 MITM 策略。
3. 取得跨进程发布锁，保存不可变 bundle、SHA-256 校验信息和宿主 manifest 恢复日志。
4. 用 compare-and-swap 更新一个原子 head 文件。head 包含版本 ID、上一版 ID 和每次发布独立的 request ID。
5. 扩展验证整包、正则、MITM 操作和 CA 信任。暂停新收包与输出，回收旧 UDP 流，应用 OS 隧道设置，随后无挂起地替换模块输入并重建数据平面。
6. 扩展为确切版本写 receipt，再确认快照。宿主只有拿到正确确认后才显示完成。停止状态下保存的版本等待下一次启动确认。

连接级 Network Extension 偏好通过宿主自动重连应用。一般版本更新重建数据平面，既有连接会被关闭；这是保持一致性的热更新，不是无损连接迁移。

DNS 读取固定在一个设置视图，缓存有代际隔离；旧路由编译、延迟重启、UDP 解析回调不能覆盖新版本。原有协议、IP 栈、传输池及 MITM 执行器继续使用。

## 失败与回滚

编译、资源下载、完整性、CA、模块准备、隧道设置或 receipt 写入失败，会恢复上一版整包及 OS 设置。旧版脚本直接使用保存的字节，不重新下载。

扩展在启动时可退回上一版；宿主根据精确 request ID 的 receipt 和恢复日志还原 manifest。宿主进程退出后，重新获知 VPN 状态时恢复待发布事务。旧 receipt 不能确认一次新的回滚请求。恢复 OS 设置本身失败时终止 provider，宿主尝试重启上一版，错误会保留在配置状态中。

“Restore Previous Runtime Version”直接恢复不可变上一版；历史列表的“载入文本再应用”属于新发布，会重新获取文档引用的远程资源。

这里的失败指配置准备/发布/安装失败。节点的远程认证、可达性及网站连接失败仍属于连接错误，不据此自动切换到旧版本。设备断电、磁盘永久损坏等不可恢复条件不承诺事务持久性。

## 原生能力与限制

| 项目 | 原生 v1 |
| --- | --- |
| 路由 | 顺序首条命中、每条策略、FINAL；精确域名、后缀、关键字、通配符、正则；IPv4 CIDR、来源 IP/端口、目标端口、TCP/UDP；AND/OR/NOT |
| 外部规则集 | RULE-SET 引用 HTTPS 或 App 可读的绝对 file:/// 文件；发布前展开、校验并固定到运行包，详见 [RuleSets.md](RuleSets.md) |
| Geo | [GeoIP] 中的国家/ASN 前缀和 [GeoSite] 的域名后缀列表，随版本固定；不附带外部数据库 |
| 分组 | select，支持嵌套、内置动作和 selected=成员；不支持自动延迟选择/负载均衡 |
| Host | 精确域名 → IPv4 字面量。没有把 server:、通配符或别名当作有效绑定 |
| MITM | enable、hostname 后缀；URL、Header、Body、JSON 改写、Map Local；必须先安装并信任既有 CA |
| 脚本 | http-request/http-response；普通或逐帧 process(ctx)，复用已有原生脚本 ABI；HTTPS 或 base64 源，固定字节；支持 $argument |
| 无损导出 | [MITM Set] 保存原生规则集的 Base64 JSON，保留作用域 ID、参数和脚本字节；不把多个作用域扁平化 |

PROCESS-NAME、USER-AGENT、URL 路由、定时/DNS 脚本、证书导入、其他客户端脚本 API、未实现 General 字段会明确拒绝。bypass-country 只有本机存在对应预设数据库时才接受；也可使用文档内的 Geo 数据。规则匹配可能先等待 DNS；no-resolve 不触发额外查询。

文本文档最多 16 MiB，脚本源最多 1 MB，运行包最多 16 MiB。请求/响应完整消息、流式脚本和 JSON path 的行为遵循现有 MITM 引擎，见 MITM.md。

## 验证状态

新增测试覆盖顺序与 FINAL、DNS 等待、no-resolve、流元数据、逻辑短路、Geo、CIDR 边界、文本改写、脚本固定、作用域导出、离线发布、失败恢复、过期确认、内容损坏、并发发布和宿主中断恢复。

当前编辑环境没有 Swift/Xcode：只执行 Swift 语法树回归检查、工程文件/目标引用检查和 git diff --check；没有声称构建、单元测试或真机通过。

在满足本工程 Swift tools 版本要求的 Mac 上执行（模拟器名按本机替换）：

```sh
xcodebuild build -project RuleProxy.xcodeproj -scheme RuleProxy -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project RuleProxy.xcodeproj -scheme RuleProxy -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'RuleProxy Tests' CODE_SIGNING_ALLOWED=NO
```

真机需覆盖：旧连接切断、新连接使用新规则、MITM CA 未信任时回滚、脚本下载失败、连续切换、应用退出后恢复、重连偏好变更、睡眠/唤醒和网络切换。连通性测试需要受控节点，跳过不能算通过。

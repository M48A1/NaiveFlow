# 原生 RULE-SET

在 `[Rule]` 中引用条件列表，并为整份列表指定策略：

```ini
[Rule]
DOMAIN, first.example, DIRECT
RULE-SET, https://example.com/rules/ads.list, REJECT
RULE-SET, https://example.com/rules/local.list, DIRECT, no-resolve
FINAL, PROXY
```

这是 NaiveFlow 原生语法，形式参考常见代理客户端。不承诺兼容其他客户端的全部规则类型或规则提供器格式。

## 规则集文件

UTF-8 纯文本，一行一个条件，不写策略、不写 `[Rule]` 标题：

```text
# 注释；也支持以 ; 或 // 开头的整行注释
DOMAIN, ads.example.com
DOMAIN-SUFFIX, tracker.example
IP-CIDR, 192.0.2.0/24
AND,((PROTOCOL,UDP),(DEST-PORT,443))
```

支持原生域名、CIDR、端口、协议、逻辑及 Geo 条件；Geo 条件所需的数据仍由主配置的 `[GeoIP]` / `[GeoSite]` 提供。正则或带逗号的字段应使用双引号。文件中的 `FINAL`、嵌套 `RULE-SET`、每行自带策略、YAML/JSON 提供器、二进制数据库、纯域名列表和未实现类型会报错，整次应用中止。空规则集也会报错，避免错误地址返回空文件后意外清空过滤。

## 顺序与策略

规则集在引用所在的位置展开；主配置和规则集内部都保持原顺序，首条命中获胜。同一来源可以在不同位置引用并使用不同策略；一次发布只读取一次该来源。

引用上的 `no-resolve` 会传播到内部需要目标 IP 的条件。域名条件正常匹配；规则集内部的 `no-resolve` 也保留。

## 来源与更新

支持 HTTPS URL，以及 App 已有权限读取的绝对 `file:///` URL：

```ini
[Rule]
RULE-SET, file:///absolute/app-accessible/path/local.list, DIRECT
FINAL, PROXY
```

本地 URL 必须指向 App 沙盒或已获授权的位置。此功能不提供新的文件选择器或持久安全书签，不能借此访问 iOS/macOS 任意目录；也不解析相对于导入配置的路径。URL 含逗号时应整体加双引号。不允许明文 HTTP、URL 用户名/密码及 fragment。

每次点击“应用”重新读取资源并校验。没有后台定时刷新、自动更新或下载失败时复用缓存；HTTPS 响应必须为 2xx，最终地址仍为 HTTPS。网络请求超时为 20 秒，用户取消会中断应用。

下载及完整语义校验发生在发布前，错误包含主配置引用位置或源文件行号。任何来源失败都保留当前运行版本，不发布部分结果。校验成功后，只有展开后的规则进入不可变运行包；扩展无需联网。启动和“恢复上一运行版本”复用保存的规则，源文件变更或失效不会影响旧版本。历史文本重新应用属于新发布，会重新获取来源。

编辑器实时预览不联网，未解析的引用会显示“应用时验证、路由预览不完整”的警告。成功应用时的快照统计包含展开后的规则数。

## 限制与验证

每个来源最多 4 MiB，最多 64 个独立来源，总下载文本最多 16 MiB，展开后整份配置最多 100,000 条规则，最终仍受运行包 16 MiB 限制。HTTPS 来源顺序下载，任一失败立即停止。

新增测试覆盖引用顺序、策略覆盖、no-resolve、注释与换行、错误行号、非法内容、重复下载去重、本地文件读取、大小/编码限制、刷新失败保留旧版本及回滚不下载。当前环境没有 Swift/Xcode，单元测试和真机验证尚未执行。

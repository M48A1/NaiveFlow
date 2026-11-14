# GeoIP / GeoSite 数据库

原生有序规则可使用配置内数据，也可显式引用外部资源。Geo 数据与节点、规则及 DNS 设置一起进入不可变运行版本；扩展不联网下载数据库。

## 外部格式与配置

支持以下格式，不依赖新的第三方解析库：

| format | 内容 |
| --- | --- |
| `geoip-dat` | V2Ray routercommon `GeoIPList` protobuf；选择一个 category，提取 IPv4 CIDR |
| `geosite-dat` | V2Ray routercommon `GeoSiteList` protobuf；完整域名、后缀、关键字、正则四种条件 |
| `cidr` | UTF-8 文本，每行一个 IPv4 CIDR 或 IPv4 地址 |
| `domain` | UTF-8 文本，每行一个域名后缀，或 `domain:`、`full:`、`keyword:`、`regexp:` 条件 |

```ini
[GeoIP]
# HTTPS URL 或已授权的绝对 file:/// 路径；替换为自己选择的数据源。
CN = https://example.com/geoip.dat, format=geoip-dat, category=CN
AS64500 = file:///absolute/app-accessible/as64500.txt, format=cidr

[GeoSite]
cn = https://example.com/geosite.dat, format=geosite-dat, category=CN
ads = https://example.com/geosite.dat, format=geosite-dat, category=category-ads-all
cn-ads = https://example.com/geosite.dat, format=geosite-dat, category=CN@ads
internal = file:///absolute/app-accessible/domains.txt, format=domain

[Rule]
GEOSITE,internal,DIRECT
GEOSITE,ads,REJECT
GEOSITE,cn,DIRECT
GEOIP,CN,DIRECT
GEOASN,64500,DIRECT
FINAL,PROXY
```

这些 URL 是语法示例，不是随包提供或默认联网的数据源。`category` 缺省采用左侧名称；IP 与站点格式缺省分别为 `geoip-dat`、`geosite-dat`。GeoIP 左侧名称是路由用国家/分类标识，或 `AS` 加正整数；GeoSite 左侧是路由用 tag，统一小写。可以将数据源分类映射到自选标识。配置内原有国家/ASN 前缀及域名后缀写法继续有效。

可选 `sha256=<64位十六进制摘要>` 固定整个来源文件；摘要不匹配拒绝更新。固定摘要后，要更新数据库必须同时修改摘要。下载入口禁止明文 HTTP、凭据和 fragment；响应必须为 2xx，最终 URL 必须仍为 HTTPS。本地路径需要 App 已有读取权限；不新增任意目录访问或安全书签。

GeoSite 支持 `category@attribute`，只选择指定属性值非零的记录；不带属性选择器时包含该分类所有记录。正则使用系统 `NSRegularExpression`，无法编译的规则拒绝整次更新。V2Ray 反向 GeoIP 分类不支持，显式报错；混合 GeoIP 数据中的有效非 IPv4 记录跳过，选中分类没有 IPv4 数据则拒绝。MMDB、Clash YAML、sing-box SRS 不在本次格式支持范围。

文本格式允许空行及以 `#`、`;`、`//` 开头的整行注释，不支持 include、内嵌策略或行尾注释。无效行、未知选项、空分类、缺失分类、越界或截断 protobuf 均拒绝；不把无法解释的匹配条件转换成不同语义。

## 下载、更新与失败恢复

1. 编辑器预览只校验声明，显示“应用时下载校验”的警告，不联网。
2. 点击“应用”时下载所有显式来源；相同 URL 在本次操作中只读取一次。即使配置文本没改，也可以再次应用以刷新数据库。
3. 校验来源格式、可选 SHA-256、分类、条件与容量；只有所需分类进入运行数据。
4. 数据来源 URL、SHA-256、加载时间和格式固定在运行版本中。原始文件以摘要命名、原子写入审计缓存；缓存总量尽量限制在 256 MiB，清理失败不影响运行版本。
5. 所有数据准备成功后才发布完整配置。任一下载、校验、编译或扩展激活失败，沿用既有版本恢复机制；不安装部分数据库，也不静默使用旧下载掩盖更新失败。
6. 启动及“恢复上一运行版本”使用已固定的数据，不重新下载。历史文本重新应用是一次新更新，会重新获取资源。

这是手动刷新机制，不包含后台定时更新。原始文件缓存不决定当前版本；清理它不影响当前或可回滚版本。若首次激活时隧道未运行，仍需在后续启动时获得扩展确认。

## 索引与优先级

- **IPv4**：按前缀长度建立数值地址哈希桶；一次查询最多 33 次桶探测，不随前缀总数线性扫描。国家与 ASN 分别取最长前缀；相同前缀的相同字段保持首条声明优先。
- **域名**：完整域名哈希集合，后缀按标签探测；关键字使用 Aho–Corasick 自动机。
- **正则**：导入时校验，建立索引时预编译；索引条件未命中时才检查该 tag 的正则。正则部分仍随正则数量线性增长，不能承诺任意正则集合恒定耗时。
- **规则顺序**：索引仅加速 Geo 条件，不重排主配置规则；首条命中、逻辑规则与 `no-resolve` 语义保持原样。
- 索引不写入配置 JSON，在编译完成或运行包解码时构建一次，再共享给匹配器。

## 资源边界与验证状态

最多 32 个来源声明；单个原始文件 64 MiB，本次下载去重后合计 128 MiB；转换后的前缀及域名条件合计最多 2,000,000 条。整个运行包 JSON 仍受 64 MiB 限制（校验和封装文件最多 96 MiB），任一限制超出均拒绝发布；两百万条是硬上限，不是所有设备的性能保证。配置文本仍限制 16 MiB，脚本限制不变。

索引结构已接入实际运行匹配路径。客户端回归测试覆盖数据源编辑、手动刷新及失败时保留旧版本；吞吐、内存性能基准和真机兼容性尚未验收。

## 客户端维护入口

设置首页的 GeoIP / GeoSite 页面可维护具名更新地址、格式、来源分类及可选 SHA-256；右上角 + 新增，点击编辑，左滑可编辑或删除。页面从当前运行版本读取来源加载时间，避免将预览结果误认为已加载数据。保存并更新、手动更新都沿用完整配置发布流程，失败保留旧版本。手动更新会刷新当前配置引用的全部外部资源，不只刷新当前页面的类型。

客户端回归测试使用本地 CIDR 和域名文件验证更新后运行匹配数据的变化，以及无效文件时旧运行版本的保留。

# 第一步：工程基线检查

最新构建与测试记录见文末「2026-11-13 DNS 缓存清理优化」。以下早期记录保留当时状态。

检查日期：2026-11-03（静态检查）、2026-11-04（依赖收敛与构建）。状态：iOS 与 tvOS 无签名构建通过；签名、真机与单元测试验收未完成。

## 已完成

- 工作副本无 Anywhere 文件名及源码残留；原始 Reference 目录除外。
- 工程 project.pbxproj 格式合法；此前检查的 9 个 plist/entitlements、2 个 JSON/xcstrings、6 个 XML 配置均可解析。
- 检查 49 处同步目录、本地包、Info.plist、entitlements、scheme target 引用。
- 当前 target：主应用、Network Extension、Tests、Widget、TV 共 5 个（11-03 检查时还存在 Watch App，随后按平台范围要求删除）。
- 本地 NaiveFlowIP、NaiveFlowQUIC、BLAKE、YAML 目录存在，改名后的包名与源码目录对应。
- 主应用及扩展共享 `group.com.argsment.NaiveFlow`；AWCore 使用对应 bundle、App Group 与 CloudKit 名称。本地声明一致不代表账号已开通能力。
- 主应用 scheme 引用了仓库不存在的 StoreKit 配置。已移除该失效引用；未创建虚构的 StoreKit 商品配置。

## 环境与阻塞

> 以下为 2026-11-03 使用 Command Line Tools 时的情况记录。Xcode 27.2 启用后已不再成立，最新构建结论见“构建验证”一节。

- 当时 developer directory：`/Library/Developer/CommandLineTools`（现为 `/Applications/Xcode.app/Contents/Developer`，Xcode 27.2 / 27B52）。
- 当时已安装 Swift 6.4.2；本地网络包 manifest 要求 Swift tools 6.4。
- 当时 `/Applications` 下未发现 Xcode.app；`xcodebuild -list -project NaiveFlow.xcodeproj` 失败，提示需要完整 Xcode，因此当时没有完成工程加载、Swift 编译、SDK 链接或运行验证。
- 部署版本仍待真机确认：主应用/扩展可见 iOS 18，测试 iOS 26，TV 为 tvOS 26，项目层还有 iOS 26.6；无签名构建已通过，说明 build settings 可解析，但不擅自降级部署版本。
- 开发团队仍为 `C7AS5D38Q8`，是否属于当前用户可用账号尚未验证。不自动更换团队，不声称签名通过。

## 远程资源核对

批量改名改变了以下地址，不能据此认定资源已经存在；未联网验证或替用户创建资源：

- AboutView 中的 Telegram 群组链接已整段移除（见文末清理记录），不再作为待核对资源。
- MITMRuleEditorView 中 `https://argsment.com/naiveflow`：只是输入示例，不能作为有效服务承诺。
- README 中的品牌图片、仓库等链接：发布文档前按实际资源替换。
- `http://127.0.0.1:…/NaiveFlowMITMRoot.mobileconfig` 为本地证书服务路径，与远程资源分开处理。

不擅自恢复旧品牌地址，也不把未知地址当作已经配置完成的服务。

## 待补验收

1. 安装完整 Xcode 并启用其 developer directory，确认所需 iOS/tvOS/watchOS SDK。
2. 加载 NaiveFlow.xcodeproj，运行主应用无签名构建及相关 target 构建，记录实际编译问题。
3. 在用户的开发者账号中核对团队、Bundle ID、App Group、CloudKit、Network Extension 和 provisioning profile。
4. 真机签名安装，验证共享文件、provider message 与 VPN 启停。
5. 使用受控测试节点完成导入、连接、实际访问与断开，记录协议、网络和系统版本。

第一步尚未整体通过，不能将静态检查结果替代编译或真机结果。本次没有修改网络功能或新增测试。


## 后续复核：平台清理

Xcode 27.2 已安装并启用，许可阻塞已解除。本次删除 Watch 目标与源代码后，检查剩余工程对象无悬空引用，pbxproj 格式合法。现有 target 为主应用、TV、Network Extension、Widget、Tests，尚无 macOS 客户端。

已尝试完整 Xcode 的 `-list` 加载：包依赖 `https://github.com/hiDandelion/NaiveFlowRules.git` 拉取失败，提示无法读取 GitHub 用户名。当时尚未进入源码编译，也未完成签名与真机验证；不将仓库访问错误判断为代码编译错误。（该阻塞已在“构建验证”一节通过移除该私有预设包解除。）

## 后续清理：移除 Anywhere/Voyager 支付与 Telegram 群组

本次按要求删除从 Anywhere 继承的付费/群组入口，不涉及网络内核与路由逻辑：

- 删除 StoreKit 内购层：`NaiveFlow/Stores/VoyagerStore.swift`（商品加载、购买、恢复、交易监听、会员凭证）以及空目录 `NaiveFlow/Stores`。
- 删除付费墙 UI：`Views/Components/VoyagerNotice.swift`、`Views/Components/JoinVoyagerButton.swift`。
- 删除依赖会员身份的公开测试页：`Views/Pages/About/AdvancedSettings/JoinBetaView.swift`，并从 `AdvancedSettingsView` 移除 “Public Beta” 入口，保留 “Experimental Features”。
- 移除 `PersonalizationView` 的 “Voyager Member Card” 开关、`ToolboxView`/`HomeView` 的会员卡片块，以及 `CustomizeAppIconView`、`CustomizeThemeView` 的 `isMember` 门禁（原先是未购买即禁用）。
- `NaiveFlowApp` 不再创建/注入 `VoyagerStore`。
- `Shared/AWCore.swift` 移除 `voyagerMembership`、`showVoyagerCard` 两个 UserDefaults 键及其读写方法；`AppSettings` 移除 `showVoyagerCard`。
- `AboutView` 删除 Telegram 群组 `Link` 段，并删除仅为该链接存在的 `TextWithColorfulIconAndCustomImage` 组件；`AcknowledgementsView` 商标列表移除 Telegram 条目。
- `Shared/Localizable.xcstrings` 删除 22 个随之失效的键（Voyager 会员、解锁、购买/恢复购买、公开测试、Telegram 群组及 Join 等；478 → 456），JSON 校验通过，仅删不改格式。

未删除 `Reference/Anywhere` 对照副本。以上改动仅做过 `swiftc -parse` 语法检查与 JSON 校验，当时尚未完成工程编译；包依赖拉取失败是当时的编译阻塞原因，已在下一节通过移除该私有预设包解除。

## 构建验证：依赖本地化与全量编译

日期 2026-11-04，Xcode 27.2（build 27B52）。

### 依赖核对结论

- 检查时工程共 5 个 SwiftPM 依赖，其中 4 个为仓库内本地包（`NaiveFlowIP`、`NaiveFlowQUIC`、`BLAKE`、`YAML`），
  manifest 内无远程依赖；全部自包含，**无需额外下载**。
- 第 5 个 `NaiveFlowRules`（上游 `AnywhereRules`）为私有仓库：匿名访问 GitHub 返回 404，
  仓库搜索命中 0；上游公开仓库 `NodePassProject/Anywhere` 也指向同一私有地址，
  其公开 git 树中既没有该包源码也没有 `Rules.db`。因此该包**无法下载**，只能本地替身或由用户提供访问权限。
- 明细与恢复步骤见 `Reference/Dependencies.md`。

### 依赖处理：只保留核心组件

工程现在只链接 4 个仓库内本地包——`NaiveFlowIP`、`NaiveFlowQUIC`、`BLAKE`、`YAML`，即上游的核心组件，
manifest 内无远程依赖，**没有任何需要联网拉取的东西**。第 5 个 `NaiveFlowRules`（上游 `AnywhereRules`）
只提供路由预设数据库、属于私有仓库（匿名访问 404，仓库搜索 0 命中，上游公开仓库也指向同一私有地址，
其公开 git 树中既无源码也无 `Rules.db`），已按“只参考核心组件”**从工程中移除**：

1. `Shared/DataStore/RoutingRulesDatabase.swift`：删除 `import NaiveFlowRules`，改为 `resolveDatabaseURL()`
   在 `Bundle.main` 查找可选的 `Rules.db`（含 `Rules/` 子目录）；找不到时沿用原有兜底
   （记 `[Routing] Rules.db not found`，预设查询返回空数组/空字典）。路由内核、规则集编辑、连接流程不受影响。
2. `NaiveFlow.xcodeproj/project.pbxproj`：删除该包的 5 类对象及全部引用（远程包引用、两个产品依赖、
   两个 `PBXBuildFile`、主应用与 TV target 的 `packageProductDependencies` 与 `Frameworks` 条目、
   `packageReferences` 条目）。`plutil -lint` 通过，全文已无相关对象。`Package.resolved` 因无远程包被删除。
3. 明细与恢复步骤见 `Reference/Dependencies.md`。

### 本次加入的临时内容

`Shared/Assets.xcassets`：补 9 个占位色板 + 空 `AppIcon.appiconset`。源码依赖
`Color.homeBackgroundStart` 等资源目录生成符号，而本仓库与上游公开仓库都没有任何 `.xcassets`，
缺这些占位资源主应用与 TV 都无法编译。色值为中性占位、`AppIcon` 无图片，发布前必须替换。

### 编译结果

| Scheme | 目标平台 | 命令要点 | 结果 |
| --- | --- | --- | --- |
| NaiveFlow | iOS（generic/platform=iOS） | Debug、`CODE_SIGNING_ALLOWED=NO` | **BUILD SUCCEEDED**，0 error（日志 `/tmp/xcbuild5.log`） |
| NaiveFlow TV | tvOS（generic/platform=tvOS） | Debug、`CODE_SIGNING_ALLOWED=NO` | **BUILD SUCCEEDED**，0 error（日志 `/tmp/xcbuildtv3.log`） |

### 2026-11-04 追加：02 文本配置 + 应用内配置页

| 动作 | 命令要点 | 结果 |
| --- | --- | --- |
| 构建主应用（含 NE、Widget） | `xcodebuild build -scheme NaiveFlow -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` | **BUILD SUCCEEDED**，0 error（日志 `/tmp/naiveflow_build.log`）；`ConfigurationView.swift` 与 `ConfigurationDocumentOperations.swift` 均参与编译 |
| 运行单元测试 | `xcodebuild test -scheme NaiveFlow -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO` | **TEST SUCCEEDED**，40 个用例全部通过、0 失败（日志 `/tmp/t3.log`），含 `ConfigurationTextTests`、`ConfigurationExporterTests`、`OrderedRouteMatcherTests`、`DeterministicBytesTests` |

### 2026-11-04 追加：`[General]` 目录化（settings catalog）

| 动作 | 命令要点 | 结果 |
| --- | --- | --- |
| 构建主应用（含 NE、Widget） | `xcodebuild build -scheme NaiveFlow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` | **BUILD SUCCEEDED**，0 error；`ConfigurationSettings.swift` 参与编译 |
| 运行单元测试 | `xcodebuild test-without-building -scheme NaiveFlow -destination 'platform=iOS Simulator,id=DE25C87A-…' -only-testing:'NaiveFlow Tests' CODE_SIGNING_ALLOWED=NO` | **TEST EXECUTE SUCCEEDED**，66 个用例 / 6 个 suite 全部通过、0 失败（日志 `/tmp/tB.log`），新增 `ConfigurationSettingsTests`（19 例） |

`[General]` 的键集合改由 `ConfigurationSettings.catalog` 声明、`ConfigurationSettingsBindings.all` 绑定；
解析/校验/编译/安装/导出/重载分级共用这两张表，`[General]` 覆盖 17 → 54 个键。
测试里新增的“目录与绑定表互为子集”“`applies: false` 不允许有绑定”两条断言，防止以后加参数时只改一半。

本次测试首次运行暴露并修复了两个真实缺陷：

1. **应用在无签名模拟器上启动即崩溃**：`AWCore.routingDataURL` / `mitmDataURL` 对 App Group
   容器强制解包，无签名构建拿不到容器 URL → `SIGTRAP`（`AWCore.mitmDataURL` 的一次性初始化）。
   现改为与 `ConfigurationSnapshotStore` 一致的兜底：容器不可用时落到 `URL.temporaryDirectory`，
   启动不再崩溃；代价是该环境下主应用与扩展无法共享 `routing.bin` / `mitm.bin`。
2. **节点名与内置策略 token 冲突**：`Policy(token:)` 会先把 token 转成大写再匹配，因此名为
   `Proxy` / `Direct` 的节点（或分组）永远无法被规则引用（`RULE, value, DIRECT` 绑定的是内置动作）。
   新增诊断 `reservedPolicyName`（warning，`[Proxy]` 与 `[Proxy Group]` 都检查）显式说明原因；
   导出器在净化名称时追加 `_` 并写入 `notes`，保证“导出 → 导入”行为一致；模板里的示例节点由
   `Proxy` 改名为 `Node`。

- 依赖解析结果只剩 4 个本地核心包，全部 `@ local`，无网络拉取阻塞。
- 主应用 scheme 同时构建 Network Extension 与 Widget，13 个 target 全部成功。
- Voyager/Telegram 清理处**没有产生任何编译错误**；此前出现的
  `Color.homeBackgroundStart/End`、`statCardBackground`、`connected/disconnectedBackgroundStart/End`
  报错全部由缺失资源目录导致，与本次删除无关。

### 2026-11-04 追加：编辑器会话层（`ProfileEditorModel`）

| 动作 | 命令要点 | 结果 |
| --- | --- | --- |
| 构建主应用（含 NE、Widget） | `xcodebuild build -scheme NaiveFlow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` | **BUILD SUCCEEDED**，0 error（日志 `/tmp/pB.log`、最后一次增量构建 `/tmp/pD.log`）；`Shared/ViewModels/ProfileEditorModel.swift`、`NaiveFlow/Views/Pages/Profile/ProfileView.swift` 均参与编译 |
| 运行单元测试 | `xcodebuild test -scheme NaiveFlow -destination 'platform=iOS Simulator,id=DE25C87A-…' -only-testing:'NaiveFlow Tests' CODE_SIGNING_ALLOWED=NO` | **TEST SUCCEEDED**，7 个 suite、73 个用例通过、0 失败（日志 `/tmp/tG.log`、最后一次全量 `/tmp/tH.log`），其中新增 `ProfileEditorModelTests` 14 例；`ConfigurationConnectivityTests` 7 例按 `TestEnvironment` 未配置跳过 |

`ConfigurationView` 换名为 `ProfileView`，会话逻辑移入 `ProfileEditorModel`（经 `ProfileEditing` 协议与流水线解耦，
测试用桩件即可覆盖 dirty 追踪、被拒绝的 apply、reload 分级与导入失败），`Views/Pages/Configuration/` 目录随之删除，
侧边栏与 `Toolbox` 的引用同步更新。页面文案与 `navigationTitle` 仍是 “Configuration”，用户可见名称不变。

调试记录：`ProfileEditorModelTests` 首轮 2 例失败，原因是测试样例与桩件默认草稿完全相同（`edit()` 因此提前返回）
以及样例里用了 `FINAL`——当前 `Validator.Capabilities.current` 不支持 `FINAL`，会额外产生 warning。样例改为单条
`DOMAIN-SUFFIX` 规则后全绿；这也说明样例文档必须落在“当前引擎能力”内，否则断言的是能力缺口而不是编辑器行为。


### 仍未完成

1. 签名、provisioning profile、真机安装与 VPN 启停验证未做（本次全部无签名构建）。
2. 真实 `AppIcon`、`AccentColor` 与其余品牌资源未提供，当前为占位。
3. 内置路由预设为空（不链接私有预设包）；需要时把自备 `Rules.db` 加入主应用 target 资源即可自动加载。
4. 单元测试 target 未执行（`NaiveFlow Tests` 未纳入本次构建范围）。

### 2026-11-08 最终检查更新

- Xcode 工程解析成功，当前仅使用仓库内的 `NaiveFlowIP`、`NaiveFlowQUIC`、`BLAKE`、`YAML` 四个本地包；target 列表无悬空项。
- 最新全量模拟器测试 **318 项通过**，不再适用“单元测试未执行”的旧记录；历史段落保留作当时快照。
- 当前仍未完成的是签名、开发者账号能力、真机 VPN/网络路径和受控服务验收。根目录未新增 README 文件。


### 2026-11-12 构建与测试回归

- 基线提交：`b7d9139209d76c6e6e7bde67a1c547bbf6d6f863`；检查开始时工作区干净。本次另补齐 `ConfigurationModule.settingOwners` 中 `lan-proxy-enabled` 的 `.outbound` 归属，并更新检查记录。
- 环境：Xcode 27.2（27B52），iPhone 17 / iOS 27.2 模拟器（`DE25C87A-6656-4AEF-93E0-12FE8D85407F`）。工程识别 6 个 target、4 个本地 SwiftPM 包，无远程包依赖。
- 使用独立 DerivedData 目录执行 Debug 无签名构建（`CODE_SIGNING_ALLOWED=NO`）；首次构建及修复后复构建均成功。

| 检查 | 目标 / destination | 最终结果 | 日志（本机临时目录） |
| --- | --- | --- | --- |
| iOS 构建 | `NaiveFlow` / `generic/platform=iOS`，含 Network Extension、Widget | BUILD SUCCEEDED | `/tmp/naiveflow-20261112/ios-fixed.log` |
| tvOS 构建 | `NaiveFlow TV` / `generic/platform=tvOS`，含 Network Extension | BUILD SUCCEEDED | `/tmp/naiveflow-20261112/tvos-fixed.log` |
| macOS 构建 | `NaiveFlow macOS` / `platform=macOS`，依赖 Network Extension | BUILD SUCCEEDED | `/tmp/naiveflow-20261112/macos-fixed.log` |
| IPv4 内核包测试 | `swift test --package-path Packages/NaiveFlowIP --scratch-path /tmp/naiveflow-20261112/ip-package` | 3 项通过，0 失败 | `/tmp/naiveflow-20261112/ip-package.log` |

#### 最终模拟器全量结果

修复后返回 **TEST SUCCEEDED**。xcresult summary：**357 项通过、0 失败、7 项跳过，总计 364 项**；参数化用例展开后的设备执行统计为 **361 次通过、0 失败、7 次跳过**。两种统计口径分别保留，避免与历史测试数量直接混比。

结果包：`/tmp/naiveflow-20261112/Tests-fixed.xcresult`；日志：`/tmp/naiveflow-20261112/tests-fixed.log`；摘要：`/tmp/naiveflow-20261112/test-summary-fixed.json`。

复现全量测试（结果包路径须尚不存在）：

```sh
xcodebuild -project NaiveFlow.xcodeproj -scheme NaiveFlow -configuration Debug \
  -destination 'platform=iOS Simulator,id=DE25C87A-6656-4AEF-93E0-12FE8D85407F' \
  -derivedDataPath /tmp/naiveflow-20261112/simulator \
  -resultBundlePath /tmp/naiveflow-20261112/Tests-fixed.xcresult \
  CODE_SIGNING_ALLOWED=NO test
```

各平台构建使用同一工程的相应 scheme、上表 destination 和独立 DerivedData 目录，执行 `CODE_SIGNING_ALLOWED=NO build`。最终 `git diff --check` 通过。

#### 首次失败及修复

首次全量模拟器测试返回 TEST FAILED：按 xcresult summary 的测试定义口径，356 项通过、1 项失败、7 项跳过，总计 364 项。失败用例为 `ConfigurationCoordinatorTests/everyAppliedKeyHasAnOwner()`，断言指出 `lan-proxy-enabled` 已列为可应用配置，却未登记模块归属。已将该键归属至 `.outbound`，保留现有一致性测试，并在修改后重新执行全量测试与各平台构建。

首次结果包：`/tmp/naiveflow-20261112/Tests.xcresult`；日志：`/tmp/naiveflow-20261112/tests.log`；摘要：`/tmp/naiveflow-20261112/test-summary.json`。参数化用例按执行实例统计时通过数量为 360，与测试定义口径不同。

#### 跳过与未执行的环境验收

`ConfigurationConnectivityTests` 的 7 项测试由 `TestEnvironment.isConfigured` 控制，本次未提供 `NAIVEFLOW_TEST_PROXY_URL`，因此跳过，不计作通过：

- `http11PlaintextRoundTrips`
- `http11OverTLSRoundTrips`
- `http2RoundTrips`
- `http11PlaintextLargePayloadIsByteExact`
- `http2LargePayloadIsByteExact`
- `http3RoundTrips`
- `http3LargePayloadIsByteExact`

执行这些用例还需可达的受控代理和符合测试约定的 HTTP/HTTPS 回显服务；目标可通过 `NAIVEFLOW_TEST_TARGET_HOST`、`NAIVEFLOW_TEST_HTTP_PORT`、`NAIVEFLOW_TEST_HTTPS_PORT` 指定。不得把上述跳过当作协议连通性已通过。

macOS、tvOS、Widget 和 Network Extension 没有各自独立的已配置测试 action；本次对它们执行构建检查，应用测试在 iOS 模拟器运行，内核包测试在 macOS 运行。签名、provisioning profile、真机安装、VPN/防绕行、受控 DNS 抓包、网络切换和长期运行均未执行。

#### 构建警告

存在非阻塞源码警告：AnyTLS / Shadowsocks 的 `CC_MD5` 弃用、LAN 地址处理的 `String(cString:)` 弃用、MITM 脚本 `JSValue?` 到 `Any` 的转换、未修改的局部变量、未使用的 `try?` 结果及多余 `try`。首次各平台日志按源文件位置去重均为 12 条；模拟器测试另有 `TunnelStartSequencerTests` 的 4 处多余 `try` 警告。本次没有改变协议算法或批量清理这些警告。

首次沙箱执行无法访问 CoreSimulator 服务和 Xcode 缓存；获准使用所需本机服务后已正常完成构建与测试执行，该环境问题与源码失败分别记录。原始日志、构建产物和 xcresult 位于 `/tmp/naiveflow-20261112`，属于临时文件，后续可能被系统清理。


### 2026-11-12 内存积压限制改动

- DNS：每缓存最多 64 个未完成解析任务、每任务最多 64 个等待者；刷新/切换上游取消旧任务且拒绝过时代次结果，但直到工作真正完成才释放额度。系统 DNS 默认实例共用 16 个执行额度，取消无限等待队列，过载立即失败。
- 发包：队列最多 2 MiB 且最多 1,024 个包，超额丢弃新包；单个已取出的写出批次仍在队列外，所以该限额不是整个发包路径的总内存上限。TCP 保留重传语义；UDP 不保证送达。
- MITM：已接入的正文缓冲、原生编辑估算工作区、脚本与其 HTTP 响应、HTTP/2 下行积压、拨号前缓冲和写队列共用 24 MiB 计账预算；额度不足时沿用透传/不改写、HTTP 请求失败、stream reset 或关闭连接的相应路径，并记录原因。
- 预算通过生命周期 reservation 释放，覆盖错误、对象销毁和异步发送批次；不把计账容量声称为实际进程物理内存上限。Geo、请求日志和既有 TCP/UDP 缓冲额度未调整。
- 新增 `MemoryAdmissionTests` 5 项，验证 DNS 超时与刷新不绕过上限、取消请求不启动工作、系统 DNS 满载立即拒绝、包队列字节/数量限制与复用、共享 reservation 争用与销毁释放。
- 初次编译发现新共享工具尚未纳入扩展 target，已补齐工程 membership；首轮全量测试随后通过。最终代码包含额外的 HTTP/2 pacing 和脚本响应生命周期计账，最终结果另记于下方。


最终验证（内存限制改动后）：

| 检查 | 结果 | 本机日志 / 结果包 |
| --- | --- | --- |
| iOS 主应用、Network Extension、Widget 无签名构建 | BUILD SUCCEEDED | `/tmp/naiveflow-20261112/memory-ios.log` |
| tvOS 主应用及扩展无签名构建 | BUILD SUCCEEDED | `/tmp/naiveflow-20261112/memory-tvos.log` |
| macOS 主应用及扩展依赖无签名构建 | BUILD SUCCEEDED | `/tmp/naiveflow-20261112/memory-macos.log` |
| iPhone 17 / iOS 27.2 全量测试 | TEST SUCCEEDED；362 项通过、0 失败、7 项跳过（共 369 项；参数化展开后 366 次通过） | `/tmp/naiveflow-20261112/MemoryTests-final.xcresult`；`memory-tests-final.log`；`memory-test-summary-final.json` |
| 工程格式与差异检查 | `plutil -lint`、`git diff --check` 通过 | — |

7 项跳过仍为缺少受控代理配置的 `ConfigurationConnectivityTests`，与本次新增测试无关。新增 5 项全部通过。尚未执行真机内存采样、压力流量、MITM 并发流量与吞吐基准；不能把这些静态预算换算成已实测节省的 MiB。


### 2026-11-12 移除 Anywhere 原生脚本兼容

- 删除脚本方言 `.native`、`process(ctx)` 编译/执行分支、原生 `NaiveFlow.*` 全局注入及其 codec/crypto/JWT/JSON/store/params/log/http API 实现；保留 Surge 与 Quantumult X 适配器使用的底层 HTTP、存储和字节转换工具。
- 配置校验不再要求声明 `process(context)`；有效的 Surge/QX 顶层脚本可通过语法校验，常见的原生入口/命名空间用法会给出明确的已移除错误。注释和字符串中的旧名称不作为可执行 API 判断。
- QX 的 `$task` / `$prefs` / `$notify` 用法进入 Quantumult X 分支；其余接受的脚本进入 Surge。尚未增加显式方言配置，不声称完整 Surge/QX 兼容。
- 外部脚本使用 `$done` 完成：同步调用首个结果生效，异步回调期间保留运行上下文，并沿用取消、超时和共享内存预算。通用 MITM、静态改写和原生 JSON/regex 正文规则保留。
- 原生脚本说明与示例从 MITM 文档移除。旧 Parameter 元数据仍可读取/导出，其 `NaiveFlow.params` 脚本 API 不再可用。
- 新增 `ForeignScriptValidationTests`，覆盖 Surge/QX 源码、5 种旧 ABI 写法拒绝、注释/字符串误判、stream=true 的预下载诊断和非法语法；更新原有成功脚本样例为 `$done` 形式。


最终验证（移除 Anywhere ABI 后）：iOS 主应用、扩展、Widget、tvOS、macOS 的无签名构建全部 BUILD SUCCEEDED；最终全量模拟器测试 TEST SUCCEEDED，**368 项通过、0 失败、7 项跳过，总计 375 项**，参数化展开后 **376 次通过**。新增验证全部通过。7 项跳过仍为未配置受控代理的连通性测试。

日志：`/tmp/naiveflow-20261112/foreign-ios.log`、`foreign-tvos.log`、`foreign-macos.log`、`foreign-scripts-final.log`；结果包：`/tmp/naiveflow-20261112/ForeignScripts-final.xcresult`；摘要：`/tmp/naiveflow-20261112/foreign-script-summary.json`。工程格式与 `git diff --check` 检查通过。真机 MITM、第三方实际脚本和异步 HTTP 兼容行为仍需单独验收，不能把本次源码/配置校验测试称为 Surge/QX 全量兼容验收。


### 2026-11-12 Surge 默认方言与显式 QX 选择

- `[Script]` 新增 `dialect=surge|quantumult-x`，省略时固定为 Surge；空值和未知值在预览/激活前报错。QX 脚本需显式选择，不再依赖源码中的 `$task` / `$prefs` / `$notify` 猜测。
- 方言进入 `MITMOperation.script`、Codable、文本编译、不可变运行版本与扩展编译后的脚本操作；导出 `[MITM Set]` 保留该字段。旧 JSON 无字段时默认 Surge；未知 JSON 值拒绝解码。`.amrs` operation 100 可追加 `surge` 或 `quantumult-x` 字段。
- MITM 二进制载荷升级为 v3，script 操作增加方言字节（0 Surge、1 Quantumult X），读取 v1/v2 时使用 Surge，未知方言字节拒绝。旧内核不应读取新载荷；应用与扩展需使用同次构建。
- 执行路径直接使用编译后的方言，移除每次请求时的源码类型猜测和重复语法检查；语法/旧 ABI 校验仍在发布与策略加载时进行。Surge/QX 继续共用 VM、路由/DNS、HTTP、存储和共享内存预算，不引入第二套网络实现。
- 新增 `ScriptDialectTests` 8 个测试定义，覆盖默认值、显式两种方言、4 组非法值、旧 JSON、导出回读、`.amrs` 导入、方言编辑触发 MITM 重载以及不可变版本保存读取。
- 首次新测试编译时使用了错误的导出器测试 API，已改用现有 `ConfigurationExporter.export`；随后一项版本保存测试因缺少必需偏好键而得到 `.invalidBundle`，已补齐测试数据。生产代码未因该测试数据问题放宽运行版本校验。


最终结果（显式方言改动后）：iOS（含 Network Extension / Widget）、tvOS、macOS 无签名构建全部 BUILD SUCCEEDED；全量模拟器测试 TEST SUCCEEDED，**376 项通过、0 失败、7 项跳过，共 383 项**；参数化展开后 **388 次通过**。新增 8 个测试定义全部通过。7 项跳过仍因未配置受控代理。

构建日志：`/tmp/naiveflow-20261112/dialect-ios.log`、`dialect-tvos.log`、`dialect-macos.log`；最终测试日志：`/tmp/naiveflow-20261112/script-dialects-verified.log`；结果包：`/tmp/naiveflow-20261112/ScriptDialects-verified.xcresult`；统计：`/tmp/naiveflow-20261112/script-dialect-summary.json`。`plutil -lint` 和 `git diff --check` 通过。尚未做真机脚本兼容矩阵或性能基准，不声明性能提升数值。


### 2026-11-13 队列优化与完整回归

起始提交：`8cbcf63`，工作区干净；环境为 Xcode 27.2（27B52）、iPhone 17 / iOS 27.2 模拟器。此次修改留在本地，未提交或推送。

#### 修改

- `AsyncInbox` 单条读取改用游标，消费后立即清空槽位以释放数据；累计消费至少 64 项且已消费部分不小于未消费部分时才移动剩余数组，避免每次出队都移动全部积压元素。容量判断、压缩回调阈值和唤醒条件均使用未读数量。
- 批量读取提取未读部分并重置游标；该路径需要线性转换可选槽位，未据单条读取基准推断批量读取也会加速。
- 首轮构建发现现有 `MITMScriptTransform.hasBufferedBodyRule` 调用了缺失的 `hasBodyJSONRule`；补齐 JSON 正文规则与 gate verdict 的匹配判断，恢复扩展编译。
- 测试编译发现 `ModuleScriptExecutionTests` 中一处 JavaScriptCore 键名未桥接到 `NSString`；补齐转换。
- 新增 `AsyncInboxTests` 8 项：积压顺序、容量复用、混合单条/批量读取、压缩阈值、可选 nil 元素、消费后引用释放、终止错误仅交付一次、取消后复用。全部通过。

#### 验证结果

| 检查 | 结果 | 本机日志 / 结果 |
| --- | --- | --- |
| iOS 模拟器全量测试，含应用、Network Extension、Widget 编译 | TEST SUCCEEDED；387 项通过、0 失败、8 项跳过，共 395 项 | `/tmp/NaiveFlow-verified.log`；`/tmp/NaiveFlow-verified.xcresult` |
| macOS 无签名构建，含扩展依赖 | BUILD SUCCEEDED | `/tmp/NaiveFlow-macos-build.log` |
| tvOS 无签名构建，含扩展 | BUILD SUCCEEDED | `/tmp/NaiveFlow-tvos-build.log` |
| IPv4 内核包测试 | 3 项通过，0 失败 | `/tmp/NaiveFlow-IP-tests.log` |
| 工程格式与差异 | `plutil -lint`、`git diff --check` 通过 | — |

全量数量按 xcresult summary 的测试定义口径；参数化展开后的执行实例为 397 次通过、8 次跳过。摘要：`/tmp/NaiveFlow-test-summary.json`。

8 项跳过为：7 项 `ConfigurationConnectivityTests` 缺少 `NAIVEFLOW_TEST_PROXY_URL`；1 项参数化的 BiliBili 实际脚本导入/执行测试缺少 `/private/tmp/BiliBili.ADBlock.sgmodule` 和 `.snippet` 测试素材。跳过项不作为通过。未执行真机签名、VPN 启停或真实代理流量验收。

复现（结果包路径须尚不存在）：

```sh
xcodebuild -project NaiveFlow.xcodeproj -scheme NaiveFlow -configuration Debug \
  -destination 'platform=iOS Simulator,id=DE25C87A-6656-4AEF-93E0-12FE8D85407F' \
  -derivedDataPath /tmp/NaiveFlow-validation \
  -resultBundlePath /tmp/NaiveFlow-verified.xcresult CODE_SIGNING_ALLOWED=NO test
swift test --package-path Packages/NaiveFlowIP --scratch-path /tmp/NaiveFlow-IP-validation
```

#### 单条读取微基准

分别将起始提交与修改后的 `AsyncInbox.swift` 和同一测试程序使用 `swiftc -O -parse-as-library` 编译，在 detached task 内预填充整数，调用 `finish()` 后逐项读取至结束，校验总和；只计读取耗时，每个深度取 7 次中位数。测试程序：`/tmp/NaiveFlowInboxBenchmark.swift`；原始样本：`/tmp/NaiveFlow-inbox-before-final.txt`、`/tmp/NaiveFlow-inbox-after-final.txt`。

| 积压项数 | 修改前中位数 | 修改后中位数 |
| --- | --- | --- |
| 256 | 0.214 ms | 0.093 ms |
| 4,096 | 3.337 ms | 1.563 ms |
| 20,000 | 105.581 ms | 6.861 ms |

这些是本机合成队列读取数据，尤其 20,000 项的修改前样本波动较大；不能换算为实际 VPN 吞吐、延迟或内存收益。日志和基准程序均位于临时目录，可能被系统清理。已有的源码弃用等非阻塞构建警告仍保留。


### 2026-11-13 DNS 缓存清理优化

- `DNSLookupCache` 记录最早到期时间的保守下界。在没有条目到期且容量未超限时，写入不再扫描缓存；触发清理时，一次遍历同时找到过期项和最早到期的可淘汰项，避免原先的多次遍历及过滤字典重建。
- 刷新、淘汰可能使记录的清理时间早于实际最早到期时间，最多触发一次额外扫描；不会延后清理。每次写入最多新增一条记录，所以超限时只需淘汰一项。满容量且持续插入新域名的路径仍为 O(n)，不声称所有写入都是 O(1)。
- TTL、零 TTL、最早到期优先淘汰、容量 1,024、现有过期结果回退、并发额度和代次失效策略保留；未引入新的失败退避或过期回退期限。
- 注入默认使用单调时钟的时间源，新增 `DNSLookupCacheTests` 12 项。覆盖到期边界、提前/延后刷新、清理与淘汰、零容量、失败回退、flush、上游切换、32 个请求合并，以及 ECH 使用的可选 nil 结果缓存。

#### 测试与构建

| 检查 | 最终结果 | 本机结果 / 日志 |
| --- | --- | --- |
| iPhone 17 / iOS 27.2 全量测试，含应用、扩展、Widget 编译 | TEST SUCCEEDED；399 项通过、0 失败、8 项跳过，共 407 项 | `/tmp/NaiveFlow-DNS-final.xcresult`；`/tmp/NaiveFlow-DNS-final.log` |
| macOS 无签名构建 | BUILD SUCCEEDED | `/tmp/NaiveFlow-DNS-macos.log` |
| tvOS 无签名构建 | BUILD SUCCEEDED | `/tmp/NaiveFlow-DNS-tvos.log` |
| 差异检查 | `git diff --check` 通过 | — |

数量采用 xcresult summary 测试定义口径，参数化展开后为 409 次通过、8 次跳过。摘要：`/tmp/NaiveFlow-DNS-final-summary.json`。8 项跳过与上一轮相同，仍缺少受控代理或外部脚本素材；未执行真机 VPN 与真实代理流量验收。

首轮回归时新增 DNS 测试中已编译的 11 项通过，但 `ProfileEditorModelTests.debouncedPreviewCoalescesRapidEdits` 在固定等待 400 ms 后仍未收到预览。将该测试改成每 10 ms 检查完成条件、最多等待 5 秒，保留原先对仅预览最终输入、持久化和编辑文本的断言；生产防抖实现未改。随后编译最后补入的 ECH 测试，重新运行全量回归，12 项 DNS 测试及防抖测试全部通过。首轮失败结果保留在 `/tmp/NaiveFlow-DNS-verified.xcresult`，摘要为 `/tmp/NaiveFlow-DNS-first-summary.json`。

全量复现沿用上一节命令，结果包改为尚不存在的 `/tmp/NaiveFlow-DNS-final.xcresult`。代码改动仍未提交或推送。

#### 缓存写入微基准

使用同一个独立程序分别编译起始提交与修改后的缓存源码（`swiftc -O -parse-as-library`）。预填充 256 或 1,024 个整数键，TTL 为 3,600 秒，再对已有键执行 5,000 次 `forceFresh` 查询；查询直接返回整数，不发起网络请求。每组 5 次取中位数，并校验查询结果和最终缓存条数。

| 条目数 | 修改前 | 修改后 |
| --- | --- | --- |
| 256 | 224.931 ms | 42.734 ms |
| 1,024 | 745.190 ms | 31.231 ms |

程序位于 `/tmp/NaiveFlowDNSBenchmark.swift`，最终样本为 `/tmp/NaiveFlow-dns-before-final.txt` 和 `/tmp/NaiveFlow-dns-after-final.txt`。独立程序使用 `systemUptime` 作为单调时钟及睡眠适配器；基准路径未设置等待超时，因此不执行睡眠适配器。结果只说明合成场景的缓存管理开销，受调度影响，不代表真实 DNS 延迟、VPN 吞吐或所有缓存写入场景的收益。临时目录中的日志和程序可能被系统清理。

# 第一步：工程基线检查

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


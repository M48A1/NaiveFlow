# 依赖说明：工程已只保留核心组件（无远程依赖）

检查日期 2026-11-04。结论：本工程现在只使用**仓库内内联的核心组件包**，没有任何需要联网拉取的
SwiftPM 依赖；上游的预设数据库包（`AnywhereRules` / 改名后的 `RuleProxyRules`）已从工程移除。
完整构建记录见根目录 `BASELINE_CHECK.md`。

## 1. 保留的依赖（全部为核心组件，本地包）

| 包 | 位置 | 作用 | 外部依赖 |
| --- | --- | --- | --- |
| RuleProxyIP | `Packages/RuleProxyIP` | IP 协议栈（原名 AnywhereIP） | 无 |
| RuleProxyQUIC | `Packages/RuleProxyQUIC` | QUIC 传输（原名 AnywhereQUIC） | 无 |
| BLAKE | `Packages/BLAKE` | 哈希实现 | 无 |
| YAML | `Packages/YAML` | YAML 解析 | 无 |

四个 manifest 都是 `swift-tools-version 6.4`、iOS 18 / macOS 15 / tvOS 18，内部没有声明任何远程依赖。
上游公开仓库 `NodePassProject/Anywhere` 的 `Packages/` 就是这四个目录，可确认核心组件已经完整内联，
不需要再从上游下载任何东西。

## 2. 已移除：`RuleProxyRules`（上游 `AnywhereRules`）预设库

移除原因：该包是**私有仓库**，只能提供路由预设数据库，不属于核心组件，也无法公开获取。

- `https://github.com/hiDandelion/AnywhereRules` → 404，`https://github.com/hiDandelion/RuleProxyRules` → 404，
  GitHub 仓库搜索 `AnywhereRules` 命中 0。
- 上游公开仓库 `NodePassProject/Anywhere` 自身也指向同一私有地址，公开 git 树中既没有该包源码，
  也没有任何 `Rules.db`（759 个文件中 0 个 `.db`），没有可替代的下载源。

工程侧改动：

1. `Shared/DataStore/RoutingRulesDatabase.swift`：删除 `import RuleProxyRules`，改为
   `resolveDatabaseURL()` 在 `Bundle.main` 里查找可选的 `Rules.db`（含 `Rules/` 子目录）。
   找不到时保留原有兜底：记录 `[Routing] Rules.db not found`，目录查询返回空数组/空字典。
   **路由内核、规则集编辑与连接流程不依赖该包**，只是“内置服务/国家预设”为空。
2. `RuleProxy.xcodeproj/project.pbxproj`：删除该包的 5 类对象及其全部引用
   （`XCRemoteSwiftPackageReference`、两个 `XCSwiftPackageProductDependency`、两个 `PBXBuildFile`、
   主应用与 TV target 的 `packageProductDependencies` 及 `Frameworks` 条目、`packageReferences` 条目）。
   `plutil -lint` 通过，全文已无 `CBFA0DE…` 相关对象。
3. `Package.resolved` 因不再有远程包而被 `xcodebuild` 删除。

如果要恢复预设列表：自备一个符合表结构的 `Rules.db`（表 `rules(type,value,source)`、
`metadata(key,value)`），加进主应用 target 的资源即可被自动加载，无需改代码。

## 3. 如需重新接回私有包（拿到访问权限后）

1. pbxproj 的 `packageReferences` 加回 `XCRemoteSwiftPackageReference`：
   `repositoryURL = "https://github.com/hiDandelion/RuleProxyRules.git"; requirement = { branch = main; kind = branch; }`，
   并在主应用与 TV target 的 `packageProductDependencies` / `Frameworks` 里加回同名产品。
2. 重建 `Package.resolved`：

```json
{
  "originHash" : "cf185425e5d03a6fc7a6db6830cb97ada9a3d876054d809039398c09051f6918",
  "pins" : [
    {
      "identity" : "ruleproxyrules",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/hiDandelion/RuleProxyRules.git",
      "state" : {
        "branch" : "main",
        "revision" : "1a7940ecdc003c81fb8b65036d39a42ec8be4a97"
      }
    }
  ],
  "version" : 3
}
```

3. `RoutingRulesDatabase.swift` 恢复 `import RuleProxyRules` 并把 `resolveDatabaseURL()` 换成
   `RuleProxyRules.databaseURL`。

原始文件备份（临时目录，重启后可能丢失，需要长期保留请另存）：
`/tmp/project.pbxproj.bak`（本次改动前的 pbxproj）、`/tmp/Package.resolved.bak`（原始 Pin）。

## 4. 资源目录（不属于 SwiftPM 依赖）

本仓库与上游公开仓库都没有任何 `.xcassets`，而源码使用 `Color.homeBackgroundStart`、
`Color.statCardBackground`、`UIColor(resource: .connectedBackgroundStart)` 等由资源目录生成的符号，
原始状态下主应用与 TV 均无法编译。已在 `Shared/Assets.xcassets` 补 9 个中性占位色板
（`homeBackgroundStart/End`、`statCardBackground`、`connectedBackgroundStart/End`、
`disconnectedBackgroundStart/End`、`AccentColor`、`WidgetBackground`）与空的 `AppIcon.appiconset`。
占位色值不是设计稿、`AppIcon` 无图片，发布前需替换为真实资源。

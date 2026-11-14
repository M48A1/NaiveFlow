# 客户端 Design System

实现配置：[`DesignSystem.swift`](../NaiveFlow/Views/Client/DesignSystem.swift)。iPhone、iPad、原生 macOS 与 tvOS 共用同一组语义样式；电视端使用适合远距离阅读的字号。仅使用浅色主题。

## 字体与层级

正文采用系统字体（SF 系列），配置正文和日志采用系统等宽字体。字号单位为 pt，表内为默认文字大小；`designText` 通过 `@ScaledMetric` 跟随系统文字大小。不要把正文样式用于页面标题，也不要把辅助说明加粗当作分区标题。

| 用途 | 角色 | iPhone / iPad / macOS | tvOS | 默认字重 |
| --- | --- | ---: | ---: | --- |
| 页面内一级标题 | `pageTitle` | 28 | 48 | Bold |
| 二级标题、内容分区名称 | `sectionTitle` | 22 | 36 | Semibold |
| 卡片标题，如 Outbound Mode / PROXY | `cardTitle` | 20 | 30 | Semibold |
| 条目标题，如节点名、设置项名称 | `contentTitle` | 17 | 26 | Semibold |
| 正文、输入框默认文字 | `body` | 16 | 24 | Regular |
| 次要描述、卡片摘要 | `secondary` | 14 | 22 | Regular |
| 时间、来源、说明 | `caption` | 12 | 20 | Regular |
| 短标签、协议标记 | `micro` | 10 | 16 | Regular |
| 配置源文本、日志 | `code` | 13 | 20 | Regular，等宽 |
| 操作按钮 | `button` | 16 | 22 | Medium |
| 突出的计数值 | `value` | 28 | 42 | Semibold |

`navigationTitle` 和原生 Form / List 的导航及分区标题保留系统布局，避免重做导航栏或损失辅助功能。自绘标题按上表选择角色。多行正文附加 3pt 行间距，其他文字 2pt；电视为 4pt。配置源编辑器的 UIKit / AppKit 实现也从此配置读取等宽字号。

```swift
Text("Outbound Mode").designText(.cardTitle)
Text(node.name).designText(.contentTitle)
Text(profile.sourceURL ?? "").designText(.caption)
Text(source).designText(.code)
```

## 颜色

- `Colors.background`：统一浅色页面背景。
- `Colors.card`：白色卡片基底。
- `Colors.text / secondaryText / tertiaryLabel`：主文字、辅助文字、弱化信息。
- `Colors.accent`：可交互项、选中态。
- `Colors.success / warning / error`：成功、警告和错误状态；同时使用文字或图标表达状态。
- `CardTheme.outbound / profiles / proxies / rules`：出站蓝、配置紫、节点橙、规则粉，首页与对应入口保持一致。
- `Colors.policyPalettes`：策略组自选渐变，顺序影响已保存的 palette 索引，不能任意重排。

公共视图通过 `ClientAppearance`、`ClientPalette` 使用的也是这份配置，不再另存一份颜色值。主题仅为浅色，不能在单个页面重新添加深色分支。

## 卡片和交互

- 普通卡片与首页卡片统一通过 `designCard` 绘制基底、渐变和边框。策略组与新增卡片在电视端也直接复用同一个组件。
- 卡片圆角：iPhone / iPad / macOS 为 24pt，tvOS 为 28pt。
- 策略组卡片圆角 22pt，普通端基准高度 146pt，电视端 220pt；文字大小变化时同步扩展。「新建策略组」卡片使用相同尺寸，固定在最后。
- 内容内边距：普通端 20pt，电视端 28pt。
- 渐变覆盖透明度统一为 0.12。
- 图标按钮点击区域至少 44pt；新增入口位于内容区，采用图标加文字。
- 菜单不显示下拉箭头。电视焦点使用 3pt 边框、1.025 倍缩放；减少动态效果开启时取消缩放动画。

## 主页面布局

Home / Groups / Settings 的共同边距通过 `clientMainContent` 应用，实际值来自 `DesignSystem.Layout`：

| 参数 | 数值 |
| --- | --- |
| 手机窄屏顶部留白 | 28pt |
| iPad / macOS 顶部留白 | 40pt |
| tvOS 顶部留白 | 56pt |
| 水平边距 | 手机 / iPad 20pt，macOS 32pt，tvOS 48pt |
| 阅读内容最大宽度 | 760pt |
| 策略组最大宽度 | 1000pt |
| 电视内容最大宽度 | 1700pt |
| 底部留白 | 40pt |

内容容器水平居中，卡片少时减少网格列数，避免空列把内容推向左边。长内容仍可正常滚动。

## 修改约定

新增页面优先使用 `designText`、`designCard`、`ClientForm`、`clientMainContent`。调整视觉规范先改配置，再检查普通端与电视端。不要在页面里另写一套 RGB、文字字号、卡片圆角或主页面边距。图标尺寸、原生控件适配及特殊内容布局可以有单独参数，但要从配置读取可共用的值。

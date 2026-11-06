# NaiveFlow 配置协调架构

配置格式属于 NaiveFlow，只借鉴分段、键值与规则列表形式，不承诺导入其他客户端配置。保留现有协议实现、路由内核、MITM 执行器和数据平面。

## 职责与入口

| 层 | 职责 | 现有实现的接入方式 |
| --- | --- | --- |
| RuleManager | 文档读取、草稿保存、结构解析、历史、快照及回滚 | 复用 ConfigurationActivation / SnapshotStore，编辑器通过 ConfigurationDocumentOperations 调用 |
| ConfigurationCoordinator | 编译、校验、模块归属、差异计划 | 调用 RuleManager.parse、Validator、Compiler；Installer 使用同一个模块计划 |
| RuntimeCoordinator | 生命周期状态、模块顺序、热更新计划、异步工作有效性 | State 由 TunnelStack actor 持有；现有内核作为执行适配器 |

文本处理路径：编辑器 → RuleManager → ConfigurationCoordinator → Compiler / Validator → Installer → 现有 Store / Exporter → 通知 → RuntimeCoordinator → TunnelStack 适配器。

TextConfigurationPipeline 是保留的调用门面，实际编译统一进入 ConfigurationCoordinator。解析错误与语义错误合并，任何错误都会阻止安装；草稿仍可保存。

## 下发与热更新

- 模块统一为 DNS、Rule、MITM、Outbound，主应用与扩展共享模块标识。
- General 与 Host 写入、安装记录保存之后，安装器才通知设置变化。只修改或删除 Host 也会通知。
- 路由和 MITM 继续由现有二进制导出器发布；节点继续由 TunnelController 发布。各自写完资源才发送对应通知，避免先通知后写文件。
- MITM 即使规则字节未变，也在导出之后通知，因为证书或信任设置可能已经变化。
- DNS 重载清除 Host、查询、代理解析和 ECH 缓存，上游通过现有动态 getter 获取。
- 重启和初次启动都按 DNS → MITM → Outbound → Rule 加载模块，然后启动数据平面。保留原有重启节流、睡眠时静默清理及停止时正常清理。
- 扩展先注册通知再做一次状态对齐，覆盖启动阶段错过通知的窗口。
- 异步路由编译带生命周期 epoch 和模块 revision。停止、重新启动或更新模块后，旧任务不能再安装结果。

节点比较包含完整 Outbound 值（认证、TLS、Reality、传输参数）和链式配置；编译生成的 UUID、时间戳和注释行号不构成语义变化。

## 运行状态与边界

新增 provider message `fetchRuntimeStatus`，返回阶段、epoch、已加载模块、待完成模块及加载失败。这里的“已加载”表示适配器读取了当前输入，并不保证网络连通，也不表示跨进程事务完成。

现有 Store 与二进制导出仍分别更新。失败恢复继续尝试重新安装前一个快照，不能保证跨 Store 原子回滚。需要重新连接的 Network Extension 偏好设置继续由宿主重连生效，编辑器保留重连提示。

原有路由确认会把最新 manifest 的快照 ID 当作运行版本，这不足以证明其他模块已经更新。现在路由就绪记录明确标为 `routing`，不会再被当作完整快照确认；完整版本确认需要以后增加带同一版本号的模块发布与回执协议。

未实现的配置字段、脚本、重写、FINAL 和不支持的分组类型不能靠兼容降级生效。导出只包含可应用的内容，MITM Host 策略继续由已有规则集页面管理，导出时给出说明。原有分层路由语义保持不变，未在本次接入顺序匹配器。

## 验证

`CoordinationRegressionTests` 覆盖解析错误传递、无效草稿保存与激活拒绝、历史回滚、Host 单独修改/删除、实际 Host 表差异、认证参数变化、稳定语义比较、空配置、过期异步任务和生命周期顺序。

本次编辑环境没有 Swift / Xcode，已执行 Swift 语法树检查、Xcode 工程格式与引用检查及 `git diff --check`；这些不能替代类型检查、构建或真机测试。

在符合本项目 Swift tools 版本要求的 Mac 上运行（模拟器名称按本机替换）：

```sh
xcodebuild build -project RuleProxy.xcodeproj -scheme RuleProxy -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project RuleProxy.xcodeproj -scheme RuleProxy -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:'RuleProxy Tests' CODE_SIGNING_ALLOWED=NO
```

真机重点验证：修改/删除 Host 后解析更新；仅改节点密码后重新拨号；连续切换配置并启停 VPN；MITM 设置刷新；Wi-Fi/蜂窝切换；检查 `fetchRuntimeStatus` 与实际流量结果。连通性用例需要测试节点，跳过不算通过。

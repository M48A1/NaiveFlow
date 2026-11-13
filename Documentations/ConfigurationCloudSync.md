# 使用 iCloud Drive 共享配置

iPhone、iPad 和 macOS 的配置页都提供 **iCloud Drive**。首次用 **Save as New Configuration** 给当前草稿命名。保存后的 `.conf` 位于 iCloud Drive 的 **NaiveFlow** 文件夹。其他设备用同一个 Apple 账户，在配置页选 **Open iCloud Configuration**，打开同名文件。系统负责设备间的文件同步。

用 **Save to iCloud Drive** 更新当前关联的文件。关联会在重新打开配置页后保留。打开配置页或回到前台时检查云端文件，也可以点 **Refresh iCloud Drive**。云端版本变化时，编辑器保留本机草稿，需确认载入。保存前会在协调写入中再次比较内容和检查文件版本冲突。检测到变化时，可先载入最新版本，或用新名称保存当前草稿。

载入前会在本机备份当前草稿，可用 **Restore Draft Before iCloud Load** 恢复。载入后按 **Apply Configuration** 才会应用到本机 VPN。保存只写入配置文本，云盘同步进度由系统负责。配置使用 UTF-8，单文件上限 16 MiB。

构建 iOS 和 macOS 时，签名描述文件需要允许 `iCloud.com.argsment.NaiveFlow` 的 iCloud Documents 服务。首次保存文档后，系统会显示 NaiveFlow 的 iCloud Drive 文件夹。

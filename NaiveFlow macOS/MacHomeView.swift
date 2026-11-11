import SwiftUI
import AppKit
import Charts
import NetworkExtension

private enum MacPage: String, CaseIterable, Identifiable {
    case overview = "概览", policies = "策略", requests = "请求", logs = "日志"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .policies: "arrow.triangle.branch"
        case .requests: "list.bullet.rectangle"
        case .logs: "text.alignleft"
        }
    }
}

struct MacHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(TunnelController.self) private var tunnel
    @Environment(ConfigurationStore.self) private var configurationStore
    @Environment(ProxySelection.self) private var selection
    @Environment(ConnectionStats.self) private var stats
    @Environment(ChainStore.self) private var chains
    @Environment(GroupStore.self) private var groupStore

    @State private var page: MacPage? = .overview
    @State private var query = ""
    @State private var showingImport = false
    private var runtimeGroups: [RuntimeGroupDisplay] { selection.runtimeGroups }
    @State private var editingGroup: ProxyGroup?
    @State private var sharingNode: ProxyConfiguration?
    @State private var copiedLink = false
    @State private var importURL = ""
    @State private var importError: String?
    @State private var requests = RequestsModel()
    @State private var logs = LogsModel()
    @State private var paused = false
    @State private var samples: [TrafficSample] = []

    private struct TrafficSample: Identifiable {
        let id = UUID()
        let date: Date
        let download: Int64
        let upload: Int64
    }

    private var connected: Bool { tunnel.rawStatus == .connected }
    private var currentPage: MacPage { page ?? .overview }
    private var monitoring: MacPage? {
        guard scenePhase == .active, connected else { return nil }
        if currentPage == .overview || currentPage == .requests { return currentPage }
        return currentPage == .logs && !paused ? .logs : nil
    }
    private var sortedRoutes: [RouteTrafficEntry] { stats.routes.sorted { $0.totalBytes > $1.totalBytes } }


    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("工作区") {
                    ForEach(MacPage.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .navigationTitle("NaiveFlow")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    statusLabel
                    Text(selection.effectiveConfiguration?.name ?? "尚未选择节点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } detail: {
            VStack(spacing: 0) {
                if let error = tunnel.startError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        Spacer()
                        Button("关闭") { tunnel.startError = nil }
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.07))
                }
                switch currentPage {
                case .overview: overview
                case .policies: policies
                case .requests: requestList
                case .logs: logList
                }
            }
            .navigationTitle(currentPage.rawValue)
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 16) {
                        statusLabel
                        Button(action: toggleConnection) {
                            Label(tunnel.hasRunningTunnel ? "停止" : "启动",
                                  systemImage: tunnel.hasRunningTunnel ? "stop.fill" : "power")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!tunnel.hasRunningTunnel && (!tunnel.isManagerReady || selection.effectiveConfiguration == nil))
                    }
                }
            }
        }
        .frame(minWidth: 850, minHeight: 580)
        .sheet(isPresented: $showingImport) { importSheet }
        .sheet(item: $sharingNode, onDismiss: { copiedLink = false }) { node in
            nodeShareSheet(node)
        }
        .sheet(item: $editingGroup) { group in
            MacGroupIconEditor(group: group) { groupStore.update($0) }
        }
        .task(id: monitoring) {
            guard let monitoring else { return }
            while !Task.isCancelled {
                switch monitoring {
                case .overview:
                    if let download = stats.downloadBytesPerSecond, let upload = stats.uploadBytesPerSecond {
                        if samples.count == 60 { samples.removeFirst() }
                        samples.append(TrafficSample(date: .now, download: download, upload: upload))
                    }
                case .requests:
                    if paused { requests.pruneExpired() }
                    else { await requests.poll(using: tunnel) }
                case .logs: await logs.poll(using: tunnel)
                case .policies: break
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { break }
            }
        }
        .onChange(of: connected) { _, connected in
            samples = []
            if !connected { requests.releaseSnapshot(); logs.clear() }
        }
        .onChange(of: page) { _, _ in
            query = ""; paused = false
            if currentPage != .requests { requests.releaseSnapshot() }
            if currentPage != .logs { logs.clear() }
            if currentPage != .overview { samples = [] }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { requests.releaseSnapshot(); logs.clear(); samples = [] }
        }

    }

    private var overview: some View {
        let routes = sortedRoutes
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("网络概览").font(.title2.bold())
                        Text(connected ? "隧道正在运行，流量统计实时更新。" : "启动隧道后，在这里查看网络活动。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selection.effectiveConfiguration == nil {
                        Button("导入节点", systemImage: "plus") { showingImport = true }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("管理策略", systemImage: "arrow.triangle.branch") { page = .policies }
                    }
                }
                HStack(spacing: 12) {
                    metric("下载速度", value: rate(stats.downloadBytesPerSecond), symbol: "arrow.down", color: .blue)
                    metric("上传速度", value: rate(stats.uploadBytesPerSecond), symbol: "arrow.up", color: .orange)
                    metric("活跃连接", value: connected ? "\(stats.tcpConnectionCount + stats.udpConnectionCount)" : "—", symbol: "waveform.path", color: .green)
                }
                card("实时流量") {
                    if samples.isEmpty {
                        ContentUnavailableView(connected ? "正在采集流量" : "尚未连接", systemImage: "chart.xyaxis.line",
                                               description: Text("连接后显示最近 60 秒的上传与下载速率。"))
                            .frame(height: 190)
                    } else {
                        Chart(samples) { sample in
                            LineMark(x: .value("时间", sample.date), y: .value("字节/秒", sample.download))
                                .foregroundStyle(by: .value("方向", "下载"))
                            LineMark(x: .value("时间", sample.date), y: .value("字节/秒", sample.upload))
                                .foregroundStyle(by: .value("方向", "上传"))
                        }
                        .chartForegroundStyleScale(["下载": Color.blue, "上传": Color.orange])
                        .chartYScale(domain: .automatic(includesZero: true))
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let bytes = value.as(Int64.self) { Text("\(formatBytes(bytes))/s") }
                                }
                            }
                        }
                        .frame(height: 190)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    card("当前会话") {
                        info("下载总量", formatBytes(stats.bytesIn))
                        Divider()
                        info("上传总量", formatBytes(stats.bytesOut))
                        Divider()
                        info("TCP / UDP", connected ? "\(stats.tcpConnectionCount) / \(stats.udpConnectionCount)" : "—")
                    }
                    card("当前策略") {
                        info("节点", selection.effectiveConfiguration?.name ?? "未选择")
                        Divider()
                        info("配置来源", selection.usesRuntimeVersion ? "文本配置" : "手动节点库")
                        Divider()
                        info("节点数量", "\(configurationStore.configurations.count)")
                    }
                }
                card("策略流量") {
                    if stats.routes.isEmpty {
                        Text("暂无流量记录").foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        ForEach(routes) { entry in
                            HStack {
                                Text(routeName(entry.target))
                                Spacer()
                                Text("↓ \(formatBytes(entry.bytesIn))   ↑ \(formatBytes(entry.bytesOut))")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            if entry.id != routes.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    private var policies: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("代理节点").font(.title2.bold())
                    Text(selection.usesRuntimeVersion ? "当前路由由文本配置控制，节点库仅供查看。" : "选择默认代理节点。运行中的连接沿用原有策略。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("导入节点", systemImage: "plus") { showingImport = true }
                    .disabled(selection.usesRuntimeVersion)
            }
            policyGroupIcons
            TextField("搜索名称、服务器或协议", text: $query)
                .textFieldStyle(.roundedBorder)
            Table(filteredConfigurations) {
                TableColumn("节点") { node in
                    HStack {
                        Image(systemName: node.id == selection.effectiveConfiguration?.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(node.id == selection.effectiveConfiguration?.id ? Color.accentColor : Color.secondary)
                        Button(node.name) { sharingNode = node }
                            .buttonStyle(.link)
                    }
                }
                TableColumn("协议") { Text($0.outboundProtocol.name) }.width(100)
                TableColumn("服务器") { Text($0.serverAddress).foregroundStyle(.secondary) }
                TableColumn("端口") { Text(String($0.serverPort)).monospacedDigit() }.width(60)
                TableColumn("操作") { node in
                    HStack {
                        Button(node.id == selection.effectiveConfiguration?.id ? "已选择" : "选择") { selection.select(node) }
                            .disabled(selection.usesRuntimeVersion || node.id == selection.effectiveConfiguration?.id)
                        Button("分享链接", systemImage: "square.and.arrow.up") { sharingNode = node }
                            .labelStyle(.iconOnly)
                            .help("分享节点链接")
                    }
                }.width(110)
            }
            .overlay {
                if filteredConfigurations.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "暂无节点" : "没有匹配的节点", systemImage: "network",
                                           description: Text(query.isEmpty ? "使用右上角的导入按钮添加节点链接。" : "尝试其他名称或服务器地址。"))
                }
            }
        }.padding(24)
    }

    @ViewBuilder
    private var policyGroupIcons: some View {
        if selection.usesRuntimeVersion ? !runtimeGroups.isEmpty : !groupStore.groups.isEmpty {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 10) {
                    if selection.usesRuntimeVersion {
                        ForEach(runtimeGroups, id: \.id) { group in
                            groupIconLabel(group.name, iconURL: group.iconURL, subtitle: "\(group.memberCount) 个成员")
                        }
                    } else {
                        ForEach(groupStore.groups) { group in
                            Button { editingGroup = group } label: {
                                groupIconLabel(group.name, iconURL: group.iconURL, subtitle: "\(group.memberIds.count) 个成员 · 点击修改图标")
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.frame(maxHeight: 150)
        }
    }

    private func groupIconLabel(_ name: String, iconURL: String?, subtitle: String) -> some View {
        HStack(spacing: 10) {
            ProxyGroupIconView(iconURL: iconURL, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private var requestList: some View {
        let entries = requests.visibleRequests(query: query)
        return VStack(spacing: 12) {
            recordControls
            Table(entries) {
                TableColumn("时间") { Text($0.timestamp, style: .time).monospacedDigit() }.width(85)
                TableColumn("主机") { Text($0.host).textSelection(.enabled) }
                TableColumn("协议") { Text($0.protocol.rawValue.uppercased()) }.width(55)
                TableColumn("端口") { Text(String($0.port)) }.width(50)
                TableColumn("规则") { Text($0.ruleSetName ?? "—") }
                TableColumn("策略") { Text(routeName($0.displayRouteTarget)) }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(connected ? "暂无匹配请求" : "尚未连接", systemImage: "list.bullet.rectangle",
                                           description: Text(connected ? "新请求会自动显示，可按主机、规则或出站搜索。" : "启动隧道后查看请求记录。"))
                }
            }
            if connected && requests.refreshState == .unavailable {
                Text("暂时无法读取隧道请求，正在等待下一次更新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24)
    }

    private var logList: some View {
        let entries = filteredLogs
        return VStack(spacing: 12) {
            recordControls
            Table(entries) {
                TableColumn("时间") { Text($0.timestamp, style: .time).monospacedDigit() }.width(85)
                TableColumn("级别") { entry in
                    Text(entry.level.rawValue.uppercased())
                        .foregroundStyle(entry.level == .error ? Color.red : entry.level == .warning ? Color.orange : Color.secondary)
                }.width(75)
                TableColumn("消息") { Text($0.message).textSelection(.enabled) }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "暂无日志" : "没有匹配的日志", systemImage: "text.alignleft",
                                           description: Text(query.isEmpty ? "连接后自动读取隧道日志。" : "尝试其他关键词。"))
                }
            }
        }.padding(24)
    }

    private var recordControls: some View {
        HStack {
            TextField("搜索记录", text: $query).textFieldStyle(.roundedBorder)
            Button(paused ? "继续更新" : "暂停更新", systemImage: paused ? "play" : "pause") { paused.toggle() }
                .disabled(!connected)
        }
    }

    private func nodeShareSheet(_ node: ProxyConfiguration) -> some View {
        let link = node.toURLString()
        return VStack(alignment: .leading, spacing: 16) {
            Text(node.name).font(.title2.bold()).textSelection(.enabled)
            Text("\(node.outboundProtocol.name) · \(node.serverAddress):\(node.serverPort)")
                .foregroundStyle(.secondary).textSelection(.enabled)
            if link.isEmpty || node.chain?.isEmpty == false {
                Text("此节点暂不支持导出为单个分享链接。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(link)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 140)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button(copiedLink ? "已复制" : "复制链接", systemImage: copiedLink ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        copiedLink = NSPasteboard.general.setString(link, forType: .string)
                    }
                    ShareLink(item: link, preview: SharePreview(node.name)) {
                        Label("分享链接", systemImage: "square.and.arrow.up")
                    }
                }
            }
            HStack {
                Spacer()
                Button("完成") { sharingNode = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入代理节点").font(.title2.bold())
            Text("粘贴 SOCKS5、Shadowsocks、VLESS、Trojan 等节点分享链接。")
                .foregroundStyle(.secondary)
            TextField("节点链接", text: $importURL).textFieldStyle(.roundedBorder)
                .onSubmit(importNode)
            if let importError { Text(importError).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { showingImport = false; importError = nil }
                    .keyboardShortcut(.cancelAction)
                Button("导入", action: importNode)
                    .buttonStyle(.borderedProminent)
                    .disabled(importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
    }

    private var filteredLogs: [LogsModel.LogEntry] {
        logs.logs.filter { query.isEmpty || $0.message.localizedCaseInsensitiveContains(query) }
    }

    private var filteredConfigurations: [ProxyConfiguration] {
        configurationStore.configurations.filter {
            query.isEmpty || "\($0.name) \($0.serverAddress) \($0.outboundProtocol.name)".localizedCaseInsensitiveContains(query)
        }
    }

    private var statusLabel: some View {
        Label(tunnel.status.localizedText, systemImage: "circle.fill")
            .font(.callout)
            .foregroundStyle(connected ? Color.green : tunnel.hasRunningTunnel ? Color.orange : Color.secondary)
    }

    private func toggleConnection() {
        if tunnel.hasRunningTunnel { tunnel.disconnect() }
        else if let node = selection.effectiveConfiguration { tunnel.connect(using: node) }
    }

    private func importNode() {
        guard !selection.usesRuntimeVersion else { return }
        do {
            let node = try ProxyConfiguration.parse(url: importURL.trimmingCharacters(in: .whitespacesAndNewlines))
            configurationStore.add(node)
            selection.selectIfNone(node)
            importURL = ""; importError = nil; showingImport = false
        } catch { importError = error.localizedDescription }
    }

    private func routeName(_ target: RouteTarget) -> String {
        target.displayName(configStore: configurationStore, chainStore: chains, selection: selection)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    private func rate(_ bytes: Int64?) -> String {
        guard connected, let bytes else { return "—" }
        return "\(formatBytes(bytes))/s"
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).lineLimit(1).textSelection(.enabled)
        }.font(.callout).padding(.vertical, 3)
    }

    private func metric(_ title: String, value: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).foregroundStyle(color)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

private struct MacGroupIconEditor: View {
    @Environment(\.dismiss) private var dismiss
    let group: ProxyGroup
    let onSave: (ProxyGroup) -> Void
    @State private var iconURL = ""

    private var trimmedURL: String { iconURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { trimmedURL.isEmpty || ProxyGroupIconURL.parse(trimmedURL) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(group.name).font(.title2.bold())
            HStack(spacing: 12) {
                ProxyGroupIconView(iconURL: trimmedURL, size: 40)
                TextField("https://example.com/icon.png", text: $iconURL).textFieldStyle(.roundedBorder)
            }
            Text(valid ? "填写 HTTPS 图片直链，留空使用默认图标。支持 PNG、JPEG 等系统可读取的图片格式。" : "请输入有效的 HTTPS 图片地址。")
                .foregroundStyle(valid ? Color.secondary : Color.red)
                .font(.callout)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    var updated = group
                    updated.iconURL = trimmedURL.isEmpty ? nil : trimmedURL
                    onSave(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!valid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 490)
        .onAppear { iconURL = group.iconURL ?? "" }
    }
}

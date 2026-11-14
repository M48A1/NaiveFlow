import SwiftUI
import AppKit
import Charts
import NetworkExtension

private enum MacPage: String, CaseIterable, Identifiable {
    case overview = "Overview", policies = "Policy", profile = "Profile", requests = "Requests", logs = "Logs"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .policies: "arrow.triangle.branch"
        case .profile: "doc.text"
        case .requests: "list.bullet.rectangle"
        case .logs: "text.alignleft"
        }
    }
}

struct MacHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Operations.self) private var operations
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
                Section("Workspace") {
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
                    Text(selection.effectiveConfiguration?.name ?? "No Node Selected")
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
                        Button("Close") { tunnel.startError = nil }
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.07))
                }
                switch currentPage {
                case .overview: overview
                case .policies: policies
                case .profile: MacConfigurationEditor(operations: operations)
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
                            Label(tunnel.hasRunningTunnel ? "Stop" : "Connect",
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
                case .policies, .profile: break
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
                        Text("Network Overview").font(.title2.bold())
                        Text(connected ? "The tunnel is running. Traffic statistics update in real time." : "Connect to view network activity here.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selection.effectiveConfiguration == nil {
                        Button("Import Nodes", systemImage: "plus") { showingImport = true }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Manage Policies", systemImage: "arrow.triangle.branch") { page = .policies }
                    }
                }
                HStack(spacing: 12) {
                    metric("Download Speed", value: rate(stats.downloadBytesPerSecond), symbol: "arrow.down", color: .blue)
                    metric("Upload Speed", value: rate(stats.uploadBytesPerSecond), symbol: "arrow.up", color: .orange)
                    metric("Active Connections", value: connected ? "\(stats.tcpConnectionCount + stats.udpConnectionCount)" : "—", symbol: "waveform.path", color: .green)
                }
                card("Live Traffic") {
                    if samples.isEmpty {
                        ContentUnavailableView(connected ? "Collecting Traffic" : "Not Connected", systemImage: "chart.xyaxis.line",
                                               description: Text("Upload and download rates for the last 60 seconds appear after connecting."))
                            .frame(height: 190)
                    } else {
                        Chart(samples) { sample in
                            LineMark(x: .value("Time", sample.date), y: .value("Bytes per Second", sample.download))
                                .foregroundStyle(by: .value("Direction", "Download"))
                            LineMark(x: .value("Time", sample.date), y: .value("Bytes per Second", sample.upload))
                                .foregroundStyle(by: .value("Direction", "Upload"))
                        }
                        .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.orange])
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
                    card("Current Session") {
                        info("Total Download", formatBytes(stats.bytesIn))
                        Divider()
                        info("Total Upload", formatBytes(stats.bytesOut))
                        Divider()
                        info("TCP / UDP", connected ? "\(stats.tcpConnectionCount) / \(stats.udpConnectionCount)" : "—")
                    }
                    card("Current Policy") {
                        info("Nodes", selection.effectiveConfiguration?.name ?? "Not Selected")
                        Divider()
                        info("Profile Source", selection.usesRuntimeVersion ? "Text Profile" : "Manual Node Library")
                        Divider()
                        info("Node Count", "\(configurationStore.configurations.count)")
                    }
                }
                card("Policy Traffic") {
                    if stats.routes.isEmpty {
                        Text("No Traffic Records").foregroundStyle(.secondary).padding(.vertical, 12)
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
                    Text("Proxy Nodes").font(.title2.bold())
                    Text(selection.usesRuntimeVersion ? "Routing is controlled by the active text profile. This node library is read-only." : "Choose the default proxy node. Existing connections keep their original policy.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import Nodes", systemImage: "plus") { showingImport = true }
                    .disabled(selection.usesRuntimeVersion)
            }
            policyGroupIcons
            TextField("Search Name, Server, or Protocol", text: $query)
                .textFieldStyle(.roundedBorder)
            Table(filteredConfigurations) {
                TableColumn("Nodes") { node in
                    HStack {
                        Image(systemName: node.id == selection.effectiveConfiguration?.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(node.id == selection.effectiveConfiguration?.id ? Color.accentColor : Color.secondary)
                        Button(node.name) { sharingNode = node }
                            .buttonStyle(.link)
                    }
                }
                TableColumn("Protocol") { Text($0.outboundProtocol.name) }.width(100)
                TableColumn("Server") { Text($0.serverAddress).foregroundStyle(.secondary) }
                TableColumn("Port") { Text(String($0.serverPort)).monospacedDigit() }.width(60)
                TableColumn("Actions") { node in
                    HStack {
                        Button(node.id == selection.effectiveConfiguration?.id ? "Selected" : "Select") { selection.select(node) }
                            .disabled(selection.usesRuntimeVersion || node.id == selection.effectiveConfiguration?.id)
                        Button("Share Link", systemImage: "square.and.arrow.up") { sharingNode = node }
                            .labelStyle(.iconOnly)
                            .help("Share Node Link")
                    }
                }.width(110)
            }
            .overlay {
                if filteredConfigurations.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No Nodes" : "No Matching Nodes", systemImage: "network",
                                           description: Text(query.isEmpty ? "Use Import in the top-right corner to add node links." : "Try another name or server address."))
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
                            groupIconLabel(group.name, iconURL: group.iconURL, subtitle: "\(group.memberCount) members")
                        }
                    } else {
                        ForEach(groupStore.groups) { group in
                            Button { editingGroup = group } label: {
                                groupIconLabel(group.name, iconURL: group.iconURL, subtitle: "\(group.memberIds.count) members · Tap to Change Icon")
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
                TableColumn("Time") { Text($0.timestamp, style: .time).monospacedDigit() }.width(85)
                TableColumn("Host") { Text($0.host).textSelection(.enabled) }
                TableColumn("Protocol") { Text($0.protocol.rawValue.uppercased()) }.width(55)
                TableColumn("Port") { Text(String($0.port)) }.width(50)
                TableColumn("Rules") { Text($0.ruleSetName ?? "—") }
                TableColumn("Policy") { Text(routeName($0.displayRouteTarget)) }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(connected ? "No Matching Requests" : "Not Connected", systemImage: "list.bullet.rectangle",
                                           description: Text(connected ? "New requests appear automatically. Search by host, rule, or outbound." : "Connect to view requests."))
                }
            }
            if connected && requests.refreshState == .unavailable {
                Text("Could not read tunnel requests. Waiting for the next update.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24)
    }

    private var logList: some View {
        let entries = filteredLogs
        return VStack(spacing: 12) {
            recordControls
            Table(entries) {
                TableColumn("Time") { Text($0.timestamp, style: .time).monospacedDigit() }.width(85)
                TableColumn("Level") { entry in
                    Text(entry.level.rawValue.uppercased())
                        .foregroundStyle(entry.level == .error ? Color.red : entry.level == .warning ? Color.orange : Color.secondary)
                }.width(75)
                TableColumn("Message") { Text($0.message).textSelection(.enabled) }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No Logs" : "No Matching Logs", systemImage: "text.alignleft",
                                           description: Text(query.isEmpty ? "Tunnel logs appear automatically after connecting." : "Try different keywords."))
                }
            }
        }.padding(24)
    }

    private var recordControls: some View {
        HStack {
            TextField("Search Records", text: $query).textFieldStyle(.roundedBorder)
            Button(paused ? "Resume Updates" : "Pause Updates", systemImage: paused ? "play" : "pause") { paused.toggle() }
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
                Text("This node cannot be exported as a single share link.")
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
                    Button(copiedLink ? "Copied" : "Copy Link", systemImage: copiedLink ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        copiedLink = NSPasteboard.general.setString(link, forType: .string)
                    }
                    ShareLink(item: link, preview: SharePreview(node.name)) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { sharingNode = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Proxy Nodes").font(.title2.bold())
            Text("Paste a SOCKS5, Shadowsocks, VLESS, Trojan, or other node share link.")
                .foregroundStyle(.secondary)
            TextField("Node Link", text: $importURL).textFieldStyle(.roundedBorder)
                .onSubmit(importNode)
            if let importError { Text(importError).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { showingImport = false; importError = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: importNode)
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
            Text(valid ? "Enter a direct HTTPS image URL, or leave blank for the default icon. Supports PNG, JPEG, and other system image formats." : "Enter a valid HTTPS image URL.")
                .foregroundStyle(valid ? Color.secondary : Color.red)
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
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

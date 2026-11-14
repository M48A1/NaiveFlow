import SwiftUI
import UserNotifications

struct ClientSettingsView: View {
    @Environment(ClientModel.self) private var model
    @Environment(MITMCertificateController.self) private var certificate
    @State private var showClearCache = false
    private var mitmEnabled: Bool { model.parsed.mitm.bool("enable") ?? model.parsed.general.bool("mitm") ?? false }

    var body: some View {
        List {
            Section("代理核心") {
                NavigationLink { ClientDNSView() } label: { row("DNS", symbol: "safari", detail: dnsSummary) }
                NavigationLink { ClientGeoSettingsView(site: false) } label: { row("GeoIP", symbol: "globe.europe.africa") }
                NavigationLink { ClientGeoSettingsView(site: true) } label: { row("GeoSite", symbol: "globe") }
                Toggle(isOn: Binding(get: { model.parsed.general.bool("always-on") ?? false }, set: { value in
                    Task { await model.setSetting("always-on", value: value ? "true" : "false") }
                })) { row("始终保持连接", symbol: "arrow.triangle.2.circlepath") }
                    .tint(.blue).disabled(model.isBusy)
                NavigationLink { LANProxySettingsView() } label: { row("局域网共享", symbol: "wifi") }
                NavigationLink { ClientLogsView() } label: { row("日志", symbol: "doc.text.fill") }
                NavigationLink { RequestsView() } label: { row("请求记录", symbol: "list.bullet.rectangle") }
            }
            Section("MITM 与模块") {
                Toggle(isOn: Binding(get: { mitmEnabled }, set: { value in Task { await model.setSetting("enable", value: value ? "true" : "false", section: .mitm) } })) {
                    HStack(spacing: 15) { ClientSectionIcon(symbol: "shield.lefthalf.filled"); Text("MITM") }
                }.tint(.blue).disabled(model.isBusy)
                NavigationLink { ClientModulesView() } label: { row("模块", symbol: "puzzlepiece.extension.fill", detail: model.modules.isEmpty ? nil : "\(model.modules.filter(\.enabled).count) 已启用") }
                NavigationLink { MITMCertificateView() } label: { row("证书管理", symbol: "lock.square.fill", detail: certificate.isTrusted ? "已信任" : certificate.hasCA ? "未信任" : "未生成") }
                NavigationLink { ClientHostnamesView() } label: { row("Hostname", symbol: "house.fill", detail: "\(model.parsed.mitm.list("hostname")?.count ?? 0) 个域名") }
            }
            Section("通用设置") {
                NavigationLink { ClientGeneralView() } label: { row("通用设置", symbol: "gearshape.fill") }
                NavigationLink { AboutView() } label: { row("关于", symbol: "info.circle") }
                Button(role: .destructive) { showClearCache = true } label: {
                    HStack(spacing: 15) { ClientSectionIcon(symbol: "trash", color: .red); Text("清除缓存") }
                }
            }
        }
        .listStyle(.insetGrouped).listRowSpacing(0)
        .navigationTitle("设置")
        .task { certificate.refresh() }
        .confirmationDialog("清除应用缓存？", isPresented: $showClearCache, titleVisibility: .visible) {
            Button("清除缓存", role: .destructive) { URLCache.shared.removeAllCachedResponses(); cacheMessage = true }
        } message: { Text("清除网络请求缓存，保留配置、节点和证书。") }
        .alert("缓存已清除", isPresented: $cacheMessage) { Button("好", role: .cancel) {} }
    }
    @State private var cacheMessage = false
    private var dnsSummary: String {
        switch model.parsed.general["dns-mode"] { case "plain": return "传统 DNS"; case "doh": return "DNS over HTTPS"; default: return "系统 DNS" }
    }
    private func row(_ title: String, symbol: String, detail: String? = nil) -> some View {
        HStack(spacing: 15) {
            ClientSectionIcon(symbol: symbol)
            Text(title)
            Spacer(minLength: 6)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
        }.padding(.vertical, 4)
    }
}

struct ClientDNSView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String:String] = [:]
    private let resolvers: [(String,String)] = [("", "本机解析"), ("proxy-", "代理解析"), ("subscription-", "订阅解析"), ("ech-", "ECH 解析")]

    var body: some View {
        Form {
            ForEach(resolvers, id: \.0) { prefix, title in
                Section(title) {
                    Picker("解析方式", selection: binding(prefix + "dns-mode", fallback: "default")) {
                        Text("系统默认").tag("default")
                        Text("传统 DNS").tag("plain")
                        Text("DNS over HTTPS").tag("doh")
                    }
                    if values[prefix + "dns-mode"] == "plain" {
                        TextField("IPv4 地址，如 1.1.1.1", text: binding(prefix + "dns-server", fallback: DNSUpstream.defaultPlainServer)).keyboardType(.URL)
                    } else if values[prefix + "dns-mode"] == "doh" {
                        TextField("https://…/dns-query", text: binding(prefix + "encrypted-dns-server", fallback: DNSUpstream.defaultDoHURL)).keyboardType(.URL)
                    }
                }
            }
            Section("Bootstrap DNS") {
                TextField("system 或 IPv4 服务器列表", text: binding("bootstrap-dns", fallback: "system")).keyboardType(.URL)
            }
            Section {
                Button("保存并应用") { Task {
                    var text = model.operatingText
                    for (key,value) in values {
                        text = ClientDocumentEditing.set(text, section: .dns, key: key, value: value.isEmpty ? nil : value)
                    }
                    if await model.commit(text) { dismiss() }
                } }.disabled(model.isBusy)
            } footer: { Text("修改将应用到当前配置，代理运行时会同步更新解析设置。") }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("DNS").navigationBarTitleDisplayMode(.inline)
        .task {
            for (prefix,_) in resolvers {
                for suffix in ["dns-mode", "dns-server", "encrypted-dns-server"] {
                    let key = prefix + suffix
                    if let value = model.parsed.general[key] { values[key] = value }
                }
                if values[prefix + "dns-mode"] == nil { values[prefix + "dns-mode"] = "default" }
            }
            values["bootstrap-dns"] = model.parsed.general["bootstrap-dns"] ?? "system"
        }
    }
    private func binding(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: { values[key] ?? fallback }, set: { values[key] = $0 })
    }
}

struct ClientActiveProfileEditor: View {
    @Environment(ClientModel.self) private var model
    var body: some View {
        if let profile = model.profile { ClientProfileEditorView(profile: profile) }
        else { ContentUnavailableView("暂无配置", systemImage: "doc") }
    }
}

struct ClientHostnamesView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var hostnames = ""
    var body: some View {
        Form {
            Section {
                TextEditor(text: $hostnames).font(.system(.body, design: .monospaced)).frame(minHeight: 240)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("MITM 域名，每行一个")
            } header: { Text("拦截域名") } footer: { Text("每行一个域名后缀，如 example.com。仅对配置中的域名启用 MITM，并且必须先安装和信任证书。") }
            Section { Button("保存并应用") { Task {
                let names = hostnames.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let source = model.operatingText
                let text = ClientDocumentEditing.set(source, section: .mitm, key: "hostname", value: names.isEmpty ? nil : names.map(ClientDocumentEditing.token).joined(separator: ", "))
                if await model.commit(text) { dismiss() }
            } }.disabled(model.isBusy) }
        }.clientKeyboardDone().navigationTitle("Hostname").navigationBarTitleDisplayMode(.inline)
        .task { hostnames = (model.parsed.mitm.list("hostname") ?? []).joined(separator: "\n") }
    }
}

struct ClientGeneralView: View {
    @Environment(AppSettings.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("配置") { NavigationLink("配置管理") { ClientProfilesView() } }
            Section("通知") { NavigationLink("通知设置") { ClientNotificationSettingsView() } }
            Section("订阅请求") { Toggle("Remnawave HWID", isOn: $settings.remnawaveHWIDEnabled) }
            Section("诊断") { NavigationLink("诊断工具") { DiagnosisView() } }
        }.navigationTitle("通用设置").navigationBarTitleDisplayMode(.inline)
    }
}

struct ClientLogsView: View {
    @Environment(TunnelController.self) private var tunnel
    @Environment(\.scenePhase) private var scenePhase
    @State private var logs = LogsModel()
    @State private var showClear = false
    @State private var clearedBefore = Date.distantPast
    private var visibleLogs: [LogsModel.LogEntry] { logs.logs.filter { $0.timestamp > clearedBefore } }
    var body: some View {
        List {
            ForEach(visibleLogs.reversed()) { entry in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(entry.level.rawValue.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(entry.level == .error ? Color.red : entry.level == .warning ? .orange : .blue)
                        Spacer(); Text(entry.timestamp, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(entry.message).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }.padding(.vertical, 5)
            }
        }
        .overlay { if visibleLogs.isEmpty { ContentUnavailableView("暂无日志", systemImage: "doc.text.magnifyingglass", description: Text(tunnel.hasRunningTunnel ? "等待新的运行日志" : "启动代理后显示运行日志")) } }
        .navigationTitle("日志").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: visibleLogs.map { "[\($0.timestamp.formatted())] [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")) { Image(systemName: "square.and.arrow.up") }.disabled(visibleLogs.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) { Button("清除", systemImage: "trash") { showClear = true }.disabled(visibleLogs.isEmpty) }
        }
        .confirmationDialog("清除当前显示的日志？", isPresented: $showClear, titleVisibility: .visible) { Button("清除", role: .destructive) { clearedBefore = .now; logs.clear(); Task { _ = await tunnel.send(.clearLogs) } } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if tunnel.hasRunningTunnel { await logs.poll(using: tunnel) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct ClientNotificationSettingsView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("notifyConnectionEvents") private var enabled = false
    @State private var allowed = false
    @State private var requesting = false
    var body: some View {
        Form {
            Section {
                Toggle("连接状态通知", isOn: Binding(get: { enabled && allowed }, set: { value in
                    if !value { enabled = false }
                    else { Task { await requestPermission() } }
                })).tint(.blue).disabled(requesting)
            } footer: { Text("应用在后台时，通知代理已连接、已停止或连接失败。") }
            Section {
                LabeledContent("系统通知权限", value: allowed ? "已允许" : "未允许")
                if !allowed {
                    Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
            }
        }
        .navigationTitle("通知").navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
    }
    private func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
    private func requestPermission() async {
        requesting = true; defer { requesting = false }
        do { enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); await refresh() }
        catch { model.report(error) }
    }
}

import SwiftUI
import UserNotifications

struct ClientSettingsView: View {
    @Environment(ClientModel.self) private var model
    @Environment(MITMCertificateController.self) private var certificate
    @State private var showClearCache = false
    private var mitmEnabled: Bool { model.parsed.mitm.bool("enable") ?? model.parsed.general.bool("mitm") ?? false }

    var body: some View {
        List {
            Section("Proxy Core") {
                NavigationLink { ClientDNSView() } label: { row("DNS", symbol: "safari", detail: dnsSummary) }
                NavigationLink { ClientGeoSettingsView(site: false) } label: { row("GeoIP", symbol: "globe.europe.africa") }
                NavigationLink { ClientGeoSettingsView(site: true) } label: { row("GeoSite", symbol: "globe") }
                Toggle(isOn: Binding(get: { model.parsed.general.bool("always-on") ?? false }, set: { value in
                    Task { await model.setSetting("always-on", value: value ? "true" : "false") }
                })) { row("Always Connected", symbol: "arrow.triangle.2.circlepath") }
                    .tint(.blue).disabled(model.isBusy)
                NavigationLink { LANProxySettingsView() } label: { row("LAN Sharing", symbol: "wifi") }
                NavigationLink { ClientLogsView() } label: { row("Logs", symbol: "doc.text.fill") }
                NavigationLink { RequestsView() } label: { row("Requests", symbol: "list.bullet.rectangle") }
            }
            Section("MITM and Modules") {
                Toggle(isOn: Binding(get: { mitmEnabled }, set: { value in Task { await model.setSetting("enable", value: value ? "true" : "false", section: .mitm) } })) {
                    HStack(spacing: 15) { ClientSectionIcon(symbol: "shield.lefthalf.filled"); Text("MITM") }
                }.tint(.blue).disabled(model.isBusy)
                NavigationLink { ClientModulesView() } label: { row("Modules", symbol: "puzzlepiece.extension.fill", detail: model.modules.isEmpty ? nil : "\(model.modules.filter(\.enabled).count) enabled") }
                NavigationLink { MITMCertificateView() } label: { row("Certificates", symbol: "lock.square.fill", detail: certificate.isTrusted ? "Trusted" : certificate.hasCA ? "Not Trusted" : "Not Created") }
                NavigationLink { ClientHostnamesView() } label: { row("Hostname", symbol: "house.fill", detail: "\(model.parsed.mitm.list("hostname")?.count ?? 0)") }
            }
            Section("General") {
                NavigationLink { ClientGeneralView() } label: { row("General", symbol: "gearshape.fill") }
                NavigationLink { AboutView() } label: { row("About", symbol: "info.circle") }
                Button(role: .destructive) { showClearCache = true } label: {
                    HStack(spacing: 15) { ClientSectionIcon(symbol: "trash", color: .red); Text("Clear Cache") }
                }
            }
        }
        .listStyle(.insetGrouped).listRowSpacing(0)
        .navigationTitle("Settings")
        .task { certificate.refresh() }
        .confirmationDialog("Clear App Cache?", isPresented: $showClearCache, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) { URLCache.shared.removeAllCachedResponses(); cacheMessage = true }
        } message: { Text("Clear network caches while keeping profiles, nodes, and certificates.") }
        .alert("Cache Cleared", isPresented: $cacheMessage) { Button("OK", role: .cancel) {} }
    }
    @State private var cacheMessage = false
    private var dnsSummary: String {
        switch model.parsed.general["dns-mode"] { case "plain": return "Plain DNS"; case "doh": return "DNS over HTTPS"; default: return "System DNS" }
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
    private let resolvers: [(String,String)] = [("", "Local DNS"), ("proxy-", "Proxy DNS"), ("subscription-", "Subscription DNS"), ("ech-", "ECH DNS")]

    var body: some View {
        Form {
            ForEach(resolvers, id: \.0) { prefix, title in
                Section(title) {
                    Picker("Resolver Type", selection: binding(prefix + "dns-mode", fallback: "default")) {
                        Text("System Default").tag("default")
                        Text("Plain DNS").tag("plain")
                        Text("DNS over HTTPS").tag("doh")
                    }
                    if values[prefix + "dns-mode"] == "plain" {
                        TextField("IPv4 Address, e.g. 1.1.1.1", text: binding(prefix + "dns-server", fallback: DNSUpstream.defaultPlainServer)).keyboardType(.URL)
                    } else if values[prefix + "dns-mode"] == "doh" {
                        TextField("https://…/dns-query", text: binding(prefix + "encrypted-dns-server", fallback: DNSUpstream.defaultDoHURL)).keyboardType(.URL)
                    }
                }
            }
            Section("Bootstrap DNS") {
                TextField("system or IPv4 DNS Servers", text: binding("bootstrap-dns", fallback: "system")).keyboardType(.URL)
            }
            Section {
                Button("Save and Apply") { Task {
                    var text = model.operatingText
                    for (key,value) in values {
                        text = ClientDocumentEditing.set(text, section: .dns, key: key, value: value.isEmpty ? nil : value)
                    }
                    if await model.commit(text) { dismiss() }
                } }.disabled(model.isBusy)
            } footer: { Text("Changes apply to the current profile and update DNS settings while connected.") }
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
        else { ContentUnavailableView("No Profile", systemImage: "doc") }
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
                    .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("MITM Hostnames, One per Line")
            } header: { Text("Intercepted Hostnames") } footer: { Text("Enter one domain suffix per line, e.g. example.com. MITM applies only to configured domains and requires an installed, trusted certificate.") }
            Section { Button("Save and Apply") { Task {
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
            Section("Notifications") { NavigationLink("Notification Settings") { ClientNotificationSettingsView() } }
            Section("Subscription Requests") { Toggle("Remnawave HWID", isOn: $settings.remnawaveHWIDEnabled) }
        }.navigationTitle("General").navigationBarTitleDisplayMode(.inline)
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
        .overlay { if visibleLogs.isEmpty { ContentUnavailableView("No Logs", systemImage: "doc.text.magnifyingglass", description: Text(tunnel.hasRunningTunnel ? "Waiting for new logs" : "Connect to view logs.")) } }
        .navigationTitle("Logs").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: visibleLogs.map { "[\($0.timestamp.formatted(.dateTime.locale(Locale(identifier: "en"))))] [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")) { Image(systemName: "square.and.arrow.up") }.disabled(visibleLogs.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) { Button("Clear", systemImage: "trash") { showClear = true }.disabled(visibleLogs.isEmpty) }
        }
        .confirmationDialog("Clear Visible Logs?", isPresented: $showClear, titleVisibility: .visible) { Button("Clear", role: .destructive) { clearedBefore = .now; logs.clear(); Task { _ = await tunnel.send(.clearLogs) } } }
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
                Toggle("Connection Status Notifications", isOn: Binding(get: { enabled && allowed }, set: { value in
                    if !value { enabled = false }
                    else { Task { await requestPermission() } }
                })).tint(.blue).disabled(requesting)
            } footer: { Text("Notify when the proxy connects, disconnects, or fails while the app is in the background.") }
            Section {
                LabeledContent("System Notification Permission", value: allowed ? "Allowed" : "Not Allowed")
                if !allowed {
                    Button("Open System Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
            }
        }
        .navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
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

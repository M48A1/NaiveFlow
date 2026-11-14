import SwiftUI
import UserNotifications

struct ClientSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                section("Connectivity") {
                    row("DNS", symbol: "safari", color: .blue) { ClientDNSView() }
                    separator
                    row("Latency Test", symbol: "bolt.horizontal.circle", color: .blue) { ClientLatencySettingsView() }
                    separator
                    row("GeoIP", symbol: "globe.europe.africa", color: .blue) { ClientGeoSettingsView(site: false) }
                    separator
                    row("GeoSite", symbol: "globe", color: .blue) { ClientGeoSettingsView(site: true) }
                    separator
                    row("Always Connected", symbol: "arrow.triangle.2.circlepath", color: .blue) { ClientAlwaysConnectedSettingsView() }
                    separator
                    row("LAN Sharing", symbol: "wifi", color: .blue) { LANProxySettingsView() }
                }
                section("Traffic Processing") {
                    row("MITM", symbol: "shield.lefthalf.filled", color: .purple) { MITMCertificateView() }
                    separator
                    row("Modules", symbol: "puzzlepiece.extension.fill", color: .purple) { ClientModulesView() }
                }
                section("Diagnostics") {
                    row("Connection Diagnostics", symbol: "stethoscope", color: .orange) { ClientDiagnosticsView() }
                    separator
                    row("Rule Test", symbol: "arrow.triangle.branch", color: .orange) { ClientRuleTestView() }
                    separator
                    row("Resource Updates", symbol: "arrow.clockwise", color: .orange) { ClientResourceCenterView() }
                    separator
                    row("Logs", symbol: "doc.text.fill", color: .orange) { ClientLogsView() }
                    separator
                    row("Requests", symbol: "list.bullet.rectangle", color: .orange) { RequestsView() }
                }
                section("Application") {
                    row("Notification Settings", symbol: "bell.fill", color: .teal) { ClientNotificationSettingsView() }
                    separator
                    row("Backup and Restore", symbol: "externaldrive", color: .teal) { ClientBackupView() }
                    separator
                    row("About", symbol: "info.circle", color: .teal) { AboutView() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            ClientCard(content: content)
        }
    }

    private var separator: some View {
        Divider().padding(.leading, 70).padding(.trailing, 20)
    }

    private func row<Destination: View>(_ title: String, symbol: String, color: Color,
        @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ClientAlwaysConnectedSettingsView: View {
    @Environment(ClientModel.self) private var model

    var body: some View {
        Form {
            Toggle("Always Connected", isOn: Binding(get: { model.parsed.general.bool("always-on") ?? false }, set: { value in
                Task { await model.setSetting("always-on", value: value ? "true" : "false") }
            })).tint(.blue).disabled(model.isBusy)
        }
        .navigationTitle("Always Connected").navigationBarTitleDisplayMode(.inline)
    }
}

struct ClientDNSView: View {
    private struct MappingDraft: Identifiable {
        let id = UUID()
        var host = ""
        var address = ""
    }
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String:String] = [:]
    @State private var mappings: [MappingDraft] = []
    @State private var useSystemBootstrap = true
    @State private var customBootstrap = "223.5.5.5"
    private let resolvers: [(String,String)] = [("", "Local DNS"), ("proxy-", "Proxy Server DNS"), ("subscription-", "Subscription DNS"), ("ech-", "ECH DNS")]

    var body: some View {
        Form {
            ForEach(resolvers, id: \.0) { prefix, title in
                Section {
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
                } header: { Text(title) } footer: {
                    if prefix == "proxy-" {
                        Text("Resolves proxy server domain names when connecting and testing latency.")
                    }
                }
            }
            Section {
                Picker("Resolver Type", selection: $useSystemBootstrap) {
                    Text("System Default").tag(true)
                    Text("Custom").tag(false)
                }
                if !useSystemBootstrap {
                    TextField("223.5.5.5", text: $customBootstrap)
                        .keyboardType(.numbersAndPunctuation).accessibilityLabel("Bootstrap DNS Servers")
                }
            } header: { Text("Bootstrap DNS") } footer: {
                Text("Resolves DNS over HTTPS server domain names. Use the system resolver or enter up to 8 IPv4 addresses separated by commas, e.g. 223.5.5.5, 1.1.1.1.")
            }
            Section {
                ForEach($mappings) { $mapping in
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Domain, e.g. example.com", text: $mapping.host)
                            .keyboardType(.URL).accessibilityLabel("Mapping Domain")
                        HStack {
                            TextField("IPv4 Address, e.g. 192.168.1.10", text: $mapping.address)
                                .keyboardType(.decimalPad).accessibilityLabel("Mapping IPv4 Address")
                            Button(role: .destructive) { mappings.removeAll { $0.id == mapping.id } } label: {
                                Image(systemName: "minus.circle.fill")
                            }.buttonStyle(.borderless).accessibilityLabel("Delete DNS Mapping")
                        }
                    }.padding(.vertical, 4)
                }
                Button("Add Mapping", systemImage: "plus") { mappings.append(MappingDraft()) }
            } header: { Text("Local DNS Mapping") } footer: {
                Text("Resolve domains to the specified IPv4 addresses before querying DNS. Supports *.example.com. Add multiple mappings for multiple addresses. Saved in the current profile.")
            }
            Section {
                Button("Save and Apply") { Task {
                    do {
                        guard let bootstrap = DNSBootstrapPolicy.parse(useSystemBootstrap ? "system" : customBootstrap) else {
                            throw ClientFailure("Enter 1 to 8 IPv4 addresses separated by commas, e.g. 223.5.5.5, 1.1.1.1.")
                        }
                        var text = try ClientDocumentEditing.setHostMappings(model.operatingText, mappings: mappings.map { HostMapping(host: $0.host, address: $0.address) })
                        text = ClientDocumentEditing.set(text, section: .dns, key: "bootstrap-dns", value: bootstrap.rendered)
                        for (key,value) in values {
                            text = ClientDocumentEditing.set(text, section: .dns, key: key, value: value.isEmpty ? nil : value)
                        }
                        if await model.commit(text) { dismiss() }
                    } catch {
                        model.report(error)
                    }
                } }.disabled(model.isBusy)
            } footer: { Text("Changes apply to the current profile and update DNS settings while connected.") }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled().clientKeyboardDone()
        .navigationTitle("DNS").navigationBarTitleDisplayMode(.inline)
        .task {
            mappings = model.parsed.hosts.map { MappingDraft(host: $0.host, address: $0.address) }
            for (prefix,_) in resolvers {
                for suffix in ["dns-mode", "dns-server", "encrypted-dns-server"] {
                    let key = prefix + suffix
                    if let value = model.parsed.general[key] { values[key] = value }
                }
                if values[prefix + "dns-mode"] == nil { values[prefix + "dns-mode"] = "default" }
            }
            let bootstrap = model.parsed.general["bootstrap-dns"] ?? "system"
            useSystemBootstrap = bootstrap.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system"
            customBootstrap = useSystemBootstrap ? "223.5.5.5" : bootstrap
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

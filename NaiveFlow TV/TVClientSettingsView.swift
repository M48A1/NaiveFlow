import SwiftUI
import UIKit

struct TVClientSettingsView: View {
    @Environment(ClientModel.self) private var model
    let container: AppContainer

    var body: some View {
        List {
            Section("Configuration") {
                NavigationLink("Profiles") { TVClientProfilesView() }
                NavigationLink("DNS") { TVClientDNSView() }
                NavigationLink("Rules") { TVClientRulesView() }
                NavigationLink("Modules") {
                    List(model.modules) { module in
                        Toggle(module.name, isOn: Binding(
                            get: { model.modules.first { $0.id == module.id }?.enabled ?? false },
                            set: { enabled in Task { await model.toggleModule(module, enabled: enabled) } }
                        ))
                        .disabled(model.isBusy)
                    }
                    .navigationTitle("Modules")
                }
            }
            Section("Resources") {
                NavigationLink("Subscriptions") { TVClientSubscriptionsView() }
                Button("Update Rule Sets") {
                    Task { _ = await model.manageResource(.update(.ruleSets(sources: nil))) }
                }
                .disabled(model.isBusy)
                Button("Update GeoIP") { Task { _ = await model.manageResource(.update(.geo(site: false))) } }
                    .disabled(model.isBusy)
                Button("Update GeoSite") { Task { _ = await model.manageResource(.update(.geo(site: true))) } }
                    .disabled(model.isBusy)
                Button("Update Modules") { Task { _ = await model.refreshAllModules() } }
                    .disabled(model.isBusy || model.modules.isEmpty)
            }
            Section("Diagnostics") {
                NavigationLink("Requests") { TVClientActivityView(tunnel: container.tunnel, showsLogs: false) }
                NavigationLink("Logs") { TVClientActivityView(tunnel: container.tunnel, showsLogs: true) }
            }
        }
        .navigationTitle("Settings")
    }
}

struct TVClientRulesView: View {
    @Environment(ClientModel.self) private var model

    var body: some View {
        List {
            ForEach(model.parsed.rules) { rule in
                Text(rule.raw).font(.system(.body, design: .monospaced))
            }
        }
        .navigationTitle("Rules")
    }
}

private struct TVClientDNSView: View {
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
                        TextField("IPv4 Address, e.g. 1.1.1.1", text: binding(prefix + "dns-server", fallback: DNSUpstream.defaultPlainServer))
                    } else if values[prefix + "dns-mode"] == "doh" {
                        TextField("https://…/dns-query", text: binding(prefix + "encrypted-dns-server", fallback: DNSUpstream.defaultDoHURL))
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
                        .accessibilityLabel("Bootstrap DNS Servers")
                }
            } header: { Text("Bootstrap DNS") } footer: {
                Text("Resolves DNS over HTTPS server domain names. Use the system resolver or enter up to 8 IPv4 addresses separated by commas, e.g. 223.5.5.5, 1.1.1.1.")
            }
            Section {
                ForEach($mappings) { $mapping in
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Domain, e.g. example.com", text: $mapping.host)
                            .accessibilityLabel("Mapping Domain")
                        HStack {
                            TextField("IPv4 Address, e.g. 192.168.1.10", text: $mapping.address)
                                .accessibilityLabel("Mapping IPv4 Address")
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
        .autocorrectionDisabled()
        .navigationTitle("DNS")
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

struct TVClientNodesView: View {
    @Environment(ClientModel.self) private var model
    let latency: LatencyCenter
    let tunnel: TunnelController
    @State private var source = ""
    @State private var nodeEditor: NodeEditor?
    @State private var pendingDelete: ProxyConfiguration?

    private struct NodeEditor: Identifiable {
        let id = UUID()
        var node: ProxyConfiguration?
    }

    var body: some View {
        List {
            Section("Proxies") {
                ForEach(model.nodes) { node in
                    Button {
                        Task { await model.selectNode(node.name) }
                    } label: {
                        HStack {
                            Label(node.name, systemImage: model.selectedNodeName == node.name ? "checkmark.circle.fill" : "circle")
                            Spacer()
                            if case .success(let milliseconds) = latency.latencyResults[node.id] {
                                Text("\(milliseconds) ms").monospacedDigit()
                            }
                        }
                    }
                    .disabled(model.isBusy)
                    .contextMenu {
                        Button("Edit") { nodeEditor = NodeEditor(node: node) }
                        Button("Test Latency") { latency.testLatency(for: node, transport: tunnel) }
                        Button("Delete", role: .destructive) { pendingDelete = node }
                    }
                }
                Button("Latency Test") { latency.testLatencies(for: model.nodes, transport: tunnel) }
                    .disabled(model.nodes.isEmpty)
            }
            Section("Import Nodes") {
                Button("Add Node") { nodeEditor = NodeEditor() }.disabled(model.isBusy)
                NavigationLink("Subscription Groups") { TVClientSubscriptionsView() }
                TextField("Node Link", text: $source).autocorrectionDisabled()
                Button("Import into Current Profile") {
                    Task {
                        do {
                            if try await model.importNodes(source) { source = "" }
                        } catch { model.report(error) }
                    }
                }
                .disabled(model.isBusy || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Proxies")
        .sheet(item: $nodeEditor) { editor in
            TVClientNodeEditorHost(node: editor.node) { node in
                Task { await model.saveNode(node, replacing: editor.node?.name) }
            }
        }
        .confirmationDialog("Delete Node?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { node in
            Button("Delete", role: .destructive) {
                Task { _ = await model.removeNodes([node.name]) }
            }
        } message: { node in
            Text(node.name)
        }
    }
}

private struct TVClientNodeEditorHost: UIViewControllerRepresentable {
    let node: ProxyConfiguration?
    let onSave: (ProxyConfiguration) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: TVProxyEditorViewController(configuration: node, onSave: onSave))
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

private struct TVClientSubscriptionsView: View {
    @Environment(ClientModel.self) private var model
    @State private var source = ""

    var body: some View {
        List {
            Section("Subscriptions") {
                ForEach(model.profile?.nodeSubscriptions ?? []) { subscription in
                    Button {
                        Task { _ = await model.manageResource(.update(.subscription(subscription))) }
                    } label: {
                        Label(subscription.name, systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                }
                Button("Update Subscriptions") { Task { _ = await model.refreshNodeSubscriptions() } }
                    .disabled(model.isBusy || model.profile?.nodeSubscriptions?.isEmpty != false)
            }
            Section("Import Subscription") {
                TextField("HTTPS Subscription URL", text: $source).autocorrectionDisabled()
                Button("Import into Current Profile") {
                    guard let url = subscriptionURL, let host = url.host else { return }
                    Task {
                        let subscription = model.profile?.nodeSubscriptions?.first { $0.url == url.absoluteString }
                            ?? ClientNodeSubscription(name: host, url: url.absoluteString)
                        if await model.manageResource(.update(.subscription(subscription))) { source = "" }
                    }
                }
                .disabled(model.isBusy || subscriptionURL == nil)
            }
        }
        .navigationTitle("Subscriptions")
    }

    private var subscriptionURL: URL? {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

private struct TVClientActivityView: View {
    @Environment(\.scenePhase) private var scenePhase
    let tunnel: TunnelController
    let showsLogs: Bool
    @State private var logs = LogsModel()
    @State private var requests = RequestsModel()

    var body: some View {
        List {
            if showsLogs {
                ForEach(logs.logs) { entry in Text(entry.message) }
            } else {
                ForEach(requests.requests) { entry in Text(entry.host) }
            }
        }
        .navigationTitle(showsLogs ? "Logs" : "Requests")
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if tunnel.isTunnelActive {
                    if showsLogs { await logs.poll(using: tunnel) }
                    else { await requests.poll(using: tunnel) }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { requests.releaseSnapshot() }
    }
}

import SwiftUI
import NetworkExtension

struct MainControlView: View {
    @Environment(Operations.self) private var operations
    @Environment(TunnelController.self) private var tunnel
    @Environment(ProxySelection.self) private var selection
    @Environment(ConfigurationStore.self) private var configurations
    @Environment(ConnectionStats.self) private var stats
    @Environment(AppSettings.self) private var settings

    @State private var showingProxies = false
    @State private var showingAdd = false
    @State private var showingManualAdd = false

    private var isConnected: Bool { tunnel.rawStatus == .connected }
    private var canToggle: Bool {
        tunnel.isManagerReady && !tunnel.rawStatus.isTransitioning
            && (isConnected || selection.effectiveConfiguration != nil)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { isConnected },
                        set: { _ in operations.tunnel.toggle() }
                    )) {
                        HStack(spacing: 12) {
                            Image(systemName: "power")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(isConnected ? Color.green : Color.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("NaiveFlow").font(.headline)
                                Text(tunnel.status.localizedText)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if tunnel.rawStatus.isTransitioning {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .tint(.green)
                    .disabled(!canToggle)

                    NavigationLink {
                        ProfileView()
                    } label: {
                        Label("Configuration", systemImage: "doc.text")
                    }
                } footer: {
                    if !configurations.isLoaded {
                        Text("Loading…")
                    } else if selection.effectiveConfiguration == nil {
                        Text("Add a Configuration")
                    }
                }

                Section {
                    Picker(selection: Binding(
                        get: { settings.proxyMode },
                        set: { settings.proxyMode = $0 }
                    )) {
                        Text("Rule").tag(ProxyMode.rule)
                        Text("Global").tag(ProxyMode.global)
                        Text("Direct").tag(ProxyMode.direct)
                    } label: {
                        Label("Outbound Mode", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(selection.usesRuntimeVersion)

                    Button {
                        if selection.effectiveConfiguration == nil {
                            showingAdd = true
                        } else {
                            showingProxies = true
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Label("Proxy", systemImage: "network")
                            Spacer(minLength: 8)
                            Text(selection.effectiveConfiguration?.name ?? String(localized: "Add a Configuration"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)

                    NavigationLink {
                        RoutingView()
                    } label: {
                        Label("Routing Rules", systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text("Routing")
                } footer: {
                    if selection.usesRuntimeVersion {
                        Text("The active configuration controls routing. Edit Configuration to change it; these lists remain your manual library.")
                    }
                }

                Section("Activity") {
                    HStack(spacing: 0) {
                        trafficMetric("Download", symbol: "arrow.down", rate: stats.downloadBytesPerSecond, total: stats.bytesIn, color: .blue)
                        Divider().padding(.horizontal, 16)
                        trafficMetric("Upload", symbol: "arrow.up", rate: stats.uploadBytesPerSecond, total: stats.bytesOut, color: .orange)
                    }
                    .padding(.vertical, 8)

                    NavigationLink {
                        ScrollView {
                            ConnectionStatsView()
                                .padding()
                        }
                        .navigationTitle("Dashboard")
                    } label: {
                        HStack {
                            Label("Active Connections", systemImage: "waveform.path")
                            Spacer()
                            Text(isConnected ? "\(stats.tcpConnectionCount + stats.udpConnectionCount)" : "—")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Tools") {
                    NavigationLink { RequestsView() } label: {
                        Label("Requests", systemImage: "list.bullet.rectangle.portrait")
                    }
                    NavigationLink { MITMView() } label: {
                        Label("MITM", systemImage: "lock.open")
                    }
                    NavigationLink { ModulesView() } label: {
                        Label("Modules", systemImage: "shippingbox")
                    }
                    NavigationLink { DiagnosisView() } label: {
                        Label("Diagnosis", systemImage: "stethoscope")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add a Configuration", systemImage: "plus") { showingAdd = true }
                }
            }
        }
        .sheet(isPresented: $showingProxies) { ProxiesView() }
        .sheet(isPresented: $showingAdd) {
            DynamicSheet(animation: .snappy(duration: 0.3, extraBounce: 0)) {
                AddProxyView(showingManualAddSheet: $showingManualAdd)
                    .environment(operations)
            }
        }
        .sheet(isPresented: $showingManualAdd) {
            ProxyEditorView { configuration in
                operations.configurations.add(configuration)
                operations.selection.selectIfNone(configuration)
            }
        }
    }

    private func trafficMetric(_ title: LocalizedStringKey, symbol: String, rate: Int64?, total: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(color)
            Text(isConnected ? rate.map { "\(bytes($0))/s" } ?? "—" : "—")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(bytes(total))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }
}

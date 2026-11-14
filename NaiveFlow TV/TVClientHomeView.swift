import SwiftUI
import NetworkExtension

struct TVClientHomeView: View {
    @Environment(ClientModel.self) private var model
    let tunnel: TunnelController
    let stats: ConnectionStats
    let latency: LatencyCenter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                HStack(spacing: 40) {
                    Button(tunnel.hasRunningTunnel ? "Disconnect" : "Connect",
                           systemImage: tunnel.hasRunningTunnel ? "stop.fill" : "power") {
                        model.operations.tunnel.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!tunnel.isManagerReady || tunnel.rawStatus.isTransitioning || (!tunnel.hasRunningTunnel && !model.hasApplied))

                    VStack(alignment: .leading) {
                        Text(tunnel.status.localizedText).font(.title2)
                        Text(model.hasApplied ? model.activeName : "Select and apply a profile to connect.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        traffic("arrow.up", bytes: stats.bytesOut, rate: stats.uploadBytesPerSecond)
                        traffic("arrow.down", bytes: stats.bytesIn, rate: stats.downloadBytesPerSecond)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Proxy Mode").font(.headline)
                    HStack(spacing: 24) {
                        modeButton("Direct", mode: .direct)
                        modeButton("Global Proxy", mode: .global)
                        modeButton("Rule", mode: .rule)
                    }
                }

                HStack(spacing: 24) {
                    NavigationLink {
                        TVClientProfilesView()
                    } label: {
                        Label("Configuration", systemImage: "doc.text")
                    }
                    NavigationLink {
                        TVClientNodesView(latency: latency, tunnel: tunnel)
                    } label: {
                        Label("Proxies", systemImage: "server.rack")
                    }
                    NavigationLink {
                        TVClientRulesView()
                    } label: {
                        Label("Rules", systemImage: "list.bullet.rectangle")
                    }
                }
            }
            .padding(36)
        }
        .alert("VPN Error", isPresented: Binding(
            get: { tunnel.startError != nil },
            set: { if !$0 { tunnel.startError = nil } }
        )) {
            Button("OK") { tunnel.startError = nil }
        } message: { Text(tunnel.startError ?? "") }
    }

    private func traffic(_ symbol: String, bytes: Int64, rate: Int64?) -> some View {
        HStack {
            Image(systemName: symbol)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary))
            if let rate, tunnel.rawStatus == .connected {
                Text(ByteCountFormatter.string(fromByteCount: rate, countStyle: .binary) + "/s")
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }

    private func modeButton(_ title: LocalizedStringKey, mode: ProxyMode) -> some View {
        Button {
            Task { await model.setSetting("proxy-mode", value: mode.rawValue) }
        } label: {
            Label(title, systemImage: model.mode == mode ? "checkmark.circle.fill" : "circle")
        }
        .disabled(model.isBusy)
    }
}

struct TVClientGroupsView: View {
    let latency: LatencyCenter
    let tunnel: TunnelController
    @Environment(ClientModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 28)], spacing: 28) {
                NavigationLink {
                    TVClientNodesView(latency: latency, tunnel: tunnel)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("PROXY", systemImage: "shippingbox").font(.headline)
                        Text(model.selectedNodeName).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                ForEach(model.groups) { group in
                    NavigationLink {
                        TVClientGroupDetailView(name: group.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(group.name, systemImage: "square.stack.3d.up.fill")
                                .font(.headline)
                            Text(model.selectedMember(in: group))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(36)

            if model.groups.isEmpty {
                Text("Add a [Proxy Group] section in Configuration.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.pollPolicyStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct TVClientGroupDetailView: View {
    @Environment(ClientModel.self) private var model
    let name: String

    var body: some View {
        List {
            if let original = model.groups.first(where: { $0.name == name }) {
                let group = model.resolvedGroup(original)
                Section {
                    ForEach(group.members, id: \.self) { member in
                        if group.kind == .select {
                            Button {
                                Task { await model.selectMember(member, in: original) }
                            } label: {
                                Label(member, systemImage: model.selectedMember(in: original) == member ? "checkmark.circle.fill" : "circle")
                            }
                            .disabled(model.isBusy)
                        } else {
                            Text(member)
                        }
                    }
                } header: {
                    Text(model.selectedMember(in: original))
                }
            }
        }
        .navigationTitle(name)
    }
}

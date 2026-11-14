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
                    .disabled(model.isBusy || !tunnel.isManagerReady || tunnel.rawStatus.isTransitioning || (!tunnel.hasRunningTunnel && !model.hasApplied))

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
    @State private var pendingDelete: ParsedProxyGroup?

    var body: some View {
        ScrollView {
            NavigationLink("New Group") { TVClientGroupEditor(group: nil) }
                .disabled(model.isBusy)
                .padding(.top, 24)
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
                            TVClientGroupLabel(name: group.name, iconURL: group.parameters["icon-url"])
                                .font(.headline)
                            Text(model.selectedMember(in: group))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .contextMenu {
                        Button("Delete Group", role: .destructive) { pendingDelete = group }
                    }
                }
            }
            .padding(36)

            if model.groups.isEmpty {
                Text("Add a [Proxy Group] section in Configuration.")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Delete Group?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { group in
            Button("Delete", role: .destructive) { Task { await model.deleteGroup(group.name) } }
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
                NavigationLink("Edit Group") { TVClientGroupEditor(group: original) }
                    .disabled(model.isBusy)
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
                    TVClientGroupLabel(name: model.selectedMember(in: original), iconURL: original.parameters["icon-url"])
                }
            }
        }
        .navigationTitle(name)
    }
}

private struct TVClientGroupEditor: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: ParsedProxyGroup?
    @State private var name: String
    @State private var kind: String
    @State private var members: [String]
    @State private var iconURL: String

    init(group: ParsedProxyGroup?) {
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _kind = State(initialValue: group?.kindToken ?? "select")
        _members = State(initialValue: group?.members ?? [])
        _iconURL = State(initialValue: group?.parameters["icon-url"] ?? "")
    }

    var body: some View {
        List {
            Section("Group") {
                TextField("Group Name", text: $name)
                Picker("Type", selection: $kind) {
                    ForEach(kinds, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Group Icon") {
                TVClientGroupLabel(name: "Icon Preview", iconURL: normalizedIconURL)
                TextField("HTTPS Icon URL", text: $iconURL).autocorrectionDisabled()
                NavigationLink("Choose from Icon Pack") { TVClientGroupIconPacksView(iconURL: $iconURL) }
                if !normalizedIconURL.isEmpty {
                    Button("Use Default Icon") { iconURL = "" }
                }
                if !validIconURL {
                    Text("Enter a valid HTTPS icon URL.").foregroundStyle(.red)
                }
            }
            Section("Member Order") {
                ForEach(Array(members.enumerated()), id: \.offset) { index, member in
                    Menu(member) {
                        Button("Move Up") { members.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("Move Down") { members.swapAt(index, index + 1) }.disabled(index + 1 == members.count)
                        Button("Remove", role: .destructive) { members.remove(at: index) }
                    }
                }
            }
            Section("Add Members") {
                ForEach(candidates, id: \.self) { member in
                    Button(member) { members.append(member) }
                }
            }
            Button("Save and Apply") { Task { await save() } }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || members.isEmpty || !validIconURL)
        }
        .navigationTitle(group == nil ? "New Group" : "Edit Group")
        .disabled(model.isBusy)
    }

    private var normalizedIconURL: String {
        iconURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validIconURL: Bool {
        normalizedIconURL.isEmpty || ProxyGroupIconURL.parse(normalizedIconURL) != nil
    }

    private var kinds: [String] {
        let defaults = ["select", "url-test", "fallback", "load-balance"]
        guard let original = group?.kindToken, !defaults.contains(original) else { return defaults }
        return defaults + [original]
    }

    private var candidates: [String] {
        let available = model.nodes.map(\.name) + model.groups.map(\.name).filter { $0 != group?.name && $0 != name }
            + ["DIRECT", "REJECT", "PROXY"]
        var seen = Set(members)
        return available.filter { seen.insert($0).inserted }
    }

    private func save() async {
        let style = group.flatMap { model.profile?.groupStyles[$0.name] } ?? ClientGroupStyle()
        var parameters = (group?.parameters.pairs ?? []).filter { key, value in
            key.caseInsensitiveCompare("icon-url") != .orderedSame &&
                (key != "selected" || (kind == "select" && members.contains(value)))
        }
        if !normalizedIconURL.isEmpty { parameters.append(("icon-url", normalizedIconURL)) }
        if await model.saveGroup(original: group?.name, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 kind: kind, members: members, parameters: parameters, style: style) {
            dismiss()
        }
    }
}

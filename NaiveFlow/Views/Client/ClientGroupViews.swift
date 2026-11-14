import SwiftUI

struct ClientGroupsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ClientModel.self) private var model
    @State private var editing: ClientGroupEditor?
    @State private var deleteGroup: String?
    @State private var managing = false
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                NavigationLink { ClientGroupDetailView(name: nil) } label: {
                    ClientPolicyCard(name: "PROXY", selected: model.selectedNodeName,
                        style: ClientGroupStyle(symbol: "shippingbox", palette: 0))
                }.buttonStyle(.plain)
                ForEach(model.groups) { group in
                    NavigationLink { ClientGroupDetailView(name: group.name) } label: {
                        ClientPolicyCard(name: group.name, selected: model.selectedMember(in: group),
                            style: style(group.name), iconURL: group.parameters["icon-url"])
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = ClientGroupEditor(group: group) }
                        Button("Duplicate", systemImage: "doc.on.doc") { editing = ClientGroupEditor(group: group, duplicate: true) }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteGroup = group.name }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
            if model.groups.isEmpty {
                Text("Group your nodes to choose an outbound for different traffic.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.pollPolicyStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Group", systemImage: "plus") { editing = ClientGroupEditor() }
                    Button("Manage and Reorder", systemImage: "arrow.up.arrow.down") { managing = true }
                } label: { Image(systemName: "plus").font(.system(size: 21, weight: .medium)) }
            }
        }
        .sheet(item: $editing) { ClientGroupEditorView(draft: $0) }
        .sheet(isPresented: $managing) { NavigationStack { ClientGroupManagementView() } }
        .confirmationDialog("Delete Group?", isPresented: Binding(get: { deleteGroup != nil }, set: { if !$0 { deleteGroup = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let deleteGroup { Task { await model.deleteGroup(deleteGroup) } }; deleteGroup = nil }
        }
    }
    private func style(_ name: String) -> ClientGroupStyle { model.profile?.groupStyles[name] ?? ClientGroupStyle(symbol: symbol(name), palette: ClientPalette.index(for: name)) }
    private func symbol(_ name: String) -> String {
        let name = name.lowercased()
        if name.contains("video") || name.contains("youtube") { return "play.rectangle.fill" }
        if name.contains("bank") { return "building.columns.fill" }
        if name.contains("game") { return "gamecontroller.fill" }
        if name.contains("discord") || name.contains("chat") { return "bubble.left.and.bubble.right.fill" }
        return "square.stack.3d.up.fill"
    }
}

struct ClientGroupDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ClientModel.self) private var model
    @Environment(LatencyCenter.self) private var latency
    @Environment(TunnelController.self) private var tunnel
    let name: String?
    @State private var editing: ClientGroupEditor?
    private var group: ParsedProxyGroup? { model.groups.first { $0.name == name } }
    private var title: String { name ?? "PROXY" }
    private var candidates: [String] { group?.members ?? model.nodes.map(\.name) }
    private var selected: String { group.map { model.selectedMember(in: $0) } ?? model.selectedNodeName }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ClientPolicyCard(name: title, selected: selected,
                    style: model.profile?.groupStyles[title] ?? ClientGroupStyle(symbol: name == nil ? "shippingbox" : "square.stack.3d.up.fill", palette: name == nil ? 0 : ClientPalette.index(for: title)),
                    iconURL: group?.parameters["icon-url"])
                    .overlay(alignment: .topTrailing) {
                        Button { latency.testLatencies(for: candidateNodes, transport: tunnel) } label: {
                            HStack(spacing: 5) {
                                if testing { ProgressView().tint(.white) }
                                else { Image(systemName: "bolt.fill") }
                                Text(testing ? "Testing…" : "Latency Test")
                            }.font(.caption.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(.black.opacity(0.16), in: Capsule())
                        }.buttonStyle(.plain).disabled(candidateNodes.isEmpty || testing)
                            .accessibilityLabel("Test Latency for This Group's Nodes")
                            .padding(14)
                    }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Available Nodes").font(.footnote.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
                    ClientCard {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { index, member in
                            if index > 0 { Divider().padding(.leading, 56) }
                            if let node = model.nodes.first(where: { $0.name == member }) {
                                ClientNodeRow(node: node, selected: selected == member, latency: liveLatency(for: node)) { choose(member) }
                            } else {
                                Button { choose(member) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: selected == member ? "checkmark.circle.fill" : "circle").foregroundStyle(selected == member ? Color.blue : .secondary)
                                        Text(member).foregroundStyle(.primary); Spacer()
                                    }.padding(20)
                                }
                            }
                        }
                        if candidates.isEmpty { Text("Add nodes on the Home tab first.").font(.subheadline).foregroundStyle(.secondary).padding(24) }
                    }
                }
                if let group {
                    ClientCard {
                        Button("Auto Select", systemImage: "shuffle") { Task {
                            _ = await model.saveGroup(original: group.name, name: group.name, kind: "url-test", members: group.members,
                                parameters: group.parameters.pairs.filter { $0.0 != "selected" }, style: model.profile?.groupStyles[title] ?? ClientGroupStyle(palette: ClientPalette.index(for: title)))
                        } }.font(.subheadline).frame(maxWidth: .infinity).padding(18)
                    }
                }
                if let group, group.kind != .select {
                    Text("Currently selected by \(group.kindToken). Selecting a node switches to manual selection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.pollPolicyStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .toolbar {
            if let group { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = ClientGroupEditor(group: group) } } }
        }
        .sheet(item: $editing) { ClientGroupEditorView(draft: $0) }
        .disabled(model.isBusy)
    }
    private func liveLatency(for node: ProxyConfiguration) -> LatencyResult? {
        if let result = latency.latencyResults[node.id] { return result }
        if let name, let ms = model.liveGroups[name]?.latencies[node.name] { return .success(ms) }
        return latency.latencyResults[node.id]
    }
    private var testing: Bool { candidateNodes.contains { latency.latencyResults[$0.id] == .testing } }
    private var candidateNodes: [ProxyConfiguration] { model.nodes.filter { candidates.contains($0.name) } }
    private func choose(_ member: String) {
        Task { if let group { await model.selectMember(member, in: group) } else { await model.selectNode(member) } }
    }
}

struct ClientGroupEditor: Identifiable {
    var id = UUID()
    var originalName: String?
    var name = ""
    var kind = "select"
    var members: [String] = []
    var selected = ""
    var iconURL = ""
    var interval = "300"
    var tolerance = "50"
    var probeURL = "https://www.gstatic.com/generate_204"
    init() {}
    init(group: ParsedProxyGroup, duplicate: Bool = false) {
        originalName = duplicate ? nil : group.name
        name = group.name + (duplicate ? " Copy" : "")
        kind = group.kindToken
        members = group.members
        selected = group.parameters["selected"] ?? ""
        iconURL = group.parameters["icon-url"] ?? ""
        interval = group.parameters["interval"] ?? "300"
        tolerance = group.parameters["tolerance"] ?? "50"
        probeURL = group.parameters["url"] ?? "https://www.gstatic.com/generate_204"
    }
}

struct ClientGroupEditorView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: ClientGroupEditor
    @State private var style = ClientGroupStyle()
    @State private var showIconPacks = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ClientPolicyCard(name: draft.name.isEmpty ? "New Group" : draft.name,
                        selected: draft.selected.isEmpty ? draft.members.first ?? "Select Members" : draft.selected, style: style, iconURL: draft.iconURL)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section("Basic Information") {
                    TextField("Group Name", text: $draft.name)
                    Picker("Type", selection: $draft.kind) {
                        Text("Select · Manual Selection").tag("select")
                        Text("URL Test · Lowest Latency").tag("url-test")
                        Text("Fallback · Failover").tag("fallback")
                        Text("Load Balance · Load Balance").tag("load-balance")
                    }
                    Button { showIconPacks = true } label: {
                        HStack {
                            Text("Icon").foregroundStyle(.primary)
                            Spacer()
                            if let url = ProxyGroupIconURL.parse(draft.iconURL) {
                                AsyncImage(url: url) { image in image.resizable().scaledToFit() }
                                    placeholder: { Image(systemName: "photo").foregroundStyle(.secondary) }
                                    .frame(width: 30, height: 30)
                            } else {
                                Text("Choose Icon").foregroundStyle(.secondary)
                            }
                        }.frame(minHeight: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("Open icon packs to select an icon.")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ClientPalette.colors.indices, id: \.self) { index in
                                Button { style.palette = index } label: {
                                    Circle().fill(LinearGradient(colors: ClientPalette.colors[index], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 29, height: 29)
                                        .overlay(Circle().stroke(style.palette == index ? Color.primary : .clear, lineWidth: 2).padding(-3))
                                }.buttonStyle(.plain).accessibilityLabel("Color \(index + 1)").padding(4)
                            }
                        }
                    }
                }
                Section("Member Order") {
                    ForEach(draft.members, id: \.self) { member in
                        HStack {
                            Text(member)
                            Spacer()
                            Button { draft.members.removeAll { $0 == member } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.borderless)
                        }
                    }.onMove { draft.members.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("Add Members") {
                    ForEach(availableMembers, id: \.self) { member in
                        Button { draft.members.append(member) } label: { Label(member, systemImage: "plus.circle") }
                    }
                    if availableMembers.isEmpty { Text("All available members have been added.").foregroundStyle(.secondary) }
                }
                Section("Parameters") {
                    if draft.kind == "select" {
                        Picker("Default Member", selection: $draft.selected) {
                            Text("Use First Member").tag("")
                            ForEach(draft.members, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        TextField("Probe URL", text: $draft.probeURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Probe Interval (seconds)", text: $draft.interval).keyboardType(.numberPad)
                        if draft.kind == "url-test" { TextField("Switching Tolerance (ms)", text: $draft.tolerance).keyboardType(.numberPad) }
                    }
                }
            }
            .navigationTitle(draft.originalName == nil ? "New Group" : "Edit Group").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await model.saveGroup(original: draft.originalName, name: draft.name, kind: draft.kind, members: draft.members, parameters: parameters, style: style) { dismiss() } } }
                        .disabled(model.isBusy || draft.name.isEmpty || draft.members.isEmpty)
                }
            }
            .sheet(isPresented: $showIconPacks) { ClientIconPacksView(selectedURL: $draft.iconURL) }
            .task { style = model.profile?.groupStyles[draft.originalName ?? draft.name] ?? ClientGroupStyle(palette: ClientPalette.index(for: draft.name)) }
            .alert("Could Not Save Group", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
    private var availableMembers: [String] {
        (model.nodes.map(\.name) + model.groups.map(\.name).filter { $0 != draft.originalName && $0 != draft.name } + ["DIRECT", "REJECT", "PROXY"])
            .filter { !draft.members.contains($0) }
    }
    private var parameters: [(String,String)] {
        var result: [(String,String)] = []
        if !draft.iconURL.isEmpty { result.append(("icon-url", draft.iconURL)) }
        if draft.kind == "select" {
            if draft.members.contains(draft.selected) { result.append(("selected", draft.selected)) }
        } else {
            result += [("url", draft.probeURL), ("interval", draft.interval)]
            if draft.kind == "url-test" { result.append(("tolerance", draft.tolerance)) }
        }
        return result
    }
}

struct ClientGroupManagementView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ClientGroupEditor?
    @State private var pendingDelete: String?
    var body: some View {
        List {
            ForEach(model.groups) { group in
                Button { editing = ClientGroupEditor(group: group) } label: {
                    HStack { Text(group.name).foregroundStyle(.primary); Spacer(); Text(group.kindToken).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .onMove { from, to in
                var names = model.groups.map(\.name); names.move(fromOffsets: from, toOffset: to)
                Task { await model.reorderGroups(names) }
            }
            .onDelete { offsets in if let index = offsets.first { pendingDelete = model.groups[index].name } }
        }
        .navigationTitle("Manage Groups").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }; ToolbarItem(placement: .primaryAction) { EditButton() } }
        .sheet(item: $editing) { ClientGroupEditorView(draft: $0) }
        .confirmationDialog("Delete Group?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let pendingDelete { Task { await model.deleteGroup(pendingDelete) } }; pendingDelete = nil }
        }
    }
}

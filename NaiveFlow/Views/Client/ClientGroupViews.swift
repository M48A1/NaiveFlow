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
                        Button("编辑", systemImage: "pencil") { editing = ClientGroupEditor(group: group) }
                        Button("复制", systemImage: "doc.on.doc") { editing = ClientGroupEditor(group: group, duplicate: true) }
                        Button("删除", systemImage: "trash", role: .destructive) { deleteGroup = group.name }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
            if model.groups.isEmpty {
                Text("把常用节点放入策略组，为不同流量选择出站。")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("新建策略组", systemImage: "plus") { editing = ClientGroupEditor() }.padding(.top, 8)
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
        .navigationTitle("策略组")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新建策略组", systemImage: "plus") { editing = ClientGroupEditor() }
                    Button("管理与排序", systemImage: "arrow.up.arrow.down") { managing = true }
                } label: { Image(systemName: "plus").font(.system(size: 21, weight: .medium)) }
            }
        }
        .sheet(item: $editing) { ClientGroupEditorView(draft: $0) }
        .sheet(isPresented: $managing) { NavigationStack { ClientGroupManagementView() } }
        .confirmationDialog("删除策略组？", isPresented: Binding(get: { deleteGroup != nil }, set: { if !$0 { deleteGroup = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let deleteGroup { Task { await model.deleteGroup(deleteGroup) } }; deleteGroup = nil }
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
                VStack(alignment: .leading, spacing: 10) {
                    Text("可用节点").font(.footnote.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
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
                        if candidates.isEmpty { Text("先在首页添加节点").font(.subheadline).foregroundStyle(.secondary).padding(24) }
                    }
                }
                ClientCard {
                    HStack {
                        Button("延迟测试", systemImage: "bolt.fill") { latency.testLatencies(for: candidateNodes, transport: tunnel) }.frame(maxWidth: .infinity)
                        Divider().frame(height: 20)
                        if let group {
                            Button("自动选择", systemImage: "shuffle") { Task {
                                _ = await model.saveGroup(original: group.name, name: group.name, kind: "url-test", members: group.members,
                                    parameters: group.parameters.pairs.filter { $0.0 != "selected" }, style: model.profile?.groupStyles[title] ?? ClientGroupStyle(palette: ClientPalette.index(for: title)))
                            } }.frame(maxWidth: .infinity)
                        } else {
                            NavigationLink("节点管理") { ClientNodesView() }.frame(maxWidth: .infinity)
                        }
                    }.font(.subheadline).padding(18)
                }
                if let group, group.kind != .select {
                    Text("当前由 \(group.kindToken) 自动选择。点击节点会切换为 Select 手动选择。")
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
            if let group { ToolbarItem(placement: .topBarTrailing) { Button("编辑") { editing = ClientGroupEditor(group: group) } } }
        }
        .sheet(item: $editing) { ClientGroupEditorView(draft: $0) }
        .disabled(model.isBusy)
    }
    private func liveLatency(for node: ProxyConfiguration) -> LatencyResult? {
        if let name, let ms = model.liveGroups[name]?.latencies[node.name] { return .success(ms) }
        return latency.latencyResults[node.id]
    }
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
        name = group.name + (duplicate ? " 副本" : "")
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
    private let symbols = ["square.stack.3d.up.fill", "shippingbox", "globe", "building.columns.fill", "play.rectangle.fill", "gamecontroller.fill", "bubble.left.and.bubble.right.fill", "house.fill", "bolt.fill", "network"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ClientPolicyCard(name: draft.name.isEmpty ? "新策略组" : draft.name,
                        selected: draft.selected.isEmpty ? draft.members.first ?? "选择成员" : draft.selected, style: style, iconURL: draft.iconURL)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section("基本信息") {
                    TextField("策略组名称", text: $draft.name)
                    Picker("类型", selection: $draft.kind) {
                        Text("Select · 手动选择").tag("select")
                        Text("URL Test · 延迟优先").tag("url-test")
                        Text("Fallback · 故障转移").tag("fallback")
                        Text("Load Balance · 负载均衡").tag("load-balance")
                    }
                    Picker("图标", selection: $style.symbol) { ForEach(symbols, id: \.self) { Image(systemName: $0).tag($0) } }
                    TextField("自定义图标 HTTPS 地址", text: $draft.iconURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ClientPalette.colors.indices, id: \.self) { index in
                                Button { style.palette = index } label: {
                                    Circle().fill(LinearGradient(colors: ClientPalette.colors[index], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 29, height: 29)
                                        .overlay(Circle().stroke(style.palette == index ? Color.primary : .clear, lineWidth: 2).padding(-3))
                                }.buttonStyle(.plain).accessibilityLabel("配色 \(index + 1)").padding(4)
                            }
                        }
                    }
                }
                Section("成员顺序") {
                    ForEach(draft.members, id: \.self) { member in
                        HStack {
                            Text(member)
                            Spacer()
                            Button { draft.members.removeAll { $0 == member } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.borderless)
                        }
                    }.onMove { draft.members.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("添加成员") {
                    ForEach(availableMembers, id: \.self) { member in
                        Button { draft.members.append(member) } label: { Label(member, systemImage: "plus.circle") }
                    }
                    if availableMembers.isEmpty { Text("所有可用成员已添加").foregroundStyle(.secondary) }
                }
                Section("参数") {
                    if draft.kind == "select" {
                        Picker("默认成员", selection: $draft.selected) {
                            Text("使用第一个成员").tag("")
                            ForEach(draft.members, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        TextField("探测 URL", text: $draft.probeURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("探测间隔（秒）", text: $draft.interval).keyboardType(.numberPad)
                        if draft.kind == "url-test" { TextField("切换容差（ms）", text: $draft.tolerance).keyboardType(.numberPad) }
                    }
                }
            }
            .navigationTitle(draft.originalName == nil ? "新建策略组" : "编辑策略组").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { if await model.saveGroup(original: draft.originalName, name: draft.name, kind: draft.kind, members: draft.members, parameters: parameters, style: style) { dismiss() } } }
                        .disabled(model.isBusy || draft.name.isEmpty || draft.members.isEmpty)
                }
            }
            .task { style = model.profile?.groupStyles[draft.originalName ?? draft.name] ?? ClientGroupStyle(palette: ClientPalette.index(for: draft.name)) }
            .alert("无法保存策略组", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
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
        .navigationTitle("管理策略组").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }; ToolbarItem(placement: .primaryAction) { EditButton() } }
        .sheet(item: $editing) { ClientGroupEditorView(draft: $0) }
        .confirmationDialog("删除策略组？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let pendingDelete { Task { await model.deleteGroup(pendingDelete) } }; pendingDelete = nil }
        }
    }
}

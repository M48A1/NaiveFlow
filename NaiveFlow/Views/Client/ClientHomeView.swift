import SwiftUI
import NetworkExtension
import UniformTypeIdentifiers

struct ClientHomeView: View {
    @Environment(ClientModel.self) private var model
    @Environment(TunnelController.self) private var tunnel
    @Environment(ConnectionStats.self) private var stats
    @Environment(LatencyCenter.self) private var latency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var configurationsExpanded = false
    @State private var modeExpanded = false
    @State private var proxiesExpanded = false
    @State private var rulesExpanded = false
    @State private var editor: ClientProfile?
    @State private var showURL = false
    @State private var remoteURL = ""
    @State private var importingFile = false
    @State private var pendingDelete: ClientProfile?
    @State private var autoChoosing = false
    @State private var showNodeEditor = false
    @State private var nodeToEdit: ProxyConfiguration?

    private var connected: Bool { tunnel.rawStatus == .connected }
    private var canToggle: Bool { tunnel.isManagerReady && !tunnel.rawStatus.isTransitioning && (connected || model.hasApplied) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                runningCard
                configurationCard
                modeCard
                proxyCard
                rulesCard
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editor) { ClientProfileEditorView(profile: $0) }
        .sheet(isPresented: $showNodeEditor) {
            ProxyEditorView(configuration: nodeToEdit) { node in Task { await model.saveNode(node, replacing: nodeToEdit?.name) } }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let text = try model.operations.configurationDocument.read(contentsOf: url)
                editor = model.createProfile(name: url.deletingPathExtension().lastPathComponent, text: text)
            } catch { model.report(error) }
        }
        .alert("从 URL 导入配置", isPresented: $showURL) {
            TextField("https://example.com/config.conf", text: $remoteURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("导入") { Task {
                do {
                    let text = try await model.fetchText(remoteURL)
                    editor = model.createProfile(name: URL(string: remoteURL)?.deletingPathExtension().lastPathComponent ?? "远程配置", text: text, sourceURL: remoteURL)
                } catch { model.report(error) }
            } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除配置？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let pendingDelete { model.deleteProfile(pendingDelete.id) }; pendingDelete = nil }
        }
        .onChange(of: latency.latencyResults) { _, results in
            guard autoChoosing else { return }
            let targets = model.nodes
            guard !targets.contains(where: { results[$0.id] == .testing }) else { return }
            autoChoosing = false
            let fastest = targets.compactMap { node -> (String, Int)? in
                if case .success(let ms) = results[node.id] { return (node.name, ms) }; return nil
            }.min { $0.1 < $1.1 }
            if let fastest { Task { await model.selectNode(fastest.0) } }
            else { model.error = "没有可用的延迟结果，请检查网络后重试。" }
        }
        .alert("VPN 错误", isPresented: Binding(get: { tunnel.startError != nil }, set: { if !$0 { tunnel.startError = nil } })) {
            Button("好") { tunnel.startError = nil }
        } message: { Text(tunnel.startError ?? "") }
    }

    private var configurationCard: some View {
        ClientHomeCard(colors: [Color(red: 0.43, green: 0.28, blue: 0.77), Color(red: 0.64, green: 0.39, blue: 0.87)]) {
            cardHeader("我的配置", symbol: "doc.text.fill", summary: model.activeName, expanded: $configurationsExpanded)
            if configurationsExpanded {
            ForEach(model.library.profiles) { profile in
                HStack(spacing: 10) {
                    Button { Task { await model.activate(profile) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(.body.weight(.medium))
                                Text("上次更新：\(profile.updatedAt.formatted(.dateTime.month().day().hour().minute()))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if model.library.selectedID == profile.id { Image(systemName: "checkmark").font(.title3.weight(.semibold)) }
                        }.frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.isBusy)
                    Menu {
                        Button("编辑 / 重命名", systemImage: "pencil") { editor = profile }
                        if profile.sourceURL != nil { Button("更新远程配置", systemImage: "arrow.clockwise") { Task { await model.updateProfile(profile) } } }
                        Button("复制配置", systemImage: "doc.on.doc") { editor = model.createProfile(name: profile.name + " 副本", text: profile.text) }
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = profile }
                            .disabled(profile.id == model.library.selectedID)
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(model.library.selectedID == profile.id ? Color.primary.opacity(0.045) : .clear)
            }
            HStack(spacing: 8) { configurationActions }
                .buttonStyle(ClientHomeActionStyle()).padding(16)
            }
        }
    }

    @ViewBuilder private var configurationActions: some View {
        Button("新建") { editor = model.createProfile() }.frame(maxWidth: .infinity)
        Menu {
            Button("从 URL 导入", systemImage: "link") { showURL = true }
            Button("从文件导入", systemImage: "folder") { importingFile = true }
        } label: { Text("导入").frame(maxWidth: .infinity).frame(minHeight: 44).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
        NavigationLink("配置管理") { ClientProfilesView().toolbar(.visible, for: .navigationBar) }.frame(maxWidth: .infinity)
    }

    private var runningCard: some View {
        ClientHomeCard(colors: [Color(red: 0.06, green: 0.47, blue: 0.43), Color(red: 0.13, green: 0.65, blue: 0.51)]) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    if tunnel.rawStatus.isTransitioning { ProgressView() }
                    else { Image(systemName: connected ? "power.circle.fill" : "power.circle").font(.title2) }
                    Text("NaiveFlow")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(connected ? Color.green : Color.red)
                        .accessibilityValue(connected ? "运行中" : tunnel.rawStatus.isTransitioning ? "正在切换连接" : "已停止")
                    Spacer()
                    Toggle("代理运行", isOn: Binding(get: { connected }, set: { _ in model.operations.tunnel.toggle() }))
                        .labelsHidden().tint(.teal).disabled(!canToggle || model.isBusy)
                }
                HStack(spacing: 30) {
                    traffic(symbol: "arrow.up", total: stats.bytesOut, rate: stats.uploadBytesPerSecond)
                    traffic(symbol: "arrow.down", total: stats.bytesIn, rate: stats.downloadBytesPerSecond)
                }
                if !model.hasApplied { Text("选择并应用配置后即可启动").font(.caption).foregroundStyle(.secondary) }
            }.padding(20)
        }
    }

    private func traffic(symbol: String, total: Int64, rate: Int64?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.body.weight(.medium))
            VStack(alignment: .leading, spacing: 4) {
                Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)).font(.subheadline.weight(.medium))
                if connected, let rate { Text(ByteCountFormatter.string(fromByteCount: rate, countStyle: .binary) + "/s").font(.caption) }
            }.monospacedDigit()
        }.foregroundStyle(.secondary)
    }

    private var modeCard: some View {
        ClientHomeCard(colors: [Color(red: 0.25, green: 0.31, blue: 0.81), Color(red: 0.20, green: 0.56, blue: 0.88)]) {
            cardHeader("出站模式", symbol: "arrow.triangle.branch", summary: modeTitle(model.mode), expanded: $modeExpanded)
            if modeExpanded {
            ForEach([ProxyMode.direct, .global, .rule], id: \.rawValue) { mode in
                Button { Task { await model.setSetting("proxy-mode", value: mode.rawValue) } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark").font(.title3.weight(.semibold))
                            .opacity(model.mode == mode ? 1 : 0).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(modeTitle(mode)).font(.body.weight(model.mode == mode ? .semibold : .regular))
                            if model.mode == mode {
                                Text(mode == .rule ? "使用规则系统决定如何处理请求" : mode == .global ? "所有请求通过代理连接" : "所有请求直接连接")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 20).padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.mode == mode ? Color.blue.opacity(0.09) : .clear).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.isBusy)
                    .accessibilityAddTraits(model.mode == mode ? [.isSelected] : [])
            }
            }
        }
    }
    private func modeTitle(_ mode: ProxyMode) -> String { mode == .rule ? "规则模式" : mode == .global ? "全局代理" : "直接连接" }

    private var proxyCard: some View {
        ClientHomeCard(colors: [Color(red: 0.70, green: 0.31, blue: 0.11), Color(red: 0.85, green: 0.48, blue: 0.18)]) {
            cardHeader("PROXY", symbol: "paperplane.fill", summary: "\(model.selectedNodeName) · \(model.nodes.count) 个节点", expanded: $proxiesExpanded)
            if proxiesExpanded {
            if model.nodes.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有节点").font(.subheadline.weight(.medium))
                    Text("添加节点，或导入包含节点的配置").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(20)
            } else {
                ForEach(model.nodes) { node in
                    Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5).padding(.horizontal, 20)
                    ClientNodeRow(node: node, selected: model.selectedNodeName == node.name, latency: latency.latencyResults[node.id]) {
                        Task { await model.selectNode(node.name) }
                    }.disabled(model.isBusy)
                    .background(model.selectedNodeName == node.name ? Color.primary.opacity(0.045) : .clear)
                    .contextMenu { Button("编辑节点", systemImage: "pencil") { nodeToEdit = node; showNodeEditor = true } }
                }
            }
            HStack(spacing: 8) { proxyActions }
                .buttonStyle(ClientHomeActionStyle()).padding(16)
            }
        }
    }

    @ViewBuilder private var proxyActions: some View {
        Menu {
            Button("延迟测试", systemImage: "bolt.fill") { latency.testLatencies(for: model.nodes, transport: tunnel) }
                .disabled(model.nodes.isEmpty)
            Button("测速并自动选择", systemImage: "shuffle") { autoChoosing = true; latency.testLatencies(for: model.nodes, transport: tunnel) }
                .disabled(model.nodes.isEmpty || autoChoosing)
        } label: { Text(autoChoosing ? "测速中…" : "测速").frame(maxWidth: .infinity).frame(minHeight: 44).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
        NavigationLink("节点管理") { ClientNodesView().toolbar(.visible, for: .navigationBar) }.frame(maxWidth: .infinity)
    }
    private var ruleSetCount: Int { model.parsed.rules.filter { $0.kind == .ruleSet }.count }
    private var localRuleCount: Int { model.parsed.rules.filter { $0.kind != .ruleSet }.count }

    private var rulesCard: some View {
        ClientHomeCard(colors: [Color(red: 0.60, green: 0.30, blue: 0.48), Color(red: 0.79, green: 0.46, blue: 0.56)]) {
            cardHeader("分流规则", symbol: "line.3.horizontal.decrease.circle", summary: "RuleSet · \(ruleSetCount)   Local · \(localRuleCount)", expanded: $rulesExpanded)
            if rulesExpanded {
                HStack(spacing: 12) {
                    ruleTile("RuleSet", symbol: "square.stack.3d.up", count: ruleSetCount, color: .indigo, ruleSets: true)
                    ruleTile("Local", symbol: "doc.text", count: localRuleCount, color: .teal, ruleSets: false)
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }

    private func ruleTile(_ title: String, symbol: String, count: Int, color: Color, ruleSets: Bool) -> some View {
        NavigationLink { ClientRoutingRulesView(ruleSets: ruleSets).toolbar(.visible, for: .navigationBar) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(color)
                Text(title).font(.headline)
                Text("\(count) \(ruleSets ? "个规则集引用" : "条本地规则")").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

    private func toggleDetails(_ expanded: Binding<Bool>) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            expanded.wrappedValue.toggle()
        }
    }

    private func cardHeader(_ title: String, symbol: String, summary: String, expanded: Binding<Bool>) -> some View {
        Button { toggleDetails(expanded) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title3.weight(.semibold))
                    if !expanded.wrappedValue { Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if title == "我的配置", model.isBusy { ProgressView() }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(expanded.wrappedValue ? "已展开" : "已折叠")
            .accessibilityHint("点按展开或收起明细")
    }
}

private struct ClientHomeCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var colors: [Color]
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .foregroundStyle(.primary).tint(.primary)
            .background {
                GeometryReader { geometry in
                    ZStack {
                        Color(uiColor: .secondarySystemGroupedBackground)
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            .opacity(colorScheme == .dark ? 0.18 : 0.12)
                        Rectangle().fill(.white.opacity(0.10))
                            .frame(width: geometry.size.width * 1.5, height: geometry.size.height * 0.5)
                            .rotationEffect(.degrees(-30)).offset(x: geometry.size.width * 0.12, y: -geometry.size.height * 0.3)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct ClientHomeActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium))
            .lineLimit(1).frame(maxWidth: .infinity).frame(minHeight: 44)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.primary)
    }
}

private struct ClientRoutingRulesView: View {
    @Environment(ClientModel.self) private var model
    let ruleSets: Bool
    @State private var editing = false
    @State private var ruleEditor: ClientRuleSetDraft?

    private var rules: [ParsedRule] {
        model.parsed.rules.filter { ($0.kind == .ruleSet) == ruleSets }
    }

    var body: some View {
        List {
            Section {
                if rules.isEmpty {
                    ContentUnavailableView(ruleSets ? "暂无规则集" : "暂无本地规则", systemImage: ruleSets ? "square.stack.3d.up" : "doc.text", description: Text(ruleSets ? "点击右上角 +，添加规则集并选择策略。" : "可在当前配置中添加分流规则。"))
                } else {
                    ForEach(rules) { rule in
                        Button {
                            if ruleSets { ruleEditor = ClientRuleSetDraft(rule: rule) }
                        } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(rule.kind.token).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Text(rule.policy.token).font(.caption.weight(.medium)).foregroundStyle(.blue)
                            }
                            Text(rule.value ?? "最终匹配").font(.subheadline).textSelection(.enabled)
                            if !rule.options.isEmpty {
                                Text(rule.options.map(\.token).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!ruleSets)
                    }
                }
            } header: {
                Text(ruleSets ? "\(rules.count) 个规则集引用" : "\(rules.count) 条本地规则")
            } footer: {
                Text(ruleSets ? "显示当前配置中的 RULE-SET 引用及其策略；应用配置时读取规则集内容。" : "按配置中的匹配顺序显示，包含最终匹配规则。")
            }
        }
        .navigationTitle(ruleSets ? "RuleSet" : "Local")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if ruleSets {
                    Button { ruleEditor = ClientRuleSetDraft() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新建 RuleSet")
                        .disabled(model.profile == nil || model.isBusy)
                } else {
                    Button { editing = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加本地规则")
                        .disabled(model.profile == nil || model.isBusy)
                }
            }
        }
        .sheet(isPresented: $editing) { ClientActiveProfileEditor() }
        .sheet(item: $ruleEditor) { draft in
            ClientRuleSetEditorView(draft: draft)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ClientRuleSetDraft: Identifiable {
    let id = UUID()
    var original: ParsedRule?
    var source = ""
    var policy = "PROXY"
    var noResolve = false

    init(rule: ParsedRule? = nil) {
        original = rule
        if let rule {
            source = rule.value ?? ""
            policy = rule.policy.token
            noResolve = rule.hasOption(.noResolve)
        }
    }
}

private struct ClientRuleSetEditorView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: ClientRuleSetDraft
    @State private var saving = false
    @State private var error: String?

    private var policies: [String] {
        var names = ["PROXY", "DIRECT", "REJECT"]
        for group in model.groups where !names.contains(group.name) { names.append(group.name) }
        if !names.contains(draft.policy) { names.append(draft.policy) }
        return names
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("规则集地址") {
                    TextField("https://example.com/rules.list", text: $draft.source)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("规则集地址")
                }
                Section {
                    Picker("策略", selection: $draft.policy) {
                        ForEach(policies, id: \.self) { policy in Text(policy).tag(policy) }
                    }
                    Toggle("不主动解析域名", isOn: $draft.noResolve)
                } footer: {
                    Text("选择策略组、DIRECT（直连）或 REJECT（拒绝）。保存时下载并校验规则集，成功后应用到当前配置。")
                }
            }
            .navigationTitle(draft.original == nil ? "新建 RuleSet" : "编辑 RuleSet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("保存") }
                    }.disabled(saving || model.isBusy || draft.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .alert("无法保存规则集", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    @MainActor private func save() async {
        saving = true
        defer { saving = false }
        do {
            let text = try ClientDocumentEditing.saveRuleSet(model.operatingText, original: draft.original,
                source: draft.source, policy: draft.policy, noResolve: draft.noResolve)
            if await model.commit(text) { dismiss() }
            else {
                error = model.error ?? "保存失败，请稍后重试。"
                model.error = nil
            }
        } catch { self.error = error.localizedDescription }
    }
}

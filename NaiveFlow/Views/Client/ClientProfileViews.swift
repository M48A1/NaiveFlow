import SwiftUI
import UniformTypeIdentifiers

struct ClientProfileEditorView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: ClientProfile
    @State private var preview: TextConfigurationPipeline.Result?
    @State private var showDiscard = false
    @State private var initialText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("配置文件") {
                    TextField("配置名称", text: $profile.name)
                    TextField("远程地址（可选，HTTPS）", text: Binding(get: { profile.sourceURL ?? "" }, set: { profile.sourceURL = $0.isEmpty ? nil : $0 }))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("配置内容") {
                    TextEditor(text: $profile.text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 340).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityLabel("配置内容")
                }
                if let preview {
                    Section("检查结果") {
                        LabeledContent("节点", value: "\(preview.compiled.proxies.count)")
                        LabeledContent("策略组", value: "\(preview.parsed.proxyGroups.count)")
                        LabeledContent("规则", value: "\(preview.compiled.orderedRules.count)")
                        ForEach(Array(preview.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text(diagnostic.message).font(.caption).foregroundStyle(diagnostic.severity == .error ? Color.red : .orange)
                        }
                    }
                }
                Section {
                    Button("保存并应用") { Task { if await model.saveProfile(profile, apply: true) { dismiss() } } }
                        .disabled(model.isBusy || preview?.isActivatable != true || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("仅保存") { Task { if await model.saveProfile(profile, apply: false) { dismiss() } } }
                        .disabled(model.isBusy || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .clientKeyboardDone()
            .navigationTitle("编辑配置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") {
                    if profile.text != initialText { showDiscard = true } else { dismiss() }
                } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { Task { if await model.saveProfile(profile, apply: true) { dismiss() } } }
                        .disabled(model.isBusy || preview?.isActivatable != true || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .primaryAction) { if model.isBusy { ProgressView() } }
            }
            .task { initialText = profile.text; preview = TextConfigurationPipeline.process(text: profile.text) }
            .task(id: profile.text) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                preview = TextConfigurationPipeline.process(text: profile.text)
            }
            .confirmationDialog("放弃未保存的修改？", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
            }
            .interactiveDismissDisabled(profile.text != initialText)
            .alert("无法保存配置", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

struct ClientProfilesView: View {
    @Environment(ClientModel.self) private var model
    @State private var editing: ClientProfile?
    @State private var pendingDelete: ClientProfile?
    @State private var showHistory = false
    var body: some View {
        List {
            Section {
                ForEach(model.library.profiles) { profile in
                    HStack {
                        Button { Task { await model.activate(profile) } } label: {
                            HStack(spacing: 13) {
                                ClientSectionIcon(symbol: "doc.text")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.updatedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.library.selectedID == profile.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                        Menu {
                            Button("编辑 / 重命名", systemImage: "pencil") { editing = profile }
                            if profile.sourceURL != nil { Button("更新", systemImage: "arrow.clockwise") { Task { await model.updateProfile(profile) } } }
                            Button("复制", systemImage: "doc.on.doc") { editing = model.createProfile(name: profile.name + " 副本", text: profile.text) }
                            Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = profile }.disabled(profile.id == model.library.selectedID)
                        } label: { Image(systemName: "ellipsis.circle").frame(width: 36, height: 40) }
                    }
                }
            } footer: { Text("点击配置即可应用。当前配置需先切换后再删除。") }
            Section {
                Button("新建配置", systemImage: "plus") { editing = model.createProfile() }
                Button("iCloud Drive 与版本历史") { showHistory = true }
            }
        }
        .navigationTitle("配置管理").navigationBarTitleDisplayMode(.inline)
        .disabled(model.isBusy)
        .sheet(item: $editing) { ClientProfileEditorView(profile: $0) }
        .sheet(isPresented: $showHistory, onDismiss: { model.refresh() }) { ProfileView() }
        .confirmationDialog("删除这份配置？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let pendingDelete { model.deleteProfile(pendingDelete.id) }; pendingDelete = nil }
        }
    }
}

struct ClientNodesView: View {
    @Environment(ClientModel.self) private var model
    @Environment(LatencyCenter.self) private var latency
    @Environment(TunnelController.self) private var tunnel
    @State private var editNode: ProxyConfiguration?
    @State private var showEditor = false
    @State private var deleteName: String?
    @State private var url = ""
    @State private var importingURL = false
    @State private var importingFile = false

    var body: some View {
        List {
            Section {
                ForEach(model.nodes) { node in
                    ClientNodeRow(node: node, selected: model.selectedNodeName == node.name, latency: latency.latencyResults[node.id]) {
                        Task { await model.selectNode(node.name) }
                    }.listRowInsets(EdgeInsets())
                    .contextMenu {
                        Button("编辑", systemImage: "pencil") { editNode = node; showEditor = true }
                        Button("测试延迟", systemImage: "bolt") { latency.testLatency(for: node, transport: tunnel) }
                        Button("删除", systemImage: "trash", role: .destructive) { deleteName = node.name }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { deleteName = node.name }
                        Button("编辑") { editNode = node; showEditor = true }.tint(.blue)
                    }
                }
                .onMove { from, to in
                    var names = model.nodes.map(\.name)
                    names.move(fromOffsets: from, toOffset: to)
                    Task { await model.reorderNodes(names) }
                }
            }
            Section {
                Button("批量延迟测试", systemImage: "bolt.fill") { latency.testLatencies(for: model.nodes, transport: tunnel) }.disabled(model.nodes.isEmpty)
                Button("按延迟排序", systemImage: "arrow.up.arrow.down") {
                    let names = model.nodes.sorted { ms($0) < ms($1) }.map(\.name)
                    Task { await model.reorderNodes(names) }
                }.disabled(model.nodes.isEmpty)
            }
        }
        .overlay { if model.nodes.isEmpty { ContentUnavailableView("暂无节点", systemImage: "network", description: Text("点击 + 添加节点或导入节点列表。")) } }
        .navigationTitle("节点管理").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新增节点", systemImage: "plus") { editNode = nil; showEditor = true }
                    Button("从 URL 导入", systemImage: "link") { importingURL = true }
                    Button("从配置文件导入", systemImage: "doc") { importingFile = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showEditor) { ProxyEditorView(configuration: editNode) { node in Task { await model.saveNode(node, replacing: editNode?.name) } } }
        .confirmationDialog("删除节点？", isPresented: Binding(get: { deleteName != nil }, set: { if !$0 { deleteName = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let deleteName { Task { await model.deleteNode(deleteName) } }; deleteName = nil }
        }
        .alert("从 URL 导入节点", isPresented: $importingURL) {
            TextField("HTTPS 节点订阅或配置地址", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("导入") { Task { do { let source = try await model.fetchText(url); try await importNodes(source) } catch { model.report(error) } } }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let file = try result.get()
                let access = file.startAccessingSecurityScopedResource()
                defer { if access { file.stopAccessingSecurityScopedResource() } }
                let text = try model.operations.configurationDocument.read(contentsOf: file)
                Task { do { try await importNodes(text) } catch { model.report(error) } }
            } catch { model.report(error) }
        }
        .disabled(model.isBusy)
    }

    private func ms(_ node: ProxyConfiguration) -> Int { if case .success(let ms) = latency.latencyResults[node.id] { return ms }; return .max }

    private func importNodes(_ source: String) async throws {
        _ = try await model.importNodes(source)
    }
}

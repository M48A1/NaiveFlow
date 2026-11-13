import SwiftUI
import UniformTypeIdentifiers

struct ClientModulesView: View {
    @Environment(ClientModel.self) private var model
    @State private var editing: ClientModule?
    @State private var pendingDelete: ClientModule?
    var body: some View {
        List {
            Section {
                ForEach(model.modules) { module in
                    HStack(spacing: 12) {
                        Button { editing = module } label: {
                            HStack(spacing: 12) {
                                ClientSectionIcon(symbol: "puzzlepiece.extension.fill")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(module.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text(module.summary.isEmpty ? module.format.displayName : module.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Toggle(module.name, isOn: Binding(get: { module.enabled }, set: { value in Task { await model.toggleModule(module, enabled: value) } })).labelsHidden().tint(.blue)
                    }.padding(.vertical, 5)
                    .contextMenu {
                        Button("编辑", systemImage: "pencil") { editing = module }
                        if module.sourceURL != nil { Button("更新", systemImage: "arrow.clockwise") { Task { await model.refreshModule(module) } } }
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = module }
                    }
                    .swipeActions { Button("删除", role: .destructive) { pendingDelete = module }; Button("编辑") { editing = module }.tint(.blue) }
                }
            } footer: { Text("模块规则随当前配置保存与应用。启用模块前，请在设置中完成 MITM 证书信任及域名配置。") }
        }
        .overlay {
            if model.modules.isEmpty {
                ContentUnavailableView {
                    Label("暂无模块", systemImage: "puzzlepiece.extension")
                } description: { Text("导入 Surge 或 Quantumult X 模块。") } actions: { Button("添加模块") { addModule() } }
            }
        }
        .navigationTitle("模块").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("添加模块", systemImage: "plus") { addModule() } } }
        .sheet(item: $editing) { ClientModuleEditorView(module: $0) }
        .confirmationDialog("删除模块及其规则？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let pendingDelete { Task { await model.deleteModule(pendingDelete) } }; pendingDelete = nil }
        }
        .disabled(model.isBusy)
    }
    private func addModule() { editing = ClientModule(name: "新模块", summary: "", source: "", format: .surge) }
}

struct ClientModuleEditorView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var module: ClientModule
    @State private var importingFile = false
    @State private var downloading = false
    var body: some View {
        NavigationStack {
            Form {
                Section("模块信息") {
                    TextField("模块名称", text: $module.name)
                    TextField("模块描述", text: $module.summary, axis: .vertical)
                    Picker("格式", selection: $module.format) { ForEach(ModuleFormat.allCases) { Text($0.displayName).tag($0) } }
                    Toggle("启用模块", isOn: $module.enabled).tint(.blue)
                }
                Section("导入与更新") {
                    TextField("远程地址（HTTPS）", text: Binding(get: { module.sourceURL ?? "" }, set: { module.sourceURL = $0.isEmpty ? nil : $0 }))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("从 URL 载入", systemImage: "arrow.down.circle") { Task {
                        downloading = true; defer { downloading = false }
                        do { module.source = try await model.fetchText(module.sourceURL ?? "") } catch { model.report(error) }
                    } }.disabled(module.sourceURL?.isEmpty != false)
                    Button("从本地文件导入", systemImage: "folder") { importingFile = true }
                }
                Section("模块内容") {
                    TextEditor(text: $module.source).font(.system(size: 12, design: .monospaced)).frame(minHeight: 260)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("模块内容")
                }
                Section {
                    Button("保存并应用") { Task {
                        downloading = true; defer { downloading = false }
                        if await model.saveModule(module) { dismiss() }
                    } }.disabled(module.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || module.name.isEmpty)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .clientKeyboardDone()
            .disabled(downloading || model.isBusy)
            .interactiveDismissDisabled(downloading || model.isBusy)
            .navigationTitle("编辑模块").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(downloading || model.isBusy) }
                ToolbarItem(placement: .primaryAction) { if downloading || model.isBusy { ProgressView() } }
            }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.plainText, .data]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    module.source = try model.operations.configurationDocument.read(contentsOf: url)
                    if url.pathExtension.lowercased() == "snippet" { module.format = .quantumultX }
                    else if url.pathExtension.lowercased() == "sgmodule" { module.format = .surge }
                    if module.name == "新模块" { module.name = url.deletingPathExtension().lastPathComponent }
                } catch { model.report(error) }
            }
            .alert("模块处理失败", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}

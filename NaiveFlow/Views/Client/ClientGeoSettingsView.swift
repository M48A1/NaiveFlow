import SwiftUI

struct ClientGeoSettingsView: View {
    @Environment(ClientModel.self) private var model
    let site: Bool
    @State private var editor: ClientGeoSourceDraft?
    @State private var pendingDelete: ClientGeoSourceDraft?
    @State private var updating = false
    @State private var error: String?
    @State private var success = false
    @State private var loadedSources: [NativeGeoDatabase.Source] = []
    private var title: String { site ? "GeoSite" : "GeoIP" }
    private var references: [NativeGeoResources.Reference] {
        ((try? NativeGeoResources.references(model.parsed)) ?? []).filter { $0.site == site }
    }
    private var referenceError: String? {
        do { _ = try NativeGeoResources.references(model.parsed); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        List {
            Section {
                if let referenceError { Text(referenceError).font(.footnote).foregroundStyle(.red) }
                if references.isEmpty {
                    ContentUnavailableView("尚未添加更新地址", systemImage: "globe", description: Text("点击右上角 + 添加 \(title) 数据源。"))
                }
                ForEach(references, id: \.key) { reference in
                    Button { editor = draft(reference) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(site ? reference.key : reference.key.uppercased()).font(.headline)
                                Spacer()
                                Text(reference.format).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(reference.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("来源分类：\(reference.category)").font(.caption).foregroundStyle(.secondary)
                            if let date = lastLoaded(reference) {
                                Text("上次加载：\(date.formatted(.dateTime.month().day().hour().minute()))").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("尚未加载").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .swipeActions(allowsFullSwipe: false) {
                            Button("编辑") { editor = draft(reference) }.tint(.blue)
                            Button("删除", role: .destructive) { pendingDelete = draft(reference) }
                        }
                }
            } header: { Text("更新地址") } footer: {
                Text("分类标识用于分流规则，来源分类用于选择数据库内容。已有配置内的数据会保留。")
            }
            Section {
                Button { Task { await update() } } label: {
                    HStack {
                        Label(updating ? "正在更新…" : "手动更新", systemImage: "arrow.clockwise")
                        Spacer()
                        if updating { ProgressView() }
                    }
                }.disabled(references.isEmpty || model.isBusy || updating)
            } footer: {
                Text("重新下载并校验当前配置引用的外部资源，成功后应用；失败保留原运行版本。")
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { editor = ClientGeoSourceDraft(site: site) } label: { Image(systemName: "plus") }
                .accessibilityLabel("添加 \(title) 数据源").disabled(model.isBusy || updating)
        } }
        .task(id: model.profile?.updatedAt) {
            let directory = model.document.activation.store.directory.appendingPathComponent("runtime-v2", isDirectory: true)
            let sources = await Self.loadSources(in: directory)
            if !Task.isCancelled { loadedSources = sources }
        }
        .sheet(item: $editor) { draft in ClientGeoSourceEditor(site: site, draft: draft) }
        .confirmationDialog("删除这个数据源？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let draft = pendingDelete { Task { await remove(draft) } }; pendingDelete = nil }
        } message: { Text("删除后会重新校验并应用配置。仍被规则引用的数据源无法删除。") }
        .alert("更新完成", isPresented: $success) { Button("好", role: .cancel) {} } message: { Text("数据已通过校验并应用到当前配置。") }
        .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .disabled(model.isBusy && !updating)
    }

    private func draft(_ reference: NativeGeoResources.Reference) -> ClientGeoSourceDraft {
        ClientGeoSourceDraft(site: site, reference: reference, originalValue: (site ? model.parsed.geoSite : model.parsed.geoIP)[reference.key])
    }
    private func lastLoaded(_ reference: NativeGeoResources.Reference) -> Date? {
        loadedSources.filter { $0.url == reference.url.absoluteString && $0.format == reference.format }.map(\.loadedAt).max()
    }
    @concurrent private static func loadSources(in directory: URL) async -> [NativeGeoDatabase.Source] {
        let store = RuntimeBundleStore(directory: directory)
        guard let head = try? store.head(), let bundle = try? store.load(head.current) else { return [] }
        return bundle.geo.sources
    }
    @MainActor private func update() async {
        guard !model.isBusy, !updating else { return }
        updating = true
        defer { updating = false }
        if await model.commit(model.operatingText) { success = true }
        else { error = model.error ?? "更新失败，请稍后重试。"; model.error = nil }
    }
    @MainActor private func remove(_ draft: ClientGeoSourceDraft) async {
        do {
            let text = try draft.applying(to: model.operatingText, site: site, deleting: true)
            if !(await model.commit(text)) { error = model.error ?? "删除失败。"; model.error = nil }
        } catch { self.error = error.localizedDescription }
    }
}

private struct ClientGeoSourceEditor: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let site: Bool
    @State var draft: ClientGeoSourceDraft
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(site ? "分类标识，如 cn、ads" : "分类标识，如 CN、AS64500", text: $draft.key)
                        .disabled(draft.originalValue != nil)
                    TextField("HTTPS 更新地址", text: $draft.source).keyboardType(.URL)
                    Picker("数据格式", selection: $draft.format) {
                        Text(site ? "GeoSite DAT" : "GeoIP DAT").tag(site ? "geosite-dat" : "geoip-dat")
                        Text(site ? "域名文本" : "IPv4 CIDR 文本").tag(site ? "domain" : "cidr")
                    }
                    if draft.format.hasSuffix("-dat") {
                        TextField("来源分类，留空使用分类标识", text: $draft.category)
                    }
                } header: { Text("数据源") } footer: {
                    Text("分类标识应与分流规则中的名称一致。DAT 数据库可通过来源分类选择所需内容。")
                }
                Section {
                    TextField("SHA-256（可选）", text: $draft.checksum).font(.system(.footnote, design: .monospaced))
                } footer: { Text("填写摘要后，只接受匹配的文件；更新数据库时需同步修改摘要。") }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled().clientKeyboardDone()
            .navigationTitle(draft.originalValue == nil ? "添加数据源" : "编辑数据源").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("保存并更新") } }
                        .disabled(saving || model.isBusy || draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .alert("无法保存数据源", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    @MainActor private func save() async {
        guard !saving, !model.isBusy else { return }
        saving = true
        defer { saving = false }
        do {
            let text = try draft.applying(to: model.operatingText, site: site)
            if await model.commit(text) { dismiss() }
            else { error = model.error ?? "保存失败。"; model.error = nil }
        } catch { self.error = error.localizedDescription }
    }
}

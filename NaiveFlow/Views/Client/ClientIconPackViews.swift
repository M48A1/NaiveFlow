import SwiftUI

struct ClientIconPacksView: View {
    @Binding var selectedURL: String
    @Environment(\.dismiss) private var dismiss
    @State private var library = ClientIconPackLibrary()
    @State private var editor: SourceDraft?
    @State private var saving = false

    private struct SourceDraft: Identifiable {
        var id = UUID()
        var packID: UUID?
        var source = ""
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.packs) { pack in
                        NavigationLink {
                            ClientIconPackBrowser(library: library, packID: pack.id) { icon in
                                selectedURL = icon.url
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(pack.name).font(.headline)
                                    Spacer()
                                    if library.updating.contains(pack.id) { ProgressView() }
                                }
                                Text(pack.icons.isEmpty ? "点击加载图标" : "\(pack.icons.count) 个图标").font(.caption).foregroundStyle(.secondary)
                                if let date = pack.updatedAt { Text("更新于 \(date.formatted(.dateTime.month().day().hour().minute()))").font(.caption2).foregroundStyle(.secondary) }
                            }.padding(.vertical, 5)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("更新") { Task { await library.update(id: pack.id) } }.tint(.blue)
                                .disabled(library.updating.contains(pack.id))
                            Button("编辑") { editor = SourceDraft(packID: pack.id, source: pack.source) }.tint(.orange)
                                .disabled(library.updating.contains(pack.id))
                            Button("删除", role: .destructive) { library.remove(pack.id) }.disabled(library.updating.contains(pack.id))
                        }
                    }
                } footer: {
                    Text("左滑图标集可编辑地址、更新或删除。点击图标集浏览并选择图标。")
                }
            }
            .navigationTitle("外部自定义图标集").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { editor = SourceDraft() } label: { Image(systemName: "plus") }.accessibilityLabel("添加图标集") }
            }
            .sheet(item: $editor) { draft in sourceEditor(draft) }
            .alert("图标集操作失败", isPresented: Binding(get: { library.error != nil && editor == nil }, set: { if !$0 { library.error = nil } })) {
                Button("好") { library.error = nil }
            } message: { Text(library.error ?? "") }
        }
    }

    private func sourceEditor(_ initial: SourceDraft) -> some View {
        ClientIconPackSourceEditor(source: initial.source, saving: saving, error: library.error) { source in
            saving = true
            Task {
                let success: Bool
                if let id = initial.packID { success = await library.update(id: id, source: source) }
                else { success = await library.add(source: source) }
                saving = false
                if success { library.error = nil; editor = nil }
            }
        }.presentationDetents([.medium, .large])
    }
}

private struct ClientIconPackSourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var source: String
    var saving: Bool
    var error: String?
    var save: (String) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("图标集 JSON 地址") {
                    TextField("https://example.com/icons.json", text: $source)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle("编辑图标集").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save(source) } label: { if saving { ProgressView() } else { Text("保存并更新") } }
                        .disabled(saving || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

private struct ClientIconPackBrowser: View {
    var library: ClientIconPackLibrary
    let packID: UUID
    var select: (ClientIconPack.Icon) -> Void
    @State private var search = ""
    private var pack: ClientIconPack? { library.pack(packID) }
    private var icons: [ClientIconPack.Icon] {
        (pack?.icons ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 16) {
                ForEach(icons) { icon in
                    Button { select(icon) } label: {
                        VStack(spacing: 7) {
                            AsyncImage(url: URL(string: icon.url)) { image in image.resizable().scaledToFit() }
                                placeholder: { Image(systemName: "photo").foregroundStyle(.secondary) }
                                .frame(width: 44, height: 44)
                            Text(icon.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).frame(minHeight: 86).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(16)
            if library.updating.contains(packID) { ProgressView("正在更新图标集…").padding() }
            else if icons.isEmpty { ContentUnavailableView("没有匹配的图标", systemImage: "photo", description: Text("尝试更新图标集或更改搜索内容。")) }
        }
        .navigationTitle(pack?.name ?? "图标集").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索图标名称")
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("更新") { Task { await library.update(id: packID) } }.disabled(library.updating.contains(packID))
        } }
        .task { if pack?.icons.isEmpty == true { await library.update(id: packID) } }
    }
}

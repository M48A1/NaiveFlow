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
                                Text(pack.icons.isEmpty ? "Tap to Load Icons" : "Icons: \(pack.icons.count)").font(.caption).foregroundStyle(.secondary)
                                if let date = pack.updatedAt { Text("Updated \(date.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "en"))))").font(.caption2).foregroundStyle(.secondary) }
                            }.padding(.vertical, 5)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Update") { Task { await library.update(id: pack.id) } }.tint(.blue)
                                .disabled(library.updating.contains(pack.id))
                            Button("Edit") { editor = SourceDraft(packID: pack.id, source: pack.source) }.tint(.orange)
                                .disabled(library.updating.contains(pack.id))
                            Button("Delete", role: .destructive) { library.remove(pack.id) }.disabled(library.updating.contains(pack.id))
                        }
                    }
                } footer: {
                    Text("Swipe left to edit, update, or delete an icon pack. Open a pack to browse and select an icon.")
                }
            }
            .navigationTitle("Icon Packs").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { editor = SourceDraft() } label: { Image(systemName: "plus") }.accessibilityLabel("Add Icon Pack") }
            }
            .sheet(item: $editor) { draft in sourceEditor(draft) }
            .alert("Icon Pack Operation Failed", isPresented: Binding(get: { library.error != nil && editor == nil }, set: { if !$0 { library.error = nil } })) {
                Button("OK") { library.error = nil }
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
                Section("Icon Pack JSON URL") {
                    TextField("https://example.com/icons.json", text: $source)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle("Edit Icon Pack").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save(source) } label: { if saving { ProgressView() } else { Text("Save and Update") } }
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
            if library.updating.contains(packID) { ProgressView("Updating icon pack…").padding() }
            else if icons.isEmpty { ContentUnavailableView("No Matching Icons", systemImage: "photo", description: Text("Update the icon pack or try a different search.")) }
        }
        .navigationTitle(pack?.name ?? "Icon Pack").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search Icons")
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("Update") { Task { await library.update(id: packID) } }.disabled(library.updating.contains(packID))
        } }
        .task { if pack?.icons.isEmpty == true { await library.update(id: packID) } }
    }
}

import SwiftUI

struct TVClientGroupLabel: View {
    let name: String
    let iconURL: String?

    var body: some View {
        Label {
            Text(name)
        } icon: {
            if let url = ProxyGroupIconURL.parse(iconURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "square.stack.3d.up.fill")
                }
                .frame(width: 36, height: 36)
            } else {
                Image(systemName: "square.stack.3d.up.fill")
            }
        }
    }
}

struct TVClientGroupIconPacksView: View {
    @Binding var iconURL: String
    @State private var library = ClientIconPackLibrary()
    @State private var source = ""

    var body: some View {
        List {
            Section("Icon Packs") {
                ForEach(library.packs) { pack in
                    NavigationLink(pack.name) {
                        TVClientGroupIconPicker(library: library, packID: pack.id, iconURL: $iconURL)
                    }
                }
            }
            Section("Add Icon Pack") {
                TextField("HTTPS Icon Pack JSON URL", text: $source).autocorrectionDisabled()
                Button("Add Icon Pack") {
                    Task { if await library.add(source: source) { source = "" } }
                }
                .disabled(ProxyGroupIconURL.parse(source.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
                          || !library.updating.isEmpty)
            }
            if let error = library.error { Text(error).foregroundStyle(DesignSystem.Colors.error) }
        }
        .navigationTitle("Icon Packs")
    }
}

private struct TVClientGroupIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    let library: ClientIconPackLibrary
    let packID: UUID
    @Binding var iconURL: String
    @State private var search = ""

    var body: some View {
        List {
            TextField("Filter Icons", text: $search)
            Button("Refresh Icon Pack") { Task { await library.update(id: packID) } }
                .disabled(library.updating.contains(packID))
            if library.updating.contains(packID) { ProgressView() }
            if let error = library.error { Text(error).foregroundStyle(DesignSystem.Colors.error) }
            ForEach(icons) { icon in
                Button {
                    iconURL = icon.url
                    dismiss()
                } label: {
                    TVClientGroupLabel(name: icon.name, iconURL: icon.url)
                }
            }
        }
        .navigationTitle(library.pack(packID)?.name ?? "Icon Pack")
        .task {
            if library.pack(packID)?.icons.isEmpty == true { await library.update(id: packID) }
        }
    }

    private var icons: [ClientIconPack.Icon] {
        (library.pack(packID)?.icons ?? []).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        }
    }
}

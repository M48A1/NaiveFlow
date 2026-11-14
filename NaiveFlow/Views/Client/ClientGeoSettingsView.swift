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
                    ContentUnavailableView("No Update Sources", systemImage: "globe", description: Text("Tap + to add a \(title) source."))
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
                            Text("Source category: \(reference.category)").font(.caption).foregroundStyle(.secondary)
                            if let date = lastLoaded(reference) {
                                Text("Last loaded: \(date.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "en"))))").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("Not Loaded").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Edit") { editor = draft(reference) }.tint(.blue)
                            Button("Delete", role: .destructive) { pendingDelete = draft(reference) }
                        }
                }
            } header: { Text("Update Sources") } footer: {
                Text("Tags are used in routing rules. Source categories select database contents. Existing inline data is preserved.")
            }
            Section {
                Button { Task { await update() } } label: {
                    HStack {
                        Label(updating ? "Updating…" : "Update Now", systemImage: "arrow.clockwise")
                        Spacer()
                        if updating { ProgressView() }
                    }
                }.disabled(references.isEmpty || model.isBusy || updating)
            } footer: {
                Text("Download and validate the current profile's external resources before applying. Failed updates preserve the running version.")
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { editor = ClientGeoSourceDraft(site: site) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add \(title) Source").disabled(model.isBusy || updating)
        } }
        .task(id: model.profile?.updatedAt) {
            let directory = model.document.activation.store.directory.appendingPathComponent("runtime-v2", isDirectory: true)
            let sources = await Self.loadSources(in: directory)
            if !Task.isCancelled { loadedSources = sources }
        }
        .sheet(item: $editor) { draft in ClientGeoSourceEditor(site: site, draft: draft) }
        .confirmationDialog("Delete This Source?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let draft = pendingDelete { Task { await remove(draft) } }; pendingDelete = nil }
        } message: { Text("Deleting revalidates and applies the profile. Sources still referenced by rules cannot be deleted.") }
        .alert("Update Complete", isPresented: $success) { Button("OK", role: .cancel) {} } message: { Text("The data was validated and applied to the current profile.") }
        .alert("Operation Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
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
        else { error = model.error ?? "Could not update. Try again later."; model.error = nil }
    }
    @MainActor private func remove(_ draft: ClientGeoSourceDraft) async {
        do {
            let text = try draft.applying(to: model.operatingText, site: site, deleting: true)
            if !(await model.commit(text)) { error = model.error ?? "Could not delete."; model.error = nil }
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
                    TextField(site ? "Tag, e.g. cn or ads" : "Tag, e.g. CN or AS64500", text: $draft.key)
                        .disabled(draft.originalValue != nil)
                    TextField("HTTPS Update URL", text: $draft.source).keyboardType(.URL)
                    Picker("Format", selection: $draft.format) {
                        Text(site ? "GeoSite DAT" : "GeoIP DAT").tag(site ? "geosite-dat" : "geoip-dat")
                        Text(site ? "Domain Text" : "IPv4 CIDR Text").tag(site ? "domain" : "cidr")
                    }
                    if draft.format.hasSuffix("-dat") {
                        TextField("Source Category (Defaults to Tag)", text: $draft.category)
                    }
                } header: { Text("Source") } footer: {
                    Text("The tag must match the name in routing rules. Use the source category to select DAT database contents.")
                }
                Section {
                    TextField("SHA-256 (Optional)", text: $draft.checksum).font(.system(.footnote, design: .monospaced))
                } footer: { Text("When a checksum is set, only matching files are accepted. Update it when the database changes.") }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled().clientKeyboardDone()
            .navigationTitle(draft.originalValue == nil ? "Add Source" : "Edit Source").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("Save and Update") } }
                        .disabled(saving || model.isBusy || draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .alert("Could Not Save Source", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
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
            else { error = model.error ?? "Could not save."; model.error = nil }
        } catch { self.error = error.localizedDescription }
    }
}

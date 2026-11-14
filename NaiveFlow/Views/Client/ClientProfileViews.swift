import SwiftUI
import UniformTypeIdentifiers

struct ClientProfileEditorView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: ClientProfile
    @State private var errors: [ConfigurationDiagnostic] = []
    @State private var errorFocus = UUID()
    @State private var showDiscard = false
    @State private var initialProfile: ClientProfile?

    private var hasUnsavedChanges: Bool { initialProfile.map { $0 != profile } ?? false }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                Form {
                    Section("Profile") {
                        TextField("Profile Name", text: Binding(get: { profile.displayName }, set: { profile.name = $0 }))
                        TextField("Remote URL (Optional, HTTPS)", text: Binding(get: { profile.sourceURL ?? "" }, set: { profile.sourceURL = $0.isEmpty ? nil : $0 }))
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section("Profile Content") {
                        ProfileSourceEditor(text: Binding(get: { profile.text }, set: {
                            profile.text = $0
                            errors = []
                        }), errors: errors, focus: errorFocus)
                            .frame(height: 380)
                            .id("profile-source")
                    }
                    Section {
                        Button("Save and Apply") { Task { await save(apply: true) } }
                            .disabled(model.isBusy || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Save Only") { Task { await save(apply: false) } }
                            .disabled(model.isBusy || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .disabled(model.isBusy)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: errorFocus) { _, _ in
                    if !errors.isEmpty { scroll.scrollTo("profile-source", anchor: .top) }
                }
            }
            .clientKeyboardDone()
            .navigationTitle("Edit Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") {
                    if hasUnsavedChanges { showDiscard = true } else { dismiss() }
                }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { Task { await save(apply: true) } }
                        .disabled(model.isBusy || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .primaryAction) { if model.isBusy { ProgressView() } }
            }
            .onAppear { if initialProfile == nil { initialProfile = profile } }
            .confirmationDialog("Discard Unsaved Changes?", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
            }
            .interactiveDismissDisabled(hasUnsavedChanges || model.isBusy)
            .alert("Could Not Save Profile", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }

    private func save(apply: Bool) async {
        // Preserve even invalid drafts, but never send them to the running tunnel.
        let submitted = profile
        guard await model.saveProfile(submitted, apply: false) else { return }
        initialProfile = submitted
        errors = TextConfigurationPipeline.process(text: submitted.text).diagnostics.errors.sorted
        errorFocus = UUID()
        guard errors.isEmpty else { return }
        if apply {
            guard await model.saveProfile(submitted, apply: true) else { return }
        }
        if profile == submitted { dismiss() }
    }
}

struct ClientProfilesView: View {
    @Environment(ClientModel.self) private var model
    @State private var editing: ClientProfile?
    @State private var pendingDelete: ClientProfile?
    @State private var showHistory = false
    @State private var importingFile = false
    @State private var showURL = false
    @State private var remoteURL = ""
    @State private var downloading = false
    var body: some View {
        List {
            Section {
                ForEach(model.library.profiles) { profile in
                    HStack {
                        Button { Task { await model.activate(profile) } } label: {
                            HStack(spacing: 13) {
                                ClientSectionIcon(symbol: "doc.text")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.displayName).foregroundStyle(.primary)
                                    Text(profile.updatedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.library.selectedID == profile.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                        Menu {
                            Button("Edit / Rename", systemImage: "pencil") { editing = profile }
                            if profile.sourceURL != nil { Button("Update", systemImage: "arrow.clockwise") { Task { await model.updateProfile(profile) } } }
                            Button("Duplicate", systemImage: "doc.on.doc") { editing = model.createProfile(name: profile.name + " Copy", text: profile.text) }
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = profile }.disabled(profile.id == model.library.selectedID)
                        } label: { Image(systemName: "ellipsis.circle").frame(width: 36, height: 40) }
                    }
                }
            } footer: { Text("Tap a profile to apply it. Switch profiles before deleting the current one.") }
            Section {
                Button("New Profile", systemImage: "plus") { editing = model.createProfile() }
                Menu("Import Profile", systemImage: "square.and.arrow.down") {
                    Button("Import from URL", systemImage: "link") { showURL = true }
                    Button("Import from File", systemImage: "folder") { importingFile = true }
                }
                Button("iCloud Drive and Version History") { showHistory = true }
                NavigationLink("Backup and Restore") { ClientBackupView() }
            }
        }
        .navigationTitle("Manage Profiles").navigationBarTitleDisplayMode(.inline)
        .disabled(model.isBusy || downloading)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if downloading { ProgressView() } } }
        .alert("Import Profile from URL", isPresented: $showURL) {
            TextField("https://example.com/config.conf", text: $remoteURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Import") {
                let source = remoteURL
                Task {
                    downloading = true; defer { downloading = false }
                    do {
                        let text = try await model.fetchText(source)
                        editing = model.createProfile(name: URL(string: source)?.deletingPathExtension().lastPathComponent ?? "Remote Profile", text: text, sourceURL: source)
                    } catch { model.report(error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let url = try result.get()
                let text = try model.operations.configurationDocument.read(contentsOf: url)
                editing = model.createProfile(name: url.deletingPathExtension().lastPathComponent, text: text)
            } catch { model.report(error) }
        }
        .sheet(item: $editing) { ClientProfileEditorView(profile: $0) }
        .sheet(isPresented: $showHistory, onDismiss: { model.refresh() }) { ProfileView() }
        .confirmationDialog("Delete This Profile?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let pendingDelete { model.deleteProfile(pendingDelete.id) }; pendingDelete = nil }
        }
    }
}

struct ClientNodesView: View {
    var body: some View { ClientNodeManagerView() }
}

struct ClientNodeSubscriptionsView: View {
    @Environment(ClientModel.self) private var model
    @Environment(SubscriptionStore.self) private var legacySubscriptions
    @Environment(ConfigurationStore.self) private var legacyNodes
    @State private var editing: ClientNodeSubscription?

    var body: some View {
        List {
            Section {
                if (model.profile?.nodeSubscriptions ?? []).isEmpty {
                    ContentUnavailableView("No Subscriptions", systemImage: "tray.2", description: Text("Tap + to add a subscription. Nodes also remain in Manage Nodes and PROXY."))
                }
                ForEach(model.profile?.nodeSubscriptions ?? []) { subscription in
                    NavigationLink { ClientNodeSubscriptionDetailView(id: subscription.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(subscription.name)
                            Text(subscription.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Subscription Groups").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack { ClientSubscriptionUpdateAllButton(); Spacer() }
                .padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("Add Subscription", systemImage: "plus") { editing = ClientNodeSubscription(name: "", url: "") }
        } }
        .sheet(item: $editing) { ClientNodeSubscriptionEditorView(subscription: $0) }
        .task {
            for source in legacySubscriptions.subscriptions {
                guard !(model.profile?.nodeSubscriptions ?? []).contains(where: { $0.url == source.url }) else { continue }
                let names = Set(legacyNodes.configurations(for: source).map(\.name))
                let members = model.nodes.filter { names.contains($0.name) }.map {
                    ClientSubscriptionMember(sourceName: $0.name, name: $0.name, edited: true)
                }
                guard !members.isEmpty else { continue }
                _ = await model.manageResource(.save(.subscription(ClientNodeSubscription(id: source.id, name: source.name, url: source.url, members: members))))
            }
        }
        .disabled(model.isBusy)
    }
}

struct ClientNodeSubscriptionDetailView: View {
    @Environment(ClientModel.self) private var model
    let id: UUID
    @State private var editing: ClientNodeSubscription?
    @State private var editingNode: ProxyConfiguration?
    private var subscription: ClientNodeSubscription? { model.profile?.nodeSubscriptions?.first { $0.id == id } }
    private var nodes: [ProxyConfiguration] {
        (subscription?.members ?? []).compactMap { member in model.nodes.first { $0.name == member.name } }
    }

    var body: some View {
        List {
            Section {
                ForEach(nodes) { node in
                    Button { editingNode = node } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(node.name).foregroundStyle(.primary)
                            Text(node.outboundProtocol.name).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            } footer: { Text("Tap a node to edit its name and configuration. Edited nodes are preserved when the subscription updates. All nodes remain in Manage Nodes and PROXY.") }
        }
        .navigationTitle(subscription?.name ?? "Subscription").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack { ClientSubscriptionUpdateAllButton(ids: [id]); Spacer() }
                .padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = subscription } } }
        .sheet(item: $editing) { ClientNodeSubscriptionEditorView(subscription: $0) }
        .sheet(item: $editingNode) { original in
            ProxyEditorView(configuration: original) { node in Task { await model.saveNode(node, replacing: original.name) } }
        }
        .disabled(model.isBusy)
    }
}

private struct ClientSubscriptionUpdateAllButton: View {
    @Environment(ClientModel.self) private var model
    var ids: Set<UUID>? = nil
    @State private var updating = false

    var body: some View {
        Button { Task {
            updating = true; defer { updating = false }
            _ = await model.prepareSubscriptionUpdate(ids: ids)
        } } label: {
            HStack {
                Label(updating ? "Updating…" : "Update All", systemImage: "arrow.clockwise")
                if updating { ProgressView() }
            }
        }
        .buttonStyle(.bordered).labelStyle(.titleAndIcon)
        .disabled(updating || model.isBusy || !(model.profile?.nodeSubscriptions ?? []).contains { ids?.contains($0.id) ?? true })
    }
}

struct ClientNodeSubscriptionEditorView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var subscription: ClientNodeSubscription
    var onSaved: (() -> Void)? = nil
    @State private var saving = false
    private var exists: Bool { model.profile?.nodeSubscriptions?.contains { $0.id == subscription.id } == true }
    private var valid: Bool {
        guard !subscription.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: subscription.url), url.scheme?.lowercased() == "https", url.host != nil else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Subscription Name", text: $subscription.name)
                    TextField("HTTPS Subscription URL", text: $subscription.url).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Toggle("Remnawave HWID", isOn: $subscription.remnawaveHWIDEnabled).tint(.blue)
                } footer: {
                    Text("Send this device's HWID when importing or updating this subscription. Enable only if required by its provider.")
                }
            }
            .navigationTitle(exists ? "Edit Subscription" : "Add Subscription").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(exists ? "Save" : "Import") { Task {
                        saving = true; defer { saving = false }
                        let request: ClientResourceRequest = exists ? .save(.subscription(subscription)) : .update(.subscription(subscription))
                        let saved = await model.manageResource(request)
                        if saved { dismiss(); onSaved?() }
                    } }.disabled(!valid || saving || model.isBusy)
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .alert("Subscription Operation Failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

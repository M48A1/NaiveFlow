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
                Section("Profile") {
                    TextField("Profile Name", text: Binding(get: { profile.displayName }, set: { profile.name = $0 }))
                    TextField("Remote URL (Optional, HTTPS)", text: Binding(get: { profile.sourceURL ?? "" }, set: { profile.sourceURL = $0.isEmpty ? nil : $0 }))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Profile Content") {
                    TextEditor(text: $profile.text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 340).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityLabel("Profile Content")
                }
                if let preview {
                    Section("Validation") {
                        LabeledContent("Nodes", value: "\(preview.compiled.proxies.count)")
                        LabeledContent("Groups", value: "\(preview.parsed.proxyGroups.count)")
                        LabeledContent("Rules", value: "\(preview.compiled.orderedRules.count)")
                        ForEach(Array(preview.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text(diagnostic.message).font(.caption).foregroundStyle(diagnostic.severity == .error ? Color.red : .orange)
                        }
                    }
                }
                Section {
                    Button("Save and Apply") { Task { if await model.saveProfile(profile, apply: true) { dismiss() } } }
                        .disabled(model.isBusy || preview?.isActivatable != true || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Save Only") { Task { if await model.saveProfile(profile, apply: false) { dismiss() } } }
                        .disabled(model.isBusy || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .clientKeyboardDone()
            .navigationTitle("Edit Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") {
                    if profile.text != initialText { showDiscard = true } else { dismiss() }
                } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { Task { if await model.saveProfile(profile, apply: true) { dismiss() } } }
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
            .confirmationDialog("Discard Unsaved Changes?", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
            }
            .interactiveDismissDisabled(profile.text != initialText)
            .alert("Could Not Save Profile", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
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
                Button("iCloud Drive and Version History") { showHistory = true }
            }
        }
        .navigationTitle("Manage Profiles").navigationBarTitleDisplayMode(.inline)
        .disabled(model.isBusy)
        .sheet(item: $editing) { ClientProfileEditorView(profile: $0) }
        .sheet(isPresented: $showHistory, onDismiss: { model.refresh() }) { ProfileView() }
        .confirmationDialog("Delete This Profile?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let pendingDelete { model.deleteProfile(pendingDelete.id) }; pendingDelete = nil }
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
    @State private var subscriptionToImport: ClientNodeSubscription?
    @State private var importingFile = false

    var body: some View {
        List {
            Section {
                NavigationLink("Subscription Groups") { ClientNodeSubscriptionsView() }
            }
            Section {
                if model.nodes.isEmpty {
                    ContentUnavailableView("No Nodes", systemImage: "network", description: Text("Tap + to add a node or import a node list."))
                }
                ForEach(model.nodes) { node in
                    ClientNodeRow(node: node, selected: model.selectedNodeName == node.name, latency: latency.latencyResults[node.id]) {
                        Task { await model.selectNode(node.name) }
                    }.listRowInsets(EdgeInsets())
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editNode = node; showEditor = true }
                        Button("Test Latency", systemImage: "bolt") { latency.testLatency(for: node, transport: tunnel) }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteName = node.name }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleteName = node.name }
                        Button("Edit") { editNode = node; showEditor = true }.tint(.blue)
                    }
                }
                .onMove { from, to in
                    var names = model.nodes.map(\.name)
                    names.move(fromOffsets: from, toOffset: to)
                    Task { await model.reorderNodes(names) }
                }
            }
            Section {
                Button("Test All Nodes", systemImage: "bolt.fill") { latency.testLatencies(for: model.nodes, transport: tunnel) }.disabled(model.nodes.isEmpty)
                Button("Sort by Latency", systemImage: "arrow.up.arrow.down") {
                    let names = model.nodes.sorted { ms($0) < ms($1) }.map(\.name)
                    Task { await model.reorderNodes(names) }
                }.disabled(model.nodes.isEmpty)
            }
        }
        .navigationTitle("Manage Nodes").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add Node", systemImage: "plus") { editNode = nil; showEditor = true }
                    Button("Import from URL", systemImage: "link") { subscriptionToImport = ClientNodeSubscription(name: "", url: "") }
                    Button("Import from Profile File", systemImage: "doc") { importingFile = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showEditor) { ProxyEditorView(configuration: editNode) { node in Task { await model.saveNode(node, replacing: editNode?.name) } } }
        .confirmationDialog("Delete Node?", isPresented: Binding(get: { deleteName != nil }, set: { if !$0 { deleteName = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let deleteName { Task { await model.deleteNode(deleteName) } }; deleteName = nil }
        }
        .sheet(item: $subscriptionToImport) { ClientNodeSubscriptionEditorView(subscription: $0) }
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
    @State private var complete = false

    var body: some View {
        Button { Task {
            updating = true; defer { updating = false }
            complete = await model.manageResource(.update(.subscriptions(ids: ids)))
        } } label: {
            HStack {
                Label(updating ? "Updating…" : "Update All", systemImage: "arrow.clockwise")
                if updating { ProgressView() }
            }
        }
        .buttonStyle(.bordered).labelStyle(.titleAndIcon)
        .disabled(updating || model.isBusy || !(model.profile?.nodeSubscriptions ?? []).contains { ids?.contains($0.id) ?? true })
        .alert("Update Complete", isPresented: $complete) { Button("OK", role: .cancel) {} } message: {
            Text("The subscription nodes were updated. Manual edits were preserved.")
        }
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

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
        .overlay { if model.nodes.isEmpty { ContentUnavailableView("No Nodes", systemImage: "network", description: Text("Tap + to add a node or import a node list.")) } }
        .navigationTitle("Manage Nodes").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add Node", systemImage: "plus") { editNode = nil; showEditor = true }
                    Button("Import from URL", systemImage: "link") { importingURL = true }
                    Button("Import from Profile File", systemImage: "doc") { importingFile = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showEditor) { ProxyEditorView(configuration: editNode) { node in Task { await model.saveNode(node, replacing: editNode?.name) } } }
        .confirmationDialog("Delete Node?", isPresented: Binding(get: { deleteName != nil }, set: { if !$0 { deleteName = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let deleteName { Task { await model.deleteNode(deleteName) } }; deleteName = nil }
        }
        .alert("Import Nodes from URL", isPresented: $importingURL) {
            TextField("HTTPS Subscription or Profile URL", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Import") { Task { do { let source = try await model.fetchText(url); try await importNodes(source) } catch { model.report(error) } } }
            Button("Cancel", role: .cancel) {}
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

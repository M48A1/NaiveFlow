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
                    Button { editing = module } label: {
                        HStack(spacing: 12) {
                            ClientSectionIcon(symbol: "puzzlepiece.extension.fill")
                            VStack(alignment: .leading, spacing: 5) {
                                Text(module.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text(module.summary.isEmpty ? module.format.displayName : module.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, 5)
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = module }
                        if module.sourceURL != nil { Button("Update", systemImage: "arrow.clockwise") { Task { await model.refreshModule(module) } } }
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = module }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { pendingDelete = module }
                        Button("Edit", systemImage: "pencil") { editing = module }.tint(.blue)
                        Button("Update", systemImage: "arrow.clockwise") { Task { await model.refreshModule(module) } }
                            .tint(.orange).disabled(module.sourceURL?.isEmpty != false)
                    }
                }
            } footer: { Text("Module rules are saved and applied with the current profile. Configure MITM certificate trust and hostnames before enabling modules.") }
        }
        .overlay {
            if model.modules.isEmpty {
                ContentUnavailableView("No Modules", systemImage: "puzzlepiece.extension")
            }
        }
        .navigationTitle("Modules").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Module", systemImage: "plus") {
                    editing = ClientModule(name: "New Module", summary: "", source: "", format: .surge)
                }
            }
        }
        .sheet(item: $editing) { ClientModuleEditorView(module: $0) }
        .confirmationDialog("Delete Module and Its Rules?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let pendingDelete { Task { await model.deleteModule(pendingDelete) } }; pendingDelete = nil }
        }
        .disabled(model.isBusy)
    }
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
                Section("Module Information") {
                    TextField("Module Name", text: $module.name)
                    TextField("Description", text: $module.summary, axis: .vertical)
                    Picker("Format", selection: $module.format) { ForEach(ModuleFormat.allCases) { Text($0.displayName).tag($0) } }
                    Toggle("Enable Module", isOn: $module.enabled).tint(.blue)
                }
                Section("Import and Update") {
                    TextField("Remote URL (HTTPS)", text: Binding(get: { module.sourceURL ?? "" }, set: { module.sourceURL = $0.isEmpty ? nil : $0 }))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Load from URL", systemImage: "arrow.down.circle") { Task {
                        downloading = true; defer { downloading = false }
                        do { module.source = try await model.fetchText(module.sourceURL ?? "") } catch { model.report(error) }
                    } }.disabled(module.sourceURL?.isEmpty != false)
                    Button("Import Local File", systemImage: "folder") { importingFile = true }
                }
                Section("Module Content") {
                    TextEditor(text: $module.source).font(.system(size: 12, design: .monospaced)).frame(minHeight: 260)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Module Content")
                }
                Section {
                    Button("Save and Apply") { Task {
                        downloading = true; defer { downloading = false }
                        if await model.saveModule(module) { dismiss() }
                    } }.disabled(module.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || module.name.isEmpty)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .clientKeyboardDone()
            .disabled(downloading || model.isBusy)
            .interactiveDismissDisabled(downloading || model.isBusy)
            .navigationTitle("Edit Module").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(downloading || model.isBusy) }
                ToolbarItem(placement: .primaryAction) { if downloading || model.isBusy { ProgressView() } }
            }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.plainText, .data]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    module.source = try model.operations.configurationDocument.read(contentsOf: url)
                    if url.pathExtension.lowercased() == "snippet" { module.format = .quantumultX }
                    else if url.pathExtension.lowercased() == "sgmodule" { module.format = .surge }
                    if module.name == "New Module" { module.name = url.deletingPathExtension().lastPathComponent }
                } catch { model.report(error) }
            }
            .alert("Module Operation Failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}

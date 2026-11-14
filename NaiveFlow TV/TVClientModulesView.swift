import SwiftUI

struct TVClientModulesView: View {
    @Environment(ClientModel.self) private var model
    @State private var pendingDelete: ClientModule?

    var body: some View {
        List {
            NavigationLink("Add Module") {
                TVClientModuleEditor(module: ClientModule(name: "", summary: "", source: "", format: .surge))
            }
            ForEach(model.modules) { module in
                NavigationLink(module.name) { TVClientModuleEditor(module: module) }
                    .contextMenu {
                        if module.sourceURL != nil {
                            Button("Update") {
                                Task { _ = await model.manageResource(.update(.modules(ids: [module.id]))) }
                            }
                        }
                        Button("Delete", role: .destructive) { pendingDelete = module }
                    }
            }
        }
        .navigationTitle("Modules")
        .confirmationDialog("Delete Module and Its Rules?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { module in
            Button("Delete", role: .destructive) { Task { await model.deleteModule(module) } }
        }
        .disabled(model.isBusy)
    }
}

private struct TVClientModuleEditor: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var module: ClientModule
    @State private var downloading = false

    var body: some View {
        Form {
            Section("Module") {
                TextField("Module Name", text: $module.name)
                TextField("Description", text: $module.summary)
                Picker("Format", selection: $module.format) {
                    ForEach(ModuleFormat.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Enabled", isOn: $module.enabled)
            }
            Section("Source") {
                TextField("Remote URL (HTTPS)", text: Binding(
                    get: { module.sourceURL ?? "" },
                    set: { module.sourceURL = $0.isEmpty ? nil : $0 }
                )).autocorrectionDisabled()
                Button("Load from URL") { Task { await download() } }
                    .disabled(module.sourceURL == nil)
                TextField("Module Content", text: $module.source, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            }
            Button("Save and Apply") {
                Task { if await model.saveModule(module) { dismiss() } }
            }
            .disabled(module.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || module.source.isEmpty)
        }
        .navigationTitle("Edit Module")
        .disabled(model.isBusy || downloading)
    }

    private func download() async {
        guard let source = module.sourceURL else { return }
        downloading = true
        defer { downloading = false }
        do { module.source = try await model.fetchText(source) }
        catch { model.report(error) }
    }
}

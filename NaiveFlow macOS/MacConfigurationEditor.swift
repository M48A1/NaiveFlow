import SwiftUI

struct MacConfigurationEditor: View {
    @State private var model: ProfileEditorModel

    init(operations: Operations) {
        _model = State(initialValue: ProfileEditorModel(document: operations.configurationDocument))
    }

    var body: some View {
        Form {
            Section("Configuration File") {
                TextEditor(text: Binding(get: { model.text }, set: { model.edit($0) }))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 280)
                Button("Apply Configuration") { Task { await model.apply() } }
                    .disabled(!model.canApply)
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                if let message = model.statusMessage { Text(message).foregroundStyle(.secondary) }
                ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { entry in
                    Text(entry.element.message)
                }
            }
            ConfigurationDriveSection(model: model)
        }
        .formStyle(.grouped)
        .task { model.load() }
    }
}

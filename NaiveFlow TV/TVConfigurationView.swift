import SwiftUI

struct TVConfigurationView: View {
    @State private var model: ProfileEditorModel

    init(container: AppContainer) {
        _model = State(initialValue: ProfileEditorModel(document: Operations(container: container).configurationDocument))
    }

    var body: some View {
        Form {
            Section("Configuration") {
                TextField("Configuration", text: Binding(get: { model.text }, set: { model.edit($0) }), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
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
        .task { model.load() }
    }
}

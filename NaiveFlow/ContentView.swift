import SwiftUI

struct ContentView: View {
    @Environment(DeepLinkManager.self) private var deepLinkManager
    @State private var pendingLink: String?
    @State private var showImport = false

    var body: some View {
        HomeView()
            .onChange(of: deepLinkManager.url, initial: true) { _, value in
                guard let value else { return }
                pendingLink = value
                deepLinkManager.url = nil
                showImport = true
            }
            .sheet(isPresented: $showImport) { ClientNodeImportView(source: pendingLink ?? "") }
            .onOpenURL { deepLinkManager.handle(url: $0) }
    }
}

struct ClientNodeImportView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var source: String
    @State private var loading = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Node Links or HTTPS Subscription") {
                    TextEditor(text: $source).frame(minHeight: 150).font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("Import into Current Profile") { Task {
                    loading = true; defer { loading = false }
                    do {
                        let text = source.hasPrefix("https://") ? try await model.fetchText(source) : source
                        if try await model.importNodes(text) { dismiss() }
                    } catch { model.report(error) }
                } }.disabled(loading || model.isBusy || source.isEmpty)
            }
            .navigationTitle("Import Nodes").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Import Failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}

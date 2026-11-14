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
            .sheet(isPresented: $showImport) { ClientNodeImportView(source: pendingLink ?? "").clientEditorWindow() }
            .onOpenURL { deepLinkManager.handle(url: $0) }
    }
}

struct ClientNodeImportView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var source: String
    @State private var loading = false
    @State private var subscriptionDraft: ClientNodeSubscription?
    var body: some View {
        NavigationStack {
            ClientForm {
                Section("Node Links or HTTPS Subscription") {
                    TextEditor(text: $source).frame(minHeight: 150).designText(.code)
                        .clientNoAutocapitalization().autocorrectionDisabled()
                }
                Button("Import into Current Profile") { Task {
                    loading = true; defer { loading = false }
                    do {
                        if URL(string: source)?.scheme?.lowercased() == "https" {
                            if let existing = model.profile?.nodeSubscriptions?.first(where: { $0.url == source }) {
                                if await model.manageResource(.update(.subscription(existing))) { dismiss() }
                            } else {
                                subscriptionDraft = ClientNodeSubscription(name: URL(string: source)?.host ?? "Subscription", url: source)
                            }
                        } else if try await model.importNodes(source) { dismiss() }
                    } catch { model.report(error) }
                } }.disabled(loading || model.isBusy || source.isEmpty)
            }
            .navigationTitle("Import Nodes").clientInlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $subscriptionDraft) { subscription in
                ClientNodeSubscriptionEditorView(subscription: subscription, onSaved: { dismiss() })
            }
            .alert("Import Failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}

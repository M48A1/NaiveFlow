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
                Section("节点链接或 HTTPS 订阅") {
                    TextEditor(text: $source).frame(minHeight: 150).font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("导入到当前配置") { Task {
                    loading = true; defer { loading = false }
                    do {
                        let text = source.hasPrefix("https://") ? try await model.fetchText(source) : source
                        if try await model.importNodes(text) { dismiss() }
                    } catch { model.report(error) }
                } }.disabled(loading || model.isBusy || source.isEmpty)
            }
            .navigationTitle("导入节点").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .alert("无法导入", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}

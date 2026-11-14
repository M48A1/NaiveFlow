import SwiftUI

struct ClientDiagnosticsView: View {
    @Environment(ClientModel.self) private var model
    @State private var diagnostics = ClientConnectionDiagnostics()
    @State private var nodeName = ""
    @State private var target = LatencyTestSettings.load().effective.url
    @State private var inputError: String?
    var body: some View {
        ClientForm {
            Section {
                Picker("Node", selection: $nodeName) { ForEach(model.nodes) { Text($0.name).tag($0.name) } }
                TextField("HTTP or HTTPS Test URL", text: $target)
#if !os(tvOS)
                    .clientKeyboardType(.URL).clientNoAutocapitalization()
#endif
                    .autocorrectionDisabled()
                Button("Run Diagnostics") {
                    guard let node = model.nodes.first(where: { $0.name == nodeName }), let endpoint = LatencyTarget(url: target) else {
                        inputError = "Select a node and enter a valid HTTP or HTTPS URL."; return
                    }
                    inputError = nil; diagnostics.start(node: node, target: endpoint)
                }.disabled(diagnostics.isRunning || model.nodes.isEmpty)
                if diagnostics.isRunning { Button("Cancel", role: .cancel) { diagnostics.cancel() } }
            } header: { Text("Connection") } footer: { Text("Makes test connections from this app using the chosen node and its certificate settings. It does not change your selected node or test other apps' VPN routing. Insecure certificate exceptions remain in effect.") }
            if let inputError { Text(inputError).foregroundStyle(DesignSystem.Colors.error) }
            ForEach(diagnostics.steps) { step in
                Section(step.title) {
                    HStack {
                        if step.state == .running { ProgressView() }
                        else { Image(systemName: icon(step.state)).foregroundStyle(color(step.state)) }
                        Text(step.detail.isEmpty ? "Waiting" : step.detail)
#if !os(tvOS)
                            .textSelection(.enabled)
#endif
                    }
                }
            }
        }
        .navigationTitle("Connection Diagnostics")
#if !os(tvOS)
        .clientInlineTitle()
#endif
        .onAppear { if nodeName.isEmpty { nodeName = model.nodes.first { $0.name == model.selectedNodeName }?.name ?? model.nodes.first?.name ?? "" } }
        .onDisappear { diagnostics.cancel() }
    }
    private func icon(_ state: ClientConnectionDiagnostics.Step.State) -> String {
        switch state { case .passed: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .skipped: "minus.circle"; default: "circle" }
    }
    private func color(_ state: ClientConnectionDiagnostics.Step.State) -> Color {
        switch state { case .passed: .green; case .failed: .red; default: .secondary }
    }
}

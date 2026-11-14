import SwiftUI

struct ClientLatencySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TunnelController.self) private var tunnel
    @State private var settings = LatencyTestSettings.load()
    @State private var customURL = false
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                Picker("Test Address", selection: $customURL) {
                    Text("Apple (Default)").tag(false)
                    Text("Custom URL").tag(true)
                }
                if customURL {
                    TextField("https://example.com/generate_204", text: $settings.url)
#if !os(tvOS)
                        .clientKeyboardType(.URL)
#endif
                        .accessibilityLabel("Latency Test URL")
                } else {
                    Text(LatencyTestSettings.defaultURL).foregroundStyle(.secondary)
                }
            } header: { Text("Test Address") } footer: {
                Text("Measures the time for an HTTP or HTTPS response through each node. This tests latency, not download speed.")
            }
            Section {
#if os(tvOS)
                Picker("Timeout (seconds)", selection: $settings.timeoutSeconds) {
                    ForEach(Array(LatencyTestSettings.timeoutRange), id: \.self) { Text(String($0)).tag($0) }
                }
                Picker("Concurrent Tests", selection: $settings.concurrency) {
                    ForEach(Array(LatencyTestSettings.concurrencyRange), id: \.self) { Text(String($0)).tag($0) }
                }
#else
                Stepper("Timeout: \(settings.timeoutSeconds) seconds", value: $settings.timeoutSeconds, in: LatencyTestSettings.timeoutRange)
                Stepper("Concurrent Tests: \(settings.concurrency)", value: $settings.concurrency, in: LatencyTestSettings.concurrencyRange)
#endif
            } header: { Text("Test Options") } footer: {
                Text("Applies to manual tests and background policy-group tests. Groups can override the test address in their configuration and keep their own test intervals. Concurrent Tests limits total background probes across groups.")
            }
            Section {
                Button("Save") { Task { await save() } }
            }
        }
        .navigationTitle("Latency Test")
        .disabled(saving)
#if !os(tvOS)
        .clientInlineTitle()
        .clientNoAutocapitalization()
        .clientKeyboardDone()
#endif
        .autocorrectionDisabled()
        .task { customURL = settings.url != LatencyTestSettings.defaultURL }
        .alert("Latency Test Settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        var saved = settings
        saved.url = customURL ? settings.url.trimmingCharacters(in: .whitespacesAndNewlines) : LatencyTestSettings.defaultURL
        guard saved.isValid else {
            error = "Enter a valid HTTP or HTTPS URL without a username, password, or fragment."
            return
        }
        do {
            try saved.save()
            if tunnel.isTunnelActive {
                guard let response = await tunnel.send(.updateLatencyTestSettings(saved)),
                      (try? JSONDecoder().decode(Bool.self, from: response)) == true else {
                    error = "Settings were saved. Reconnect the VPN to update background policy-group tests."
                    return
                }
            }
            dismiss()
        }
        catch { self.error = error.localizedDescription }
    }
}

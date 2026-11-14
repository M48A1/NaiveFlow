import SwiftUI

struct ClientLatencySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = LatencyTestSettings.load()
    @State private var customURL = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("Test Address", selection: $customURL) {
                    Text("Apple (Default)").tag(false)
                    Text("Custom URL").tag(true)
                }
                if customURL {
                    TextField("https://example.com/generate_204", text: $settings.url)
                        .keyboardType(.URL)
                        .accessibilityLabel("Latency Test URL")
                } else {
                    Text(LatencyTestSettings.defaultURL).foregroundStyle(.secondary)
                }
            } header: { Text("Test Address") } footer: {
                Text("Measures the time for an HTTP or HTTPS response through each node. This tests latency, not download speed.")
            }
            Section {
                Stepper("Timeout: \(settings.timeoutSeconds) seconds", value: $settings.timeoutSeconds, in: LatencyTestSettings.timeoutRange)
                Stepper("Concurrent Tests: \(settings.concurrency)", value: $settings.concurrency, in: LatencyTestSettings.concurrencyRange)
            } header: { Text("Test Options") } footer: {
                Text("Applies to manual node and chain tests, including automatic selection on the Home screen. Policy groups use their own configuration.")
            }
            Section {
                Button("Save") { save() }
            }
        }
        .navigationTitle("Latency Test")
        .navigationBarTitleDisplayMode(.inline)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .clientKeyboardDone()
        .task { customURL = settings.url != LatencyTestSettings.defaultURL }
        .alert("Could Not Save Settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save() {
        var saved = settings
        saved.url = customURL ? settings.url.trimmingCharacters(in: .whitespacesAndNewlines) : LatencyTestSettings.defaultURL
        guard saved.isValid else {
            error = "Enter a valid HTTP or HTTPS URL without a username, password, or fragment."
            return
        }
        do { try saved.save(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

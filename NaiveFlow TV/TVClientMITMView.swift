import SwiftUI

struct TVClientMITMView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var certificate = MITMCertificateController()
    @State private var confirmRegenerate = false
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Toggle("Enable MITM", isOn: Binding(
                get: { model.parsed.mitm.bool("enable") ?? model.parsed.general.bool("mitm") ?? false },
                set: { enabled in
                    Task { await model.setSetting("enable", value: enabled ? "true" : "false", section: .mitm) }
                }
            ))
            .disabled(model.isBusy)

            Section("Root Certificate") {
                LabeledContent("Status", value: status)
                if !certificate.hasCA {
                    Button("Generate Certificate") {
                        do { try certificate.ensureCA() }
                        catch { model.report(error) }
                    }
                } else {
                    Button("Regenerate Certificate") { confirmRegenerate = true }
                    Button("Delete Certificate", role: .destructive) { confirmDelete = true }
                }
                Button("Refresh Trust Status") { certificate.refresh() }
            }
        }
        .navigationTitle("MITM")
        .alert("Regenerate Certificate?", isPresented: $confirmRegenerate) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) {
                do { try certificate.regenerate() }
                catch { model.report(error) }
            }
        } message: {
            Text("The replacement certificate requires a new trust setup.")
        }
        .alert("Delete Certificate?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { certificate.delete() }
        } message: {
            Text("Generate and trust a new certificate before using MITM again.")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { certificate.refresh() }
        }
    }

    private var status: String {
        guard certificate.hasCA else { return String(localized: "No Certificate") }
        return certificate.isTrusted ? String(localized: "Trusted") : String(localized: "Not Trusted")
    }
}

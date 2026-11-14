import SwiftUI

struct TVClientMITMView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var certificate = MITMCertificateController()
    @State private var confirmRegenerate = false
    @State private var confirmDelete = false

    private var certificatePKCS12: String? { model.parsed.mitm[MITMPKCS12.configurationKey] }

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
                if let name = certificate.certificateName { LabeledContent("Certificate", value: name) }
                if let fingerprint = certificate.fingerprint { LabeledContent("SHA-256", value: fingerprint) }
                LabeledContent("Status", value: status)
                if certificate.hasCA && !certificate.isTrusted {
                    Text("Install and trust this root CA on Apple TV using a configuration profile.")
                }
                if !certificate.hasCA {
                    Button("Generate Certificate") {
                        Task { await generateCertificate() }
                    }
                } else {
                    Button("Regenerate Certificate") { confirmRegenerate = true }
                    Button("Delete Certificate", role: .destructive) { confirmDelete = true }
                }
                Button("Refresh Trust Status") { certificate.refresh(certificatePKCS12) }
            }
            .disabled(model.isBusy)
        }
        .navigationTitle("MITM")
        .alert("Regenerate Certificate?", isPresented: $confirmRegenerate) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) {
                Task { await generateCertificate() }
            }
        } message: {
            Text("The replacement certificate requires a new trust setup.")
        }
        .alert("Delete Certificate?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    let hadEmbeddedCertificate = certificatePKCS12 != nil
                    let current = ClientDocumentEditing.set(model.operatingText, section: .mitm,
                                                            key: MITMPKCS12.configurationKey, value: nil)
                    let disabled = ClientDocumentEditing.set(current, section: .mitm, key: "enable", value: "false")
                    if await model.commit(disabled), !hadEmbeddedCertificate { certificate.deleteLegacyCertificate() }
                    certificate.refresh(certificatePKCS12)
                }
            }
        } message: {
            Text("Generate and trust a new certificate before using MITM again.")
        }
        .onChange(of: certificatePKCS12, initial: true) { _, value in certificate.refresh(value) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { certificate.refresh(certificatePKCS12) }
        }
    }

    private func generateCertificate() async {
        do {
            let value = try MITMPKCS12.create().base64EncodedString()
            let text = ClientDocumentEditing.set(model.operatingText, section: .mitm, key: MITMPKCS12.configurationKey, value: value)
            _ = await model.commit(text)
        } catch { model.report(error) }
    }

    private var status: String {
        if certificate.isInvalid { return String(localized: "Invalid CA Identity") }
        guard certificate.hasCA else { return String(localized: "No Certificate") }
        return certificate.isTrusted ? String(localized: "Trusted") : String(localized: "Not Trusted")
    }
}

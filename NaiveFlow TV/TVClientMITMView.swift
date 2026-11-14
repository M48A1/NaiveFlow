import SwiftUI

struct TVClientMITMView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var certificate = MITMCertificateController()

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
                }
                Button("Refresh Trust Status") { certificate.refresh() }
            }
        }
        .navigationTitle("MITM")
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { certificate.refresh() }
        }
    }

    private var status: String {
        guard certificate.hasCA else { return String(localized: "No Certificate") }
        return certificate.isTrusted ? String(localized: "Trusted") : String(localized: "Not Trusted")
    }
}

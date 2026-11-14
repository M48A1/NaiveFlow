//
//  MITMCertificateView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/3/26.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

struct MITMCertificateView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var controller = MITMCertificateController()
    var editor: ProfileEditorModel? = nil

    private var certificatePKCS12: String? {
        if let editor {
            return editor.preview?.parsed.mitm[MITMPKCS12.configurationKey]
        }
        return model.parsed.mitm[MITMPKCS12.configurationKey]
    }

    private var isBusy: Bool { model.isBusy || (editor?.isApplying ?? false) }

#if os(iOS)
    @State private var exportedFile: URL?
#endif
    @State private var showRegenerateConfirm = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        ClientForm {
            Section {
                HStack {
                    Image("certificate")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 60)
                    VStack(alignment: .leading) {
                        HStack {
                            Image(systemName: badgeIcon)
                                .foregroundStyle(badgeColor)
                                .animation(.default, value: badgeIcon)
                                .animation(.default, value: badgeColor)
                            Text(badgeTitle)
                                .designText(.contentTitle)
                                .animation(.default, value: badgeTitle)
                        }
                        if let fingerprint = controller.fingerprint {
                            Text(fingerprint)
                                .designText(.micro, design: .monospaced)
                                .textSelection(.enabled)
                        }
                        Text(badgeSubtitle)
                            .designText(.caption)
                            .foregroundStyle(DesignSystem.Colors.secondaryText)
                            .animation(.default, value: badgeSubtitle)
                    }
                }
                .frame(minHeight: 80)
            }

            Section {
                Toggle("Enable MITM", isOn: Binding(
                    get: {
                        let parsed = editor?.preview?.parsed ?? model.parsed
                        return parsed.mitm.bool("enable") ?? parsed.general.bool("mitm") ?? false
                    },
                    set: { enabled in Task { await updateMITM("enable", value: enabled ? "true" : "false") } }
                )).tint(DesignSystem.Colors.accent)
            }
            if controller.hasCA {
                Section {
                    Button { installProfile() } label: {
                        HStack {
                            TextWithColorfulIcon(title: "Install Certificate", systemName: "square.and.arrow.down", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }

                Section {
                    Button {
                        if let der = controller.certificateData() { export(der, fileExtension: "cer") }
                    } label: {
                        Text("Export Certificate (.cer)")
                    }

                    if let value = certificatePKCS12, let data = Data(base64Encoded: value) {
                        Button("Export Certificate and Private Key (.p12)") { export(data, fileExtension: "p12") }
                    }

                    Button {
                        showRegenerateConfirm = true
                    } label: {
                        Text("Regenerate Certificate")
                    }

                    if editor == nil || certificatePKCS12 != nil {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("Delete Certificate")
                        }
                    }
                }
            } else {
                Section {
                    Button {
                        Task { await generateCertificate() }
                    } label: {
                        Label("Generate Certificate", systemImage: "plus")
                    }
                }
            }
        }
        .disabled(isBusy)
        .navigationTitle("MITM")
        .clientInlineTitle()
        .alert("Regenerate Certificate", isPresented: $showRegenerateConfirm) {
            Button("Regenerate", role: .destructive) {
                Task { await generateCertificate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any previously installed MITM profile will stop working until you re-install the new certificate.")
        }
        .alert("Delete Certificate", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    let hadEmbeddedCertificate = certificatePKCS12 != nil
                    let updated = await updateMITM(MITMPKCS12.configurationKey, value: nil, disableMITM: true)
                    if updated && !hadEmbeddedCertificate && editor == nil { controller.deleteLegacyCertificate() }
                    controller.refresh(certificatePKCS12)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to regenerate a certificate to use MITM again.")
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
#if os(iOS)
        .sheet(isPresented: Binding(get: { exportedFile != nil }, set: { if !$0 {
            if let exportedFile { try? FileManager.default.removeItem(at: exportedFile.deletingLastPathComponent()) }
            exportedFile = nil
        } })) {
            if let exportedFile { ShareSheet(items: [exportedFile]) }
        }
#endif
        .onChange(of: certificatePKCS12, initial: true) { _, value in
            controller.refresh(value)
        }
#if os(iOS)
        .onDisappear {
            Task { await MITMProfileServer.shared.stop() }
        }
#endif
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                controller.refresh(certificatePKCS12)
            }
        }
    }

    // MARK: - Status badge

    private var badgeIcon: String {
        if !controller.hasCA { return "xmark.circle.fill" }
        return controller.isTrusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var badgeColor: Color {
        if !controller.hasCA { return .red }
        return controller.isTrusted ? .green : .orange
    }

    private var badgeTitle: String {
        if !controller.hasCA { return String(localized: "No Certificate") }
        return controller.certificateName ?? String(localized: "Root Certificate")
    }

    private var badgeSubtitle: String {
        if !controller.hasCA {
            return controller.isInvalid ? String(localized: "The configuration contains an invalid CA identity.")
                : String(localized: "Generate a certificate to begin.")
        }
        if controller.isTrusted { return String(localized: "System Trusted") }
#if os(macOS)
        return String(localized: "Open the certificate in Keychain Access, then set its trust for SSL.")
#else
        return String(localized: "Install the profile and trust in Settings to use MITM.")
#endif
    }

    private func generateCertificate() async {
        do {
            let value = try MITMPKCS12.create().base64EncodedString()
            _ = await updateMITM(MITMPKCS12.configurationKey, value: value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func updateMITM(_ key: String, value: String?, disableMITM: Bool = false) async -> Bool {
        let current = editor?.text ?? model.operatingText
        var text = ClientDocumentEditing.set(current, section: .mitm, key: key, value: value)
        if disableMITM { text = ClientDocumentEditing.set(text, section: .mitm, key: "enable", value: "false") }
        if let editor {
            do { try editor.saveEditedDraft(text) }
            catch { errorMessage = error.localizedDescription; return false }
            return true
        }
        let committed = await model.commit(text)
        if !committed { errorMessage = model.error }
        return committed
    }

    private func export(_ data: Data, fileExtension: String) {
#if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NaiveFlowMITMRoot.\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
#else
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent("NaiveFlowMITMRoot.\(fileExtension)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportedFile = url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            errorMessage = error.localizedDescription
        }
#endif
    }

    /// Profile install requires a URL; serve the .mobileconfig over a one-shot 127.0.0.1 HTTP server.
    private func installProfile() {
#if os(macOS)
        guard let url = certificateURL(), NSWorkspace.shared.open(url) else {
            errorMessage = String(localized: "Failed to open certificate.")
            return
        }
#else
        guard let plist = controller.mobileConfigData() else {
            errorMessage = String(localized: "Failed to export profile.")
            return
        }
        Task { @MainActor in
            do {
                let url = try await MITMProfileServer.shared.start(payload: plist)
                UIApplication.shared.open(url) { success in
                    if !success {
                        Task { @MainActor in
                            errorMessage = String(localized: "Failed to open profile installer.")
                        }
                    }
                }
            } catch {
                errorMessage = String(describing: error)
            }
        }
#endif
    }

    private func certificateURL() -> URL? {
        guard let der = controller.certificateData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NaiveFlowMITMRoot.cer")
        do {
            try der.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }
}

#if os(iOS)
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

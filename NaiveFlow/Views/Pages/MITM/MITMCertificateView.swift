//
//  MITMCertificateView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/3/26.
//

import SwiftUI
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

@MainActor
@Observable
final class MITMCertificateController {

    @ObservationIgnored private let store = MITMCertificateStore()

    private(set) var hasCA: Bool = false
    private(set) var isTrusted: Bool = false

    init() {
        (hasCA, isTrusted) = currentState()
    }

    func refresh() {
        let (exists, trustedNow) = currentState()
        guard exists != hasCA || trustedNow != isTrusted else { return }
        hasCA = exists
        isTrusted = trustedNow
        AWNotificationCenter.notifyConfigurationVersionChanged()
    }

    func ensureCA() throws {
        _ = try store.loadOrCreateCA()
        refresh()
    }

    func regenerate() throws {
        _ = try store.regenerate()
        refresh()
    }

    func delete() {
        store.delete()
        refresh()
    }

    func certificateData() -> Data? {
        store.exportCertificateDER()
    }

    func mobileConfigData() -> Data? {
        store.exportMobileConfig()
    }

    private func currentState() -> (hasCA: Bool, isTrusted: Bool) {
        let exists = store.exportCertificateDER() != nil
        return (exists, exists && store.isCATrusted())
    }
}

struct MITMCertificateView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @Environment(MITMCertificateController.self) private var controller

#if os(iOS)
    @State private var isExportingCertificate = false
#endif
    @State private var showRegenerateConfirm = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable MITM", isOn: Binding(
                    get: { model.parsed.mitm.bool("enable") ?? model.parsed.general.bool("mitm") ?? false },
                    set: { value in Task { await model.setSetting("enable", value: value ? "true" : "false", section: .mitm) } }
                )).tint(.blue).disabled(model.isBusy)
            }
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
                                .font(.headline)
                                .animation(.default, value: badgeTitle)
                        }
                        Text(badgeSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .animation(.default, value: badgeSubtitle)
                    }
                }
                .frame(minHeight: 80)
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
                        prepareCerExport()
                    } label: {
                        Text("Export Certificate")
                    }

                    Button {
                        showRegenerateConfirm = true
                    } label: {
                        Text("Regenerate Certificate")
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("Delete Certificate")
                    }
                }
            } else {
                Section {
                    Button {
                        do {
                            try controller.ensureCA()
                        } catch {
                            errorMessage = String(describing: error)
                        }
                    } label: {
                        Label("Generate Certificate", systemImage: "plus")
                    }
                }
            }
        }
        .navigationTitle("MITM")
        .clientInlineTitle()
        .alert("Regenerate Certificate", isPresented: $showRegenerateConfirm) {
            Button("Regenerate", role: .destructive) {
                do {
                    try controller.regenerate()
                } catch {
                    errorMessage = String(describing: error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any previously installed MITM profile will stop working until you re-install the new certificate.")
        }
        .alert("Delete Certificate", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                controller.delete()
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
        .sheet(isPresented: $isExportingCertificate) {
            if let url = certificateURL() {
                ShareSheet(items: [url])
            }
        }
#endif
        .onAppear {
            controller.refresh()
        }
#if os(iOS)
        .onDisappear {
            Task { await MITMProfileServer.shared.stop() }
        }
#endif
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                controller.refresh()
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
        return controller.isTrusted ? String(localized: "Trusted") : String(localized: "Not Trusted")
    }

    private var badgeSubtitle: String {
        if !controller.hasCA {
            return String(localized: "Generate a certificate to begin.")
        }
        if controller.isTrusted { return String(localized: "NaiveFlow Root Certificate is installed and trusted.") }
#if os(macOS)
        return String(localized: "Open the certificate in Keychain Access, then set its trust for SSL.")
#else
        return String(localized: "Install the profile and trust in Settings to use MITM.")
#endif
    }

    // MARK: - Export

    private func prepareCerExport() {
#if os(macOS)
        guard let der = controller.certificateData() else {
            errorMessage = String(localized: "Failed to export certificate.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NaiveFlowMITMRoot.cer"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try der.write(to: url, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
#else
        guard certificateURL() != nil else {
            errorMessage = String(localized: "Failed to export certificate.")
            return
        }
        isExportingCertificate = true
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

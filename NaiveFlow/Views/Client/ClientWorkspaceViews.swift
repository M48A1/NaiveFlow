import SwiftUI
import UniformTypeIdentifiers
import NetworkExtension

struct ClientConfigurationStatusView: View {
    @Environment(ClientModel.self) private var model
    @Environment(TunnelController.self) private var tunnel
    @State private var reviewing = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                Label(status, systemImage: model.hasSavedDraft ? "doc.badge.ellipsis" : "checkmark.shield")
                    .font(.caption.weight(.medium)).foregroundStyle(model.hasSavedDraft ? .orange : .secondary)
                if model.hasSavedDraft {
                    Button("Review Saved Changes") { reviewing = true }.font(.caption)
                }
            }
        }
        .sheet(isPresented: $reviewing) { ClientDraftReviewView() }
    }
    private var status: String {
        if model.hasSavedDraft { return "Saved changes · Not applied" }
        if !model.hasApplied { return "Saved · Not applied" }
        if tunnel.rawStatus == .connecting || tunnel.rawStatus == .reasserting { return "Connecting · Waiting for tunnel confirmation" }
        if tunnel.rawStatus == .connected { return model.isRuntimeConfirmed ? "Running · Configuration confirmed" : "Waiting for tunnel confirmation" }
        return "Applied · VPN stopped"
    }
}

struct ClientDraftReviewView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var restore = false
    private var changes: [ClientTextChange] { ClientTextChange.compare(model.operatingText, model.profile?.text ?? "") }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Apply Saved Profile") { Task { if let profile = model.profile, await model.saveProfile(profile, apply: true) { dismiss() } } }
                    Button("Restore Applied Content", role: .destructive) { restore = true }
                } footer: { Text("Restoring replaces the saved draft with the currently applied text. It does not change the VPN.") }
                Section {
                    if changes.isEmpty { Text("No text changes") }
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Line \(change.line)").font(.caption).foregroundStyle(.secondary)
                            if let before = change.before { Text("− " + before).foregroundStyle(.red) }
                            if let after = change.after { Text("+ " + after).foregroundStyle(.green) }
                        }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                } header: { Text("Changed Lines") } footer: { Text("Compares the same line numbers in each version. Up to 400 changed lines are shown; inserting a line can shift later comparisons.") }
            }
            .navigationTitle("Saved vs Applied").clientInlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Replace Saved Draft?", isPresented: $restore, titleVisibility: .visible) {
                Button("Restore Applied Content", role: .destructive) { Task { if await model.restoreRunningDraft() { dismiss() } } }
            }
            .disabled(model.isBusy)
            .alert("Could Not Apply", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

private struct ClientBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ClientBackupView: View {
    @Environment(ClientModel.self) private var model
    @State private var exporting = false
    @State private var importing = false
    @State private var document = ClientBackupDocument(data: Data())
    @State private var incoming: ClientBackup?
    @State private var replaceMatches = false
    @State private var notice: String?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Button("Export Complete Profile Backup") {
                    do {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        let data = try encoder.encode(ClientBackup(library: model.library))
                        guard data.count <= ClientBackup.maximumBytes else { throw ClientFailure("The backup exceeds 64 MiB.") }
                        document = ClientBackupDocument(data: data); exporting = true
                    } catch { self.error = error.localizedDescription }
                }
                Button("Import Backup") { importing = true }
            } footer: { Text("Includes all named profiles, subscription sources, modules and group styles. Backups contain node credentials and subscription URLs; keep them private. System VPN permissions and CA private keys are not included.") }
            if let incoming {
                Section {
                    LabeledContent("Profiles in Backup", value: String(incoming.library.profiles.count))
                    LabeledContent("Matching Profile IDs", value: String(incoming.library.profiles.filter { source in model.library.profiles.contains { $0.id == source.id } }.count))
                    Toggle("Replace Matching Profiles", isOn: $replaceMatches)
                    ForEach(incoming.library.profiles) { profile in Text(profile.displayName) }
                    Button("Restore Profiles") { Task {
                        if await model.restoreBackup(incoming, replaceMatches: replaceMatches) {
                            self.incoming = nil; notice = "Restored. The running VPN was not changed. Apply a profile when ready."
                        } else { error = model.error; model.error = nil }
                    } }
                    Button("Cancel Restore", role: .cancel) { self.incoming = nil }
                } header: { Text("Restore Preview") } footer: { Text("Matching IDs are kept unless replacement is enabled. Newly restored profiles are added. Nothing is applied to the VPN automatically.") }
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        .navigationTitle("Backup and Restore").clientInlineTitle()
        .disabled(model.isBusy)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "NaiveFlow-backup") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                let data = try file.read(upToCount: ClientBackup.maximumBytes + 1) ?? Data()
                incoming = try ClientBackup.decode(data); replaceMatches = false; notice = nil
            } catch { self.error = error.localizedDescription }
        }
        .alert("Backup Operation Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}

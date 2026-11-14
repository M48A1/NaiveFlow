import SwiftUI
import UniformTypeIdentifiers

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
            if let notice { Text(notice).foregroundStyle(DesignSystem.Colors.secondaryText) }
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

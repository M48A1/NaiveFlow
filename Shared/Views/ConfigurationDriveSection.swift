import SwiftUI

struct ConfigurationDriveSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var drive = ConfigurationDrive()
    @State private var files: [String] = []
    @AppStorage("linkedICloudConfigurationName") private var selectedName = ""
    @AppStorage("linkedICloudConfigurationDigest") private var selectedDigest = ""
    @State private var pending: ConfigurationDrive.Version?
    @State private var showSaveAs = false
    @State private var fileName = ""
    @State private var changed = false
    @State private var busy = false
    @State private var error: String?
    @State private var status: String?

    let model: ProfileEditorModel

    var body: some View {
        Section("iCloud Drive") {
            if !selectedName.isEmpty {
                LabeledContent("Linked Configuration", value: selectedName)
                if changed {
                    Text("A newer version is available in iCloud Drive.")
                        .foregroundStyle(.orange)
                    Button("Review Cloud Version") { run { pending = try await drive.read(selectedName) } }
                }
                Button("Save to iCloud Drive") {
                    let text = model.text
                    run {
                        select(try await drive.save(text, name: selectedName, replacing: selectedDigest))
                        status = "Saved. iCloud Drive will sync this file to your other devices."
                    }
                }
                .disabled(changed)
            }
            Button("Save as New Configuration") {
                fileName = ""
                showSaveAs = true
            }
            Menu("Open iCloud Configuration") {
                if files.isEmpty { Text("No configurations listed") }
                ForEach(files, id: \.self) { name in
                    Button(name) { run { pending = try await drive.read(name) } }
                }
            }
            Button("Refresh iCloud Drive") { run { try await refresh() } }
            if model.cloudDraftBackup != nil {
                Button("Restore Draft Before iCloud Load") { model.restoreDraftBeforeCloudLoad() }
            }
            if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if model.preview?.parsed.mitm.contains(MITMPKCS12.configurationKey) == true {
                Text("The iCloud configuration includes this MITM certificate and private key.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(model.isApplying || busy || !model.isLoaded)
        .alert("Save iCloud Configuration", isPresented: $showSaveAs) {
            TextField("File Name", text: $fileName)
            Button("Save") {
                let text = model.text
                run {
                    let name = try ConfigurationDrive.fileName(fileName)
                    select(try await drive.save(text, name: name, replacing: nil))
                    changed = false
                    if !files.contains(name) { files.append(name); files.sort() }
                    status = "Saved. iCloud Drive will sync this file to your other devices."
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Load iCloud Configuration?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), presenting: pending) { version in
            Button("Load into Editor") {
                if model.loadCloudText(version.text, name: version.name) {
                    select(version)
                    changed = false
                }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { _ in
            Text("Your current draft will be backed up. Press Apply to use the loaded configuration on this device.")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            guard !busy else { return }
            do { try await refresh() }
            catch ConfigurationDrive.Failure.downloading { changed = true }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }

    }

    private func refresh() async throws {
        let name = selectedName
        let digest = selectedDigest
        let listed = try await drive.files()
        try Task.checkCancellation()
        guard selectedName == name, selectedDigest == digest else { return }
        files = listed
        guard !name.isEmpty else { return }
        guard listed.contains(name) else {
            changed = true
            return
        }
        let current = try await drive.read(name)
        try Task.checkCancellation()
        if selectedName == name, selectedDigest == digest {
            changed = current.digest != digest
        }
    }

    private func select(_ version: ConfigurationDrive.Version) {
        selectedName = version.name
        selectedDigest = version.digest
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        status = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch ConfigurationDrive.Failure.changed {
                changed = true
                error = ConfigurationDrive.Failure.changed.localizedDescription
            }
            catch { self.error = error.localizedDescription }
        }
    }
}

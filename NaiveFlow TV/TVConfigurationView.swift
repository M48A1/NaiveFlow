import SwiftUI

struct TVClientProfilesView: View {
    @Environment(ClientModel.self) private var model

    var body: some View {
        List {
            Section("Profiles") {
                ForEach(model.library.profiles) { profile in
                    NavigationLink {
                        TVClientProfileEditor(profile: profile)
                    } label: {
                        Label(profile.displayName, systemImage: model.library.selectedID == profile.id && model.hasApplied
                              ? "checkmark.circle.fill" : "doc.text")
                    }
                }
                NavigationLink("New Profile") {
                    TVClientProfileEditor(profile: ClientProfile(name: "New Profile", text: TextConfigurationPipeline.template))
                }
            }
            Section("iCloud Drive") {
                NavigationLink("Open iCloud Configuration") { TVClientCloudProfilesView() }
            }
        }
        .navigationTitle("Configuration")
    }
}

private struct TVClientCloudProfilesView: View {
    @Environment(ClientModel.self) private var model
    @State private var names: [String] = []
    private let drive = ConfigurationDrive()

    var body: some View {
        List {
            ForEach(names, id: \.self) { name in
                NavigationLink(name) {
                    TVClientCloudProfileView(name: name, drive: drive)
                }
            }
            Button("Refresh") { Task { await reload() } }
        }
        .navigationTitle("iCloud Drive")
        .task { await reload() }
    }

    private func reload() async {
        do { names = try await drive.files() }
        catch { model.report(error) }
    }
}

private struct TVClientCloudProfileView: View {
    @Environment(ClientModel.self) private var model
    let name: String
    let drive: ConfigurationDrive
    @State private var version: ConfigurationDrive.Version?

    var body: some View {
        Group {
            if let version {
                TVClientProfileEditor(
                    profile: ClientProfile(name: (version.name as NSString).deletingPathExtension, text: version.text),
                    drive: drive, cloudVersion: version
                )
            } else {
                Button("Load iCloud Configuration") { Task { await load() } }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            version = try await drive.read(name)
        } catch { model.report(error) }
    }
}

private struct TVClientProfileEditor: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: ClientProfile
    var drive = ConfigurationDrive()
    var cloudVersion: ConfigurationDrive.Version? = nil
    @State private var savingToCloud = false

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Profile Name", text: $profile.name)
                TextField("Configuration", text: $profile.text, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            }
            Section {
                Button("Save and Apply") { Task { await save(apply: true) } }
                Button("Save Only") { Task { await save(apply: false) } }
                Button(cloudVersion == nil ? "Save a Copy to iCloud Drive" : "Save to iCloud Drive") {
                    Task {
                        savingToCloud = true
                        defer { savingToCloud = false }
                        do {
                            let name = try ConfigurationDrive.fileName(cloudVersion?.name ?? profile.name)
                            _ = try await drive.save(profile.text, name: name, replacing: cloudVersion?.digest)
                            dismiss()
                        } catch { model.report(error) }
                    }
                }
            }
            .disabled(model.isBusy || savingToCloud || profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationTitle("Edit Profile")
    }

    private func save(apply: Bool) async {
        if await model.saveProfile(profile, apply: apply) { dismiss() }
    }
}

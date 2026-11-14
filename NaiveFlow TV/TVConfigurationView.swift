import SwiftUI

struct TVClientProfilesView: View {
    @Environment(ClientModel.self) private var model
    @State private var importingURL = false
    @State private var source = ""
    @State private var importedProfile: ClientProfile?
    @State private var pendingDelete: ClientProfile?
    @State private var downloading = false

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
                    .contextMenu {
                        Button("Apply") { Task { await model.activate(profile) } }
                        if profile.sourceURL != nil {
                            Button("Update Remote Profile") { Task { await model.updateProfile(profile) } }
                        }
                        Button("Delete", role: .destructive) { pendingDelete = profile }
                    }
                }
                NavigationLink("New Profile") {
                    TVClientProfileEditor(profile: ClientProfile(name: "New Profile", text: TextConfigurationPipeline.template))
                }
            }
            Button("Import Profile from URL") { importingURL = true }
                .disabled(model.isBusy || downloading)
            if downloading { ProgressView("Downloading Profile") }
        }
        .navigationTitle("Configuration")
        .alert("Import Profile from URL", isPresented: $importingURL) {
            TextField("HTTPS Configuration URL", text: $source).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Import") { Task { await importProfile() } }
        }
        .sheet(item: $importedProfile) { profile in
            NavigationStack { TVClientProfileEditor(profile: profile) }
        }
        .confirmationDialog("Delete Profile?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { profile in
            Button("Delete", role: .destructive) { model.deleteProfile(profile.id) }
        }
    }

    private func importProfile() async {
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        do {
            let url = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = try await model.fetchText(url)
            importedProfile = ClientProfile(name: URL(string: url)?.host ?? "Imported Profile", text: text, sourceURL: url)
        } catch { model.report(error) }
    }
}

struct TVClientProfileEditor: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: ClientProfile

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Profile Name", text: $profile.name)
                TextField("Remote URL (HTTPS)", text: Binding(
                    get: { profile.sourceURL ?? "" },
                    set: { profile.sourceURL = $0.isEmpty ? nil : $0 }
                )).autocorrectionDisabled()
                TextField("Configuration", text: $profile.text, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            }
            Section {
                Button("Save and Apply") { Task { await save(apply: true) } }
                Button("Save Only") { Task { await save(apply: false) } }
            }
            .disabled(model.isBusy || profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationTitle("Edit Profile")
    }

    private func save(apply: Bool) async {
        if await model.saveProfile(profile, apply: apply) { dismiss() }
    }
}

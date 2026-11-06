//
//  ProfileView.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import SwiftUI
import UniformTypeIdentifiers

/// The text profile, edited inside the app and wired straight into the app's own
/// stores.
///
/// This page is a renderer: every decision — what the buffer holds, when it is
/// recompiled, when the draft is written, what a failed apply leaves behind, and
/// how much work the tunnel still has to do — lives in `ProfileEditorModel`, so
/// the same behaviour is available to another platform, a deep link or a test.
///
/// The name is deliberate: in this project `Configuration…` means a *proxy node*
/// (`ProxyConfiguration`, `ConfigurationStore`), while the *profile* is the single
/// text document that describes the whole setup.
struct ProfileView: View {
    @Environment(Operations.self) private var operations
    @Environment(AppSettings.self) private var appSettings

    @State private var modelBox = ViewScoped<ProfileEditorModel>()
    @State private var showImporter = false
    @State private var pendingCloudDocument: CloudConfigurationDocument?

    private var model: ProfileEditorModel {
        modelBox {
            ProfileEditorModel(document: operations.configurationDocument)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                editorSection
                resultSection
                reloadSection
                actionSection
                cloudSection
                historySection
            }
            .navigationTitle("Configuration")
            .task { model.load(); await operations.configurationCloud.reload() }
            .onDisappear { model.dismissMessages() }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.plainText, .data]
            ) { picked in
                switch picked {
                case .success(let url):
                    model.importFile(at: url)
                case .failure(let error):
                    model.report(error)
                }
            }
            .confirmationDialog("Load iCloud Configuration?", isPresented: Binding(
                get: { pendingCloudDocument != nil },
                set: { if !$0 { pendingCloudDocument = nil } }
            ), presenting: pendingCloudDocument) { item in
                Button("Load into Editor") { model.loadCloudDocument(item); pendingCloudDocument = nil }
                Button("Cancel", role: .cancel) { pendingCloudDocument = nil }
            } message: { _ in
                Text("Your current draft will be backed up. Loading does not apply the configuration to this device.")
            }
            .alert("Configuration Not Applied", isPresented: errorBinding) {
                Button("OK", role: .cancel) { model.dismissError() }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented { model.dismissMessages() }
            }
        )
    }
}

// MARK: - Sections

private extension ProfileView {

    var editorSection: some View {
        Section {
            TextEditor(text: Binding(get: { model.text }, set: { model.edit($0) }))
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 300)
        } header: {
            HStack {
                Text("Configuration File")
                Spacer()
                if model.isDirty {
                    Text("Unsaved")
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(editorFooter)
                if let statusMessage = model.statusMessage {
                    Text(statusMessage)
                }
            }
        }
    }

    @ViewBuilder
    var resultSection: some View {
        Section("Result") {
            if let preview = model.preview {
                LabeledContent("Nodes", value: preview.compiled.proxies.count.formatted())
                LabeledContent("Groups", value: preview.compiled.proxyGroups.count.formatted())
                LabeledContent("Rule Sets", value: preview.compiled.ruleSets.count.formatted())
                LabeledContent("Rules", value: preview.compiled.ruleSets.reduce(0) { $0 + $1.rules.count }.formatted())
                LabeledContent("Hosts", value: preview.compiled.hosts.count.formatted())
                LabeledContent("Errors", value: model.errorCount.formatted())
                LabeledContent("Warnings", value: model.warningCount.formatted())

                ForEach(Array(model.diagnostics.prefix(30))) { diagnostic in
                    diagnosticRow(diagnostic)
                }
            } else {
                Text("Checking the document…")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.notes, id: \.self) { note in
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the running tunnel has to do about the last applied document.
    @ViewBuilder
    var reloadSection: some View {
        if let plan = model.reloadPlan, !plan.isEmpty {
            Section {
                ForEach(plan.changes) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.field)
                            .font(.footnote)
                        Text("\(change.scope.title) · \(change.summary)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Last Apply")
            } footer: {
                Text(model.reloadNotice ?? "")
            }
        }
    }

    var actionSection: some View {
        Section {
            Button {
                Task { await model.apply() }
            } label: {
                Label("Apply Configuration", systemImage: "checkmark.circle")
            }
            .disabled(!model.canApply)

            Button {
                Task { await model.rollbackRuntimeVersion() }
            } label: {
                Label("Restore Previous Runtime Version", systemImage: "arrow.uturn.backward")
            }
            .disabled(model.isApplying || model.history.isEmpty)

            Button {
                model.reloadFromCurrentSetup()
            } label: {
                Label("Load from Current Setup", systemImage: "arrow.down.doc")
            }

            Button {
                showImporter = true
            } label: {
                Label("Import File", systemImage: "square.and.arrow.down")
            }

            ShareLink(item: model.text) {
                Label("Export File", systemImage: "square.and.arrow.up")
            }

            if model.isDirty {
                Button(role: .destructive) {
                    model.discardChanges()
                } label: {
                    Label("Discard Changes", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Apply writes the document into the app's stores, which is what the tunnel reads. Import only loads a file into the editor; nothing is applied until you press Apply.")
        }
    }

    var cloudSection: some View {
        Section {
            Toggle("iCloud Sync", isOn: Binding(get: { appSettings.iCloudSyncEnabled }, set: { appSettings.iCloudSyncEnabled = $0 }))
            Button("Save for iCloud Sync") {
                let text = model.text
                Task { await operations.configurationCloud.saveNow(text) }
            }
            .disabled(model.isApplying)
            Button("Refresh iCloud Configurations") {
                Task { await operations.configurationCloud.refresh() }
            }
            .disabled(!appSettings.iCloudSyncEnabled || operations.configurationCloud.isRefreshing)
            ForEach(operations.configurationCloud.documents) { item in
                Button {
                    pendingCloudDocument = item
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.deviceName)
                        Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isApplying)
            }
            if model.cloudDraftBackup != nil {
                Button("Restore Draft Before iCloud Load") { model.restoreDraftBeforeCloudLoad() }
                    .disabled(model.isApplying)
            }
            if let message = operations.configurationCloud.statusMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if let error = operations.configurationCloud.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("iCloud Configurations")
        } footer: {
            Text("Drafts sync after editing pauses. Each device keeps its draft and last applied text separately. Load a copy to review, then press Apply on this device. Certificates and running tunnel state stay local.")
        }
    }

    @ViewBuilder
    var historySection: some View {
        if !model.history.isEmpty {
            Section("Applied Documents") {
                ForEach(model.history) { snapshot in
                    Button {
                        model.revert(to: snapshot)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                            Text(snapshotDescription(snapshot))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Rows

private extension ProfileView {

    func diagnosticRow(_ diagnostic: ConfigurationDiagnostic) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(for: diagnostic.severity))
                .font(.caption)
                .foregroundStyle(tint(for: diagnostic.severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.message)
                    .font(.footnote)
                Text(diagnosticDescription(diagnostic))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func symbol(for severity: ConfigurationDiagnostic.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    func tint(for severity: ConfigurationDiagnostic.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }

    func diagnosticDescription(_ diagnostic: ConfigurationDiagnostic) -> String {
        var parts = [diagnostic.severity.title]
        if let line = diagnostic.line {
            parts.append("Line \(line)")
        }
        if let section = diagnostic.section {
            parts.append(section)
        }
        return parts.joined(separator: " · ")
    }

    func snapshotDescription(_ snapshot: ConfigurationSnapshot) -> String {
        let counts = snapshot.summary
        return "\(counts.proxyCount) nodes · \(counts.groupCount) groups · \(counts.ruleSetCount) rule sets · \(counts.hostCount) hosts"
    }

    var editorFooter: String {
        let applied = model.lastAppliedAt.map {
            "Last applied \($0.formatted(date: .abbreviated, time: .shortened)) to the app."
        } ?? "Not applied yet."
        let state = model.isDirty
            ? "These edits are not applied yet."
            : "The buffer matches the applied document."
        return "\(applied) \(state)"
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    let container = AppContainer.preview()
    return ProfileView()
        .environment(Operations(container: container))
        .environment(AppSettings())
}
#endif

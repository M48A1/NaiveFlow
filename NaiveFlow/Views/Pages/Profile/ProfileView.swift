//
//  ProfileView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import SwiftUI
import UniformTypeIdentifiers

/// Text configuration editor with version history and iCloud Drive support.
struct ProfileView: View {
    @Environment(Operations.self) private var operations
    @Environment(ClientModel.self) private var client

    @State private var modelBox = ViewScoped<ProfileEditorModel>()
    @State private var showImporter = false

    private var model: ProfileEditorModel {
        modelBox {
            ProfileEditorModel(document: operations.configurationDocument)
        }
    }

    var body: some View {
        NavigationStack {
            ClientForm {
                editorSection
                resultSection
                reloadSection
                actionSection
                NavigationLink("MITM") { MITMCertificateView(editor: model) }
                ConfigurationDriveSection(model: model)
                historySection
            }
            .navigationTitle("Configuration")
            .task { model.load() }
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
                .designText(.caption, design: .monospaced)
                .autocorrectionDisabled()
                .clientNoAutocapitalization()
                .frame(minHeight: 300)
        } header: {
            HStack {
                Text("Configuration File")
                Spacer()
                if model.isDirty {
                    Text("Unsaved")
                        .foregroundStyle(DesignSystem.Colors.warning)
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
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            }

            ForEach(model.notes, id: \.self) { note in
                Text(note)
                    .designText(.caption)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
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
                            .designText(.caption)
                        Text("\(change.scope.title) · \(change.summary)")
                            .designText(.micro)
                            .foregroundStyle(DesignSystem.Colors.secondaryText)
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
                Task {
                    await model.apply()
                    if model.errorMessage == nil { client.adoptAppliedConfiguration() }
                }
            } label: {
                Label("Apply Configuration", systemImage: "checkmark.circle")
            }
            .disabled(!model.canApply)

            Button {
                Task {
                    await model.rollbackRuntimeVersion()
                    if model.errorMessage == nil { client.adoptAppliedConfiguration() }
                }
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

    @ViewBuilder
    var historySection: some View {
        if !model.history.isEmpty {
            Section("Applied Documents") {
                ForEach(model.history) { snapshot in
                    Button {
                        model.revert(to: snapshot)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.createdAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(Locale(identifier: "en"))))
                                .designText(.caption)
                            Text(snapshotDescription(snapshot))
                                .designText(.micro)
                                .foregroundStyle(DesignSystem.Colors.secondaryText)
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
                .designText(.caption)
                .foregroundStyle(tint(for: diagnostic.severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.message)
                    .designText(.caption)
                Text(diagnosticDescription(diagnostic))
                    .designText(.micro)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
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
            "Last applied \($0.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(Locale(identifier: "en")))) to the app."
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
    let operations = Operations(container: container)
    return ProfileView()
        .environment(operations)
        .environment(ClientModel(operations: operations))
}
#endif

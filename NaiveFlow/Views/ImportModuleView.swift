//
//  ImportModuleView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 10/9/26.
//

import Foundation
import Observation
import SwiftUI

struct ImportModuleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Operations.self) private var operations
    @Environment(MITMRuleSetStore.self) private var mitmStore

    @State private var model: ImportModuleModel

    init(link: URL) {
        _model = State(initialValue: ImportModuleModel(link: link))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Module Type", selection: $model.format) {
                        ForEach(ModuleFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                }
                switch model.status {
                case .loading:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading…")
                                .foregroundStyle(.secondary)
                        }
                    }
                case .failed(let message):
                    Section {
                        Label {
                            Text(message)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                case .ready(let module, let routingSeeds):
                    header(for: module)
                    if !module.mitmRuleSets.isEmpty && !mitmStore.isEnabled {
                        mitmDisabledWarning
                    }
                    if !module.routingRuleSets.isEmpty {
                        Section("Routing Rule Sets") {
                            ForEach(module.routingRuleSets) { ruleSet in
                                routingRow(for: ruleSet, seed: routingSeeds[ruleSet.id])
                            }
                        }
                    }
                    if !module.mitmRuleSets.isEmpty {
                        Section("MITM Rule Sets") {
                            ForEach(module.mitmRuleSets) { ruleSet in
                                mitmRow(for: ruleSet)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import Module")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton("Done") { performImport() }
                        .disabled(!model.isReady)
                }
            }
            .task(id: model.format) { await model.load() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func header(for module: Module) -> some View {
        Section {
            HStack(spacing: 12) {
                ModuleIconView(iconLight: module.iconLight, iconDark: module.iconDark)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.link.host ?? model.link.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private var mitmDisabledWarning: some View {
        Section {
            Label {
                Text("MITM rule sets won't take effect until MITM is enabled.")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func routingRow(for ruleSet: ModuleRoutingRuleSet, seed: String?) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(ruleSet.name)
                Text("\(ruleSet.rules.count) rule(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            AssignmentLabel(assignedConfigurationId: seed)
        }
    }

    @ViewBuilder
    private func mitmRow(for ruleSet: ModuleMITMRuleSet) -> some View {
        VStack(alignment: .leading) {
            Text(ruleSet.name)
            Text(summary(for: ruleSet))
                .font(.caption)
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
                .lineLimit(1)
        }
    }

    private func summary(for ruleSet: ModuleMITMRuleSet) -> String {
        var parts = [String(localized: "\(ruleSet.rules.count) rule(s)")]
        if !ruleSet.parameters.isEmpty {
            parts.append(String(localized: "\(ruleSet.parameters.count) parameter(s)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Import

    private func performImport() {
        guard case .ready(let module, let routingSeeds) = model.status else { return }
        operations.modules.add(module, routingSeeds: routingSeeds)
        dismiss()
    }
}

@MainActor
@Observable
final class ImportModuleModel {
    enum Status {
        case loading
        case ready(module: Module, routingSeeds: [UUID: String])
        case failed(String)
    }

    let link: URL
    var format: ModuleFormat = .surge {
        didSet { status = .loading; warnings = [] }
    }
    private(set) var warnings: [String] = []
    private(set) var status: Status = .loading

    init(link: URL) {
        self.link = link
        format = link.pathExtension.lowercased() == "snippet" ? .quantumultX : .surge
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    func load() async {
        guard let url = Module.validSubscriptionURL(from: link.absoluteString) else {
            status = .failed(String(localized: "Unsupported link."))
            return
        }
        do {
            let body = try await ModuleOperations.fetchBody(from: url)
            let made = try await ModuleOperations.makeModule(
                from: body,
                fallbackName: ModuleOperations.fallbackName(for: url),
                subscriptionURL: url,
                format: format
            )
            try Task.checkCancellation()
            warnings = made.warnings
            status = .ready(module: made.module, routingSeeds: made.routingSeeds)
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(error.localizedDescription)
        }
    }
}

struct ImportModuleLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Operations.self) private var operations
    @State private var link = ""
    @State private var format: ModuleFormat = .surge
    @State private var isLoading = false
    @State private var error: String?
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Module Type", selection: $format) {
                        ForEach(ModuleFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    TextField("Module URL", text: $link)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } footer: {
                    Text("The module and its scripts are downloaded together. HTTPS scripts require MITM to be enabled and its certificate trusted.")
                }
                .disabled(isLoading)
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Downloading module and scripts…")
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Module")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton("Cancel") {
                        importTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton("Import") { startImport() }
                        .disabled(isLoading || Module.validSubscriptionURL(from: link) == nil)
                }
            }
            .onDisappear { importTask?.cancel() }
        }
    }

    private func startImport() {
        guard let url = Module.validSubscriptionURL(from: link) else { return }
        isLoading = true
        error = nil
        let selectedFormat = format
        importTask = Task {
            defer { isLoading = false }
            do {
                let body = try await ModuleOperations.fetchBody(from: url)
                let made = try await ModuleOperations.makeModule(
                    from: body, fallbackName: ModuleOperations.fallbackName(for: url),
                    subscriptionURL: url, format: selectedFormat
                )
                try Task.checkCancellation()
                operations.modules.add(made.module, routingSeeds: made.routingSeeds)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

//
//  ConfigurationDocumentOperations.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Reads, previews and publishes the single text configuration document.
@MainActor
struct ConfigurationDocumentOperations {
    let activation: ConfigurationActivation
    var tunnel: TunnelController? = nil
    var selection: ProxySelection? = nil
    private var publisher: ConfigurationPublisher {
        ConfigurationPublisher(activation: activation, tunnel: tunnel, clearStateSink: { selection?.clearRuntimeVersion() }, stateSink: { selection?.showRuntimeVersion($0) })
    }

    var ruleManager: RuleManager { RuleManager(activation: activation) }

    /// Returns the applied document, or the starter template.
    func exportCurrent(
        options: ConfigurationExporter.Options = ConfigurationExporter.Options()
    ) -> ConfigurationExporter.Result {
        if let active = activation.active {
            return ConfigurationExporter.Result(text: active.text, notes: [], counts: .init(
                proxies: active.compiled.proxies.count, groups: active.compiled.proxyGroups.count,
                rules: active.compiled.orderedRules.count, hosts: active.compiled.hosts.count
            ))
        }
        return ConfigurationExporter.Result(text: TextConfigurationPipeline.template, notes: [], counts: .init(proxies: 0, groups: 0, rules: 0, hosts: 0))
    }

    // MARK: - Draft

    /// Text the editor should show, or the starter template on first launch.
    func draft() -> String {
        do { try publisher.reconcile() }
        catch RuntimeConfigurationFailure.busy { }
        catch { activation.record(error.localizedDescription) }
        return ruleManager.draft()
    }

    func hasDraft() -> Bool {
        ruleManager.hasDraft()
    }

    /// Persists the editor buffer. Saving never implies activation, so a
    /// half-finished document with errors stays on disk.
    func saveDraft(_ text: String) throws {
        try ruleManager.saveDraft(text)
    }

    // MARK: - Publication

    /// Compiles without writing anything, for the editor's live feedback.
    func preview(_ text: String) -> TextConfigurationPipeline.Result {
        ruleManager.preview(text)
    }

    /// Compiles and publishes one complete runtime version.
    func apply(_ text: String) async throws -> ConfigurationInstaller.Outcome {
        try await publisher.publish(text: text).1
    }

    func rollbackRuntimeVersion() async throws -> ProfileApplyOutcome {
        let outcome = try await publisher.rollback()
        return ProfileApplyOutcome(summary: outcome.summary, notes: outcome.notes, plan: outcome.plan)
    }

    /// Reads a picked file so the editor can show it. Reading does not apply:
    /// the user reviews the text, then presses Apply.
    func read(contentsOf url: URL) throws -> String {
        try ruleManager.read(contentsOf: url)
    }

    // MARK: - History

    func appliedAt() -> Date? {
        ruleManager.appliedAt()
    }

    func history(limit: Int = 5) -> [ConfigurationSnapshot] {
        ruleManager.history(limit: limit)
    }
}

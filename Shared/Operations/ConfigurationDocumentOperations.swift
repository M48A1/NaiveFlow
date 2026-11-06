//
//  ConfigurationDocumentOperations.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// One editable text document that sits on top of the app's stores, in both
/// directions:
///
/// - **out** — `exportCurrent()` renders the current stores as a document, so
///   editing starts from what the app already runs instead of a blank file;
/// - **in** — `apply(_:)` compiles the text and writes it into the stores
///   through `ConfigurationPublisher`, refusing anything with errors.
///
/// The document itself lives in the App Group container
/// (`configurations/draft.txt`), so it survives a relaunch and the extension can
/// read what the host activated. Nothing here keeps its own copy of the text:
/// the editor owns the buffer, this type owns the two crossings.
@MainActor
struct ConfigurationDocumentOperations {
    let configurationStore: ConfigurationStore
    let chainStore: ChainStore
    let groupStore: GroupStore
    let routingRuleSetStore: RoutingRuleSetStore
    let mitmRuleSetStore: MITMRuleSetStore
    let moduleStore: ModuleStore
    let activation: ConfigurationActivation
    var tunnel: TunnelController? = nil
    var selection: ProxySelection? = nil
    private var publisher: ConfigurationPublisher {
        ConfigurationPublisher(activation: activation, tunnel: tunnel, stateSink: { selection?.showRuntimeVersion($0) })
    }

    var ruleManager: RuleManager { RuleManager(activation: activation) }

    // MARK: - Stores to text

    /// Renders the stores as a document. Whatever the text format cannot carry
    /// (chains, module rule sets, unassigned rule sets) comes back in
    /// `Result.notes` instead of being dropped silently.
    func exportCurrent(
        options: ConfigurationExporter.Options = ConfigurationExporter.Options()
    ) -> ConfigurationExporter.Result {
        if let active = activation.active {
            return ConfigurationExporter.Result(text: active.text, notes: [], counts: .init(
                proxies: active.compiled.proxies.count, groups: active.compiled.proxyGroups.count,
                rules: active.compiled.orderedRules.count, hosts: active.compiled.hosts.count
            ))
        }
        return         ConfigurationExporter.exportCurrentConfiguration(
            configurationStore: configurationStore,
            chainStore: chainStore,
            groupStore: groupStore,
            routingRuleSetStore: routingRuleSetStore,
            mitmRuleSetStore: mitmRuleSetStore,
            moduleStore: moduleStore,
            options: options
        )
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

    // MARK: - Text to stores

    /// Compiles without writing anything, for the editor's live feedback.
    func preview(_ text: String) -> TextConfigurationPipeline.Result {
        ruleManager.preview(text)
    }

    /// Compiles and installs. A document with errors is refused before the
    /// stores are touched, and if installation fails halfway the manifest is
    /// rolled back and the previous snapshot installed again.
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

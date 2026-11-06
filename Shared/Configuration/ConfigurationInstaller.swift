//
//  ConfigurationInstaller.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// What a text configuration put into the app's stores.
///
/// Re-activating the same document must update those items instead of appending
/// duplicates, and a document that drops a node, group or rule set must delete
/// exactly the items the previous activation created — never a node the user
/// added by hand. Remembering the ids is enough to tell the two apart.
nonisolated struct ConfigurationInstallation: Codable, Equatable, Sendable {
    var installedAt: Date = .now
    var snapshotId: UUID?
    var proxyIds: [String: UUID] = [:]
    var groupIds: [String: UUID] = [:]
    var ruleSetIds: [String: UUID] = [:]

    var isEmpty: Bool {
        proxyIds.isEmpty && groupIds.isEmpty && ruleSetIds.isEmpty
    }
}

nonisolated extension ConfigurationSnapshotStore {

    private var installationURL: URL {
        directory.appendingPathComponent("installation.json")
    }

    func installation() -> ConfigurationInstallation? {
        guard let data = try? Data(contentsOf: installationURL) else { return nil }
        return try? JSONDecoder().decode(ConfigurationInstallation.self, from: data)
    }

    func saveInstallation(_ installation: ConfigurationInstallation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(installation).write(to: installationURL, options: .atomic)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    func clearInstallation() {
        try? FileManager.default.removeItem(at: installationURL)
    }
}

/// Applies a compiled text configuration to the app's existing stores.
///
/// This is the step that keeps one source of truth: the text document owns the
/// nodes, groups, rule sets, host mappings and settings it declares, and the
/// pages that already exist keep reading from the same stores. Nothing here
/// writes a second copy of the configuration.
///
/// Everything is written only after `TextConfigurationPipeline` produced a
/// document without errors, so a broken document cannot replace a working one.
@MainActor
struct ConfigurationInstaller {

    enum Failure: LocalizedError {
        case notActivatable(errors: Int, warnings: Int)
        case registryUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .notActivatable(let errors, let warnings):
                let plural = errors == 1 ? "error" : "errors"
                return "The configuration has \(errors) \(plural) and \(warnings) warning(s), so nothing was installed."
            case .registryUnavailable(let detail):
                return "The configuration was applied but its record could not be saved: \(detail)"
            }
        }
    }

    /// What installation changed, for the editor to show after activation.
    struct Outcome: Equatable, Sendable {
        let installation: ConfigurationInstallation
        let plan: ConfigurationReloadPlan
        let modulePlan: ConfigurationCoordinator.Plan
        let addedProxies: [String]
        let updatedProxies: [String]
        let removedProxies: [String]
        let addedGroups: [String]
        let removedGroups: [String]
        let ruleSets: [String]
        let removedRuleSets: [String]
        let notes: [String]

        var requiresReconnect: Bool { plan.requiresReconnect }
        var requiresStackRestart: Bool { plan.requiresStackRestart }

        var summary: String {
            var parts: [String] = []
            if !addedProxies.isEmpty { parts.append("+\(addedProxies.count) node(s)") }
            if !updatedProxies.isEmpty { parts.append("~\(updatedProxies.count) node(s)") }
            if !removedProxies.isEmpty { parts.append("-\(removedProxies.count) node(s)") }
            if !ruleSets.isEmpty { parts.append("\(ruleSets.count) rule set(s)") }
            if !removedRuleSets.isEmpty { parts.append("-\(removedRuleSets.count) rule set(s)") }
            let changes = parts.isEmpty ? String(localized: "Configuration applied.") : parts.joined(separator: ", ")
            return "\(changes) · \(modulePlan.summary)"
        }
    }

    let configurationStore: ConfigurationStore
    let groupStore: GroupStore
    let ruleSetStore: RoutingRuleSetStore
    let selection: ProxySelection
    /// Refreshes selection and schedules the routing export. Optional so the
    /// installer can be exercised without a full container.
    let reaction: StoreMutationReaction?
    let store: ConfigurationSnapshotStore
    /// Draft/snapshot glue, so activate-and-install can be a single call.
    let activation: ConfigurationActivation

    init(
        configurationStore: ConfigurationStore,
        groupStore: GroupStore,
        ruleSetStore: RoutingRuleSetStore,
        selection: ProxySelection,
        reaction: StoreMutationReaction? = nil,
        store: ConfigurationSnapshotStore = ConfigurationSnapshotStore(),
        activation: ConfigurationActivation? = nil
    ) {
        self.configurationStore = configurationStore
        self.groupStore = groupStore
        self.ruleSetStore = ruleSetStore
        self.selection = selection
        self.reaction = reaction
        self.store = store
        self.activation = activation ?? ConfigurationActivation(store: store)
    }

    /// Convenience for the editor: install what an activation just froze.
    @discardableResult
    func install(_ activation: ConfigurationActivation.Activation) throws -> Outcome {
        try install(activation.compiled, snapshotId: activation.snapshot.id)
    }

    @discardableResult
    func install(_ result: TextConfigurationPipeline.Result) throws -> Outcome {
        guard result.isActivatable else {
            throw Failure.notActivatable(errors: result.errorCount, warnings: result.warningCount)
        }
        return try install(result.compiled)
    }
}

// MARK: - Installation

@MainActor
extension ConfigurationInstaller {

    /// Writes a compiled configuration into the stores and returns what changed.
    ///
    /// Order matters: proxies are written before the rule sets that point at
    /// them, because `StoreMutationReaction` drops assignments that reference a
    /// configuration id it cannot resolve.
    @discardableResult
    func install(_ compiled: CompiledConfiguration, snapshotId: UUID? = nil) throws -> Outcome {
        guard compiled.isActivatable else {
            throw Failure.notActivatable(errors: compiled.errors.count, warnings: compiled.diagnostics.count { $0.severity == .warning })
        }
        var notes: [String] = []
        let previous = store.installation() ?? ConfigurationInstallation()
        let previousCompiled = previous.snapshotId.flatMap { store.snapshot($0) }.map {
            ConfigurationCoordinator().compile(text: $0.text).compiled
        }
        let modulePlan = ConfigurationCoordinator().plan(
            from: previousCompiled, to: compiled, currentHosts: HostMapping.load()
        )
        let plan = modulePlan.reload

        let proxies = installProxies(compiled.proxies, previous: previous)
        let groups = installGroups(compiled.proxyGroups, previous: previous, idMap: proxies.idMap)
        let ruleSets = installRuleSets(compiled.ruleSets, previous: previous, idMap: proxies.idMap)

        // [Host] is a single App Group table, so it is replaced wholesale. The
        // resolver caches and the extension's copy are invalidated below.
        HostMapping.store(compiled.hosts)
        DNSHosts.shared.invalidate()
        DNSResolver.localRequests.flush()

        apply(compiled.settings)
        notes.append(
            contentsOf: selectDefaultProxyIfNeeded(
                preferredIds: compiled.proxies.compactMap { proxies.ids[$0.name] }
            )
        )

        let installation = ConfigurationInstallation(
            installedAt: .now,
            snapshotId: snapshotId,
            proxyIds: proxies.ids,
            groupIds: groups.ids,
            ruleSetIds: ruleSets.ids
        )
        do {
            try store.saveInstallation(installation)
        } catch {
            throw Failure.registryUnavailable(error.localizedDescription)
        }

        reaction?.run()
        // Binary routing/MITM payloads and the active node announce themselves
        // only after their existing exporters have published them. Host/settings
        // have already been written here and must also notify on Host-only edits.
        for event in modulePlan.announcements where event == .settings {
            event.post()
        }

        return Outcome(
            installation: installation,
            plan: plan,
            modulePlan: modulePlan,
            addedProxies: proxies.added,
            updatedProxies: proxies.updated,
            removedProxies: proxies.removed,
            addedGroups: groups.added,
            removedGroups: groups.removed,
            ruleSets: ruleSets.names,
            removedRuleSets: ruleSets.removed,
            notes: notes
        )
    }

    /// Activation and installation in one step.
    ///
    /// Compile before touching stores. On installation failure, attempt to restore
    /// the previous snapshot and its installation. Existing stores/exporters are
    /// independent: this is recovery, not a cross-process atomic transaction.
    @discardableResult
    func activate(text: String) throws -> (activation: ConfigurationActivation.Activation, outcome: Outcome) {
        let activated = try RuleManager(activation: activation).activate(text: text)
        do {
            let outcome = try install(activated)
            return (activated, outcome)
        } catch {
            activation.record(error.localizedDescription)
            if let restored = try? RuleManager(activation: activation).rollback() {
                _ = try? install(restored)
            }
            throw error
        }
    }

    /// Imports a file and activates it. Used by "open profile" style entry points
    /// so the file path and the text path share one code path.
    @discardableResult
    func activate(contentsOf url: URL) throws -> (activation: ConfigurationActivation.Activation, outcome: Outcome) {
        try activate(text: ConfigurationImport.read(from: url))
    }

    /// Removes everything the last installation created.
    ///
    /// Host mappings are cleared with it: `[Host]` is owned by the text
    /// configuration, so leaving entries behind would keep a stale override
    /// alive after the feature is switched off.
    func uninstall() {
        let previous = store.installation() ?? ConfigurationInstallation()

        for id in previous.ruleSetIds.values {
            ruleSetStore.removeCustomRuleSet(id)
        }
        for id in previous.groupIds.values {
            if let group = groupStore.groups.first(where: { $0.id == id }) {
                groupStore.delete(group)
            }
        }
        for id in previous.proxyIds.values {
            if let configuration = configurationStore.configurations.first(where: { $0.id == id }) {
                configurationStore.delete(configuration)
            }
        }

        HostMapping.store([])
        ConfigurationCoordinator.Announcement.settings.post()
        DNSHosts.shared.invalidate()
        DNSResolver.localRequests.flush()
        store.clearInstallation()
        store.clearConfirmation()
        reaction?.run()
    }
}



// MARK: - Stores

@MainActor
fileprivate extension ConfigurationInstaller {

    struct ProxyInstallation {
        var ids: [String: UUID] = [:]
        /// Compiled id → id actually in use, so rule targets survive a reinstall.
        var idMap: [UUID: UUID] = [:]
        var added: [String] = []
        var updated: [String] = []
        var removed: [String] = []
    }

    /// Nodes are matched by name against the ids the previous installation used.
    /// A node the user added by hand never matches, so it is never overwritten or
    /// deleted.
    func installProxies(
        _ proxies: [ProxyConfiguration],
        previous: ConfigurationInstallation
    ) -> ProxyInstallation {
        let existing = configurationStore.configurations
        let existingById = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var outcome = ProxyInstallation()
        var installed: [ProxyConfiguration] = []

        for proxy in proxies {
            let reusedId: UUID? = {
                guard let previousId = previous.proxyIds[proxy.name],
                      let previousNode = existingById[previousId],
                      previousNode.name == proxy.name
                else { return nil }
                return previousId
            }()

            let id = reusedId ?? UUID()
            outcome.idMap[proxy.id] = id
            outcome.ids[proxy.name] = id

            let rebuilt = ProxyConfiguration(
                id: id,
                name: proxy.name,
                serverAddress: proxy.serverAddress,
                serverPort: proxy.serverPort,
                resolvedIP: proxy.resolvedIP,
                subscriptionId: nil,
                outbound: proxy.outbound,
                chain: nil,
                updatedAt: .now
            )
            installed.append(rebuilt)

            if reusedId == nil {
                outcome.added.append(proxy.name)
            } else if let previousNode = existingById[id], !previousNode.contentEquals(rebuilt) {
                outcome.updated.append(proxy.name)
            }
        }

        configurationStore.upsert(installed)

        for (name, id) in previous.proxyIds where outcome.ids[name] != id {
            guard let removed = existingById[id] else { continue }
            configurationStore.delete(removed)
            outcome.removed.append(name)
        }

        return outcome
    }

    func installGroups(
        _ groups: [ProxyGroup],
        previous: ConfigurationInstallation,
        idMap: [UUID: UUID]
    ) -> (ids: [String: UUID], added: [String], removed: [String]) {
        let existing = groupStore.groups
        var ids: [String: UUID] = [:]
        var added: [String] = []
        var installed: [ProxyGroup] = []

        for group in groups {
            let reusedId: UUID? = {
                guard let previousId = previous.groupIds[group.name],
                      existing.contains(where: { $0.id == previousId && $0.name == group.name })
                else { return nil }
                return previousId
            }()

            let id = reusedId ?? UUID()
            ids[group.name] = id
            // Members were compiled against the ids of the new compile.
            let members = group.memberIds.compactMap { idMap[$0] }
            installed.append(
                ProxyGroup(id: id, name: group.name, kind: .servers, memberIds: members, updatedAt: .now)
            )
            if reusedId == nil { added.append(group.name) }
        }

        for group in installed {
            if existing.contains(where: { $0.id == group.id }) {
                groupStore.update(group)
            } else {
                groupStore.add(group)
            }
        }

        var removed: [String] = []
        for (name, id) in previous.groupIds where ids[name] != id {
            guard let group = existing.first(where: { $0.id == id }) else { continue }
            groupStore.delete(group)
            removed.append(name)
        }

        return (ids, added, removed)
    }
}

// MARK: - Rule sets and settings

@MainActor
fileprivate extension ConfigurationInstaller {

    /// One custom rule set per policy token (`Config · DIRECT`, …) because the
    /// compiled engine assigns one policy per rule set. The assignment is what
    /// `RoutingExportOperation` reads when it builds the routing payload.
    func installRuleSets(
        _ ruleSets: [CompiledRuleSet],
        previous: ConfigurationInstallation,
        idMap: [UUID: UUID]
    ) -> (ids: [String: UUID], names: [String], removed: [String]) {
        var ids: [String: UUID] = [:]
        var names: [String] = []

        for ruleSet in ruleSets {
            let assignment = assignmentToken(for: ruleSet.policy, idMap: idMap)

            if let previousId = previous.ruleSetIds[ruleSet.name],
               ruleSetStore.customRuleSets.contains(where: { $0.id == previousId }) {
                ruleSetStore.updateCustomRuleSet(previousId, name: ruleSet.name, rules: ruleSet.rules)
                ids[ruleSet.name] = previousId
                ruleSetStore.updateAssignment(
                    RoutingRuleSet(
                        id: previousId.uuidString,
                        name: ruleSet.name,
                        assignedConfigurationId: nil,
                        isCustom: true
                    ),
                    configurationId: assignment
                )
            } else {
                let created = CustomRoutingRuleSet(name: ruleSet.name, rules: ruleSet.rules)
                ruleSetStore.addCustomRuleSet(created, initialAssignment: assignment)
                ids[ruleSet.name] = created.id
            }

            names.append(ruleSet.name)
        }

        var removed: [String] = []
        for (name, id) in previous.ruleSetIds where ids[name] != id {
            guard ruleSetStore.customRuleSets.contains(where: { $0.id == id }) else { continue }
            ruleSetStore.removeCustomRuleSet(id)
            removed.append(name)
        }

        return (ids, names, removed)
    }

    /// `RoutingRuleSetStore` stores the assignment as a string: the built-in
    /// tokens or the UUID of a node.
    func assignmentToken(for target: RouteTarget, idMap: [UUID: UUID]) -> String {
        switch target {
        case .direct:
            return "DIRECT"
        case .reject:
            return "REJECT"
        case .default, .defaultProxy:
            return "PROXY"
        case .proxy(let compiledId):
            return (idMap[compiledId] ?? compiledId).uuidString
        }
    }

    /// A key the document does not mention stays absent from `settings`, so the
    /// existing value is left untouched. Which binding a key goes through comes
    /// from the catalog, so a new setting installs itself.
    ///
    /// Keys marked `applies: false` are skipped on purpose: the validator already
    /// told the user they have no effect, and writing them somewhere would make
    /// the value look honored.
    func apply(_ settings: CompiledSettings) {
        for key in ConfigurationSettings.catalog where key.applies {
            guard let value = settings.values[key.name] else { continue }
            ConfigurationSettingsBindings.write(key.name, value)
        }
    }

    /// `PROXY` in the routing payload resolves to the selected node, so a document
    /// that replaces every node must leave one selected.
    ///
    /// `preferredIds` are the nodes in document order; the first one is the
    /// natural default when nothing valid is selected anymore.
    func selectDefaultProxyIfNeeded(preferredIds: [UUID]) -> [String] {
        // A chain selection belongs to the chains page, not to the document.
        if AWCore.getSelectedChainId() != nil { return [] }

        if let selectedId = AWCore.getSelectedConfigurationId(),
           configurationStore.configurations.contains(where: { $0.id == selectedId }) {
            return []
        }

        let installed = configurationStore.configurations
        let installedById = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fallback = preferredIds.compactMap { installedById[$0] }.first ?? installed.first

        guard let fallback else {
            return ["The document declares no dialable node, so PROXY has no target."]
        }
        selection.select(fallback)
        return ["Selected '\(fallback.name)' because the previously selected node is no longer installed."]
    }
}


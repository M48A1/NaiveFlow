//
//  ConfigurationExporter+Stores.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Reads the app's stores into the value `ConfigurationExporter` renders.
///
/// This is the "generate the document from what is already configured" path: a
/// user who has been building nodes, groups and rule sets on the pages switches
/// to the text configuration and finds that setup written out, instead of an
/// empty editor that would ask them to type it all again.
@MainActor
extension ConfigurationExportSource {

    init(
        configurationStore: ConfigurationStore,
        chainStore: ChainStore,
        groupStore: GroupStore,
        routingRuleSetStore: RoutingRuleSetStore,
        mitmRuleSetStore: MITMRuleSetStore,
        moduleStore: ModuleStore? = nil
    ) {
        var notes: [String] = []

        // MARK: Nodes

        let nodes = configurationStore.configurations
        let nodeNames = Dictionary(nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        // A configuration that already carries hops is a composite built for a
        // chain; exporting its share link would describe only one hop.
        var proxies: [Proxy] = []
        for node in nodes {
            if node.chain?.isEmpty == false {
                notes.append("Node '\(node.name)' carries chain hops and is exported as its first hop only.")
            }
            proxies.append(Proxy(name: node.name, url: node.toURLString()))
        }

        let chains = chainStore.chains
        let chainNames = Dictionary(chains.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var exportedChains: [ConfigurationExportSource.Chain] = []
        for chain in chains {
            let memberNames = chain.proxyIds.compactMap { nodeNames[$0] }
            if memberNames.count == chain.proxyIds.count, memberNames.count >= 2 {
                exportedChains.append(.init(name: chain.name, members: memberNames))
            } else {
                notes.append("Chain '\(chain.name)' has missing or too few members and is not exported.")
            }
        }

        // MARK: Groups

        var groups: [Group] = []
        for group in groupStore.groups(of: .servers) {
            groups.append(
                Group(name: group.name, members: group.memberIds.compactMap { nodeNames[$0] }, iconURL: group.iconURL)
            )
        }
        let chainGroups = groupStore.groups(of: .chains)
        if !chainGroups.isEmpty {
            notes.append(
                "\(chainGroups.count) chain group(s) are not exported: they select chains, not nodes."
            )
        }

        // MARK: Rule sets

        var ruleSets: [RuleSet] = []
        for ruleSet in routingRuleSetStore.ruleSets {
            let rules: [RoutingRule]
            if ruleSet.isCustom,
               let customId = UUID(uuidString: ruleSet.id),
               let custom = routingRuleSetStore.customRuleSets.first(where: { $0.id == customId }) {
                rules = custom.rules
            } else {
                rules = RoutingRuleSetStore.loadRules(for: ruleSet.name)
            }
            ruleSets.append(
                RuleSet(
                    name: ruleSet.name,
                    policy: exportPolicy(
                        for: ruleSet,
                        nodeNames: nodeNames,
                        chainNames: chainNames,
                        notes: &notes
                    ),
                    rules: rules
                )
            )
        }

        if let moduleStore {
            let moduleRuleSets = moduleStore.modules
                .filter { $0.enabled }
                .flatMap { $0.routingRuleSets }
            if !moduleRuleSets.isEmpty {
                notes.append(
                    "\(moduleRuleSets.count) module rule set(s) are not exported: modules are refreshed from their own source."
                )
            }
        }

        self.init(
            proxies: proxies,
            groups: groups,
            ruleSets: ruleSets,
            chains: exportedChains,
            hosts: HostMapping.load(),
            settings: Self.exportSettings(),
            mitmEnabled: mitmRuleSetStore.isEnabled,
            mitmHostnames: Self.exportMITMHostnames(from: mitmRuleSetStore),
            mitmRuleSets: (moduleStore?.exportedMITMRuleSets ?? []) + mitmRuleSetStore.ruleSets,
            notes: notes
        )
    }

    init(container: AppContainer) {
        self.init(
            configurationStore: container.configurationStore,
            chainStore: container.chainStore,
            groupStore: container.groupStore,
            routingRuleSetStore: container.routingRuleSetStore,
            mitmRuleSetStore: container.mitmRuleSetStore,
            moduleStore: container.moduleStore
        )
    }
}

// MARK: - Settings and MITM

@MainActor
extension ConfigurationExportSource {

    /// The catalog is the source of this list, so `[General]` can never export a
    /// key the compiler does not read, or miss one the app can actually change.
    ///
    /// Values the app cannot report are left out rather than guessed: an empty
    /// string or list writes nothing.
    static func exportSettings() -> [Setting] {
        ConfigurationSettings.catalog.compactMap { key in
            guard key.applies,
                  let value = ConfigurationSettingsBindings.read(key.name),
                  !value.isEmpty
            else { return nil }
            return Setting(key: key.name, value: value.rendered)
        }
    }

    /// MITM hosts come from the enabled MITM rule sets: that list is what the
    /// app actually intercepts, so exporting anything else would lie about it.
    static func exportMITMHostnames(from store: MITMRuleSetStore) -> [String] {
        var seen = Set<String>()
        var hostnames: [String] = []
        for host in store.ruleSets.filter({ $0.enabled }).flatMap({ $0.domainSuffixes }) {
            let trimmed = host.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            hostnames.append(trimmed)
        }
        return hostnames
    }
}

// MARK: - Policy resolution

/// `RoutingRuleSetStore` stores a policy as a string: the built-in tokens or the
/// id of the node or chain the rules route through.
///
/// `nil` means the rule set decides nothing — `RoutingExportOperation` exports
/// those rules with a fallback action, which a text rule cannot express, so they
/// are reported instead of being given a policy they never had.
@MainActor
private func exportPolicy(
    for ruleSet: RoutingRuleSet,
    nodeNames: [UUID: String],
    chainNames: [UUID: String],
    notes: inout [String]
) -> String? {
    guard let raw = ruleSet.assignedConfigurationId?.trimmingCharacters(in: .whitespaces),
          !raw.isEmpty else {
        if ruleSet.id != "ADBlock" {
            notes.append("Rule set '\(ruleSet.name)' has no policy assigned, so its rules are not exported.")
        }
        return nil
    }

    switch raw.uppercased() {
    case "PROXY", "DIRECT", "REJECT":
        return raw.uppercased()
    default:
        break
    }

    guard let id = UUID(uuidString: raw) else {
        notes.append("Rule set '\(ruleSet.name)' points at '\(raw)', which is not a node or group.")
        return nil
    }
    if let name = nodeNames[id] {
        return name
    }
    if let name = chainNames[id] {
        notes.append(
            "Rule set '\(ruleSet.name)' routes through chain '\(name)', which a text configuration cannot express."
        )
        return nil
    }

    notes.append("Rule set '\(ruleSet.name)' points at a node that is no longer installed.")
    return nil
}

// MARK: - Formatting

private func flag(_ value: Bool) -> String {
    value ? "true" : "false"
}

/// `DNSUpstream.parsePlain` reads `1.1.1.1`, `1.1.1.1:5353`, `[::1]` and
/// `[::1]:53`, so the port is only written when it is not the default.
private func serverString(host: String, port: UInt16) -> String {
    let formatted = host.contains(":") ? "[\(host)]" : host
    return port == DNSUpstream.defaultPort ? formatted : "\(formatted):\(port)"
}


// MARK: - Entry points

@MainActor
extension ConfigurationExporter {

    /// One call for the editor's "start from what I already have": reads the
    /// stores and renders them.
    static func exportCurrentConfiguration(
        configurationStore: ConfigurationStore,
        chainStore: ChainStore,
        groupStore: GroupStore,
        routingRuleSetStore: RoutingRuleSetStore,
        mitmRuleSetStore: MITMRuleSetStore,
        moduleStore: ModuleStore? = nil,
        options: Options = Options()
    ) -> Result {
        export(
            ConfigurationExportSource(
                configurationStore: configurationStore,
                chainStore: chainStore,
                groupStore: groupStore,
                routingRuleSetStore: routingRuleSetStore,
                mitmRuleSetStore: mitmRuleSetStore,
                moduleStore: moduleStore
            ),
            options: options
        )
    }

    static func exportCurrentConfiguration(
        container: AppContainer,
        options: Options = Options()
    ) -> Result {
        exportCurrentConfiguration(
            configurationStore: container.configurationStore,
            chainStore: container.chainStore,
            groupStore: container.groupStore,
            routingRuleSetStore: container.routingRuleSetStore,
            mitmRuleSetStore: container.mitmRuleSetStore,
            moduleStore: container.moduleStore,
            options: options
        )
    }
}


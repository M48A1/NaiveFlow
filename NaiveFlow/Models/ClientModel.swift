import Foundation
import Observation

@MainActor
@Observable
final class ClientModel {
    private(set) var library = ClientProfileLibrary()
    private(set) var parsed = NaiveFlowConfigurationParser.parse(text: "").configuration
    private(set) var nodes: [ProxyConfiguration] = []
    private(set) var isBusy = false
    private(set) var hasApplied = false
    private(set) var liveGroups: [String: PolicyGroupsResponse.Group] = [:]
    var error: String?
    var message: String?
    @ObservationIgnored let operations: Operations
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let documentOverride: ConfigurationDocumentOperations?
    var document: ConfigurationDocumentOperations { documentOverride ?? operations.configurationDocument }
    @ObservationIgnored private var lastActiveText: String?

    init(operations: Operations, directory: URL = ClientProfileLibrary.directory, document: ConfigurationDocumentOperations? = nil) {
        self.documentOverride = document
        self.operations = operations
        self.directory = directory
        do { library = try ClientProfileLibrary.load(from: directory) }
        catch { self.error = "Could not load profiles: \(error.localizedDescription)" }
        let active = self.document.activation.active
        if library.profiles.isEmpty {
            let profile = ClientProfile(name: "Default Profile", text: active?.text ?? self.document.draft())
            library.profiles = [profile]
            library.selectedID = profile.id
        }
        if !library.profiles.contains(where: { $0.id == library.selectedID }) { library.selectedID = library.profiles.first?.id }
        refresh()
    }

    var profile: ClientProfile? { library.profiles.first { $0.id == library.selectedID } }
    var groups: [ParsedProxyGroup] { parsed.proxyGroups }
    var mode: ProxyMode { ProxyMode(rawValue: parsed.general["proxy-mode"] ?? "rule") ?? .rule }
    var selectedNodeName: String { parsed.general["default-node"] ?? self.document.selection?.effectiveConfiguration?.name ?? nodes.first?.name ?? "No Node Selected" }
    var modules: [ClientModule] {
        guard let profile else { return [] }
        return ClientResourceManager.modules(in: profile, parsed: parsed)
    }
    var activeName: String { profile?.displayName ?? "Profiles" }

    func refresh() {
        let active = self.document.activation.active
        hasApplied = self.document.selection?.usesRuntimeVersion == true
        if let active { lastActiveText = active.text }
        rebuild()
    }

    var operatingText: String { hasApplied ? lastActiveText ?? profile?.text ?? "" : profile?.text ?? "" }

    private func rebuild() {
        let result = TextConfigurationPipeline.process(text: operatingText)
        parsed = result.parsed
        let previous = nodes
        nodes = result.compiled.proxies.map { candidate in previous.first { $0.name == candidate.name && $0.toURLString() == candidate.toURLString() }?.withChain(candidate.chain) ?? candidate }
    }

    private func persist() throws { try library.save(to: directory) }
    func report(_ error: Error) { self.error = error.localizedDescription }

    func createProfile(name: String = "New Profile", text: String? = nil, sourceURL: String? = nil) -> ClientProfile {
        let profile = ClientProfile(name: name, text: text ?? TextConfigurationPipeline.template, sourceURL: sourceURL)
        library.profiles.append(profile)
        do { try persist() } catch { report(error) }
        return profile
    }

    @discardableResult
    func saveProfile(_ candidate: ClientProfile, apply: Bool, refreshingRuleSets: Set<String>? = nil) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await storeProfile(candidate, apply: apply, refreshingRuleSets: refreshingRuleSets)
            return true
        } catch { report(error); return false }
    }

    private func storeProfile(_ candidate: ClientProfile, apply: Bool, refreshingRuleSets: Set<String>?) async throws {
        var saved = candidate
        saved.updatedAt = .now
        if apply {
            _ = try await document.apply(saved.text, refreshingRuleSets: refreshingRuleSets)
            liveGroups = [:]
            library.selectedID = saved.id
            lastActiveText = saved.text
            hasApplied = true
        }
        if let index = library.profiles.firstIndex(where: { $0.id == saved.id }) { library.profiles[index] = saved }
        else { library.profiles.append(saved) }
        try persist()
        rebuild()
        message = apply ? "Applied \(saved.name)" : "Profile saved"
    }

    /// One entry point for external resource edits and one/many/all updates.
    @discardableResult
    func manageResource(_ request: ClientResourceRequest, fetch: ClientResourceManager.FetchText? = nil) async -> Bool {
        do { return try await runResource(request, fetch: fetch) }
        catch { report(error); return false }
    }

    private func runResource(_ request: ClientResourceRequest, fetch: ClientResourceManager.FetchText? = nil) async throws -> Bool {
        guard !isBusy, let original = profile else { return false }
        let originalText = operatingText
        isBusy = true
        defer { isBusy = false }
        try Task.checkCancellation()
        let subscriptionFetch: ClientResourceManager.FetchSubscription? = fetch == nil
            ? { [self] subscription in try await fetchNodeSubscriptionText(subscription) } : nil
        guard let change = try await ClientResourceManager.prepare(request, profile: original, text: originalText,
            fetch: fetch ?? { [self] source in try await fetchText(source) }, fetchSubscription: subscriptionFetch) else { return false }
        guard profile == original, operatingText == originalText else {
            throw ClientFailure("The current profile has changed. Reopen the resource and try again.")
        }
        try Task.checkCancellation()
        try await storeProfile(change.profile, apply: change.apply, refreshingRuleSets: change.refreshingRuleSets)
        return true
    }

    func activate(_ profile: ClientProfile) async { _ = await saveProfile(profile, apply: true) }

    func deleteProfile(_ id: UUID) {
        guard id != library.selectedID else { error = "Switch to another profile before deleting the current profile."; return }
        library.profiles.removeAll { $0.id == id }
        do { try persist() } catch { report(error) }
    }

    func updateProfile(_ profile: ClientProfile) async {
        guard let source = profile.sourceURL else { return }
        do {
            var candidate = profile
            candidate.text = try await fetchText(source)
            _ = await saveProfile(candidate, apply: profile.id == library.selectedID && hasApplied)
        } catch { report(error) }
    }

    func fetchText(_ source: String) async throws -> String {
        guard let url = URL(string: source), url.scheme?.lowercased() == "https", url.host != nil else {
            throw ClientFailure("Enter a valid HTTPS URL.")
        }
        let (data, response) = try await BoundedHTTPFetcher.fetch(url, maxBytes: ConfigurationImport.maximumBytes)
        guard (200...299).contains(response.statusCode), response.url?.scheme?.lowercased() == "https",
              let text = String(data: data, encoding: .utf8) else { throw ClientFailure("Download failed or the file is not UTF-8 text.") }
        return ConfigurationImport.normalize(text)
    }

    private func fetchNodeSubscriptionText(_ subscription: ClientNodeSubscription) async throws -> String {
        guard let url = URL(string: subscription.url), url.scheme?.lowercased() == "https", url.host != nil else {
            throw ClientFailure("Enter a valid HTTPS URL.")
        }
        let request = SubscriptionFetcher.request(url: url, remnawaveHWIDEnabled: subscription.remnawaveHWIDEnabled)
        let (data, response) = try await BoundedHTTPFetcher.fetch(request, maxBytes: ConfigurationImport.maximumBytes)
        guard (200...299).contains(response.statusCode), response.url?.scheme?.lowercased() == "https",
              let text = String(data: data, encoding: .utf8) else { throw ClientFailure("Download failed or the file is not UTF-8 text.") }
        return ConfigurationImport.normalize(text)
    }

    @discardableResult
    func commit(_ text: String, moduleUpdate: [ClientModule]? = nil, styles: [String: ClientGroupStyle]? = nil, subscriptions: [ClientNodeSubscription]? = nil, refreshingRuleSets: Set<String>? = nil) async -> Bool {
        guard var candidate = profile else { return false }
        candidate.text = text
        if let moduleUpdate { candidate.modules = moduleUpdate }
        if let styles { candidate.groupStyles = styles }
        if let subscriptions { candidate.nodeSubscriptions = subscriptions }
        return await saveProfile(candidate, apply: true, refreshingRuleSets: refreshingRuleSets)
    }

    func setSetting(_ key: String, value: String, section: ConfigurationDocument.SectionKind = .general) async {
        guard profile != nil else { return }
        let text = operatingText
        _ = await commit(ClientDocumentEditing.set(text, section: section, key: key, value: value))
    }

    func selectNode(_ name: String) async { await setSetting("default-node", value: ClientDocumentEditing.token(name)) }

    func selectMember(_ member: String, in group: ParsedProxyGroup) async {
        let parameters = group.parameters.pairs.filter { $0.0 != "selected" } + [("selected", member)]
        // A manual choice is explicit Select; automatic groups retain their strategy until edited.
        let value = ClientDocumentEditing.groupValue(kind: "select", members: group.members, parameters: parameters.filter { !["interval", "url", "tolerance"].contains($0.0) })
        guard profile != nil else { return }
        let text = operatingText
        _ = await commit(ClientDocumentEditing.set(text, section: .proxyGroup, key: group.name, value: value))
    }

    func selectedMember(in group: ParsedProxyGroup) -> String {
        let group = resolvedGroup(group)
        if group.kind != .select, let live = liveGroups[group.name]?.nextMember {
            return group.kind == .loadBalance ? "Round Robin · " + live : live
        }
        if group.kind == .select { return group.parameters["selected"] ?? group.members.first ?? "No Members" }
        switch group.kind {
        case .urlTest: return "Auto · Lowest Latency"
        case .fallback: return "Auto · Fallback"
        case .loadBalance: return "Auto · Load Balance"
        default: return group.members.first ?? "No Members"
        }
    }

    func resolvedGroup(_ group: ParsedProxyGroup) -> ParsedProxyGroup {
        var diagnostics: [ConfigurationDiagnostic] = []
        return ProxyGroupMembership.resolve(parsed, diagnostics: &diagnostics).proxyGroup(named: group.name) ?? group
    }

    func pollPolicyStatus() async {
        guard let tunnel = document.tunnel, tunnel.hasRunningTunnel,
              let data = await tunnel.send(.fetchPolicyGroups),
              let response = try? JSONDecoder().decode(PolicyGroupsResponse.self, from: data),
              let head = try? RuntimeBundleStore(directory: document.activation.store.directory.appendingPathComponent("runtime-v2")).head(),
              response.versionID == head.current else { liveGroups = [:]; return }
        liveGroups = Dictionary(response.groups.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func renameReferences(_ text: String, from old: String, to new: String) -> String {
        guard old != new else { return text }
        let parsed = NaiveFlowConfigurationParser.parse(text: text).configuration
        var result = text
        for group in parsed.proxyGroups {
            var parameters = group.parameters.pairs
            if parameters.contains(where: { $0.0 == "selected" && $0.1 == old }) {
                parameters = parameters.map { $0.0 == "selected" && $0.1 == old ? ($0.0, new) : $0 }
            }
            if group.members.contains(old) || group.parameters["selected"] == old {
                result = ClientDocumentEditing.set(result, section: .proxyGroup, key: group.name,
                    value: ClientDocumentEditing.groupValue(kind: group.kindToken, members: group.members.map { $0 == old ? new : $0 }, parameters: parameters))
            }
        }
        var document = ConfigurationDocument.parse(text: result)
        let rules = NaiveFlowConfigurationParser.parse(text: result).configuration.rules
        for rule in rules where rule.policy == .named(old) {
            let parts = ConfigurationDocument.splitExpression(rule.raw)
            var updated = parts
            let policyIndex = rule.isFinal ? 1 : 2
            if updated.indices.contains(policyIndex) { updated[policyIndex] = ClientDocumentEditing.token(new) }
            let comment = document.line(rule.line)?.comment.map { "  # " + $0 } ?? ""
            document = document.replacingLine(rule.line, with: updated.joined(separator: ", ") + comment)
        }
        result = document.text
        for chain in parsed.chains where chain.members.contains(old) {
            result = ClientDocumentEditing.set(result, section: .chain, key: chain.name,
                value: chain.members.map { ClientDocumentEditing.token($0 == old ? new : $0) }.joined(separator: ", "))
        }
        for node in nodes where node.underlyingProxy == old {
            var updated = node
            updated.underlyingProxy = new
            result = ClientDocumentEditing.set(result, section: .proxy, key: node.name, value: updated.toURLString())
        }
        if parsed.general["default-node"] == old { result = ClientDocumentEditing.set(result, section: .general, key: "default-node", value: ClientDocumentEditing.token(new)) }
        return result
    }

    @discardableResult
    func importNodes(_ source: String, subscriptionURL: String? = nil, subscription: ClientNodeSubscription? = nil) async throws -> Bool {
        try await runResource(.importNodes(source, subscriptionURL: subscriptionURL, subscription: subscription))
    }

    func saveNode(_ node: ProxyConfiguration, replacing old: String? = nil) async {
        guard profile != nil else { return }
        var text = operatingText
        if let old, old != node.name {
            guard !nodes.contains(where: { $0.name == node.name }) else { error = "A node with this name already exists."; return }
            text = renameReferences(text, from: old, to: node.name)
            text = ClientDocumentEditing.renameKey(text, section: .proxy, from: old, to: node.name)
        }
        text = ClientDocumentEditing.set(text, section: .proxy, key: node.name, value: node.toURLString())
        var subscriptions = profile?.nodeSubscriptions ?? []
        for index in subscriptions.indices {
            for member in subscriptions[index].members.indices where subscriptions[index].members[member].name == (old ?? node.name) {
                subscriptions[index].members[member].name = node.name
                subscriptions[index].members[member].edited = true
            }
        }
        _ = await commit(text, subscriptions: subscriptions)
    }

    func refreshNodeSubscriptions(ids: Set<UUID>? = nil, fetch: ClientResourceManager.FetchText? = nil) async -> Bool {
        await manageResource(.update(.subscriptions(ids: ids)), fetch: fetch)
    }

    func deleteNode(_ name: String) async {
        guard profile != nil else { return }
        var text = operatingText
        if nodes.contains(where: { $0.underlyingProxy == name }) || parsed.rules.contains(where: { $0.policy == .named(name) }) || parsed.chains.contains(where: { $0.members.contains(name) }) {
            error = "This node is still referenced by rules or a proxy chain. Update those references first."; return
        }
        text = ClientDocumentEditing.set(text, section: .proxy, key: name, value: nil)
        for group in groups where group.members.contains(name) {
            let members = group.members.filter { $0 != name }
            guard !members.isEmpty else { error = "\(group.name) requires at least one member."; return }
            let parameters = group.parameters.pairs.filter { !($0.0 == "selected" && $0.1 == name) }
            text = ClientDocumentEditing.set(text, section: .proxyGroup, key: group.name,
                value: ClientDocumentEditing.groupValue(kind: group.kindToken, members: members, parameters: parameters))
        }
        if parsed.general["default-node"] == name { text = ClientDocumentEditing.set(text, section: .general, key: "default-node", value: nil) }
        _ = await commit(text)
    }

    func reorderNodes(_ names: [String]) async {
        guard profile != nil else { return }
        let text = operatingText
        _ = await commit(ClientDocumentEditing.reorder(text, section: .proxy, keys: names))
    }

    func saveGroup(original: String?, name: String, kind: String, members: [String], parameters: [(String,String)], style: ClientGroupStyle) async -> Bool {
        guard profile != nil else { return false }
        guard ConfigurationValidator.builtInPolicyName(name) != "PROXY",
              original.map({ ConfigurationValidator.builtInPolicyName($0) != "PROXY" }) ?? true else {
            error = "PROXY is the built-in group containing all nodes and cannot be modified."; return false
        }
        var text = operatingText
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !members.isEmpty else { error = "Enter a name and select at least one member."; return false }
        if original != name, groups.contains(where: { $0.name == name }) { error = "A group with this name already exists."; return false }
        var styles = profile?.groupStyles ?? [:]
        if let original, original != name {
            text = renameReferences(text, from: original, to: name)
            text = ClientDocumentEditing.renameKey(text, section: .proxyGroup, from: original, to: name)
            styles.removeValue(forKey: original)
        }
        text = ClientDocumentEditing.set(text, section: .proxyGroup, key: name,
            value: ClientDocumentEditing.groupValue(kind: kind, members: members, parameters: parameters))
        styles[name] = style
        return await commit(text, styles: styles)
    }

    func deleteGroup(_ name: String) async {
        guard profile != nil else { return }
        guard ConfigurationValidator.builtInPolicyName(name) != "PROXY" else {
            error = "PROXY is the built-in group containing all nodes and cannot be deleted."; return
        }
        let text = operatingText
        if groups.contains(where: { $0.members.contains(name) }) || parsed.rules.contains(where: { $0.policy == .named(name) }) {
            error = "This group is still referenced by rules or other groups. Update those references first."; return
        }
        var styles = profile?.groupStyles ?? [:]
        styles.removeValue(forKey: name)
        _ = await commit(ClientDocumentEditing.set(text, section: .proxyGroup, key: name, value: nil), styles: styles)
    }

    func reorderGroups(_ names: [String]) async {
        guard profile != nil else { return }
        let text = operatingText
        _ = await commit(ClientDocumentEditing.reorder(text, section: .proxyGroup, keys: names))
    }

    func saveModule(_ candidate: ClientModule) async -> Bool {
        await manageResource(.save(.module(candidate)))
    }

    func toggleModule(_ module: ClientModule, enabled: Bool) async {
        await manageResource(.save(.moduleEnabled(module.id, enabled)))
    }

    func deleteModule(_ module: ClientModule) async {
        await manageResource(.delete(.module(module.id)))
    }

    func refreshAllModules(fetch: ClientResourceManager.FetchText? = nil) async -> Bool {
        await manageResource(.update(.modules()), fetch: fetch)
    }

}

nonisolated struct ClientFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

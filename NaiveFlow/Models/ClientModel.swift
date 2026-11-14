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
    var subscriptionReview: ClientSubscriptionReview?
    private(set) var resourceActivity: [String: ClientResourceActivity] = [:]
    private(set) var activeResourceTitle: String?
    @ObservationIgnored private var cancelResource: (() -> Void)?
    @ObservationIgnored let operations: Operations
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let documentOverride: ConfigurationDocumentOperations?
    var document: ConfigurationDocumentOperations { documentOverride ?? operations.configurationDocument }
    @ObservationIgnored private var lastActiveText: String?
    @ObservationIgnored private var rebuiltText: String?

    init(operations: Operations, directory: URL = ClientProfileLibrary.directory, document: ConfigurationDocumentOperations? = nil) {
        self.documentOverride = document
        self.operations = operations
        self.directory = directory
        do { library = try ClientProfileLibrary.load(from: directory) }
        catch { self.error = "Could not load profiles: \(error.localizedDescription)" }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("resource-activity.json")),
           let activity = try? JSONDecoder().decode([String: ClientResourceActivity].self, from: data) { resourceActivity = activity.mapValues { value in var entry = value; entry.awaitingReview = false; return entry } }
        let active = activeSnapshot
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

    private var activeSnapshot: ConfigurationSnapshot? {
        guard let id = document.activation.store.manifest().activeSnapshotId else { return nil }
        return document.activation.store.snapshot(id)
    }

    func refresh() {
        let active = activeSnapshot
        hasApplied = self.document.selection?.usesRuntimeVersion == true
        if let active { lastActiveText = active.text }
        rebuild()
    }

    var operatingText: String { hasApplied ? lastActiveText ?? profile?.text ?? "" : profile?.text ?? "" }

    private func rebuild() {
        let text = operatingText
        guard rebuiltText != text else { return }
        installDisplay(TextConfigurationPipeline.process(text: text), text: text)
    }

    private func rebuildAfterSave() async {
        let text = operatingText
        guard rebuiltText != text else { return }
        let result = await Task.detached(priority: .userInitiated) { TextConfigurationPipeline.process(text: text) }.value
        guard operatingText == text else { return }
        installDisplay(result, text: text)
    }

    private func installDisplay(_ result: TextConfigurationPipeline.Result, text: String) {
        parsed = result.parsed
        struct NodeKey: Hashable { let name: String; let url: String }
        let previous = Dictionary(nodes.map { (NodeKey(name: $0.name, url: $0.toURLString()), $0) },
                                  uniquingKeysWith: { first, _ in first })
        nodes = result.compiled.proxies.map { candidate in
            previous[NodeKey(name: candidate.name, url: candidate.toURLString())]?.withChain(candidate.chain) ?? candidate
        }
        rebuiltText = text
    }

    func report(_ error: Error) { self.error = error.localizedDescription }

    func createProfile(name: String = "New Profile", text: String? = nil, sourceURL: String? = nil) -> ClientProfile {
        let profile = ClientProfile(name: name, text: text ?? TextConfigurationPipeline.template, sourceURL: sourceURL)
        guard !isBusy else { error = "Wait for the current profile operation to finish."; return profile }
        var next = library
        next.profiles.append(profile)
        do { try next.save(to: directory); library = next } catch { report(error) }
        return profile
    }

    @discardableResult
    func saveProfile(_ candidate: ClientProfile, apply: Bool, refreshingRuleSets: Set<String>? = nil) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try Task.checkCancellation()
            try await storeProfile(candidate, apply: apply, refreshingRuleSets: refreshingRuleSets)
            return true
        } catch { report(error); return false }
    }

    private func storeProfile(_ candidate: ClientProfile, apply: Bool, refreshingRuleSets: Set<String>?) async throws {
        var saved = candidate
        saved.updatedAt = .now
        let original = library
        var next = original
        if let index = next.profiles.firstIndex(where: { $0.id == saved.id }) { next.profiles[index] = saved }
        else { next.profiles.append(saved) }
        if apply { next.selectedID = saved.id }
        // A failed local write must never publish a new runtime configuration.
        // Keep the observable library unchanged until both steps succeed.
        try next.save(to: directory)
        if apply {
            do { _ = try await document.apply(saved.text, refreshingRuleSets: refreshingRuleSets) }
            catch {
                let failure = error
                do { try original.save(to: directory) }
                catch { throw ClientFailure("\(failure.localizedDescription) Could not restore the profile library: \(error.localizedDescription)") }
                throw failure
            }
            liveGroups = [:]
            lastActiveText = saved.text
            hasApplied = true
        }
        library = next
        await rebuildAfterSave()
        message = apply ? "Applied \(saved.name)" : "Profile saved"
    }

    /// One entry point for external resource edits and one/many/all updates.
    @discardableResult
    func manageResource(_ request: ClientResourceRequest, fetch: ClientResourceManager.FetchText? = nil) async -> Bool {
        guard !isBusy, cancelResource == nil else { return false }
        let descriptors = descriptors(for: request)
        beginActivity(descriptors)
        let task = Task { try await self.runResource(request, fetch: fetch) }
        cancelResource = { task.cancel() }
        defer { cancelResource = nil; activeResourceTitle = nil }
        do {
            let success = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            finishActivity(descriptors.map(\.id), error: success ? nil : "No resources were changed.")
            return success
        } catch {
            finishActivity(descriptors.map(\.id), error: Task.isCancelled || task.isCancelled || error is CancellationError ? "Cancelled" : error.localizedDescription)
            if !Task.isCancelled && !task.isCancelled && !(error is CancellationError) { report(error) }
            return false
        }
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
        if change.apply { try requireAppliedDraft() }
        try await storeProfile(change.profile, apply: change.apply, refreshingRuleSets: change.refreshingRuleSets)
        return true
    }

    func activate(_ profile: ClientProfile) async { _ = await saveProfile(profile, apply: true) }

    func deleteProfile(_ id: UUID) {
        guard !isBusy else { return }
        guard id != library.selectedID else { error = "Switch to another profile before deleting the current profile."; return }
        var next = library
        next.profiles.removeAll { $0.id == id }
        do { try next.save(to: directory); library = next } catch { report(error) }
    }

    func updateProfile(_ profile: ClientProfile, fetch: ClientResourceManager.FetchText? = nil) async {
        guard !isBusy, let source = profile.sourceURL,
              library.profiles.first(where: { $0.id == profile.id }) == profile else { return }
        isBusy = true
        defer { isBusy = false }
        let originalText = operatingText
        do {
            try Task.checkCancellation()
            var candidate = profile
            candidate.text = try await (fetch ?? { [self] in try await fetchText($0) })(source)
            try Task.checkCancellation()
            guard library.profiles.first(where: { $0.id == profile.id }) == profile,
                  operatingText == originalText else {
                throw ClientFailure("The profile has changed. Reopen it and try again.")
            }
            try await storeProfile(candidate, apply: profile.id == library.selectedID && hasApplied, refreshingRuleSets: nil)
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
        let (data, response) = try await SubscriptionFetcher.fetchResponse(request, maxBytes: ConfigurationImport.maximumBytes)
        guard (200...299).contains(response.statusCode), response.url?.scheme?.lowercased() == "https",
              let text = String(data: data, encoding: .utf8) else { throw ClientFailure("Download failed or the file is not UTF-8 text.") }
        return ConfigurationImport.normalize(text)
    }

    @discardableResult
    func commit(_ text: String, moduleUpdate: [ClientModule]? = nil, styles: [String: ClientGroupStyle]? = nil, subscriptions: [ClientNodeSubscription]? = nil, refreshingRuleSets: Set<String>? = nil) async -> Bool {
        guard var candidate = profile else { return false }
        do { try requireAppliedDraft() }
        catch { report(error); return false }
        candidate.text = text
        if let moduleUpdate { candidate.modules = moduleUpdate }
        if let styles { candidate.groupStyles = styles }
        if let subscriptions { candidate.nodeSubscriptions = subscriptions }
        return await saveProfile(candidate, apply: true, refreshingRuleSets: refreshingRuleSets)
    }

    private func requireAppliedDraft() throws {
        guard !hasApplied || profile?.text == operatingText else {
            throw ClientFailure("This profile has saved changes that are not applied. Open the profile and apply or discard those changes before editing the running configuration.")
        }
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
        var subscriptions = profile?.nodeSubscriptions ?? []
        for index in subscriptions.indices { subscriptions[index].members.removeAll { $0.name == name } }
        _ = await commit(text, subscriptions: subscriptions)
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


extension ClientModel {
    var hasSavedDraft: Bool { hasApplied && profile?.text != operatingText }
    var runningSnapshotID: UUID? { document.activation.store.manifest().activeSnapshotId }
    var isRuntimeConfirmed: Bool { document.activation.store.isActiveSnapshotConfirmed() }

    func restoreRunningDraft() async -> Bool {
        guard var candidate = profile, hasApplied else { return false }
        candidate.text = operatingText
        return await saveProfile(candidate, apply: false)
    }

    func removeNodes(_ names: Set<String>) async -> Bool {
        guard !names.isEmpty else { return false }
        do {
            let text = try ClientNodeTools.removing(names, from: operatingText)
            var subscriptions = profile?.nodeSubscriptions ?? []
            for index in subscriptions.indices { subscriptions[index].members.removeAll { names.contains($0.name) } }
            return await commit(text, subscriptions: subscriptions)
        } catch { report(error); return false }
    }

    func addNodes(_ names: Set<String>, to groupName: String) async -> Bool {
        guard !names.isEmpty, let group = groups.first(where: { $0.name == groupName }),
              names.isSubset(of: Set(nodes.map(\.name))) else { return false }
        let members = group.members + nodes.filter { names.contains($0.name) && !group.members.contains($0.name) }.map(\.name)
        let value = ClientDocumentEditing.groupValue(kind: group.kindToken, members: members, parameters: group.parameters.pairs)
        return await commit(ClientDocumentEditing.set(operatingText, section: .proxyGroup, key: group.name, value: value))
    }

    func restoreBackup(_ backup: ClientBackup, replaceMatches: Bool) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let merged = backup.merging(into: library, replaceMatches: replaceMatches)
            try merged.save(to: directory)
            library = merged
            await rebuildAfterSave()
            message = "Profiles restored. Apply a profile when you are ready."
            return true
        } catch { report(error); return false }
    }

    var resources: [ClientResourceDescriptor] {
        guard let profile else { return [] }
        var result = (profile.nodeSubscriptions ?? []).map {
            ClientResourceDescriptor(id: "subscription:" + $0.id.uuidString, name: $0.name, kind: "Subscription", source: $0.url)
        }
        result += profile.modules.filter { $0.sourceURL?.isEmpty == false }.map {
            ClientResourceDescriptor(id: "module:" + $0.id.uuidString, name: $0.name, kind: "Module", source: $0.sourceURL ?? "")
        }
        let sets = Set(parsed.rules.filter { $0.kind == .ruleSet }.compactMap(\.value))
        result += sets.sorted().map { ClientResourceDescriptor(id: "rules:" + $0, name: URL(string: $0)?.lastPathComponent ?? $0, kind: "Rule Set", source: $0) }
        result += ((try? NativeGeoResources.references(parsed)) ?? []).map {
            ClientResourceDescriptor(id: "geo:" + $0.key + ":" + String($0.site), name: $0.key, kind: $0.site ? "GeoSite" : "GeoIP", source: $0.url.absoluteString)
        }
        return result
    }

    private func descriptors(for request: ClientResourceRequest) -> [ClientResourceDescriptor] {
        guard case .update(let scope) = request else { return [] }
        switch scope {
        case .subscriptions(let ids):
            let allowed = ids.map { Set($0.map { "subscription:" + $0.uuidString }) }
            return resources.filter { $0.kind == "Subscription" && (allowed?.contains($0.id) ?? true) }
        case .subscription(let sub): return [ClientResourceDescriptor(id: "subscription:" + sub.id.uuidString, name: sub.name, kind: "Subscription", source: sub.url)]
        case .subscriptionURL(let url): return resources.filter { $0.kind == "Subscription" && $0.source == url }
        case .modules(let ids):
            let allowed = ids.map { Set($0.map { "module:" + $0.uuidString }) }
            return resources.filter { $0.kind == "Module" && (allowed?.contains($0.id) ?? true) }
        case .ruleSets(let sources): return resources.filter { $0.kind == "Rule Set" && (sources?.contains($0.source) ?? true) }
        case .geo: return resources.filter { $0.kind == "GeoIP" || $0.kind == "GeoSite" }
        }
    }

    private func beginActivity(_ resources: [ClientResourceDescriptor]) {
        activeResourceTitle = resources.isEmpty ? "Updating configuration" : "Updating \(resources.count) resource(s)"
        for resource in resources {
            var entry = resourceActivity[resource.id] ?? ClientResourceActivity()
            entry.attemptedAt = .now; entry.error = nil; entry.awaitingReview = false
            resourceActivity[resource.id] = entry
        }
        saveActivity()
    }

    private func finishActivity(_ ids: [String], error: String?, awaitingReview: Bool = false) {
        for id in ids {
            var entry = resourceActivity[id] ?? ClientResourceActivity()
            entry.error = error; entry.awaitingReview = awaitingReview
            if error == nil && !awaitingReview {
                entry.succeededAt = .now
                entry.version = runningSnapshotID?.uuidString
            }
            resourceActivity[id] = entry
        }
        saveActivity()
    }

    private func saveActivity() {
        guard let data = try? JSONEncoder().encode(resourceActivity) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("resource-activity.json"), options: .atomic)
    }

    func cancelResourceOperation() { cancelResource?() }

    func prepareSubscriptionUpdate(ids: Set<UUID>? = nil, fetch: ClientResourceManager.FetchText? = nil) async -> Bool {
        guard !isBusy, cancelResource == nil, let original = profile else { return false }
        let text = operatingText
        let scope = ClientResourceRequest.update(.subscriptions(ids: ids))
        let descriptors = descriptors(for: scope)
        guard !descriptors.isEmpty else { return false }
        beginActivity(descriptors)
        let task = Task { () throws -> ClientResourceManager.Change? in
            guard !self.isBusy else { return nil }
            self.isBusy = true
            defer { self.isBusy = false }
            try self.requireAppliedDraft()
            try Task.checkCancellation()
            let subscriptionFetch: ClientResourceManager.FetchSubscription? = fetch == nil ? { [self] sub in try await fetchNodeSubscriptionText(sub) } : nil
            return try await ClientResourceManager.prepare(scope, profile: original, text: text,
                fetch: fetch ?? { [self] in try await fetchText($0) }, fetchSubscription: subscriptionFetch)
        }
        cancelResource = { task.cancel() }
        defer { cancelResource = nil; activeResourceTitle = nil }
        do {
            guard let change = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() }) else { return false }
            try Task.checkCancellation()
            guard profile == original, operatingText == text else { throw ClientFailure("The profile changed. Download the update again.") }
            let old = TextConfigurationPipeline.process(text: text).compiled.proxies
            let new = TextConfigurationPipeline.process(text: change.profile.text).compiled.proxies
            let oldByName = Dictionary(old.map { ($0.name, $0.toURLString()) }, uniquingKeysWith: { first, _ in first })
            let newByName = Dictionary(new.map { ($0.name, $0.toURLString()) }, uniquingKeysWith: { first, _ in first })
            let selected = (original.nodeSubscriptions ?? []).filter { ids?.contains($0.id) ?? true }
            let currentMembers = Set((change.profile.nodeSubscriptions ?? []).filter { sub in selected.contains { $0.id == sub.id } }.flatMap(\.members).map(\.name))
            let missing = selected.flatMap(\.members).filter { !currentMembers.contains($0.name) }
            let removable = Set(missing.filter { member in
                guard !member.edited, let url = oldByName[member.name] else { return false }
                return member.importedURL.map { $0 == String(url.split(separator: "#", maxSplits: 1)[0]) } ?? true
            }.map(\.name))
            let preserved = selected.flatMap(\.members).filter { $0.edited && oldByName[$0.name] != nil }.map(\.name)
            subscriptionReview = ClientSubscriptionReview(original: original, originalText: text, change: change,
                added: new.filter { oldByName[$0.name] == nil }.map(\.name),
                modified: new.filter { oldByName[$0.name] != nil && oldByName[$0.name] != newByName[$0.name] }.map(\.name),
                missing: missing.map(\.name), preserved: preserved, removable: removable, resourceIDs: descriptors.map(\.id))
            finishActivity(descriptors.map(\.id), error: nil, awaitingReview: true)
            return true
        } catch {
            finishActivity(descriptors.map(\.id), error: task.isCancelled || error is CancellationError ? "Cancelled" : error.localizedDescription)
            if !Task.isCancelled && !task.isCancelled && !(error is CancellationError) { report(error) }
            return false
        }
    }

    func applySubscriptionReview(_ review: ClientSubscriptionReview, removeMissing: Bool) async -> Bool {
        guard !isBusy else { return false }
        do {
            guard profile == review.original, operatingText == review.originalText else { throw ClientFailure("The profile changed. Download the update again.") }
            var candidate = review.change.profile
            if removeMissing { candidate.text = try ClientNodeTools.removing(review.removable, from: candidate.text) }
            let success = await saveProfile(candidate, apply: true, refreshingRuleSets: review.change.refreshingRuleSets)
            finishActivity(review.resourceIDs, error: success ? nil : error ?? "The update could not be applied.")
            if success { subscriptionReview = nil }
            return success
        } catch { report(error); return false }
    }
}


extension ClientModel {
    func discardSubscriptionReview() {
        guard let review = subscriptionReview else { return }
        for id in review.resourceIDs { resourceActivity[id]?.awaitingReview = false }
        saveActivity()
        subscriptionReview = nil
    }
}

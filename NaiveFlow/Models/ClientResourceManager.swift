import Foundation

nonisolated enum ClientResourceScope {
    case subscriptions(ids: Set<UUID>? = nil)
    case subscription(ClientNodeSubscription)
    case subscriptionURL(String)
    case modules(ids: Set<UUID>? = nil)
    case ruleSets(sources: Set<String>? = nil)
    case geo(site: Bool)
}

nonisolated enum ClientResourceEdit {
    case subscription(ClientNodeSubscription)
    case module(ClientModule)
    case moduleEnabled(UUID, Bool)
    case ruleSet(original: ParsedRule?, source: String, policy: String, noResolve: Bool)
    case geo(ClientGeoSourceDraft, site: Bool)
}

nonisolated enum ClientResourceReference {
    case subscription(UUID)
    case module(UUID)
    case ruleSet(ParsedRule)
    case geo(ClientGeoSourceDraft, site: Bool)
}

nonisolated enum ClientResourceRequest {
    case update(ClientResourceScope)
    case save(ClientResourceEdit)
    case delete(ClientResourceReference)
    case importNodes(String, subscriptionURL: String?, subscription: ClientNodeSubscription?)
}

/// Stages complete resource changes without touching the live model or stores.
/// ClientModel owns the operation lock and publishes a prepared change once.
@MainActor
enum ClientResourceManager {
    typealias FetchText = (String) async throws -> String
    typealias FetchSubscription = (ClientNodeSubscription) async throws -> String

    struct Change {
        var profile: ClientProfile
        var apply = true
        // Other providers remain pinned unless the operation refreshes them.
        var refreshingRuleSets: Set<String>? = []
    }

    static func modules(in profile: ClientProfile, parsed: ParsedConfiguration) -> [ClientModule] {
        profile.modules.map { source in
            var module = source
            let sets = source.setKeys.compactMap { key -> MITMRuleSet? in
                guard let encoded = parsed.mitmSets[key], encoded.hasPrefix("base64:"),
                      let data = Data(base64Encoded: String(encoded.dropFirst(7))) else { return nil }
                return try? JSONDecoder().decode(MITMRuleSet.self, from: data)
            }
            module.enabled = !sets.isEmpty && sets.allSatisfy(\.enabled)
            return module
        }
    }

    static func prepare(_ request: ClientResourceRequest, profile: ClientProfile, text: String,
                        fetch: FetchText, fetchSubscription: FetchSubscription? = nil) async throws -> Change? {
        var change = Change(profile: profile)
        change.profile.text = text
        switch request {
        case .importNodes(let source, let url, let subscription):
            change.profile = try importingNodes(source, into: change.profile, url: url, subscription: subscription)
        case .update(let scope):
            switch scope {
            case .subscriptions(let ids):
                let selected = (profile.nodeSubscriptions ?? []).filter { ids?.contains($0.id) ?? true }
                guard !selected.isEmpty else { return nil }
                for subscription in selected {
                    change.profile = try await updateSubscription(subscription, in: change.profile, fetch: fetch, fetchSubscription: fetchSubscription)
                }
            case .subscription(let subscription):
                change.profile = try await updateSubscription(subscription, in: change.profile, fetch: fetch, fetchSubscription: fetchSubscription)
            case .subscriptionURL(let url):
                let subscription = profile.nodeSubscriptions?.first { $0.url == url }
                    ?? ClientNodeSubscription(name: URL(string: url)?.host ?? "Subscription", url: url)
                change.profile = try await updateSubscription(subscription, in: change.profile, fetch: fetch, fetchSubscription: fetchSubscription)
            case .modules(let ids):
                let parsed = NaiveFlowConfigurationParser.parse(text: text).configuration
                let selected = modules(in: profile, parsed: parsed).filter {
                    $0.sourceURL?.isEmpty == false && (ids?.contains($0.id) ?? true)
                }
                guard !selected.isEmpty else { return nil }
                for var module in selected {
                    do {
                        module.source = try await fetch(try remoteURL(module.sourceURL ?? "").absoluteString)
                        change.profile = try await installingModule(module, into: change.profile)
                    } catch { throw ClientFailure("\(module.name): \(error.localizedDescription)") }
                }
            case .ruleSets(let sources):
                let available = Set(NaiveFlowConfigurationParser.parse(text: text).configuration.rules
                    .filter { $0.kind == .ruleSet }.compactMap(\.value))
                guard !available.isEmpty else { return nil }
                if let sources {
                    guard sources.isSubset(of: available) else { throw ClientFailure("The rule set sources have changed. Reopen the list.") }
                    guard !sources.isEmpty else { return nil }
                }
                change.refreshingRuleSets = sources
            case .geo(let site):
                let parsed = NaiveFlowConfigurationParser.parse(text: text).configuration
                guard try NativeGeoResources.references(parsed).contains(where: { $0.site == site }) else { return nil }
            }
        case .save(let edit):
            switch edit {
            case .subscription(let subscription):
                try validateSubscription(subscription)
                upsertSubscription(subscription, in: &change.profile)
                change.apply = false
            case .module(let module):
                change.profile = try await installingModule(module, into: change.profile)
            case .moduleEnabled(let id, let enabled):
                let parsed = NaiveFlowConfigurationParser.parse(text: text).configuration
                guard let index = change.profile.modules.firstIndex(where: { $0.id == id }) else { throw missingResource() }
                let module = change.profile.modules[index]
                for key in module.setKeys {
                    guard let encoded = parsed.mitmSets[key], encoded.hasPrefix("base64:"),
                          let data = Data(base64Encoded: String(encoded.dropFirst(7))) else { throw missingResource() }
                    var set = try JSONDecoder().decode(MITMRuleSet.self, from: data)
                    set.enabled = enabled
                    change.profile.text = ClientDocumentEditing.set(change.profile.text, section: .mitmSet, key: key,
                        value: "base64:" + (try JSONEncoder().encode(set)).base64EncodedString())
                }
                change.profile.modules[index].enabled = enabled
            case .ruleSet(let original, let source, let policy, let noResolve):
                change.profile.text = try ClientDocumentEditing.saveRuleSet(text, original: original, source: source, policy: policy, noResolve: noResolve)
                // A changed/new source is fetched; unrelated providers stay pinned.
                change.refreshingRuleSets = [source.trimmingCharacters(in: .whitespacesAndNewlines)]
            case .geo(let draft, let site):
                change.profile.text = try draft.applying(to: text, site: site)
            }
        case .delete(let reference):
            switch reference {
            case .subscription(let id):
                guard profile.nodeSubscriptions?.contains(where: { $0.id == id }) == true else { throw missingResource() }
                change.profile.nodeSubscriptions?.removeAll { $0.id == id }
                // Removing the source keeps its nodes in the main inventory.
                change.apply = false
            case .module(let id):
                guard let module = profile.modules.first(where: { $0.id == id }) else { throw missingResource() }
                for key in module.setKeys {
                    change.profile.text = ClientDocumentEditing.set(change.profile.text, section: .mitmSet, key: key, value: nil)
                }
                change.profile.modules.removeAll { $0.id == id }
            case .ruleSet(let rule):
                let parsed = NaiveFlowConfigurationParser.parse(text: text).configuration
                guard rule.kind == .ruleSet, parsed.rules.contains(rule) else { throw missingResource() }
                change.profile.text = ConfigurationDocument.parse(text: text).removingLine(rule.line).text
            case .geo(let draft, let site):
                change.profile.text = try draft.applying(to: text, site: site, deleting: true)
            }
        }
        if !change.apply { change.profile.text = profile.text }
        try Task.checkCancellation()
        return change
    }

    private static func updateSubscription(_ subscription: ClientNodeSubscription, in profile: ClientProfile,
                                           fetch: FetchText, fetchSubscription: FetchSubscription?) async throws -> ClientProfile {
        do {
            try validateSubscription(subscription)
            let source: String
            if let fetchSubscription { source = try await fetchSubscription(subscription) }
            else { source = try await fetch(subscription.url) }
            return try importingNodes(source, into: profile, subscription: subscription)
        } catch { throw ClientFailure("\(subscription.name): \(error.localizedDescription)") }
    }

    private static func validateSubscription(_ subscription: ClientNodeSubscription) throws {
        guard !subscription.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientFailure("Enter a subscription name.")
        }
        _ = try remoteURL(subscription.url)
    }

    private static func remoteURL(_ source: String) throws -> URL {
        guard let url = URL(string: source), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw ClientFailure("Enter a valid HTTPS URL.")
        }
        return url
    }

    private static func missingResource() -> ClientFailure {
        ClientFailure("This resource has changed or no longer exists. Reopen it and try again.")
    }

    private static func upsertSubscription(_ subscription: ClientNodeSubscription, in profile: inout ClientProfile) {
        var subscriptions = profile.nodeSubscriptions ?? []
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) { subscriptions[index] = subscription }
        else { subscriptions.append(subscription) }
        profile.nodeSubscriptions = subscriptions
    }

    private static func importingNodes(_ source: String, into original: ClientProfile, url: String? = nil,
                                       subscription: ClientNodeSubscription? = nil) throws -> ClientProfile {
        var profile = original
        let result = TextConfigurationPipeline.process(text: source)
        let imported = !result.compiled.proxies.isEmpty ? result.compiled.proxies
            : try SubscriptionFetcher.parseLocal(data: Data(source.utf8)).configurations
        guard !imported.isEmpty else { throw ClientFailure("No usable nodes found.") }
        let record = subscription ?? url.map { url in
            profile.nodeSubscriptions?.first { $0.url == url }
                ?? ClientNodeSubscription(name: URL(string: url)?.host ?? "Subscription", url: url)
        }
        if let record { try validateSubscription(record) }
        let current = TextConfigurationPipeline.process(text: profile.text).compiled.proxies
        var used = Set(current.map(\.name))
        var members: [ClientSubscriptionMember] = []
        for node in imported {
            let previous = record?.members.first { $0.sourceName == node.name }
            if let previous, previous.edited, current.contains(where: { $0.name == previous.name }) {
                members.append(previous); continue
            }
            var name = previous?.name ?? node.name
            if record != nil, previous == nil {
                var suffix = 2
                while used.contains(name) { name = "\(node.name) (\(suffix))"; suffix += 1 }
            }
            used.insert(name)
            profile.text = ClientDocumentEditing.set(profile.text, section: .proxy, key: name, value: node.toURLString())
            members.append(ClientSubscriptionMember(sourceName: node.name, name: name))
        }
        if var record {
            record.members = members; record.updatedAt = .now
            upsertSubscription(record, in: &profile)
        }
        return profile
    }

    private static func installingModule(_ candidate: ClientModule, into original: ClientProfile) async throws -> ClientProfile {
        let made = try await ModuleImporter.makeModule(from: candidate.source, fallbackName: candidate.name,
            subscriptionURL: candidate.sourceURL.flatMap(URL.init(string:)), format: candidate.format)
        guard !made.module.mitmRuleSets.isEmpty else { throw ClientFailure("This module contains no usable MITM rules.") }
        var profile = original
        var saved = candidate
        saved.summary = candidate.summary.isEmpty ? made.module.description ?? "" : candidate.summary
        let previous = profile.modules.first { $0.id == candidate.id }
        for key in previous?.setKeys ?? candidate.setKeys {
            profile.text = ClientDocumentEditing.set(profile.text, section: .mitmSet, key: key, value: nil)
        }
        saved.setKeys = []
        for (index, raw) in made.module.mitmRuleSets.enumerated() {
            var set = raw.asMITMRuleSet()
            set.id = UUID()
            set.enabled = candidate.enabled
            let key = "module_\(candidate.id.uuidString.replacingOccurrences(of: "-", with: ""))_\(index)"
            profile.text = ClientDocumentEditing.set(profile.text, section: .mitmSet, key: key,
                value: "base64:" + (try JSONEncoder().encode(set)).base64EncodedString())
            saved.setKeys.append(key)
        }
        if let index = profile.modules.firstIndex(where: { $0.id == saved.id }) { profile.modules[index] = saved }
        else { profile.modules.append(saved) }
        return profile
    }
}

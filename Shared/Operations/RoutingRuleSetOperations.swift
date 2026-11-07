//
//  RoutingRuleSetOperations.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/20/26.
//

import Foundation

@MainActor
struct RoutingRuleSetOperations {
    let routingRuleSetStore: RoutingRuleSetStore
    let routingExportScheduler: RoutingExportScheduler
    /// Shared per-rule-set refresh coordination so a slow fetch cannot overwrite
    /// a newer one. Defaulted so existing call sites/tests keep a private instance.
    var coordinator = RefreshTicketCoordinator<UUID>()
    /// Injectable fetch seam for tests; production uses the bounded downloader.
    var fetchBodyOverride: (@MainActor (URL) async throws -> String)? = nil

    // MARK: - Assignments

    func updateAssignment(_ ruleSet: RoutingRuleSet, configurationId: String?) {
        routingRuleSetStore.updateAssignment(ruleSet, configurationId: configurationId)
        routingExportScheduler.schedule()
    }

    func resetAssignments() {
        routingRuleSetStore.resetAssignments()
        routingExportScheduler.schedule()
    }

    func setBypassCountryCode(_ code: String) {
        routingRuleSetStore.bypassCountryCode = code
        routingExportScheduler.schedule()
    }

    // MARK: - Custom Rule Sets

    @discardableResult
    func addCustomRuleSet(name: String) -> CustomRoutingRuleSet {
        let ruleSet = routingRuleSetStore.addCustomRuleSet(name: name)
        routingExportScheduler.schedule()
        return ruleSet
    }

    func addCustomRuleSet(_ ruleSet: CustomRoutingRuleSet, initialAssignment: String? = nil) {
        routingRuleSetStore.addCustomRuleSet(ruleSet, initialAssignment: initialAssignment)
        routingExportScheduler.schedule()
    }

    func removeCustomRuleSet(_ id: UUID) {
        routingRuleSetStore.removeCustomRuleSet(id)
        routingExportScheduler.schedule()
    }

    func updateCustomRuleSet(_ id: UUID, name: String? = nil, rules: [RoutingRule]? = nil, icons: (light: Data?, dark: Data?)? = nil) {
        routingRuleSetStore.updateCustomRuleSet(id, name: name, rules: rules, icons: icons)
        routingExportScheduler.schedule()
    }

    func reorderCustomRuleSets(_ ordered: [CustomRoutingRuleSet]) {
        routingRuleSetStore.reorderCustomRuleSets(ordered)
        routingExportScheduler.schedule()
    }

    func removeCustomRuleSets(atOffsets offsets: IndexSet) {
        routingRuleSetStore.removeCustomRuleSets(atOffsets: offsets)
        routingExportScheduler.schedule()
    }

    func moveCustomRuleSets(fromOffsets source: IndexSet, toOffset destination: Int) {
        routingRuleSetStore.moveCustomRuleSets(fromOffsets: source, toOffset: destination)
        routingExportScheduler.schedule()
    }

    // MARK: - Subscription Refresh

    func refresh(_ id: UUID) async throws {
        guard let url = routingRuleSetStore.customRuleSet(for: id)?.subscriptionURL else {
            throw CustomRoutingRuleSetRefreshError.missingSubscriptionURL
        }
        let ticket = coordinator.begin(id)
        defer { coordinator.end(id, ticket: ticket) }

        let body: String
        if let fetchBodyOverride {
            body = try await fetchBodyOverride(url)
        } else {
            body = try await Self.fetchBody(from: url)
        }
        let parsed = RoutingRuleSetParser.parse(body)
        guard parsed.rules.count <= CustomRoutingRuleSet.maxRuleCount else {
            throw CustomRoutingRuleSetRefreshError.tooManyRules
        }

        // A superseded refresh (or one whose source was re-pointed mid-flight)
        // must not commit; leave the current rule set untouched.
        guard coordinator.isCurrent(id, ticket: ticket),
              routingRuleSetStore.customRuleSet(for: id)?.subscriptionURL == url else { return }

        guard let current = routingRuleSetStore.customRuleSet(for: id),
              current.rules != parsed.rules
                || current.iconLight != parsed.iconLight
                || current.iconDark != parsed.iconDark
        else { return }
        updateCustomRuleSet(id, rules: parsed.rules, icons: (parsed.iconLight, parsed.iconDark))
    }

    private static func fetchBody(from url: URL) async throws -> String {
        let (data, http) = try await BoundedHTTPFetcher.fetch(url)
        guard (200...299).contains(http.statusCode) else {
            throw CustomRoutingRuleSetRefreshError.invalidStatusCode(http.statusCode)
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw CustomRoutingRuleSetRefreshError.undecodableBody
        }
        return body
    }
}

nonisolated enum CustomRoutingRuleSetRefreshError: LocalizedError {
    case missingSubscriptionURL
    case invalidStatusCode(Int)
    case undecodableBody
    case tooManyRules

    var errorDescription: String? {
        switch self {
        case .missingSubscriptionURL:
            return "This rule set has no subscription URL."
        case .invalidStatusCode(let code):
            return "HTTP \(code)"
        case .undecodableBody:
            return String(localized: "Unknown content.")
        case .tooManyRules:
            return String(localized: "Rule set is too large.")
        }
    }
}

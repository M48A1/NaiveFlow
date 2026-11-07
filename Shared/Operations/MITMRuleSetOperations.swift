//
//  MITMRuleSetOperations.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/20/26.
//

import Foundation

@MainActor
struct MITMRuleSetOperations {
    let mitmRuleSetStore: MITMRuleSetStore
    let mitmExportScheduler: MITMExportScheduler
    /// Shared per-rule-set refresh coordination so a slow fetch cannot overwrite
    /// a newer one. Defaulted so existing call sites/tests keep a private instance.
    var coordinator = RefreshTicketCoordinator<UUID>()
    /// Injectable fetch seam for tests; production uses the bounded downloader.
    var fetchBodyOverride: (@MainActor (URL) async throws -> String)? = nil

    func setEnabled(_ enabled: Bool) {
        mitmRuleSetStore.setEnabled(enabled)
        mitmExportScheduler.schedule()
    }

    // MARK: - Rule Set CRUD

    func addRuleSet(_ ruleSet: MITMRuleSet) {
        mitmRuleSetStore.addRuleSet(ruleSet)
        mitmExportScheduler.schedule()
    }

    func updateRuleSet(_ id: UUID, domainSuffixes: [String], rules: [MITMRule]) {
        mitmRuleSetStore.updateRuleSet(id, domainSuffixes: domainSuffixes, rules: rules)
        mitmExportScheduler.schedule()
    }

    func setRuleSet(_ id: UUID, enabled: Bool) {
        mitmRuleSetStore.setRuleSet(id, enabled: enabled)
        mitmExportScheduler.schedule()
    }

    func setParameterValue(_ id: UUID, name: String, value: String) {
        mitmRuleSetStore.setParameterValue(id, name: name, value: value)
        mitmExportScheduler.schedule()
    }

    func removeRuleSets(atOffsets offsets: IndexSet) {
        mitmRuleSetStore.removeRuleSets(atOffsets: offsets)
        mitmExportScheduler.schedule()
    }

    func removeRuleSet(id: UUID) {
        mitmRuleSetStore.removeRuleSet(id: id)
        mitmExportScheduler.schedule()
    }

    func moveRuleSets(fromOffsets source: IndexSet, toOffset destination: Int) {
        mitmRuleSetStore.moveRuleSets(fromOffsets: source, toOffset: destination)
        mitmExportScheduler.schedule()
    }

    // MARK: - Subscription Refresh

    @discardableResult
    func refresh(id: UUID) async throws -> MITMRuleSet {
        guard let url = mitmRuleSetStore.ruleSet(id: id)?.subscriptionURL else {
            throw MITMRuleSetRefreshError.missingSubscriptionURL
        }
        let ticket = coordinator.begin(id)
        defer { coordinator.end(id, ticket: ticket) }

        let body: String
        if let fetchBodyOverride {
            body = try await fetchBodyOverride(url)
        } else {
            body = try await Self.fetchBody(from: url)
        }
        let parsed = MITMRuleSetParser.parse(body)
        guard parsed.rules.count <= MITMRuleSet.maxRuleCount else {
            throw MITMRuleSetRefreshError.tooManyRules
        }

        // A superseded refresh (or one whose source was re-pointed mid-flight)
        // must not commit; return the current rule set unchanged.
        guard coordinator.isCurrent(id, ticket: ticket),
              mitmRuleSetStore.ruleSet(id: id)?.subscriptionURL == url else {
            guard let current = mitmRuleSetStore.ruleSet(id: id) else {
                throw MITMRuleSetRefreshError.ruleSetRemoved
            }
            return current
        }
        guard let updated = mitmRuleSetStore.applyRefreshedContent(
            domainSuffixes: parsed.domainSuffixes,
            rules: parsed.rules,
            parameters: parsed.parameters,
            iconLight: parsed.iconLight,
            iconDark: parsed.iconDark,
            to: id
        ) else {
            throw MITMRuleSetRefreshError.ruleSetRemoved
        }
        mitmExportScheduler.schedule()
        return updated
    }

    private static func fetchBody(from url: URL) async throws -> String {
        let (data, http) = try await BoundedHTTPFetcher.fetch(url)
        guard (200...299).contains(http.statusCode) else {
            throw MITMRuleSetRefreshError.invalidStatusCode(http.statusCode)
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw MITMRuleSetRefreshError.undecodableBody
        }
        return body
    }
}

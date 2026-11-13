//
//  DomainRouter.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation
import Synchronization

nonisolated private let logger = NaiveFlowLogger(category: "DomainRouter")

nonisolated final class DomainRouter: Sendable {

    struct Match: Sendable {
        let action: RouteTarget
        let ruleSetName: String?
    }

    fileprivate struct RoutingState: Sendable {
        var ordered: OrderedRouteMatcher?
        var configurationMap: [UUID: ProxyConfiguration] = [:]
        /// Text-configured groups by stable id, resolved to a member at dial time.
        var policyGroups: [UUID: RuntimeProxyGroup] = [:]
        /// Per-group dial counter for `load-balance` round-robin.
        var selections: [UUID: ProxyGroupSelection] = [:]
        /// Latest probe results keyed by policy-group id, then member node id
        /// (`ms`). Absent = unknown or unreachable. Keyed per group so a node
        /// shared by several groups keeps each group's independent verdict
        /// (groups may probe different URLs). Fed by the in-tunnel prober.
        var latencies: [UUID: [UUID: Int]] = [:]
        var version: UInt64 = 1

    }

    private let routingState = Mutex(RoutingState())

    var currentRulesVersion: UInt64 { routingState.withLock { $0.version } }

    // MARK: - Loading

    func reset() {
        _ = replaceRoutingState(with: RoutingState())
    }

    private func replaceRoutingState(with replacement: RoutingState) -> RoutingState {
        routingState.withLock { state in
            var displaced = replacement
            displaced.version = state.version &+ 1
            swap(&state, &displaced)
            return displaced
        }
    }

    func installNative(_ bundle: RuntimeConfigurationBundle) {
        var state = RoutingState()
        state.ordered = OrderedRouteMatcher(rules: bundle.rules, finalAction: bundle.finalAction,
            geoIP: bundle.geo, geoSite: bundle.geo)
        state.configurationMap = Dictionary(uniqueKeysWithValues: bundle.nodes.map { ($0.id, $0) })
        state.policyGroups = Dictionary(uniqueKeysWithValues: bundle.policyGroups.map { ($0.id, $0) })
        _ = replaceRoutingState(with: state)
    }

    var usesNativeRules: Bool { routingState.withLock { $0.ordered != nil } }

    func nativeDecision(_ query: RouteQuery, allowResolution: Bool = true,
                        deferOnHostUnknown: Bool = true,
                        deferOnMissingMetadata: Bool = true) -> OrderedRouteMatcher.Evaluation? {
        routingState.withLock {
            $0.ordered?.evaluate(query, allowAddressResolution: allowResolution,
                                 deferOnHostUnknown: deferOnHostUnknown,
                                 deferOnMissingMetadata: deferOnMissingMetadata)
        }
    }

    static func nativeMatch(_ result: OrderedRouteMatcher.Result) -> Match {
        let target: RouteTarget
        switch result.action {
        case .direct: target = .direct
        case .reject: target = .reject
        case .defaultProxy: target = .defaultProxy
        case .proxy(let id): target = .proxy(id)
        }
        return Match(action: target, ruleSetName: result.ruleLine.map { "Text line \($0)" } ?? "FINAL")
    }

    // MARK: - Matching

    var hasRules: Bool {
        routingState.withLock { $0.ordered != nil }
    }

    func matchDomain(_ domain: String) -> Match? {
        matchDomainVersioned(domain).match
    }

    func matchDomainVersioned(_ domain: String) -> (match: Match?, version: UInt64) {
        guard !domain.isEmpty else { return (nil, currentRulesVersion) }
        return routingState.withLock { state in
            if let ordered = state.ordered {
                let match: Match?
                if case .matched(let result) = ordered.evaluate(RouteQuery(host: domain), allowFinal: false) {
                    match = Self.nativeMatch(result)
                } else { match = nil }
                return (match, state.version)
            }
            return (nil, state.version)
        }
    }

    func matchIP(_ ip: String) -> Match? {
        routingState.withLock { state in
            if let ordered = state.ordered {
                if case .matched(let result) = ordered.evaluate(RouteQuery(ip: ip)) { return Self.nativeMatch(result) }
                return nil
            }
            return nil
        }
    }

    func resolveConfiguration(action: RouteTarget, consumingGroupSelection: Bool = true) -> ProxyConfiguration? {
        switch action {
        case .default, .defaultProxy, .direct, .reject:
            return nil
        case .proxy(let id):
            return routingState.withLock { state in
                if let configuration = state.configurationMap[id] { return configuration }
                // The id names a policy group: apply its selection strategy to
                // pick a member node, using the latest probe results (absent =
                // unknown/unreachable).
                guard let group = state.policyGroups[id] else { return nil }
                let latencies = state.latencies[group.id] ?? [:]
                let first = state.selections[id, default: ProxyGroupSelection()].select(
                    group: group, latencies: latencies, consuming: consumingGroupSelection
                )
                if let first, let configuration = state.configurationMap[first] { return configuration }
                // A stale probe can point at a node removed by a newer runtime
                // bundle. Try the remaining declaration-order members before
                // reporting the group as unavailable; never fall through to
                // DIRECT for an explicit proxy-group route.
                for member in group.memberIDs where member != first {
                    if let configuration = state.configurationMap[member] { return configuration }
                }
                return nil
            }
        }
    }

    /// Publishes one group's probe results, leaving every other group's results
    /// intact. Groups probe on independent schedules, so a whole-table replace
    /// would let one group's pass erase another's still-fresh measurements.
    func updateLatencies(groupID: UUID, results: [UUID: Int]) {
        routingState.withLock { $0.latencies[groupID] = results }
    }
}

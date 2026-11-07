//
//  GroupProber.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation

/// Periodically probes the members of automatic policy groups (`url-test` /
/// `fallback` / `load-balance`) inside the tunnel and feeds the results back to
/// the router, so the group selector can pick the fastest / first-reachable
/// member instead of always falling back to the first one.
actor GroupProber {
    private var tasks: [Task<Void, Never>] = []
    private var generation: UInt64 = 0

    /// Starts (or restarts) probing. Each automatic group gets its own loop so it
    /// probes its members against *its* configured URL and honours *its* own
    /// interval, publishing one group's results without disturbing the others.
    /// A group with no dialable members simply contributes no task.
    func start(router: DomainRouter, nodes: [ProxyConfiguration], groups: [RuntimeProxyGroup]) {
        generation &+= 1
        tasks.forEach { $0.cancel() }
        tasks.removeAll()

        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let automatic = groups.filter { $0.kind != .select && $0.interval > 0 }
        let plans = ProxyProbePlan.groupProbes(groups: automatic, nodes: nodeMap)
        guard !plans.isEmpty else { return }

        let currentGeneration = generation
        tasks = plans.map { plan in
            Task { [weak self] in
                await self?.run(
                    generation: currentGeneration,
                    group: plan.group,
                    probes: plan.probes,
                    nodeMap: nodeMap,
                    router: router
                )
            }
        }
    }

    func stop() {
        generation &+= 1
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func run(
        generation: UInt64,
        group: RuntimeProxyGroup,
        probes: [ProxyProbe],
        nodeMap: [UUID: ProxyConfiguration],
        router: DomainRouter
    ) async {
        while !Task.isCancelled {
            // Each member is probed against this group's target URL (or the
            // built-in default). Direct nodes are included on purpose: a
            // `fallback` group that lists a reachable direct member first must be
            // able to pick it instead of always resolving to a heavier proxy.
            var results: [UUID: Int] = [:]
            for probe in probes {
                guard !Task.isCancelled else { return }
                guard let node = nodeMap[probe.memberID] else { continue }
                if case .success(let ms) = await LatencyTester.test(node, target: probe.target) {
                    results[probe.memberID] = ms
                }
            }

            // A stale generation must not clobber a newer prober's results.
            guard generation == self.generation, !Task.isCancelled else { return }
            router.updateLatencies(groupID: group.id, results: results)

            try? await Task.sleep(for: .seconds(group.interval))
        }
    }
}

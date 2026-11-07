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
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// Starts (or restarts) probing. Automatic groups with no members stop the
    /// prober.
    func start(router: DomainRouter, nodes: [ProxyConfiguration], groups: [RuntimeProxyGroup]) {
        generation &+= 1
        task?.cancel()

        let automatic = groups.filter { $0.kind != .select }
        let interval = automatic.map(\.interval).min() ?? 600
        guard !automatic.isEmpty, interval > 0 else {
            task = nil
            return
        }

        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let currentGeneration = generation
        task = Task { [weak self] in
            await self?.run(
                generation: currentGeneration,
                router: router,
                groups: automatic,
                nodeMap: nodeMap,
                interval: interval
            )
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    private func run(
        generation: UInt64,
        router: DomainRouter,
        groups: [RuntimeProxyGroup],
        nodeMap: [UUID: ProxyConfiguration],
        interval: TimeInterval
    ) async {
        // Each member is probed against its own group's target URL (or the
        // built-in default). Direct nodes are included on purpose: a `fallback`
        // group that lists a reachable direct member first must be able to pick
        // it instead of always resolving to a heavier proxy further down.
        let memberTargets = ProxyProbePlan.memberTargets(groups: groups, nodes: nodeMap)

        while !Task.isCancelled {
            var latencies: [UUID: Int] = [:]
            for (memberID, target) in memberTargets {
                guard !Task.isCancelled else { return }
                guard let node = nodeMap[memberID] else { continue }
                let result = await LatencyTester.test(node, target: target)
                if case .success(let ms) = result {
                    latencies[memberID] = ms
                }
            }

            // A stale generation must not clobber a newer prober's results.
            guard generation == self.generation, !Task.isCancelled else { return }
            router.updateLatencies(latencies)

            try? await Task.sleep(for: .seconds(interval))
        }
    }
}

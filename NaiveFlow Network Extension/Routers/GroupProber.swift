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
        // built-in default). A member shared across groups keeps the first group's
        // target; groups rarely overlap, and the target is usually identical.
        var memberTargets: [UUID: ProbeTarget] = [:]
        for group in groups {
            let target = Self.probeTarget(for: group)
            for memberID in group.memberIDs where memberTargets[memberID] == nil {
                memberTargets[memberID] = target
            }
        }

        while !Task.isCancelled {
            var latencies: [UUID: Int] = [:]
            for (memberID, target) in memberTargets {
                guard !Task.isCancelled else { return }
                guard let node = nodeMap[memberID], !node.isDirect else { continue }
                let result = await LatencyTester.test(node, host: target.host, port: target.port)
                if case .success(let ms) = result {
                    latencies[memberID] = ms
                }
            }

            // A stale generation must not clobber a newer prober's results.
            guard generation == self.generation, !Task.isCancelled else { return }
            await router.updateLatencies(latencies)

            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private struct ProbeTarget: Sendable {
        let host: String
        let port: UInt16
    }

    private nonisolated static func probeTarget(for group: RuntimeProxyGroup) -> ProbeTarget {
        if let raw = group.url,
           let components = URLComponents(string: raw),
           let host = components.host {
            let port: UInt16
            if let explicit = components.port {
                port = UInt16(clamping: explicit)
            } else {
                port = components.scheme?.lowercased() == "https" ? 443 : 80
            }
            return ProbeTarget(host: host, port: port)
        }
        return ProbeTarget(host: "captive.apple.com", port: 80)
    }
}

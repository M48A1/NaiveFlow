//
//  RuntimeProxyGroup.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation
import CryptoKit

/// The engine's representation of a text-configured `[Proxy Group]`.
///
/// Unlike the app's hand-built `ProxyGroup` (which only knows `servers` /
/// `chains`), this carries the automatic selection strategy (`url-test`,
/// `fallback`, `load-balance`) so a group policy can be resolved to a concrete
/// member at dial time instead of always flattening to the first member.
nonisolated struct RuntimeProxyGroup: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case select
        case urlTest = "url-test"
        case fallback
        case loadBalance = "load-balance"
    }

    /// Stable identity derived from the group name, so a group keeps its
    /// selection and probe state across recompiles (the same way a node keeps
    /// its name-based identity).
    let id: UUID
    let name: String
    let kind: Kind
    /// Member node/group ids in declaration order (nested groups already
    /// flattened by the compiler).
    let memberIDs: [UUID]
    /// `select`: the manually chosen member, when the document names one.
    let selectedID: UUID?
    /// `url-test`: probe interval in seconds.
    let interval: TimeInterval
    /// Probe target (e.g. `http://www.gstatic.com/generate_204`). `nil` uses the
    /// built-in default.
    let url: String?

    init(
        name: String,
        kind: Kind,
        memberIDs: [UUID],
        selectedID: UUID? = nil,
        interval: TimeInterval = 600,
        url: String? = nil
    ) {
        self.id = RuntimeProxyGroup.stableID(name: name)
        self.name = name
        self.kind = kind
        self.memberIDs = memberIDs
        self.selectedID = selectedID
        self.interval = interval
        self.url = url
    }

    /// A deterministic UUID (v5-style) from a group name.
    static func stableID(name: String) -> UUID {
        let digest = SHA256.hash(data: Data(name.utf8))
        let bytes = digest.withUnsafeBytes { buffer -> [UInt8] in
            Array(buffer.prefix(16))
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// A pure, testable member chooser. Probe results are injected so the policy
/// logic stays decoupled from the network.
nonisolated enum ProxyGroupSelector {

    /// `memberID -> milliseconds` for members the prober has measured and
    /// found reachable. Members that failed or have not been probed yet are
    /// simply absent from the map.
    typealias Latencies = [UUID: Int]

    /// Chooses the member a connection should use next.
    ///
    /// - Parameters:
    ///   - group: the policy group.
    ///   - latencies: latest probe results (absent = unknown/unreachable).
    ///   - roundRobinIndex: monotonically increasing dial counter used by
    ///     `load-balance` to spread traffic; ignored by other kinds.
    static func select(
        group: RuntimeProxyGroup,
        latencies: Latencies,
        roundRobinIndex: Int
    ) -> UUID? {
        let candidates = group.memberIDs
        guard !candidates.isEmpty else { return nil }

        switch group.kind {
        case .select:
            return candidates.first(where: { $0 == group.selectedID }) ?? candidates.first

        case .urlTest:
            // Lowest measured latency wins; unmeasured members rank last, and
            // ties keep declaration order for determinism.
            return candidates.min { lhs, rhs in
                let l = latencies[lhs] ?? .max
                let r = latencies[rhs] ?? .max
                if l != r { return l < r }
                return order(lhs, in: candidates) < order(rhs, in: candidates)
            }

        case .fallback:
            // First reachable member; without any probe result, keep the first
            // member rather than failing the connection.
            return candidates.first(where: { latencies[$0] != nil }) ?? candidates.first

        case .loadBalance:
            let healthy = candidates.filter { latencies[$0] != nil }
            let pool = healthy.isEmpty ? candidates : healthy
            let count = pool.count
            let index = ((roundRobinIndex % count) + count) % count
            return pool[index]
        }
    }

    private static func order(_ id: UUID, in ids: [UUID]) -> Int {
        ids.firstIndex(of: id) ?? Int.max
    }
}

nonisolated extension RuntimeProxyGroup {
    /// The endpoint this group's members are probed against: the configured URL
    /// when it parses to a dialable http(s) target, otherwise the built-in
    /// captive-portal default.
    var probeTarget: LatencyTarget {
        url.flatMap(LatencyTarget.init(url:)) ?? .captivePortal
    }
}

/// Builds the member -> target worklist the automatic-group prober measures.
nonisolated enum ProxyProbePlan {
    /// Every dialable member of an automatic group, keyed to the target it is
    /// measured against (a member shared by several groups keeps the first
    /// group's target).
    ///
    /// `direct` nodes are intentionally included: an explicit direct member is a
    /// real route, so a `fallback` group that lists one first must be able to
    /// pick it once it proves reachable instead of always resolving to a heavier
    /// proxy further down.
    static func memberTargets(
        groups: [RuntimeProxyGroup],
        nodes: [UUID: ProxyConfiguration]
    ) -> [UUID: LatencyTarget] {
        var targets: [UUID: LatencyTarget] = [:]
        for group in groups {
            let target = group.probeTarget
            for memberID in group.memberIDs where targets[memberID] == nil {
                guard nodes[memberID] != nil else { continue }
                targets[memberID] = target
            }
        }
        return targets
    }
}

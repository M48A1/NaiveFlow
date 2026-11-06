import Foundation

/// Why a name is being resolved. The purpose is part of the resolver's cache key,
/// so a bootstrap answer never serves a business connection and a rule-evaluation
/// lookup never leaks a DIRECT answer into a proxy-side query.
nonisolated enum DNSResolutionPurpose: Sendable, Hashable {
    /// A DIRECT outbound dial resolves the domain only after the rule chose DIRECT.
    case directConnection
    /// Rule evaluation asks for a real address to satisfy an IP / GeoIP rule
    /// (`no-resolve` rules never trigger this).
    case ruleEvaluation
    /// Resolving a proxy node or an encrypted DNS endpoint's host name.
    case proxyBootstrap
    /// An explicit DNS query the kernel answers for a managed client.
    case explicitDNSQuery
}

/// Which transport a resolver uses to reach its upstream.
nonisolated enum DNSResolutionTransport: Sendable, Equatable {
    /// The platform system resolver, discovered outside the tunnel.
    case system
    /// A locally reachable third-party upstream (plain or DoH) for DIRECT.
    case local
    /// An upstream reached through the proxy for proxy-side resolution.
    case proxy
    /// Chosen from the resolution purpose when no explicit transport is set.
    case automatic
}

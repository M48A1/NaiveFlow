//
//  DNSResolver.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/8/26.
//

import Foundation

nonisolated final class DNSResolver: Sendable {
    static let proxies = DNSResolver(
        upstream: { AWCore.getProxyDNSUpstream() },
        hosts: nil,
        fallsBackToSystem: true,
        servesStaleOnFailure: true,
        waitLimit: nil,
        purpose: .proxyBootstrap,
        transport: .proxy
    )
    
    static let localRequests = DNSResolver(
        upstream: { AWCore.getLocalRequestDNSUpstream() },
        hosts: DNSHosts.shared,
        fallsBackToSystem: false,
        servesStaleOnFailure: false,
        waitLimit: .seconds(4),
        purpose: .directConnection,
        transport: .local
    )

    static let defaultTTL: TimeInterval = 120

    static let maxEntries = 1024

    private struct Query: Hashable, Sendable {
        let name: String
        let family: DNSAddressFamily
        let bootstrap: String
        let purpose: DNSResolutionPurpose
    }

    private let upstreamSource: @Sendable () -> DNSUpstream
    private let hosts: DNSHosts?
    private let fallsBackToSystem: Bool
    /// The default resolution purpose for this resolver. Per-call overrides
    /// separate the cache keys, so one resolver can serve several purposes.
    let purpose: DNSResolutionPurpose
    /// The transport this resolver uses to reach its upstream.
    let transport: DNSResolutionTransport
    private let cache: DNSLookupCache<Query, [String]>
    private let blockingBridge = DNSSyscallConcurrencyBridge()
    
    private init(
        upstream: @escaping @Sendable () -> DNSUpstream,
        hosts: DNSHosts?,
        fallsBackToSystem: Bool,
        servesStaleOnFailure: Bool,
        waitLimit: Duration?,
        purpose: DNSResolutionPurpose,
        transport: DNSResolutionTransport
    ) {
        self.upstreamSource = upstream
        self.hosts = hosts
        self.fallsBackToSystem = fallsBackToSystem
        self.purpose = purpose
        self.transport = transport
        self.cache = DNSLookupCache(
            capacity: Self.maxEntries,
            missing: [],
            servesStaleOnFailure: servesStaleOnFailure,
            waitLimit: waitLimit
        )
    }

    // MARK: - Public API

    var usesSystemUpstream: Bool { upstreamSource().isSystem }

    func resolveAll(_ host: String, family: DNSAddressFamily = .ipv4, forceFresh: Bool = false,
                    purpose: DNSResolutionPurpose? = nil) async -> [String] {
        let bare = host
        guard IPv4Only.supportsHost(bare) else { return [] }
        if DNSName.isIPAddress(bare) { return family.admits(bare) ? [bare] : [] }
        if let mapped = hosts?.addresses(for: bare, family: family) { return mapped }
        let bootstrap = AWCore.getBootstrapDNS()
        let effectivePurpose = purpose ?? self.purpose
        let query = Query(name: DNSName.cacheKey(for: bare), family: family, bootstrap: bootstrap.rendered,
                          purpose: effectivePurpose)
        let upstream = upstreamSource()
        return await cache.value(for: query, from: upstream, forceFresh: forceFresh) { [self] in
            await lookup(bare, family: family, upstream: upstream, bootstrap: bootstrap, purpose: effectivePurpose)
        }
    }

    func resolveHost(_ host: String, family: DNSAddressFamily = .ipv4, forceFresh: Bool = false,
                     purpose: DNSResolutionPurpose? = nil) async -> String? {
        await resolveAll(host, family: family, forceFresh: forceFresh, purpose: purpose).first
    }

    /// Resolves a name for rule evaluation (IP / GeoIP matching). The purpose is
    /// explicit so a rule lookup always shares the `.ruleEvaluation` cache key
    /// and never reads (or races with) a DIRECT-connection answer.
    func resolveForRuleEvaluation(_ host: String, family: DNSAddressFamily = .ipv4) async -> String? {
        await resolveHost(host, family: family, purpose: .ruleEvaluation)
    }
    
    func prewarm(_ host: String, family: DNSAddressFamily = .ipv4, purpose: DNSResolutionPurpose? = nil) {
        let bare = host
        guard IPv4Only.supportsHost(bare), !DNSName.isIPAddress(bare), hosts?.addresses(for: bare, family: family) == nil else { return }
        let bootstrap = AWCore.getBootstrapDNS()
        let effectivePurpose = purpose ?? self.purpose
        let query = Query(name: DNSName.cacheKey(for: bare), family: family, bootstrap: bootstrap.rendered,
                          purpose: effectivePurpose)
        let upstream = upstreamSource()
        cache.warm(query, from: upstream) { [self] in
            await lookup(bare, family: family, upstream: upstream, bootstrap: bootstrap, purpose: effectivePurpose)
        }
    }

    func cachedIPs(for host: String, family: DNSAddressFamily = .ipv4, purpose: DNSResolutionPurpose? = nil) -> [String]? {
        let bare = host
        guard IPv4Only.supportsHost(bare) else { return nil }
        if DNSName.isIPAddress(bare) { return family.admits(bare) ? [bare] : nil }
        if let mapped = hosts?.addresses(for: bare, family: family) { return mapped }
        return cache.cachedValue(for: Query(name: DNSName.cacheKey(for: bare), family: family,
                                            bootstrap: AWCore.getBootstrapDNS().rendered, purpose: purpose ?? self.purpose),
                                 from: upstreamSource())
    }

    func flush() {
        cache.flush()
    }

    // MARK: - Internal

    private func lookup(
        _ host: String,
        family: DNSAddressFamily,
        upstream: DNSUpstream,
        bootstrap: DNSBootstrapPolicy,
        purpose: DNSResolutionPurpose
    ) async -> (value: [String], ttl: TimeInterval)? {
        var resolved: [String] = []
        var resolvedTTL: TimeInterval = Self.defaultTTL
        if !upstream.isSystem {
            // A proxy-side resolver only routes its DoH through the tunnel for
            // business lookups; proxy bootstrap resolves its own node and must
            // stay direct so the proxy cannot depend on itself.
            let viaProxy = transport == .proxy && purpose != .proxyBootstrap
            if let result = try? await DNSUpstreamClient.resolveWithTTL(host, via: upstream, family: family, bootstrap: bootstrap, viaProxy: viaProxy) {
                resolved = result.addresses
                resolvedTTL = result.ttl
            }
            // An explicit DoH bootstrap failure must not silently resolve the
            // original business domain through the system resolver.
            if case .doh = upstream, !bootstrap.isSystem { return Self.cacheable(resolved, ttl: resolvedTTL) }
            guard resolved.isEmpty, fallsBackToSystem else { return Self.cacheable(resolved, ttl: resolvedTTL) }
        }
        resolved = await blockingBridge.resolveAddresses(host, family: family)
        return Self.cacheable(resolved, ttl: Self.defaultTTL)
    }

    private static func cacheable(_ addresses: [String], ttl: TimeInterval = defaultTTL) -> (value: [String], ttl: TimeInterval)? {
        addresses.isEmpty ? nil : (value: addresses, ttl: ttl)
    }
}

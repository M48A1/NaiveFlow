//
//  ConnectionRouter.swift
//  NaiveFlow
//
//  Created by NodePassProject on 7/12/26.
//

import Foundation
import Synchronization

nonisolated struct RouteDecision {
    enum Action {
        case route(target: RouteTarget, configuration: ProxyConfiguration?, ruleSetName: String?)
        case reject(ruleSetName: String?)
        case unreachable
    }

    let host: String
    let hostIsResolvedDomain: Bool
    let action: Action

    var ipRuleLookupPending = false
    /// True when the verdict came from the terminal `FINAL` action rather than
    /// an explicit rule. A FINAL verdict must not preempt domain sniffing when
    /// the domain is not yet known.
    var isFinal = false
    /// True when the matcher deferred because the host was unknown, so the
    /// caller should re-evaluate once the host is known (post-sniff).
    var deferredForHost = false
}

nonisolated final class ConnectionRouter: Sendable {
    let syntheticAddressPool: SyntheticAddressPool
    let domainRouter: DomainRouter

    let preventDNSLeak = Atomic(false)

    private struct RejectedIPs {
        var v4: Set<UInt32> = []
        var count: Int { v4.count }
    }
    private let rejectedIPs = Mutex(RejectedIPs())
    private static let rejectedIPCap = 4096

    private let dnsRejectLogged = Mutex(Set<String>())
    private static let dnsRejectLoggedCap = 4096

    init(syntheticAddressPool: SyntheticAddressPool, domainRouter: DomainRouter) {
        self.syntheticAddressPool = syntheticAddressPool
        self.domainRouter = domainRouter
    }

    func decision(forIP ip: String, sourceIP: String? = nil, sourcePort: UInt16? = nil,
                  destinationPort: UInt16? = nil, protocolName: String? = nil,
                  allowAddressResolution: Bool = true, deferOnHostUnknown: Bool = true) -> RouteDecision {
        guard IPv4Only.supportsHost(ip) else { return RouteDecision(host: ip, hostIsResolvedDomain: false, action: .unreachable) }
        if domainRouter.usesNativeRules {
            let synthetic = SyntheticAddressPool.isSyntheticAddress(ip)
            let host = synthetic ? syntheticAddressPool.lookup(ip: ip)?.domain : nil
            if synthetic && host == nil {
                return RouteDecision(host: ip, hostIsResolvedDomain: false, action: .unreachable)
            }
            let resolved = synthetic ? host.flatMap { DNSResolver.localRequests.cachedIPs(for: $0, family: .ipv4, purpose: .ruleEvaluation)?.first } : ip
            let query = RouteQuery(host: host, ip: resolved, sourceIP: sourceIP, sourcePort: sourcePort,
                                   destinationPort: destinationPort, protocolName: protocolName)
            switch domainRouter.nativeDecision(query, allowResolution: allowAddressResolution && !preventDNSLeak.load(ordering: .relaxed), deferOnHostUnknown: deferOnHostUnknown) {
            case .matched(let result):
                return RouteDecision(host: host ?? ip, hostIsResolvedDomain: synthetic,
                                     action: action(for: DomainRouter.nativeMatch(result)),
                                     isFinal: result.isFinal)
            case .needsAddress:
                if let host { DNSResolver.localRequests.prewarm(host, family: .ipv4, purpose: .ruleEvaluation) }
                return RouteDecision(host: host ?? ip, hostIsResolvedDomain: synthetic,
                                     action: .route(target: .default, configuration: nil, ruleSetName: nil), ipRuleLookupPending: true)
            case .deferred:
                return RouteDecision(host: host ?? ip, hostIsResolvedDomain: synthetic,
                                     action: .route(target: .default, configuration: nil, ruleSetName: nil),
                                     deferredForHost: deferOnHostUnknown)
            default:
                return RouteDecision(host: host ?? ip, hostIsResolvedDomain: synthetic,
                                     action: .route(target: .default, configuration: nil, ruleSetName: nil))
            }
        }
        guard SyntheticAddressPool.isSyntheticAddress(ip) else {
            guard let match = domainRouter.matchIP(ip) else {
                return RouteDecision(host: ip, hostIsResolvedDomain: false, action: .route(target: .default, configuration: nil, ruleSetName: nil))
            }
            return RouteDecision(
                host: ip,
                hostIsResolvedDomain: false,
                action: markingIfRejectedIP(action(for: match), ip: ip)
            )
        }

        guard let entry = syntheticAddressPool.lookup(ip: ip) else {
            return RouteDecision(host: ip, hostIsResolvedDomain: false, action: .unreachable)
        }
        let domain = entry.domain

        let match: DomainRouter.Match?
        if entry.verdictVersion == domainRouter.currentRulesVersion {
            match = entry.verdict
        } else {
            let versioned = domainRouter.matchDomainVersioned(domain)
            match = versioned.match
            syntheticAddressPool.cacheVerdict(domain: domain, match: match, version: versioned.version)
        }

        if let match {
            return RouteDecision(
                host: domain,
                hostIsResolvedDomain: true,
                action: markingIfRejected(action(for: match), domain: domain)
            )
        }

        if !preventDNSLeak.load(ordering: .relaxed) {
            if let resolvedIP = DNSResolver.localRequests.cachedIPs(for: domain, family: .ipv4)?.first {
                if let match = domainRouter.matchIP(resolvedIP) {
                    return RouteDecision(
                        host: domain,
                        hostIsResolvedDomain: true,
                        action: action(for: match)
                    )
                }
            } else {
                DNSResolver.localRequests.prewarm(domain, family: .ipv4)
                return RouteDecision(
                    host: domain,
                    hostIsResolvedDomain: true,
                    action: .route(target: .default, configuration: nil, ruleSetName: nil),
                    ipRuleLookupPending: true
                )
            }
        }

        return RouteDecision(host: domain, hostIsResolvedDomain: true, action: .route(target: .default, configuration: nil, ruleSetName: nil))
    }

    private func markingIfRejected(
        _ action: RouteDecision.Action, domain: String
    ) -> RouteDecision.Action {
        if case .reject = action {
            syntheticAddressPool.markRejected(domain: domain)
        }
        return action
    }

    private func markingIfRejectedIP(
        _ action: RouteDecision.Action, ip: String
    ) -> RouteDecision.Action {
        if case .reject = action {
            markIPRejected(ip)
        }
        return action
    }

    private func markIPRejected(_ ip: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let key = UInt32(bigEndian: v4.s_addr)
            rejectedIPs.withLock { set in
                if set.count >= Self.rejectedIPCap { set = RejectedIPs() }
                set.v4.insert(key)
            }
        }
    }

    // MARK: - DNS-time verdict

    func dnsVerdict(forDomain domain: String) -> (match: DomainRouter.Match?, rulesVersion: UInt64) {
        if let cached = syntheticAddressPool.cachedVerdict(domain: domain),
           cached.version == domainRouter.currentRulesVersion {
            return (cached.match, cached.version)
        }
        let versioned = domainRouter.matchDomainVersioned(domain)
        return (versioned.match, versioned.version)
    }

    func shouldLogDNSReject(domain: String) -> Bool {
        dnsRejectLogged.withLock { set in
            if set.count >= Self.dnsRejectLoggedCap { set.removeAll(keepingCapacity: true) }
            return set.insert(domain).inserted
        }
    }

    // MARK: - Reject-mark intake checks

    func isRejectMarkedDestination(rawIP: UnsafeRawPointer) -> Bool {
        let key = (UInt32(rawIP.load(fromByteOffset: 0, as: UInt8.self)) << 24)
                | (UInt32(rawIP.load(fromByteOffset: 1, as: UInt8.self)) << 16)
                | (UInt32(rawIP.load(fromByteOffset: 2, as: UInt8.self)) << 8)
                |  UInt32(rawIP.load(fromByteOffset: 3, as: UInt8.self))
        return isRejectMarkedIPv4(key)
    }

    private func isRejectMarkedIPv4(_ key: UInt32) -> Bool {
        syntheticAddressPool.isRejectMarked(ipv4: key) || rejectedIPs.withLock { $0.v4.contains(key) }
    }

    func clearRejectMarks() {
        syntheticAddressPool.clearRejectMarks()
        rejectedIPs.withLock { $0 = RejectedIPs() }
        dnsRejectLogged.withLock { $0.removeAll(keepingCapacity: true) }
    }

    // MARK: - Sniffed host

    /// Re-evaluates routing after QUIC sniffing recovered a domain, carrying the
    /// connection's full context (address, port, protocol) so rules like
    /// `domain X and port 443 → REJECT` still match. The pre-sniff query only
    /// lacked the domain.
    func decision(
        forSniffedHost host: String,
        ip: String,
        sourceIP: String? = nil,
        sourcePort: UInt16? = nil,
        destinationPort: UInt16? = nil,
        protocolName: String? = nil,
        allowAddressResolution: Bool = true
    ) -> RouteDecision? {
        if domainRouter.usesNativeRules {
            let synthetic = SyntheticAddressPool.isSyntheticAddress(ip)
            let resolved = synthetic
                ? DNSResolver.localRequests.cachedIPs(for: host, family: .ipv4, purpose: .ruleEvaluation)?.first
                : ip
            let query = RouteQuery(host: host, ip: resolved, sourceIP: sourceIP, sourcePort: sourcePort,
                                   destinationPort: destinationPort, protocolName: protocolName)
            switch domainRouter.nativeDecision(query, allowResolution: allowAddressResolution && !preventDNSLeak.load(ordering: .relaxed)) {
            case .matched(let result):
                return RouteDecision(host: host, hostIsResolvedDomain: true,
                                     action: action(for: DomainRouter.nativeMatch(result)),
                                     isFinal: result.isFinal)
            case .needsAddress:
                if allowAddressResolution {
                    DNSResolver.localRequests.prewarm(host, family: .ipv4, purpose: .ruleEvaluation)
                }
                return RouteDecision(host: host, hostIsResolvedDomain: true,
                                     action: .route(target: .default, configuration: nil, ruleSetName: nil),
                                     ipRuleLookupPending: allowAddressResolution)
            default:
                return RouteDecision(host: host, hostIsResolvedDomain: true,
                                     action: .route(target: .default, configuration: nil, ruleSetName: nil))
            }
        }
        guard let match = domainRouter.matchDomain(host) else { return nil }
        return RouteDecision(host: host, hostIsResolvedDomain: true, action: action(for: match))
    }

    private func action(for match: DomainRouter.Match) -> RouteDecision.Action {
        switch match.action {
        case .default, .defaultProxy:
            return .route(target: match.action, configuration: nil, ruleSetName: match.ruleSetName)
        case .direct:
            return .route(target: .direct, configuration: nil, ruleSetName: match.ruleSetName)
        case .reject:
            return .reject(ruleSetName: match.ruleSetName)
        case .proxy(let id):
            let configuration = domainRouter.resolveConfiguration(action: match.action)
            return .route(target: .proxy(id), configuration: configuration, ruleSetName: match.ruleSetName)
        }
    }
}

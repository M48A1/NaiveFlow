//
//  TunnelStack+DNS.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/30/26.
//

import Foundation

extension TunnelStack {

    // MARK: - DNS Interception (Synthetic Address)

    enum DNSDestination {
        case naiveflowResolver
        case publicResolver
    }
    
    static let interceptedDNSServers: [String: DNSDestination] = [
        TunnelAddress.ipv4: .naiveflowResolver,
        "8.8.8.8": .publicResolver,
        "8.8.4.4": .publicResolver,
    ]
    
    static func interceptExemptDNSServers() -> Set<String> {
        let upstreams = [
            AWCore.getSubscriptionDNSUpstream(),
            AWCore.getLocalRequestDNSUpstream(),
            AWCore.getProxyDNSUpstream(),
            AWCore.getECHDNSUpstream(),
            AWCore.getFallbackDNSUpstream()
        ]
        var addresses: Set<String> = []
        for case .plain(let host, _) in upstreams
        where host != TunnelAddress.ipv4 {
            addresses.insert(host)
        }
        if case .servers(let seeds) = AWCore.getBootstrapDNS() {
            addresses.formUnion(seeds.filter { $0 != TunnelAddress.ipv4 })
        }
        for raw in AWCore.getDNSExemptServers() {
            if let canonical = DNSUpstream.canonicalIPv4(raw), canonical != TunnelAddress.ipv4 {
                addresses.insert(canonical)
            }
        }
        return addresses
    }
    
    static func dnsDestination(for dstIP: String, exempting exempt: Set<String>) -> DNSDestination? {
        if dstIP == TunnelAddress.ipv4 { return .naiveflowResolver }
        return exempt.contains(dstIP) ? nil : .publicResolver
    }

    /// Shared wire-format handler for UDP/53 and length-prefixed TCP/53.
    /// nil means a valid query requires a real upstream response.
    nonisolated func syntheticDNSResponse(_ query: Data) -> Data? {
        query.withUnsafeBytes { bytes in
            let buffer = bytes.bindMemory(to: UInt8.self)
            guard let parsed = DNSPacket.parseQuery(buffer) else { return nil }
            let domain = parsed.domain.lowercased()
            let type = parsed.qtype
            func answer(_ ip: [UInt8]? = nil, ttl: UInt32 = TunnelConstants.dnsSyntheticAddressAnswerTTL) -> Data? {
                DNSPacket.generateResponse(query: buffer, answerIP: ip, qtype: type, ttl: ttl)
            }
            if domain == "_dns.resolver.arpa" || type == 28 || type == 65 { return answer() }
            let (match, version) = connectionRouter.dnsVerdict(forDomain: domain)
            if let match, case .reject = match.action {
                if connectionRouter.shouldLogDNSReject(domain: domain) {
                    requestLog.record(protocol: .unknown, host: domain, port: 53,
                                      routeTarget: .reject, ruleSetName: match.ruleSetName)
                }
                return answer(type == 1 ? [0, 0, 0, 0] : nil, ttl: TunnelConstants.dnsBlockedAnswerTTL)
            }
            guard type == 1, !udpConfig().syntheticAddressExcludedDomains.contains(domain) else { return nil }
            // nil means the pool cannot hand out a safe address right now (every
            // reclaimed address is still inside the client's DNS cache window);
            // fall through to a real upstream instead of risking cross-domain reuse.
            guard let offset = syntheticAddressPool.allocate(domain: domain, verdict: match, verdictVersion: version) else {
                return nil
            }
            let ip = SyntheticAddressPool.ipv4Bytes(offset: offset)
            return answer([ip.0, ip.1, ip.2, ip.3])
        }
    }
}

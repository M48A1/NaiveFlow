//
//  OrderedRouteMatcher.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// One connection as the ordered matcher sees it.
///
/// The Network Extension fills in whatever it knows at evaluation time; rules
/// that need a field the query lacks simply do not match. That is also how
/// `no-resolve` behaves: an IP rule cannot match before the address is known.
nonisolated struct RouteQuery: Sendable, Equatable {
    var host: String?
    var ip: String?
    var sourceIP: String?
    var sourcePort: UInt16?
    var destinationPort: UInt16?
    var protocolName: String?
    var processName: String?
    var userAgent: String?
    var url: String?

    init(
        host: String? = nil,
        ip: String? = nil,
        sourceIP: String? = nil,
        sourcePort: UInt16? = nil,
        destinationPort: UInt16? = nil,
        protocolName: String? = nil,
        processName: String? = nil,
        userAgent: String? = nil,
        url: String? = nil
    ) {
        self.host = host
        self.ip = ip
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.protocolName = protocolName
        self.processName = processName
        self.userAgent = userAgent
        self.url = url
    }
}

/// Where a matched rule sends the connection.
nonisolated enum RouteMatchAction: Hashable, Codable, Sendable {
    case direct
    case reject
    /// `PROXY`: the currently selected default route.
    case defaultProxy
    case proxy(UUID)

    var configurationID: UUID? {
        if case .proxy(let id) = self { return id }
        return nil
    }
}

/// An IPv4 network prefix, parsed once and matched without allocations.
nonisolated struct CIDRPrefix: Hashable, Codable, Sendable {
    enum Family: Hashable, Codable, Sendable {
        case v4

        var byteCount: Int { 4 }
        var addressFamily: Int32 { AF_INET }
    }

    let family: Family
    /// Network bytes, already masked to `prefixLength`.
    let bytes: [UInt8]
    let prefixLength: Int

    /// Accepts `1.2.3.0/24`, `1.2.3.4` (treated as `/32`), with a maximum prefix of /32.
    static func parse(_ text: String) -> CIDRPrefix? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let addressText = String(parts[0])
        let prefixLength: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), parsed >= 0 else { return nil }
            prefixLength = parsed
        } else {
            prefixLength = 32
        }

        if let v4 = canonicalBytes(addressText, family: .v4) {
            guard prefixLength <= 32 else { return nil }
            return CIDRPrefix(family: .v4, bytes: mask(v4, prefixLength: prefixLength, family: .v4), prefixLength: prefixLength)
        }
        return nil
    }

    func contains(_ address: String) -> Bool {
        guard let candidate = Self.canonicalBytes(address, family: family) else { return false }
        let masked = Self.mask(candidate, prefixLength: prefixLength, family: family)
        return masked == bytes
    }

    private static func canonicalBytes(_ address: String, family: Family) -> [UInt8]? {
        var storage = [UInt8](repeating: 0, count: family.byteCount)
        let result = storage.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return inet_pton(family.addressFamily, address, base)
        }
        return result == 1 ? storage : nil
    }

    private static func mask(_ bytes: [UInt8], prefixLength: Int, family: Family) -> [UInt8] {
        var masked = bytes
        for index in 0..<masked.count {
            let bitsInByte = min(max(prefixLength - index * 8, 0), 8)
            let mask: UInt8 = bitsInByte == 8 ? 0xFF : bitsInByte == 0 ? 0 : UInt8.max << (8 - bitsInByte)
            masked[index] &= mask
        }
        return masked
    }
}

// MARK: - Geo databases

/// Country/ASN lookups for `GEOIP` / `GEOASN` / `IP-ASN` rules.
nonisolated protocol GeoIPLookup: Sendable {
    func countryCode(for address: String) -> String?
    func asn(for address: String) -> Int?
}

/// Domain lookups for `GEOSITE` rules.
nonisolated protocol GeoSiteLookup: Sendable {
    func matches(host: String, tag: String) -> Bool
    func contains(tag: String) -> Bool
}

/// Stand-in used until the geo databases are bundled: matches nothing, so
/// geo rules fall through instead of silently matching everything.
nonisolated struct EmptyGeoIPLookup: GeoIPLookup {
    func countryCode(for address: String) -> String? { nil }
    func asn(for address: String) -> Int? { nil }
}

nonisolated struct EmptyGeoSiteLookup: GeoSiteLookup {
    func matches(host: String, tag: String) -> Bool { false }
    func contains(tag: String) -> Bool { false }
}

// MARK: - Rules

/// A single rule in document order, with everything the matcher needs.
nonisolated struct OrderedRoutingRule: Codable, Sendable, Identifiable, Equatable {
    indirect enum Matcher: Codable, Sendable, Equatable {
        case allOf([Matcher]), anyOf([Matcher]), negated(Matcher)
        case domain(String)
        case domainSuffix(String)
        case domainKeyword(String)
        case domainWildcard(String)
        case domainRegex(String)
        case urlRegex(String)
        case ipCIDR(CIDRPrefix)
        case ipASN(Int)
        case geoIP(String)
        case geoASN(Int)
        case geoSite(String)
        /// A rule set reference; the tunnel expands it into its rules before
        /// matching, so a bare reference never matches on its own.
        case ruleSet(String)
        case processName(String)
        case sourceIP(CIDRPrefix)
        case sourcePort(UInt16)
        case destinationPort(UInt16)
        case protocolName(String)
        case userAgent(String)
        case unsupported(String)

        /// Rules that need the connection's resolved address.
        var requiresResolvedAddress: Bool {
            switch self {
            case .ipCIDR, .ipASN, .geoIP, .geoASN:
                return true
            case .allOf(let children), .anyOf(let children): return children.contains { $0.requiresResolvedAddress }
            case .negated(let child): return child.requiresResolvedAddress
            default:
                return false
            }
        }

        func lacksMetadata(_ query: RouteQuery) -> Bool {
            switch self {
            case .sourceIP: return query.sourceIP == nil
            case .sourcePort: return query.sourcePort == nil
            case .destinationPort: return query.destinationPort == nil
            case .protocolName: return query.protocolName == nil
            case .allOf(let children), .anyOf(let children): return children.contains { $0.lacksMetadata(query) }
            case .negated(let child): return child.lacksMetadata(query)
            default: return false
            }
        }

        /// Rules that need the destination host name.
        var requiresHost: Bool {
            switch self {
            case .domain, .domainSuffix, .domainKeyword, .domainWildcard,
                 .domainRegex, .geoSite:
                return true
            default:
                return false
            }
        }
    }

    /// Line number in the source document; also the sort key for ordering.
    let line: Int
    let matcher: Matcher
    let action: RouteMatchAction
    /// `no-resolve`: never trigger a DNS lookup to satisfy this rule.
    let noResolve: Bool

    var id: Int { line }
}

// MARK: - Matcher

/// Evaluates rules in document order: the first rule that matches wins.
///
/// The current implementation is a linear scan. That is exact and easy to
/// reason about, and it is fast enough for interactive previews and for
/// documents of a few thousand rules. Large rule sets will get the tiered
/// index treatment (per-type candidate indexes, first-match resolved by rule
/// index) once the tunnel integration lands; the semantics in this file are the
/// reference those indexes must reproduce.
nonisolated struct OrderedRouteMatcher: Sendable {

    struct Result: Sendable, Equatable {
        let action: RouteMatchAction
        /// Line of the matching rule, or `nil` when `FINAL` decided the route.
        let ruleLine: Int?
        /// Whether `FINAL` produced the action.
        var isFinal: Bool { ruleLine == nil }
    }

    let rules: [OrderedRoutingRule]
    let finalAction: RouteMatchAction

    private let geoIP: any GeoIPLookup
    private let geoSite: any GeoSiteLookup

    init(
        rules: [OrderedRoutingRule],
        finalAction: RouteMatchAction = .defaultProxy,
        geoIP: any GeoIPLookup = EmptyGeoIPLookup(),
        geoSite: any GeoSiteLookup = EmptyGeoSiteLookup()
    ) {
        self.rules = rules.sorted { $0.line < $1.line }
        self.finalAction = finalAction
        self.geoIP = geoIP
        self.geoSite = geoSite
    }

    enum Evaluation: Sendable {
        case matched(Result)
        case needsAddress
        case deferred
    }

    /// Stop before a later rule can win when an earlier rule needs DNS or flow
    /// metadata. DNS-time previews must not cache a verdict for a later rule.
    ///
    /// `deferOnMissingMetadata` mirrors `deferOnHostUnknown` for flow metadata
    /// (source address/port, destination port, protocol). When a field can never
    /// be supplied for this flow — a script/DoH request, for example, has no
    /// source address — the caller passes `false`, and a rule that needs the
    /// absent field simply does not match while the scan continues. That lets a
    /// later rule (a terminal `REJECT`, say) still decide the route instead of
    /// the whole evaluation deferring and falling through to the default route.
    func evaluate(_ query: RouteQuery, allowAddressResolution: Bool = true, allowFinal: Bool = true,
                  deferOnHostUnknown: Bool = true, deferOnMissingMetadata: Bool = true) -> Evaluation {
        // A host-based rule earlier in order cannot match while the host is
        // unknown. Track that as an explicit state and defer any later verdict
        // (including FINAL) so an earlier domain rule can still win once the host
        // is known. When the host can never be known (post-sniff), the caller
        // passes deferOnHostUnknown: false to finish the IP/FINAL match.
        var sawHostUnknown = false
        for rule in rules {
            switch Self.predicate(rule.matcher, rule: rule, query: query, geoIP: geoIP, geoSite: geoSite) {
            case .yes:
                if sawHostUnknown, deferOnHostUnknown { return .deferred }
                return .matched(Result(action: rule.action, ruleLine: rule.line))
            case .no:
                continue
            case .hostUnknown:
                sawHostUnknown = true
                continue
            case .address:
                if !rule.noResolve && allowAddressResolution { return .needsAddress }
            case .metadata:
                // The field this rule needs will not be available for this flow,
                // so the rule does not match. Keep scanning so a later rule can
                // still decide the route (instead of deferring the whole
                // evaluation and letting the caller fall through to default).
                if deferOnMissingMetadata { return .deferred }
                continue
            }
        }
        if sawHostUnknown, deferOnHostUnknown { return .deferred }
        return allowFinal ? .matched(Result(action: finalAction, ruleLine: nil)) : .deferred
    }

    func firstMatch(_ query: RouteQuery) -> OrderedRoutingRule? {
        for rule in rules where Self.matches(rule, query: query, geoIP: geoIP, geoSite: geoSite) {
            return rule
        }
        return nil
    }

    func match(_ query: RouteQuery) -> Result {
        if case .matched(let result) = evaluate(query, allowAddressResolution: false) { return result }
        return Result(action: finalAction, ruleLine: nil)
    }
}


// MARK: - Evaluation

nonisolated extension OrderedRouteMatcher {

    private enum Predicate { case yes, no, address, metadata, hostUnknown }

    private static func predicate(_ matcher: OrderedRoutingRule.Matcher, rule: OrderedRoutingRule,
                                  query: RouteQuery, geoIP: any GeoIPLookup, geoSite: any GeoSiteLookup) -> Predicate {
        switch matcher {
        case .allOf(let children):
            let results = children.map { predicate($0, rule: rule, query: query, geoIP: geoIP, geoSite: geoSite) }
            if results.contains(where: { if case .no = $0 { true } else { false } }) { return .no }
            if results.contains(where: { if case .address = $0 { true } else { false } }) { return .address }
            if results.contains(where: { if case .metadata = $0 { true } else { false } }) { return .metadata }
            if results.contains(where: { if case .hostUnknown = $0 { true } else { false } }) { return .hostUnknown }
            return .yes
        case .anyOf(let children):
            let results = children.map { predicate($0, rule: rule, query: query, geoIP: geoIP, geoSite: geoSite) }
            if results.contains(where: { if case .yes = $0 { true } else { false } }) { return .yes }
            if results.contains(where: { if case .address = $0 { true } else { false } }) { return .address }
            if results.contains(where: { if case .metadata = $0 { true } else { false } }) { return .metadata }
            if results.contains(where: { if case .hostUnknown = $0 { true } else { false } }) { return .hostUnknown }
            return .no
        case .negated(let child):
            switch predicate(child, rule: rule, query: query, geoIP: geoIP, geoSite: geoSite) {
            case .yes: return .no
            case .no: return .yes
            case .address: return .address
            case .metadata: return .metadata
            case .hostUnknown: return .hostUnknown
            }
        default:
            if matcher.requiresResolvedAddress && query.ip == nil { return .address }
            if matcher.lacksMetadata(query) { return .metadata }
            if matcher.requiresHost && query.host == nil { return .hostUnknown }
            let leaf = OrderedRoutingRule(line: rule.line, matcher: matcher, action: rule.action, noResolve: rule.noResolve)
            return matches(leaf, query: query, geoIP: geoIP, geoSite: geoSite) ? .yes : .no
        }
    }

    static func matches(
        _ rule: OrderedRoutingRule,
        query: RouteQuery,
        geoIP: any GeoIPLookup,
        geoSite: any GeoSiteLookup
    ) -> Bool {
        switch rule.matcher {
        case .allOf(let children):
            return children.allSatisfy { matches(OrderedRoutingRule(line: rule.line, matcher: $0, action: rule.action, noResolve: rule.noResolve), query: query, geoIP: geoIP, geoSite: geoSite) }
        case .anyOf(let children):
            return children.contains { matches(OrderedRoutingRule(line: rule.line, matcher: $0, action: rule.action, noResolve: rule.noResolve), query: query, geoIP: geoIP, geoSite: geoSite) }
        case .negated(let child):
            return !matches(OrderedRoutingRule(line: rule.line, matcher: child, action: rule.action, noResolve: rule.noResolve), query: query, geoIP: geoIP, geoSite: geoSite)
        case .domain(let value):
            guard let host = normalizedHost(query.host),
                  let expected = normalizedHost(value)
            else { return false }
            return host == expected

        case .domainSuffix(let value):
            guard let host = normalizedHost(query.host),
                  let suffix = normalizedHost(value)
            else { return false }
            return host == suffix || host.hasSuffix("." + suffix)

        case .domainKeyword(let value):
            guard let host = normalizedHost(query.host) else { return false }
            let keyword = value.lowercased()
            return !keyword.isEmpty && host.contains(keyword)

        case .domainWildcard(let value):
            guard let host = normalizedHost(query.host) else { return false }
            return glob(value.lowercased(), matches: host)

        case .domainRegex(let pattern):
            guard let host = normalizedHost(query.host) else { return false }
            return regexMatches(pattern, host)

        case .urlRegex(let pattern):
            guard let url = query.url else { return false }
            return regexMatches(pattern, url)

        case .ipCIDR(let cidrPrefix):
            guard let ip = query.ip else { return false }
            return cidrPrefix.contains(ip)

        case .sourceIP(let cidrPrefix):
            guard let ip = query.sourceIP else { return false }
            return cidrPrefix.contains(ip)

        case .ipASN(let asn), .geoASN(let asn):
            guard let ip = query.ip, let resolved = geoIP.asn(for: ip) else { return false }
            return resolved == asn

        case .geoIP(let country):
            guard let ip = query.ip, let resolved = geoIP.countryCode(for: ip) else { return false }
            return resolved.caseInsensitiveCompare(country) == .orderedSame

        case .geoSite(let tag):
            guard let host = normalizedHost(query.host) else { return false }
            return geoSite.matches(host: host, tag: tag)

        case .ruleSet:
            return false

        case .processName(let value):
            guard let process = query.processName else { return false }
            return process.caseInsensitiveCompare(value) == .orderedSame

        case .sourcePort(let port):
            return query.sourcePort == port

        case .destinationPort(let port):
            return query.destinationPort == port

        case .protocolName(let value):
            guard let name = query.protocolName else { return false }
            return name.caseInsensitiveCompare(value) == .orderedSame

        case .userAgent(let value):
            guard let agent = query.userAgent else { return false }
            return agent.lowercased().contains(value.lowercased())

        case .unsupported:
            return false
        }
    }

    static func normalizedHost(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    static func regexMatches(_ pattern: String, _ subject: String) -> Bool {
        guard (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil else {
            return false
        }
        return subject.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Shell-style glob: `*` matches any run of characters (dots included),
    /// `?` matches exactly one. Linear backtracking, no recursion.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let patternChars = Array(pattern)
        let textChars = Array(text)
        var patternIndex = 0
        var textIndex = 0
        var starIndex = -1
        var resumeIndex = 0

        while textIndex < textChars.count {
            if patternIndex < patternChars.count,
               patternChars[patternIndex] == "?" || patternChars[patternIndex] == textChars[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
                starIndex = patternIndex
                resumeIndex = textIndex
                patternIndex += 1
            } else if starIndex >= 0 {
                patternIndex = starIndex + 1
                resumeIndex += 1
                textIndex = resumeIndex
            } else {
                return false
            }
        }

        while patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternChars.count
    }
}


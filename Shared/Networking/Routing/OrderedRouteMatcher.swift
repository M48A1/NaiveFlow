//
//  OrderedRouteMatcher.swift
//  RuleProxy
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
nonisolated enum RouteMatchAction: Hashable, Sendable {
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

/// An IPv4/IPv6 network prefix, parsed once and matched without allocations.
nonisolated struct CIDRPrefix: Hashable, Sendable {
    enum Family: Hashable, Sendable {
        case v4
        case v6

        var byteCount: Int { self == .v4 ? 4 : 16 }
        var addressFamily: Int32 { self == .v4 ? AF_INET : AF_INET6 }
    }

    let family: Family
    /// Network bytes, already masked to `prefixLength`.
    let bytes: [UInt8]
    let prefixLength: Int

    /// Accepts `1.2.3.0/24`, `1.2.3.4` (treated as `/32`), and `2001:db8::/32`.
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
            prefixLength = addressText.contains(":") ? 128 : 32
        }

        if let v4 = canonicalBytes(addressText, family: .v4) {
            guard prefixLength <= 32 else { return nil }
            return CIDRPrefix(family: .v4, bytes: mask(v4, prefixLength: prefixLength, family: .v4), prefixLength: prefixLength)
        }
        if let v6 = canonicalBytes(addressText, family: .v6) {
            guard prefixLength <= 128 else { return nil }
            return CIDRPrefix(family: .v6, bytes: mask(v6, prefixLength: prefixLength, family: .v6), prefixLength: prefixLength)
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
            let mask: UInt8 = bitsInByte == 8 ? 0xFF : bitsInByte == 0 ? 0 : UInt8(0xFF << (8 - bitsInByte))
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
nonisolated struct OrderedRoutingRule: Sendable, Identifiable, Equatable {
    enum Matcher: Sendable, Equatable {
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
            default:
                return false
            }
        }

        /// Rules that need the destination host name.
        var requiresHost: Bool {
            switch self {
            case .domain, .domainSuffix, .domainKeyword, .domainWildcard,
                 .domainRegex, .geoSite:
                return true
            case .urlRegex:
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

    func firstMatch(_ query: RouteQuery) -> OrderedRoutingRule? {
        for rule in rules where Self.matches(rule, query: query, geoIP: geoIP, geoSite: geoSite) {
            return rule
        }
        return nil
    }

    func match(_ query: RouteQuery) -> Result {
        if let rule = firstMatch(query) {
            return Result(action: rule.action, ruleLine: rule.line)
        }
        return Result(action: finalAction, ruleLine: nil)
    }
}


// MARK: - Evaluation

nonisolated extension OrderedRouteMatcher {

    static func matches(
        _ rule: OrderedRoutingRule,
        query: RouteQuery,
        geoIP: any GeoIPLookup,
        geoSite: any GeoSiteLookup
    ) -> Bool {
        switch rule.matcher {
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

        case .ipCIDR(let prefix):
            guard let ip = query.ip else { return false }
            return prefix.contains(ip)

        case .sourceIP(let prefix):
            guard let ip = query.sourceIP else { return false }
            return prefix.contains(ip)

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


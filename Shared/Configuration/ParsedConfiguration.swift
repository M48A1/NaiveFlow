//
//  ParsedConfiguration.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Typed view of a parsed configuration document.
///
/// This is a pure value type with no dependency on the app's stores: a text
/// document in, a typed description out. `ConfigurationCompiler` turns it into
/// `ProxyConfiguration` / `ProxyGroup` / rule payload values, and
/// `ConfigurationValidator` checks it against the engine's capabilities.
nonisolated struct ParsedConfiguration: Equatable, Sendable {
    var geoIP = OrderedParameters()
    var geoSite = OrderedParameters()
    var general = OrderedParameters()
    var proxies: [ParsedProxy] = []
    var proxyGroups: [ParsedProxyGroup] = []
    var rules: [ParsedRule] = []
    var finalRule: ParsedRule?
    var hosts: [ParsedHostEntry] = []
    var mitmSets = OrderedParameters()
    var mitm = OrderedParameters()
    var scripts: [ParsedScript] = []
    var rewrites: [ParsedRewriteDirective] = []
    /// Raw header text of sections this build does not model.
    var unsupportedSections: [String] = []

    var hasContent: Bool {
        !general.isEmpty || !proxies.isEmpty || !proxyGroups.isEmpty || !rules.isEmpty
            || !geoIP.isEmpty || !geoSite.isEmpty || !mitmSets.isEmpty || finalRule != nil || !hosts.isEmpty || !mitm.isEmpty || !scripts.isEmpty
            || !rewrites.isEmpty
    }

    func proxy(named name: String) -> ParsedProxy? {
        proxies.first { $0.name == name }
    }

    func proxyGroup(named name: String) -> ParsedProxyGroup? {
        proxyGroups.first { $0.name == name }
    }

    /// Policy names referenced by rules, deduplicated and in first-use order.
    var referencedPolicies: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for rule in rules {
            guard case .named(let name) = rule.policy else { continue }
            if seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }

    /// Names that are declared but never referenced by any rule or group.
    var unusedProxies: [String] {
        let referenced = Set(referencedPolicies)
        let groupMembers = Set(proxyGroups.flatMap(\.members))
        return proxies.map(\.name).filter { !referenced.contains($0) && !groupMembers.contains($0) }
    }
}

// MARK: - Proxy

nonisolated struct ParsedProxy: Equatable, Sendable, Identifiable {
    enum Form: Equatable, Sendable {
        /// A proxy URI, e.g. `vless://…`, `ss://…`.
        case link(String)
        /// NaiveFlow fields: `vless, server, 443, uuid=…, tls=true`.
        case fields(type: String, server: String?, port: UInt16?, parameters: OrderedParameters)
    }

    let name: String
    let line: Int
    let form: Form
    let raw: String

    var id: String { name }

    var typeToken: String {
        switch form {
        case .link(let link):
            return String(link.prefix { $0 != ":" }).lowercased()
        case .fields(let type, _, _, _):
            return type
        }
    }

    var server: String? {
        if case .fields(_, let server, _, _) = form { return server }
        return nil
    }

    var port: UInt16? {
        if case .fields(_, _, let port, _) = form { return port }
        return nil
    }

    var isLink: Bool {
        if case .link = form { return true }
        return false
    }
}

// MARK: - Proxy Group

nonisolated struct ParsedProxyGroup: Equatable, Sendable, Identifiable {
    enum Kind: String, CaseIterable, Sendable {
        case select
        case urlTest = "url-test"
        case fallback
        case loadBalance = "load-balance"
        case smart
        case random

        init?(token: String) {
            let normalized = token
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            switch normalized {
            case "select", "manual": self = .select
            case "url-test", "urltest", "auto": self = .urlTest
            case "fallback": self = .fallback
            case "load-balance", "loadbalance", "balance": self = .loadBalance
            case "smart": self = .smart
            case "random": self = .random
            default: return nil
            }
        }

        /// Group kinds the current engine can represent.
        var isSupportedByEngine: Bool {
            switch self {
            case .select, .urlTest, .fallback, .loadBalance:
                return true
            case .smart, .random:
                return false
            }
        }
    }

    let name: String
    let line: Int
    /// Kind token as written; `nil` when it did not match a known kind.
    let kindToken: String
    let kind: Kind?
    let members: [String]
    let parameters: OrderedParameters
    let raw: String

    var id: String { name }

    var isWellFormed: Bool { kind != nil && !members.isEmpty }
}

// MARK: - Rule

nonisolated struct ParsedRule: Equatable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case domain
        case domainSuffix
        case domainKeyword
        case domainWildcard
        case domainRegex
        case urlRegex
        case ipCIDR
        case ipCIDR6
        case ipASN
        case geoIP
        case geoASN
        case geoSite
        case ruleSet
        case processName
        case sourceIP
        case sourcePort
        case destinationPort
        case protocolType
        case userAgent
        case final
        case logicalAnd
        case logicalOr
        case logicalNot
        case unsupported(String)

        init(token: String) {
            let normalized = token
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            switch normalized {
            case "domain": self = .domain
            case "domain-suffix": self = .domainSuffix
            case "domain-keyword": self = .domainKeyword
            case "domain-wildcard": self = .domainWildcard
            case "domain-regex": self = .domainRegex
            case "url-regex": self = .urlRegex
            case "ip-cidr": self = .ipCIDR
            case "ip-cidr6": self = .ipCIDR6
            case "ip-asn": self = .ipASN
            case "geoip": self = .geoIP
            case "geoasn": self = .geoASN
            case "geosite": self = .geoSite
            case "rule-set", "ruleset": self = .ruleSet
            case "process-name": self = .processName
            case "src-ip", "source-ip": self = .sourceIP
            case "src-port", "source-port": self = .sourcePort
            case "dest-port", "dst-port", "destination-port": self = .destinationPort
            case "protocol": self = .protocolType
            case "user-agent": self = .userAgent
            case "final", "match": self = .final
            case "and": self = .logicalAnd
            case "or": self = .logicalOr
            case "not": self = .logicalNot
            default:
                self = .unsupported(token.trimmingCharacters(in: .whitespaces).uppercased())
            }
        }

        var token: String {
            switch self {
            case .domain: return "DOMAIN"
            case .domainSuffix: return "DOMAIN-SUFFIX"
            case .domainKeyword: return "DOMAIN-KEYWORD"
            case .domainWildcard: return "DOMAIN-WILDCARD"
            case .domainRegex: return "DOMAIN-REGEX"
            case .urlRegex: return "URL-REGEX"
            case .ipCIDR: return "IP-CIDR"
            case .ipCIDR6: return "IP-CIDR6"
            case .ipASN: return "IP-ASN"
            case .geoIP: return "GEOIP"
            case .geoASN: return "GEOASN"
            case .geoSite: return "GEOSITE"
            case .ruleSet: return "RULE-SET"
            case .processName: return "PROCESS-NAME"
            case .sourceIP: return "SRC-IP"
            case .sourcePort: return "SRC-PORT"
            case .destinationPort: return "DEST-PORT"
            case .protocolType: return "PROTOCOL"
            case .userAgent: return "USER-AGENT"
            case .final: return "FINAL"
            case .logicalAnd: return "AND"
            case .logicalOr: return "OR"
            case .logicalNot: return "NOT"
            case .unsupported(let token): return token
            }
        }

        /// `FINAL` takes no argument; every other rule takes exactly one
        /// (logical rules take a nested expression string).
        var argumentCount: Int {
            switch self {
            case .final: return 0
            default: return 1
            }
        }
    }


    enum Policy: Equatable, Sendable {
        case direct
        case reject
        case rejectTinyGIF
        case defaultProxy
        case named(String)

        init(token: String) {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            switch trimmed.uppercased() {
            case "DIRECT": self = .direct
            case "REJECT", "REJECT-DROP": self = .reject
            case "REJECT-TINYGIF", "REJECT-NO-DROP": self = .rejectTinyGIF
            case "PROXY": self = .defaultProxy
            default: self = .named(trimmed)
            }
        }

        var token: String {
            switch self {
            case .direct: return "DIRECT"
            case .reject: return "REJECT"
            case .rejectTinyGIF: return "REJECT-TINYGIF"
            case .defaultProxy: return "PROXY"
            case .named(let name): return name
            }
        }

        var isBuiltIn: Bool {
            if case .named = self { return false }
            return true
        }

        var name: String? {
            if case .named(let name) = self { return name }
            return nil
        }
    }

    enum Option: Equatable, Sendable {
        case noResolve
        case extendedMatching
        case preMatching
        case dnsFailed
        case forceRemoteDNS
        case unknown(String)

        init(token: String) {
            let normalized = token
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            switch normalized {
            case "no-resolve": self = .noResolve
            case "extended-matching": self = .extendedMatching
            case "pre-matching": self = .preMatching
            case "dns-failed": self = .dnsFailed
            case "force-remote-dns": self = .forceRemoteDNS
            default: self = .unknown(token.trimmingCharacters(in: .whitespaces))
            }
        }

        var token: String {
            switch self {
            case .noResolve: return "no-resolve"
            case .extendedMatching: return "extended-matching"
            case .preMatching: return "pre-matching"
            case .dnsFailed: return "dns-failed"
            case .forceRemoteDNS: return "force-remote-dns"
            case .unknown(let token): return token
            }
        }
    }

    let line: Int
    let kind: Kind
    let value: String?
    let policy: Policy
    let options: [Option]
    let raw: String

    var id: String { "\(line)#\(raw)" }

    var isFinal: Bool { kind == .final }

    func hasOption(_ option: Option) -> Bool {
        options.contains(option)
    }
}

// MARK: - Host

nonisolated struct ParsedHostEntry: Equatable, Sendable, Identifiable {
    enum Mode: Equatable, Sendable {
        case replace
        case append
        case insert
    }

    let host: String
    let address: String
    let mode: Mode
    let line: Int

    var id: String { "\(line)#\(host)" }
}

// MARK: - Script

nonisolated struct ParsedScript: Equatable, Sendable, Identifiable {
    enum Phase: String, Sendable {
        case httpRequest = "http-request"
        case httpResponse = "http-response"
        case cron
        case dns
        case rule
        case generic

        init(token: String?) {
            switch token?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "http-request": self = .httpRequest
            case "http-response": self = .httpResponse
            case "cron": self = .cron
            case "dns": self = .dns
            case "rule": self = .rule
            default: self = .generic
            }
        }

        var isSupportedByEngine: Bool {
            switch self {
            case .httpRequest, .httpResponse:
                return true
            case .cron, .dns, .rule, .generic:
                return false
            }
        }
    }

    let name: String
    let line: Int
    let phase: Phase
    let pattern: String?
    let path: String?
    let requiresBody: Bool
    let maxSize: Int?
    let argument: String?
    let parameters: OrderedParameters
    let raw: String

    var id: String { "\(line)#\(name)" }
}

// MARK: - Rewrite

nonisolated struct ParsedRewriteDirective: Equatable, Sendable, Identifiable {
    let line: Int
    /// Section the directive came from, e.g. `URL Rewrite`.
    let section: String
    let text: String

    var id: String { "\(line)#\(text)" }
}


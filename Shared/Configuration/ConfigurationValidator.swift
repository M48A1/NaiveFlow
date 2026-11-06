//
//  ConfigurationValidator.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Checks a parsed configuration against the routing engine's capabilities and
/// reports problems as diagnostics.
///
/// `Capabilities` describes what the engine can currently evaluate. It is the
/// single place that encodes "the engine does not do this yet": when ordered
/// rules, GEOIP/GEOSITE, or per-rule policies land, update `current` and the
/// same documents become activatable without touching the parser.
nonisolated enum ConfigurationValidator {

    struct Capabilities: Sendable {
        let ruleKinds: Set<ParsedRule.Kind>
        let groupKinds: Set<ParsedProxyGroup.Kind>
        /// The matcher walks the document top to bottom (first match wins).
        let preservesRuleOrder: Bool
        /// A rule carries its own policy instead of inheriting the rule set's.
        let supportsPerRulePolicy: Bool
        /// `FINAL` is honored as the terminal catch-all.
        let supportsFinal: Bool
        /// `AND` / `OR` / `NOT` expressions are evaluated.
        let supportsLogicalRules: Bool
        /// GEOIP / GEOSITE lookups are available.
        let supportsGeoDatabases: Bool
        /// Length of the longest rule set the engine accepts.
        let maxRuleCount: Int

        /// Native documents use the ordered matcher and explicit local geo data.
        /// The preserved manual baseline continues using its original matcher.
        static let current = Capabilities(
            ruleKinds: [.domain, .domainSuffix, .domainKeyword, .domainWildcard, .domainRegex, .urlRegex,
                        .ipCIDR, .sourceIP, .sourcePort, .destinationPort, .protocolType,
                        .processName, .userAgent,
                        .ruleSet, .geoIP, .geoASN, .ipASN, .geoSite, .logicalAnd, .logicalOr, .logicalNot],
            groupKinds: [.select, .urlTest, .fallback, .loadBalance],
            preservesRuleOrder: true,
            supportsPerRulePolicy: true,
            supportsFinal: true,
            supportsLogicalRules: true,
            supportsGeoDatabases: true,
            maxRuleCount: CustomRoutingRuleSet.maxRuleCount
        )
    }

    /// Derived from the settings catalog so the parser and the compiler can never
    /// disagree about which `[General]` keys exist.
    static var knownGeneralKeys: Set<String> {
        ConfigurationSettings.names
    }

    static let knownMITMKeys: Set<String> = [
        "enable",
        "hostname",
        "tcp-connection",
        "skip-server-cert-verify",
        "ca-passphrase",
        "auto-quic-block",
        "use-default-ca",
        "client-source-address",
    ]

    /// Reserved names that have no runtime binding. They remain readable for
    /// diagnostics and editing, but are errors at activation.
    static var acceptedGeneralKeys: Set<String> {
        Set(ConfigurationSettings.unappliedKeys.map(\.name))
    }

    /// `[MITM] enable` is honored; the certificate and host fields are stored in
    /// the document but are not consumed by the MITM host list yet.
    static let acceptedMITMKeys: Set<String> = []

    static func validate(
        _ configuration: ParsedConfiguration,
        capabilities: Capabilities = .current
    ) -> [ConfigurationDiagnostic] {
        var diagnostics: [ConfigurationDiagnostic] = []

        validateGeneral(configuration, diagnostics: &diagnostics)
        validateUnsupportedSections(configuration, diagnostics: &diagnostics)
        validateProxies(configuration, diagnostics: &diagnostics)
        validateProxyGroups(configuration, capabilities: capabilities, diagnostics: &diagnostics)
        validateRules(configuration, capabilities: capabilities, diagnostics: &diagnostics)
        validateHosts(configuration, diagnostics: &diagnostics)
        validateMITM(configuration, diagnostics: &diagnostics)
        validateScripts(configuration, diagnostics: &diagnostics)
        validateAcceptedButUnapplied(configuration, diagnostics: &diagnostics)

        return diagnostics.sorted
    }

    // MARK: - General

    private static func validateGeneral(
        _ configuration: ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for name in ["tun-included-routes", "tun-excluded-routes"] {
            if let raw = configuration.general[name], ConfigurationDocument.splitList(raw).contains(where: { IPRoute($0) == nil }) {
                diagnostics.append(.init(severity: .error, code: .invalidValue, section: "General",
                    message: "Tunnel routes accept valid IPv4 CIDRs only."))
            }
        }
        for prefix in ["", "proxy-", "subscription-", "ech-"] {
            let plain = prefix + "dns-server"
            let encrypted = prefix + "encrypted-dns-server"
            let mode = prefix + "dns-mode"
            if configuration.general[plain] != nil, configuration.general[encrypted] != nil,
               configuration.general[mode] == nil {
                diagnostics.append(.init(severity: .error, code: .invalidValue, section: "DNS",
                    message: "Set \(mode) explicitly when both plain DNS and DoH addresses are configured."))
            }
        }
        for key in configuration.general.keys {
            guard let definition = ConfigurationSettings.key(named: key) else {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .unknownGeneralKey,
                        line: nil,
                        section: ConfigurationDocument.SectionKind.general.displayName,
                        message: "General setting '\(key)' is not recognized and is ignored."
                    )
                )
                continue
            }

            guard let raw = configuration.general[key] else { continue }
            if definition.parse(raw) != nil { continue }

            // Every rejection names the value the key does accept, so the editor
            // can be fixed without leaving the text view.
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: raw.trimmingCharacters(in: .whitespaces).isEmpty ? .missingValue : .invalidValue,
                    section: ConfigurationDocument.SectionKind.general.displayName,
                    message: "General setting '\(key)' \(expectation(for: definition.kind))."
                )
            )
        }
    }

    /// What a key of this kind accepts, phrased for a diagnostic.
    private static func expectation(for kind: ConfigurationSettingKey.Kind) -> String {
        switch kind {
        case .flag:
            return "expects a boolean value (true/false)"
        case .text:
            return "needs a value"
        case .enumeration(let values):
            return "must be one of \(values.joined(separator: ", "))"
        case .countryCode:
            return "must be a two-letter country code"
        case .list:
            return "expects a comma-separated list"
        case .plainServer:
            return "must be an IPv4 address, optionally with a port"
        case .bootstrapDNS:
            return "must be system or a comma-separated list of up to eight IPv4 addresses"
        case .dohURL:
            return "must be an https:// URL"
        }
    }

    private static func validateUnsupportedSections(
        _ configuration: ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for name in configuration.unsupportedSections {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .unknownSection,
                    section: name,
                    message: "Section [\(name)] is preserved but has no effect in this build."
                )
            )
        }
    }

    /// Settings this build parses and keeps but does not apply.
    ///
    /// Preserved in drafts, rejected on activation. The format belongs to
    /// NaiveFlow; accepting an inert directive is not a compatibility feature.
    private static func validateAcceptedButUnapplied(
        _ configuration: ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for key in configuration.general.keys where acceptedGeneralKeys.contains(key) {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .notApplied,
                    section: ConfigurationDocument.SectionKind.general.displayName,
                    message: "General setting '\(key)' is recognized but this build does not apply it yet."
                )
            )
        }

        for key in configuration.mitm.keys where acceptedMITMKeys.contains(key) {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .notApplied,
                    section: ConfigurationDocument.SectionKind.mitm.displayName,
                    message: "MITM setting '\(key)' is recognized but this build does not apply it yet."
                )
            )
        }


    }
}

// MARK: - Proxies

nonisolated extension ConfigurationValidator {

    static func validateProxies(
        _ configuration: ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for proxy in configuration.proxies {
            // `DIRECT`, `REJECT`, `REJECT-TINYGIF` and `PROXY` are policy tokens,
            // not names: `RULE, value, DIRECT` binds to the built-in action even
            // when a node is called `DIRECT`. The node then exists but can never
            // be selected, so say it out loud instead of letting the reference
            // quietly mean something else.
            if ParsedRule.Policy(token: proxy.name).isBuiltIn {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .warning,
                        code: .reservedPolicyName,
                        line: proxy.line,
                        section: ConfigurationDocument.SectionKind.proxy.displayName,
                        message: "Proxy '\\(proxy.name)' is named like the built-in policy '\\(proxy.name.uppercased())', so a rule pointing at '\\(proxy.name)' uses that built-in action instead of this node. Rename the node to route to it."
                    )
                )
            }
            switch proxy.form {
            case .link(let link):
                if !ProxyConfiguration.canParseURL(link) {
                    diagnostics.append(
                        ConfigurationDiagnostic(
                            severity: .error,
                            code: .invalidValue,
                            line: proxy.line,
                            section: ConfigurationDocument.SectionKind.proxy.displayName,
                            message: "Proxy '\(proxy.name)' link cannot be parsed: \(link.prefix(48))"
                        )
                    )
                }
            case .fields(let type, let server, let port, _):
                if !NaiveFlowConfigurationParser.supportedProxyTypes.contains(type) {
                    diagnostics.append(
                        ConfigurationDiagnostic(
                            severity: .error,
                            code: .unknownProxyType,
                            line: proxy.line,
                            section: ConfigurationDocument.SectionKind.proxy.displayName,
                            message: "Proxy '\(proxy.name)' uses type '\(type)', which cannot be dialed."
                        )
                    )
                }
                if (server ?? "").trimmingCharacters(in: .whitespaces).isEmpty, type != "direct" {
                    diagnostics.append(
                        ConfigurationDiagnostic(
                            severity: .error,
                            code: .missingValue,
                            line: proxy.line,
                            section: ConfigurationDocument.SectionKind.proxy.displayName,
                            message: "Proxy '\(proxy.name)' has no server address."
                        )
                    )
                }
                if port == nil, type != "direct" {
                    diagnostics.append(
                        ConfigurationDiagnostic(
                            severity: .error,
                            code: .missingValue,
                            line: proxy.line,
                            section: ConfigurationDocument.SectionKind.proxy.displayName,
                            message: "Proxy '\(proxy.name)' has no port."
                        )
                    )
                }
            }
        }
    }
}


// MARK: - Proxy Groups

nonisolated extension ConfigurationValidator {

    static func validateProxyGroups(
        _ configuration: ParsedConfiguration,
        capabilities: Capabilities,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        let proxyNames = Set(configuration.proxies.map(\.name))
        let groupNames = Set(configuration.proxyGroups.map(\.name))

        for group in configuration.proxyGroups {
            // Same reservation as in `[Proxy]`: a group named `PROXY` (or
            // `DIRECT`, `REJECT`, `REJECT-TINYGIF`) can never be the policy of a
            // rule, because that column is read as a built-in action first.
            if ParsedRule.Policy(token: group.name).isBuiltIn {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .warning,
                        code: .reservedPolicyName,
                        line: group.line,
                        section: ConfigurationDocument.SectionKind.proxyGroup.displayName,
                        message: "Proxy group '\\(group.name)' is named like the built-in policy '\\(group.name.uppercased())', so a rule pointing at '\\(group.name)' uses that built-in action instead of this group. Rename the group to route to it."
                    )
                )
            }

            guard let kind = group.kind else {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .invalidValue,
                        line: group.line,
                        section: ConfigurationDocument.SectionKind.proxyGroup.displayName,
                        message: "Proxy group '\(group.name)' has unknown type '\(group.kindToken)'."
                    )
                )
                continue
            }

            if !capabilities.groupKinds.contains(kind) {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .unsupportedRuleType,
                        line: group.line,
                        section: ConfigurationDocument.SectionKind.proxyGroup.displayName,
                        message: "Proxy group '\(group.name)' uses '\(group.kindToken)'; this build treats it as a manual selection group."
                    )
                )
            }

            let supportedParameters: Set<String> = kind == .select
                ? ["selected"]
                : ["selected", "interval", "tolerance", "url"]
            for (key, _) in group.parameters.pairs where !supportedParameters.contains(key) {
                diagnostics.append(.init(severity: .error, code: .notApplied, line: group.line,
                    section: "Proxy Group", message: "Unsupported native group option '\(key)'."))
            }
            if let selected = group.parameters["selected"], !group.members.contains(selected) {
                diagnostics.append(.init(severity: .error, code: .invalidValue, line: group.line,
                    section: "Proxy Group", message: "selected must name one of the group's members."))
            }
            for member in group.members {
                if builtInPolicyName(member) != nil { continue }
                if proxyNames.contains(member) || groupNames.contains(member) { continue }
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .unresolvedPolicy,
                        line: group.line,
                        section: ConfigurationDocument.SectionKind.proxyGroup.displayName,
                        message: "Proxy group '\(group.name)' references unknown member '\(member)'."
                    )
                )
            }

            if Set(group.members).count != group.members.count {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .info,
                        code: .duplicateName,
                        line: group.line,
                        section: ConfigurationDocument.SectionKind.proxyGroup.displayName,
                        message: "Proxy group '\(group.name)' lists the same member more than once."
                    )
                )
            }
        }

        diagnostics.append(contentsOf: groupCycles(configuration.proxyGroups))
    }

    /// Returns the canonical spelling of `DIRECT` / `REJECT` / `PROXY`, or `nil`
    /// when the token names a proxy or group instead.
    static func builtInPolicyName(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
        case "DIRECT": return "DIRECT"
        case "REJECT", "REJECT-DROP": return "REJECT"
        case "REJECT-TINYGIF", "REJECT-NO-DROP": return "REJECT"
        case "PROXY": return "PROXY"
        default: return nil
        }
    }
}


// MARK: - Group cycles

nonisolated extension ConfigurationValidator {

    private static func groupCycles(_ groups: [ParsedProxyGroup]) -> [ConfigurationDiagnostic] {
        let byName = Dictionary(groups.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var visiting = Set<String>()
        var visited = Set<String>()
        var reported = Set<String>()
        var found: [ConfigurationDiagnostic] = []

        func visit(_ name: String, path: [String]) {
            if visited.contains(name) { return }
            if visiting.contains(name) {
                let cycle = path + [name]
                let key = Set(cycle).sorted().joined(separator: ">")
                if reported.insert(key).inserted, let group = byName[name] {
                    found.append(
                        ConfigurationDiagnostic(
                            severity: .error,
                            code: .groupCycle,
                            line: group.line,
                            section: ConfigurationDocument.SectionKind.proxyGroup.displayName,
                            message: "Proxy groups form a cycle: \(cycle.joined(separator: " -> "))"
                        )
                    )
                }
                return
            }
            visiting.insert(name)
            for member in byName[name]?.members ?? [] where byName[member] != nil {
                visit(member, path: path + [name])
            }
            visiting.remove(name)
            visited.insert(name)
        }

        for group in groups {
            visit(group.name, path: [])
        }
        return found
    }
}


// MARK: - Rules

nonisolated extension ConfigurationValidator {

    static func validateRules(
        _ configuration: ParsedConfiguration,
        capabilities: Capabilities,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        let knownPolicies = Set(configuration.proxies.map(\.name))
            .union(configuration.proxyGroups.map(\.name))

        for rule in configuration.rules {
            validateRuleKind(rule, capabilities: capabilities, diagnostics: &diagnostics)
            validateRulePolicy(rule, knownPolicies: knownPolicies, diagnostics: &diagnostics)
            validateRuleOptions(rule, diagnostics: &diagnostics)
        }

        let finals = configuration.rules.filter(\.isFinal)
        if finals.count > 1 {
            for extra in finals.dropFirst() {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .duplicateFinal,
                        line: extra.line,
                        section: ConfigurationDocument.SectionKind.rule.displayName,
                        message: "FINAL is declared more than once."
                    )
                )
            }
        }
        if let final = configuration.finalRule {
            if let last = configuration.rules.last, last.line != final.line {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .finalNotLast,
                        line: final.line,
                        section: ConfigurationDocument.SectionKind.rule.displayName,
                        message: "FINAL must be the last rule."
                    )
                )
            }
            if !capabilities.supportsFinal {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .unsupportedRuleType,
                        line: final.line,
                        section: ConfigurationDocument.SectionKind.rule.displayName,
                        message: "FINAL is parsed, but the engine currently uses each rule set's assigned policy as its terminal action."
                    )
                )
            }
        }

        if !capabilities.preservesRuleOrder, configuration.rules.count > 1 {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .warning,
                    code: .unsupportedRuleType,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "Rules are matched per policy group rather than in document order until the ordered matcher lands."
                )
            )
        }

        for name in configuration.unusedProxies {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .info,
                    code: .unusedProxy,
                    section: ConfigurationDocument.SectionKind.proxy.displayName,
                    message: "Proxy '\(name)' is declared but no rule or group uses it."
                )
            )
        }

        if configuration.rules.count > capabilities.maxRuleCount {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .invalidValue,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "The document has \(configuration.rules.count) rules; the engine accepts at most \(capabilities.maxRuleCount)."
                )
            )
        }

        // The routing payload stores a rule value in a UInt16 length field and
        // skips longer values when it writes the file, so an over-long value has
        // to be an error here: otherwise the rule disappears without a trace.
        for rule in configuration.rules {
            let size = rule.value?.utf8.count ?? 0
            guard size > Int(UInt16.max) else { continue }
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .ruleValueTooLong,
                    line: rule.line,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "The rule value is \(size) UTF-8 bytes; the routing payload accepts at most \(UInt16.max)."
                )
            )
        }
    }
}


// MARK: - Rule details

nonisolated extension ConfigurationValidator {

    static func validateRuleKind(
        _ rule: ParsedRule,
        capabilities: Capabilities,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        switch rule.kind {
        case .unsupported(let token):
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .unsupportedRuleType,
                    line: rule.line,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "Rule type '\(token)' is not recognized."
                )
            )
        case .final:
            break
        default:
            if !capabilities.ruleKinds.contains(rule.kind) {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .unsupportedRuleType,
                        line: rule.line,
                        section: ConfigurationDocument.SectionKind.rule.displayName,
                        message: "Rule type '\(rule.kind.token)' cannot be evaluated by the routing engine yet."
                    )
                )
            }
            if (rule.kind == .logicalAnd || rule.kind == .logicalOr || rule.kind == .logicalNot),
               !capabilities.supportsLogicalRules {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .unsupportedRuleType,
                        line: rule.line,
                        section: ConfigurationDocument.SectionKind.rule.displayName,
                        message: "Logical rules are not implemented by the routing engine yet."
                    )
                )
            }
        }

        if rule.kind == .geoIP || rule.kind == .geoASN || rule.kind == .geoSite,
           !capabilities.supportsGeoDatabases {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .unsupportedRuleType,
                    line: rule.line,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "Geo databases are not bundled yet, so '\(rule.kind.token)' cannot be evaluated."
                )
            )
        }
    }

    static func validateRulePolicy(
        _ rule: ParsedRule,
        knownPolicies: Set<String>,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        guard case .named(let name) = rule.policy else { return }

        if name.isEmpty {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .missingRulePolicy,
                    line: rule.line,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "Rule '\(rule.kind.token)' has an empty policy."
                )
            )
            return
        }

        if knownPolicies.contains(name) { return }

        diagnostics.append(
            ConfigurationDiagnostic(
                severity: .error,
                code: .unknownPolicy,
                line: rule.line,
                section: ConfigurationDocument.SectionKind.rule.displayName,
                message: "Rule '\(rule.kind.token)' points at unknown policy '\(name)'."
            )
        )
    }

    static func validateRuleOptions(
        _ rule: ParsedRule,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        let isIPRule: Bool
        switch rule.kind {
        case .ruleSet, .ipCIDR, .ipASN, .geoIP, .geoASN, .logicalAnd, .logicalOr, .logicalNot:
            isIPRule = true
        default:
            isIPRule = false
        }

        for option in rule.options {
            switch option {
            case .noResolve:
                if !isIPRule {
                    diagnostics.append(
                        ConfigurationDiagnostic(
                            severity: .warning,
                            code: .invalidValue,
                            line: rule.line,
                            section: ConfigurationDocument.SectionKind.rule.displayName,
                            message: "no-resolve only applies to IP-based rules."
                        )
                    )
                }
            case .extendedMatching, .preMatching, .dnsFailed, .forceRemoteDNS:
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .unsupportedRuleOption,
                        line: rule.line,
                        section: ConfigurationDocument.SectionKind.rule.displayName,
                        message: "Option '\(option.token)' is recognized but ignored by this build."
                    )
                )
            case .unknown:
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .error, code: .unsupportedRuleOption, line: rule.line,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "Unknown rule option '\(option.token)'."
                ))
            }
        }
    }
}


// MARK: - Hosts

nonisolated extension ConfigurationValidator {

    static func validateHosts(
        _ configuration: ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for entry in configuration.hosts {
            if normalizedHostPattern(entry.host) == nil {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .invalidValue,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.host.displayName,
                        message: "Host '\(entry.host)' is not a valid domain."
                    )
                )
            }

            var address = entry.address
            if address.lowercased().hasPrefix("server:") {
                address = String(address.dropFirst("server:".count))
            }
            if !isValidHostValue(address) {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .invalidValue,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.host.displayName,
                        message: "Host '\(entry.host)' maps to invalid address '\(entry.address)'."
                    )
                )
            }
        }
    }

    /// Accepts exact domains, `*.suffix` wildcards, and `*`.
    static func normalizedHostPattern(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if host == "*" { return host }
        if host.hasPrefix("*.") { host = String(host.dropFirst(2)) }
        return DNSName.normalizedHost(host)
    }

    private static func isValidHostValue(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return false }
        if HostMapping.canonicalAddress(value) != nil { return true }
        return normalizedHostPattern(value) != nil
    }
}


// MARK: - MITM

nonisolated extension ConfigurationValidator {

    static func validateMITM(_ configuration: ParsedConfiguration, diagnostics: inout [ConfigurationDiagnostic]) {
        for key in configuration.mitm.keys where !["enable", "hostname"].contains(key) {
            diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .notApplied,
                section: "MITM", message: "Unsupported native MITM field '\(key)'."))
        }
        if configuration.mitm.contains("enable"), configuration.mitm.bool("enable") == nil {
            diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .invalidValue,
                section: "MITM", message: "MITM enable expects true or false."))
        }
        for suffix in configuration.mitm.list("hostname") ?? [] {
            if DNSName.normalizedHost(suffix) == nil {
                diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .invalidValue,
                    section: "MITM", message: "MITM hostname uses plain domain suffixes, such as example.com."))
            }
        }
    }

}


// MARK: - Scripts

nonisolated extension ConfigurationValidator {

    static func validateScripts(
        _ configuration: ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for script in configuration.scripts {
            if (script.path ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .missingValue,
                        line: script.line,
                        section: ConfigurationDocument.SectionKind.script.displayName,
                        message: "Script '\(script.name)' has no script-path."
                    )
                )
            }

            switch script.phase {
            case .httpRequest, .httpResponse:
                if (script.pattern ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    diagnostics.append(
                        ConfigurationDiagnostic(
                            severity: .error,
                            code: .missingValue,
                            line: script.line,
                            section: ConfigurationDocument.SectionKind.script.displayName,
                            message: "Script '\(script.name)' has no pattern."
                        )
                    )
                }
            case .cron, .dns, .rule, .generic:
                break
            }

            if let maxSize = script.maxSize, maxSize < 0 {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .invalidValue,
                        line: script.line,
                        section: ConfigurationDocument.SectionKind.script.displayName,
                        message: "Script '\(script.name)' has a negative max-size."
                    )
                )
            }
        }
    }
}


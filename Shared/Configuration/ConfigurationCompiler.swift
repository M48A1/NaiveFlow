//
//  ConfigurationCompiler.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Result of compiling a text configuration into engine values.
///
/// Compilation never touches the stores: it produces values plus diagnostics so
/// a document can be validated, previewed, and applied atomically afterwards.
nonisolated struct CompiledConfiguration: Sendable {
    let proxies: [ProxyConfiguration]
    let proxyGroups: [ProxyGroup]
    let ruleSets: [CompiledRuleSet]
    /// Rules in document order, including kinds the current binary payload
    /// cannot carry yet. Used for previews and by the ordered matcher.
    let orderedRules: [OrderedRoutingRule]
    /// Action taken when no rule matches (`FINAL`, defaulting to `PROXY`).
    let finalAction: RouteMatchAction
    let hosts: [HostMapping]
    let geo: NativeGeoDatabase
    let textMITM: CompiledTextMITM
    let settings: CompiledSettings
    let diagnostics: [ConfigurationDiagnostic]

    var isActivatable: Bool { !diagnostics.hasErrors }

    var errors: [ConfigurationDiagnostic] { diagnostics.errors }
}

/// One rule set in the engine's terms: a policy plus every rule that selects it.
nonisolated struct CompiledRuleSet: Sendable {
    let name: String
    let policy: RouteTarget
    let rules: [RoutingRule]
}


/// Maps a `ParsedConfiguration` onto the app's existing model types.
///
/// Proxies become `ProxyConfiguration` (through the URL parser or
/// `ClashProxyParser`), groups become `ProxyGroup`, and rules are grouped by
/// their policy into `CompiledRuleSet`s because the current matcher assigns one
/// policy per rule set. When the ordered matcher lands, `compileRules` is the
/// only function that has to change.
nonisolated enum ConfigurationCompiler {

    static func compile(
        _ configuration: ParsedConfiguration,
        capabilities: ConfigurationValidator.Capabilities = .current,
        parsingDiagnostics: [ConfigurationDiagnostic] = []
    ) -> CompiledConfiguration {
        var diagnostics = parsingDiagnostics + ConfigurationValidator.validate(configuration, capabilities: capabilities)

        let proxies = compileProxies(configuration, diagnostics: &diagnostics)
        let proxyIds = Dictionary(proxies.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })

        let groups = compileProxyGroups(
            configuration,
            proxyIds: proxyIds,
            diagnostics: &diagnostics
        )
        let policies = policyTargets(
            configuration,
            proxyIds: proxyIds,
            groups: groups,
            diagnostics: &diagnostics
        )
        let ruleSets = compileRules(
            configuration,
            policies: policies,
            capabilities: capabilities,
            diagnostics: &diagnostics
        )
        var ordered = compileOrderedRules(configuration, policies: policies, diagnostics: &diagnostics)
        if let country = configuration.general["bypass-country"], !country.isEmpty {
            let extra = CountryBypassCatalog.shared.rules(for: country.uppercased())
            if extra.isEmpty {
                diagnostics.append(.init(severity: .error, code: .missingValue, section: "General",
                    message: "bypass-country requires an installed country preset database; use explicit [GeoIP] data instead."))
            }
            var line = (ordered.rules.map(\.line).max() ?? 0) + 1
            for rule in extra {
                let matcher: OrderedRoutingRule.Matcher?
                switch rule.type {
                case .domainSuffix: matcher = .domainSuffix(rule.value)
                case .domainKeyword: matcher = .domainKeyword(rule.value)
                case .ipCIDR, .ipCIDR6: matcher = CIDRPrefix.parse(rule.value).map { .ipCIDR($0) }
                }
                if let matcher { ordered.rules.append(.init(line: line, matcher: matcher, action: .direct, noResolve: true)); line += 1 }
            }
        }
        let geo = compileGeo(configuration, rules: ordered.rules, diagnostics: &diagnostics)

        let textMITM = TextMITMCompiler.compile(configuration, diagnostics: &diagnostics)
        return CompiledConfiguration(
            proxies: proxies,
            proxyGroups: groups,
            ruleSets: ruleSets,
            orderedRules: ordered.rules,
            finalAction: ordered.finalAction,
            hosts: compileHosts(configuration, diagnostics: &diagnostics),
            geo: geo,
            textMITM: textMITM,
            settings: compileSettings(configuration),
            diagnostics: diagnostics.sorted
        )
    }
}

// MARK: - Proxies

nonisolated extension ConfigurationCompiler {

    static func compileProxies(
        _ configuration: ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> [ProxyConfiguration] {
        configuration.proxies.compactMap { proxy in
            compileProxy(proxy, diagnostics: &diagnostics)
        }
    }

    static func compileProxy(
        _ proxy: ParsedProxy,
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> ProxyConfiguration? {
        switch proxy.form {
        case .link(let link):
            do {
                let parsed = try ProxyConfiguration.parse(url: link)
                return renamed(parsed, to: proxy.name)
            } catch {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .invalidValue,
                        line: proxy.line,
                        section: ConfigurationDocument.SectionKind.proxy.displayName,
                        message: "Proxy '\(proxy.name)' link could not be parsed: \(error)."
                    )
                )
                return nil
            }

        case .fields(let type, let server, let port, let parameters):
            reportDroppedOptions(proxy, parameters: parameters, diagnostics: &diagnostics)
            guard let yaml = clashYAML(
                name: proxy.name,
                type: type,
                server: server,
                port: port,
                parameters: parameters
            ) else {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .unknownProxyType,
                        line: proxy.line,
                        section: ConfigurationDocument.SectionKind.proxy.displayName,
                        message: "Proxy '\(proxy.name)' uses type '\(type)', which has no Clash equivalent."
                    )
                )
                return nil
            }

            do {
                let result = try ClashProxyParser.parse(yaml: yaml)
                guard let parsed = result.configurations.first else {
                    diagnostics.append(
                        ConfigurationDiagnostic(
                            severity: .error,
                            code: .invalidValue,
                            line: proxy.line,
                            section: ConfigurationDocument.SectionKind.proxy.displayName,
                            message: "Proxy '\(proxy.name)' is missing fields required by '\(type)'."
                        )
                    )
                    return nil
                }
                return renamed(parsed, to: proxy.name)
            } catch {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .invalidValue,
                        line: proxy.line,
                        section: ConfigurationDocument.SectionKind.proxy.displayName,
                        message: "Proxy '\(proxy.name)' could not be converted: \(error)."
                    )
                )
                return nil
            }
        }
    }

    /// Options the NaiveFlow field form accepts but this build cannot express are
    /// reported instead of vanishing: dropping `skip-cert-verify` or `udp-relay`
    /// silently would change behavior without saying so.
    static func reportDroppedOptions(
        _ proxy: ParsedProxy,
        parameters: OrderedParameters,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for (key, _) in parameters.pairs where clashParameter(key: key, value: "") == nil {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .notApplied,
                    line: proxy.line,
                    section: ConfigurationDocument.SectionKind.proxy.displayName,
                    message: "Proxy '\(proxy.name)' option '\(key)' cannot be expressed by this build and was dropped."
                )
            )
        }
    }

    /// Rebuilds a configuration under the name written in the document, since
    /// `name` is a `let` on `ProxyConfiguration`.
    static func renamed(_ proxy: ProxyConfiguration, to name: String) -> ProxyConfiguration {
        ProxyConfiguration(
            id: proxy.id,
            name: name,
            serverAddress: proxy.serverAddress,
            serverPort: proxy.serverPort,
            resolvedIP: proxy.resolvedIP,
            subscriptionId: nil,
            outbound: proxy.outbound,
            chain: nil,
            updatedAt: .now
        )
    }
}


// MARK: - Clash bridge

nonisolated extension ConfigurationCompiler {

    /// Builds a one-entry Clash YAML document from a field-form proxy line so
    /// `ClashProxyParser` can do the protocol work. Reusing that parser keeps
    /// one implementation of every outbound configuration in the app.
    static func clashYAML(
        name: String,
        type: String,
        server: String?,
        port: UInt16?,
        parameters: OrderedParameters
    ) -> String? {
        guard let clashType = clashType(for: type) else { return nil }

        var fields: [String] = []
        fields.append("name: \(yamlScalar(name))")
        fields.append("type: \(yamlScalar(clashType))")
        if let server, !server.isEmpty {
            fields.append("server: \(yamlScalar(server))")
        }
        if let port, port > 0 {
            fields.append("port: \(port)")
        }

        var reality: [String] = []
        for (key, value) in parameters.pairs {
            switch key {
            case "public-key", "short-id":
                reality.append("\(key): \(yamlScalar(value))")
            case "alpn":
                let items = value
                    .split(separator: ",")
                    .map { yamlScalar($0.trimmingCharacters(in: .whitespaces)) }
                fields.append("alpn: [\(items.joined(separator: ", "))]")
            default:
                guard let pair = clashParameter(key: key, value: value) else { continue }
                fields.append("\(pair.key): \(pair.value)")
            }
        }
        if !reality.isEmpty {
            fields.append("reality-opts: {\(reality.joined(separator: ", "))}")
        }

        return "proxies:\n  - {\(fields.joined(separator: ", "))}"
    }

    static func clashType(for type: String) -> String? {
        switch type {
        case "vless", "trojan", "anytls", "sudoku", "socks5", "direct":
            return type
        case "hysteria", "hysteria2":
            return "hysteria2"
        case "ss", "shadowsocks":
            return "ss"
        case "http", "rfc":
            return "http"
        default:
            return nil
        }
    }

    /// Translates NaiveFlow option names to the Clash keys `ClashProxyParser`
    /// reads. Returns `nil` for options this build cannot express.
    static func clashParameter(key: String, value: String) -> (key: String, value: String)? {
        switch key {
        case "user":
            return ("username", yamlScalar(value))
        case "id":
            return ("uuid", yamlScalar(value))
        case "sni", "peer":
            return ("servername", yamlScalar(value))
        case "tls", "over-tls":
            return ("tls", yamlBool(value))
        case "ws":
            return ("network", yamlScalar(value.lowercased() == "true" ? "ws" : value))
        case "ws-path":
            return ("path", yamlScalar(value))
        case "ws-headers":
            return ("host", yamlScalar(value))
        case "cipher", "method":
            return ("cipher", yamlScalar(value))
        case "aead":
            return ("aead-method", yamlScalar(value))
        case "uuid", "password", "username", "flow", "encryption", "obfs",
             "obfs-password", "network", "path", "host", "servername",
             "client-fingerprint", "up", "down", "max-early-data",
             "early-data-header-name", "padding-min", "padding-max",
             "obfs-min-packet-size", "obfs-max-packet-size",
             "enable-pure-downlink", "idle-session-check-interval",
             "idle-session-timeout", "min-idle-session", "path-root":
            return (key, yamlScalar(value))
        case "skip-cert-verify", "udp", "udp-relay", "tfo", "mptcp", "ecn",
             "test-url", "ip-version", "underlying-proxy", "block-quic",
             "no-error-alert", "fast-open":
            return nil
        default:
            let normalized = key.replacingOccurrences(of: "_", with: "-")
            return (normalized, yamlScalar(value))
        }
    }

    static func yamlScalar(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    static func yamlBool(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on":
            return "true"
        case "0", "false", "no", "off":
            return "false"
        default:
            return yamlScalar(value)
        }
    }
}


// MARK: - Proxy groups

nonisolated extension ConfigurationCompiler {

    static func compileProxyGroups(
        _ configuration: ParsedConfiguration,
        proxyIds: [String: UUID],
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> [ProxyGroup] {
        var expanded: [String: [UUID]] = [:]
        for group in configuration.proxyGroups {
            var visited = Set<String>()
            expanded[group.name] = expandedMembers(
                of: group.name,
                configuration: configuration,
                proxyIds: proxyIds,
                visited: &visited
            )
            if expanded[group.name]?.isEmpty ?? true {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .warning,
                        code: .unresolvedPolicy,
                        line: group.line,
                        section: ConfigurationDocument.SectionKind.proxyGroup.displayName,
                        message: "Proxy group '\(group.name)' has no compiled members."
                    )
                )
            }
        }

        return configuration.proxyGroups.map { group in
            ProxyGroup(name: group.name, kind: .servers, memberIds: expanded[group.name] ?? [])
        }
    }

    /// Flattens nested group references into proxy ids, guarding against cycles
    /// that validation has already reported.
    static func expandedMembers(
        of name: String,
        configuration: ParsedConfiguration,
        proxyIds: [String: UUID],
        visited: inout Set<String>
    ) -> [UUID] {
        guard visited.insert(name).inserted else { return [] }

        guard let group = configuration.proxyGroup(named: name) else {
            if let id = proxyIds[name] { return [id] }
            return []
        }

        var ids: [UUID] = []
        for member in group.members {
            if let id = proxyIds[member] {
                if !ids.contains(id) { ids.append(id) }
                continue
            }
            for id in expandedMembers(
                of: member,
                configuration: configuration,
                proxyIds: proxyIds,
                visited: &visited
            ) where !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Resolves every policy name to a route target. Groups resolve to their
    /// first dialable member because this build has one selected proxy per
    /// route; `select` semantics are otherwise identical to that.
    static func policyTargets(
        _ configuration: ParsedConfiguration,
        proxyIds: [String: UUID],
        groups: [ProxyGroup],
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> [String: RouteTarget] {
        var targets: [String: RouteTarget] = [:]
        for proxy in configuration.proxies {
            if let id = proxyIds[proxy.name] {
                targets[proxy.name] = .proxy(id)
            }
        }
        func resolve(_ name: String, visiting: Set<String>) -> RouteTarget? {
            switch ParsedRule.Policy(token: name) {
            case .direct: return .direct
            case .reject: return .reject
            case .defaultProxy: return .defaultProxy
            case .rejectTinyGIF: return nil
            case .named: break
            }
            if let id = proxyIds[name] { return .proxy(id) }
            guard !visiting.contains(name), let group = configuration.proxyGroup(named: name),
                  let selected = group.parameters["selected"] ?? group.members.first else { return nil }
            return resolve(selected, visiting: visiting.union([name]))
        }
        for group in groups {
            if let target = resolve(group.name, visiting: []) { targets[group.name] = target }
            else {
                diagnostics.append(.init(severity: .error, code: .unresolvedPolicy, section: "Proxy Group",
                    message: "Group '\(group.name)' has no resolvable selected member."))
            }
        }

        return targets
    }
}


// MARK: - Rules

nonisolated extension ConfigurationCompiler {

    /// Emits one `CompiledRuleSet` per policy, in first-appearance order. This
    /// preserves the document's intent as far as the tiered matcher allows: all
    /// rules that share a policy are evaluated together.
    static func compileRules(
        _ configuration: ParsedConfiguration,
        policies: [String: RouteTarget],
        capabilities: ConfigurationValidator.Capabilities,
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> [CompiledRuleSet] {
        var order: [String] = []
        var grouped: [String: (target: RouteTarget, rules: [RoutingRule])] = [:]

        for rule in configuration.rules {
            guard !rule.isFinal else { continue }
            guard let target = routeTarget(for: rule.policy, policies: policies) else { continue }

            guard let type = routingRuleType(for: rule.kind) else {
                if capabilities.preservesRuleOrder { continue }
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .info,
                        code: .unsupportedRuleType,
                        line: rule.line,
                        section: ConfigurationDocument.SectionKind.rule.displayName,
                        message: "Rule '\(rule.kind.token)' was not compiled; the engine cannot evaluate it yet."
                    )
                )
                continue
            }
            guard let value = rule.value, !value.isEmpty else { continue }

            let token = rule.policy.token
            if grouped[token] == nil {
                order.append(token)
                grouped[token] = (target, [])
            }
            grouped[token]?.rules.append(RoutingRule(type: type, value: routingValue(value, for: type)))
        }

        if !capabilities.supportsPerRulePolicy, order.count > 1 {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .info,
                    code: .unsupportedRuleType,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "Compiled \(order.count) rule sets because the engine assigns one policy per rule set."
                )
            )
        }

        return order.compactMap { token in
            guard let entry = grouped[token] else { return nil }
            return CompiledRuleSet(
                name: "Config \u{00B7} \(token)",
                policy: entry.target,
                rules: entry.rules
            )
        }
    }

    static func routeTarget(for policy: ParsedRule.Policy, policies: [String: RouteTarget]) -> RouteTarget? {
        switch policy {
        case .direct:
            return .direct
        case .reject, .rejectTinyGIF:
            return .reject
        case .defaultProxy:
            return .defaultProxy
        case .named(let name):
            return policies[name]
        }
    }

    static func routingRuleType(for kind: ParsedRule.Kind) -> RoutingRuleType? {
        switch kind {
        case .domainSuffix: return .domainSuffix
        case .domainKeyword: return .domainKeyword
        case .ipCIDR: return .ipCIDR
        case .ipCIDR6: return .ipCIDR6
        default: return nil
        }
    }

    /// Fills in the implicit prefix length for bare addresses, matching
    /// `RoutingRuleType.normalized` without requiring main-actor isolation.
    static func routingValue(_ value: String, for type: RoutingRuleType) -> String {
        switch type {
        case .ipCIDR:
            return value.contains("/") ? value : value + "/32"
        case .ipCIDR6:
            return value.contains("/") ? value : value + "/128"
        case .domainSuffix, .domainKeyword:
            return value
        }
    }
}

// MARK: - Hosts

nonisolated extension ConfigurationCompiler {

    /// The DNS override table matches exact hosts only, so wildcard entries are
    /// reported and skipped instead of being silently stored.
    static func compileHosts(
        _ configuration: ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> [HostMapping] {
        var mappings: [HostMapping] = []
        for entry in configuration.hosts {
            guard let host = DNSName.normalizedHost(entry.host) else {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .invalidValue,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.host.displayName,
                        message: "Host '\(entry.host)' is a wildcard or invalid; the DNS override table only matches exact hosts."
                    )
                )
                continue
            }

            guard entry.mode == .replace else {
                diagnostics.append(.init(severity: .error, code: .notApplied, line: entry.line, section: "Host",
                    message: "Host entries use exact names and IPv4/IPv6 values; append/insert markers are not native syntax."))
                continue
            }
            let address = entry.address
            guard let canonical = HostMapping.canonicalAddress(address) else {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .invalidValue,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.host.displayName,
                        message: "Host '\(entry.host)' maps to invalid address '\(entry.address)'."
                    )
                )
                continue
            }

            mappings.append(HostMapping(host: host, address: canonical))
        }
        return mappings
    }
}


// MARK: - Settings

nonisolated extension ConfigurationCompiler {

    /// Every `[General]` key the catalog knows, parsed through the kind the
    /// catalog declares for it.
    ///
    /// A key the document does not mention stays absent, so installing the
    /// document leaves the app's current value alone. Keys with `applies: false`
    /// are compiled too: the diagnostics report them, and recording the value
    /// keeps the reload summary honest about what changed in the text.
    static func compileSettings(_ configuration: ParsedConfiguration) -> CompiledSettings {
        var settings = CompiledSettings()

        for key in ConfigurationSettings.catalog {
            guard let raw = configuration.general[key.name] else { continue }
            if let value = key.parse(raw) {
                settings.values[key.name] = value
            }
        }

        // `[MITM] enable` wins over `[General] mitm` when both appear: the
        // dedicated section is the more specific statement.
        if let enable = configuration.mitm.bool("enable") {
            settings.values["mitm"] = .flag(enable)
        }

        return settings
    }
}


// MARK: - Ordered rules

nonisolated extension ConfigurationCompiler {

    /// Builds the ordered rule list used by `OrderedRouteMatcher`.
    ///
    /// Unlike `compileRules`, this keeps every rule — including types the
    /// current binary payload cannot carry — because the matcher and the
    /// editor's preview can evaluate them as soon as the geo databases and the
    /// ordered payload exist.
    static func compileOrderedRules(
        _ configuration: ParsedConfiguration,
        policies: [String: RouteTarget],
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> (rules: [OrderedRoutingRule], finalAction: RouteMatchAction) {
        var rules: [OrderedRoutingRule] = []
        rules.reserveCapacity(configuration.rules.count)

        for rule in configuration.rules where !rule.isFinal {
            guard let action = routeMatchAction(for: rule.policy, policies: policies) else { continue }
            guard let matcher = matcher(for: rule) else {
                diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .invalidValue,
                    line: rule.line, section: "Rule", message: "The rule expression cannot be compiled."))
                continue
            }
            do { try validateExpression(matcher)
            } catch {
                diagnostics.append(.init(severity: .error, code: .invalidValue, line: rule.line,
                    section: "Rule", message: "Invalid regular expression or protocol value."))
            }
            rules.append(
                OrderedRoutingRule(
                    line: rule.line,
                    matcher: matcher,
                    action: action,
                    noResolve: rule.hasOption(.noResolve)
                )
            )
        }

        let finalAction = configuration.finalRule
            .flatMap { routeMatchAction(for: $0.policy, policies: policies) } ?? .defaultProxy

        return (rules.sorted { $0.line < $1.line }, finalAction)
    }

    static func routeMatchAction(
        for policy: ParsedRule.Policy,
        policies: [String: RouteTarget]
    ) -> RouteMatchAction? {
        switch policy {
        case .direct:
            return .direct
        case .reject, .rejectTinyGIF:
            return .reject
        case .defaultProxy:
            return .defaultProxy
        case .named(let name):
            guard let target = policies[name] else { return nil }
            switch target {
            case .direct: return .direct
            case .reject: return .reject
            case .proxy(let id): return .proxy(id)
            case .default, .defaultProxy: return .defaultProxy
            }
        }
    }

    private static func validateExpression(_ matcher: OrderedRoutingRule.Matcher) throws {
        switch matcher {
        case .allOf(let children), .anyOf(let children):
            for child in children { try validateExpression(child) }
        case .negated(let child): try validateExpression(child)
        case .domainRegex(let pattern): _ = try NSRegularExpression(pattern: pattern)
        case .protocolName(let name):
            guard ["TCP", "UDP"].contains(name) else { throw RuntimeConfigurationFailure.invalidBundle }
        default: break
        }
    }

    static func matcher(for rule: ParsedRule, depth: Int = 0) -> OrderedRoutingRule.Matcher? {
        guard depth <= 16, let value = rule.value, !value.isEmpty else { return nil }

        switch rule.kind {
        case .domain:
            return .domain(value)
        case .domainSuffix:
            return .domainSuffix(value)
        case .domainKeyword:
            return .domainKeyword(value)
        case .domainWildcard:
            return .domainWildcard(value)
        case .domainRegex:
            return .domainRegex(value)
        case .urlRegex:
            return .urlRegex(value)
        case .ipCIDR, .ipCIDR6:
            return CIDRPrefix.parse(value).map { .ipCIDR($0) }
        case .sourceIP:
            return CIDRPrefix.parse(value).map { .sourceIP($0) }
        case .ipASN:
            return Int(value).map { .ipASN($0) }
        case .geoASN:
            return Int(value).map { .geoASN($0) }
        case .geoIP:
            return .geoIP(value.uppercased())
        case .geoSite:
            return .geoSite(value.lowercased())
        case .ruleSet:
            return .ruleSet(value)
        case .processName:
            return .processName(value)
        case .sourcePort:
            return UInt16(value).map { .sourcePort($0) }
        case .destinationPort:
            return UInt16(value).map { .destinationPort($0) }
        case .protocolType:
            return .protocolName(value.uppercased())
        case .userAgent:
            return .userAgent(value)
        case .final:
            return nil
        case .logicalAnd, .logicalOr, .logicalNot:
            var expression = value.trimmingCharacters(in: .whitespaces)
            if expression.hasPrefix("("), expression.hasSuffix(")") {
                expression = String(expression.dropFirst().dropLast())
            }
            let children = ConfigurationDocument.splitExpression(expression)
            guard !children.isEmpty, children.count <= 64 else { return nil }
            var matchers: [OrderedRoutingRule.Matcher] = []
            for child in children {
                var content = child.trimmingCharacters(in: .whitespaces)
                if content.hasPrefix("("), content.hasSuffix(")") { content = String(content.dropFirst().dropLast()) }
                let parts = ConfigurationDocument.splitExpression(content)
                guard parts.count == 2 else { return nil }
                let kind = ParsedRule.Kind(token: parts[0])
                guard ConfigurationValidator.Capabilities.current.ruleKinds.contains(kind) else { return nil }
                let nested = ParsedRule(line: rule.line, kind: kind, value: parts[1], policy: .direct, options: [], raw: child)
                guard let matcher = matcher(for: nested, depth: depth + 1) else { return nil }
                matchers.append(matcher)
            }
            switch rule.kind {
            case .logicalAnd: return .allOf(matchers)
            case .logicalOr: return .anyOf(matchers)
            default: return matchers.count == 1 ? .negated(matchers[0]) : nil
            }
        case .unsupported:
            return nil
        }
    }
}


nonisolated extension ConfigurationCompiler {
    static func compileGeo(_ parsed: ParsedConfiguration, rules: [OrderedRoutingRule], diagnostics: inout [ConfigurationDiagnostic]) -> NativeGeoDatabase {
        var result = NativeGeoDatabase()
        for (key, raw) in parsed.geoIP.pairs {
            let token = key.uppercased()
            let asn = token.hasPrefix("AS") ? Int(token.dropFirst(2)) : nil
            guard asn != nil || (token.count == 2 && token.allSatisfy(\.isLetter)) else {
                diagnostics.append(.init(severity: .error, code: .invalidValue, section: "GeoIP", message: "GeoIP key must be a country code or AS number."))
                continue
            }
            for prefix in ConfigurationDocument.splitList(raw) {
                guard let network = CIDRPrefix.parse(prefix) else {
                    diagnostics.append(.init(severity: .error, code: .invalidValue, section: "GeoIP", message: "Invalid network prefix."))
                    continue
                }
                result.networks.append(.init(prefix: network, country: asn == nil ? token : nil, asn: asn))
            }
        }
        for (tag, raw) in parsed.geoSite.pairs {
            var suffixes: [String] = []
            for suffix in ConfigurationDocument.splitList(raw) {
                guard let host = DNSName.normalizedHost(suffix), !host.contains("*") else {
                    diagnostics.append(.init(severity: .error, code: .invalidValue, section: "GeoSite", message: "GeoSite lists plain domain suffixes."))
                    continue
                }
                suffixes.append(host)
            }
            result.sites[tag] = suffixes
        }
        func check(_ matcher: OrderedRoutingRule.Matcher) {
            let exists: Bool
            switch matcher {
            case .geoSite(let tag): exists = result.contains(tag: tag)
            case .geoIP(let country): exists = result.networks.contains { $0.country == country }
            case .geoASN(let asn), .ipASN(let asn): exists = result.networks.contains { $0.asn == asn }
            case .allOf(let children), .anyOf(let children): children.forEach(check); return
            case .negated(let child): check(child); return
            default: return
            }
            if !exists { diagnostics.append(.init(severity: .error, code: .missingValue, section: "Rule", message: "Geo rule references data absent from [GeoIP] or [GeoSite].")) }
        }
        rules.forEach { check($0.matcher) }
        return result
    }
}

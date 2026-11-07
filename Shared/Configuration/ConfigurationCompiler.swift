//
//  ConfigurationCompiler.swift
//  NaiveFlow
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
    /// Helper nodes whose ids appear in group members (for example a built-in
    /// `DIRECT` used inside an automatic group) but which are not user proxies.
    /// Kept separate from `proxies` so counts, ordering and previews are
    /// unaffected, yet merged into the runtime bundle's dialable nodes.
    var syntheticProxies: [ProxyConfiguration] = []
    let proxyGroups: [ProxyGroup]
    /// Text-configured groups with their automatic-selection strategy intact
    /// (`url-test` / `fallback` / `load-balance`), the engine's group-policy
    /// input. Distinct from `proxyGroups`, which only models hand-built
    /// `servers` / `chains` containers for the app UI.
    let policyGroups: [RuntimeProxyGroup]
    let ruleSets: [CompiledRuleSet]
    /// Rules in document order, including kinds the current binary payload
    /// cannot carry yet. Used for previews and by the ordered matcher.
    let orderedRules: [OrderedRoutingRule]
    /// Action taken when no rule matches (`FINAL`, defaulting to `PROXY`).
    let finalAction: RouteMatchAction
    let hosts: [HostMapping]
    let chains: [ProxyChain]
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
/// Proxies become `ProxyConfiguration`, groups become `ProxyGroup`, and native
/// rules retain document order. Resolved provider entries are expanded in place;
/// grouped `CompiledRuleSet`s are retained for inventory reports.
nonisolated enum ConfigurationCompiler {

    static func compile(
        _ sourceConfiguration: ParsedConfiguration,
        capabilities: ConfigurationValidator.Capabilities = .current,
        parsingDiagnostics: [ConfigurationDiagnostic] = [],
        ruleSetContents: [String: String] = [:],
        geoResources: NativeGeoDatabase? = nil
    ) -> CompiledConfiguration {
        var diagnostics = parsingDiagnostics
        let configuration = NativeRuleSet.expand(sourceConfiguration, contents: ruleSetContents, diagnostics: &diagnostics)
        diagnostics += ConfigurationValidator.validate(configuration, capabilities: capabilities)

        let proxies = compileProxies(configuration, diagnostics: &diagnostics)
        let proxyIds = Dictionary(proxies.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })

        // A built-in `DIRECT` used as a group member is neither a proxy nor a
        // group, so `expandedMembers` would silently drop it. Synthesize one
        // shared, probeable direct node so DIRECT in a group behaves like a
        // declared `Name = direct` node instead of vanishing. It is carried in
        // `syntheticProxies` (not `proxies`) so user-facing counts and ordering
        // are unchanged.
        let builtInDirectNode = referencesBuiltInDirect(configuration) && proxyIds["DIRECT"] == nil
            ? ProxyConfiguration(name: "DIRECT", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration()))
            : nil
        let directNodeID = builtInDirectNode?.id

        let groups = compileProxyGroups(
            configuration,
            proxyIds: proxyIds,
            directNodeID: directNodeID,
            diagnostics: &diagnostics
        )
        let policyGroups = compilePolicyGroups(configuration, proxyIds: proxyIds, directNodeID: directNodeID)
        let chains = compileChains(configuration, proxyIds: proxyIds, diagnostics: &diagnostics)
        let chainIds = Dictionary(chains.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let policies = policyTargets(
            configuration,
            proxyIds: proxyIds,
            chainIds: chainIds,
            policyGroups: policyGroups
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
                case .ipCIDR: matcher = CIDRPrefix.parse(rule.value).map { .ipCIDR($0) }
                }
                if let matcher { ordered.rules.append(.init(line: line, matcher: matcher, action: .direct, noResolve: true)); line += 1 }
            }
        }
        let geo = compileGeo(configuration, rules: ordered.rules, resources: geoResources, diagnostics: &diagnostics)

        let textMITM = TextMITMCompiler.compile(configuration, diagnostics: &diagnostics)
        return CompiledConfiguration(
            proxies: proxies,
            syntheticProxies: builtInDirectNode.map { [$0] } ?? [],
            proxyGroups: groups,
            policyGroups: policyGroups,
            ruleSets: ruleSets,
            orderedRules: ordered.rules,
            finalAction: ordered.finalAction,
            hosts: compileHosts(configuration, diagnostics: &diagnostics),
            chains: chains,
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
            guard let node = compileProxy(proxy, diagnostics: &diagnostics) else { return nil }
            if !node.isDirect, !IPv4Only.supportsHost(node.serverAddress) {
                diagnostics.append(.init(severity: .error, code: .invalidValue, line: proxy.line,
                    section: "Proxy", message: "This build accepts IPv4 node addresses or host names only."))
                return nil
            }
            return node
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
        directNodeID: UUID?,
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> [ProxyGroup] {
        var expanded: [String: [UUID]] = [:]
        for group in configuration.proxyGroups {
            var visited = Set<String>()
            expanded[group.name] = expandedMembers(
                of: group.name,
                configuration: configuration,
                proxyIds: proxyIds,
                directNodeID: directNodeID,
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

    /// Builds the engine's group-policy list, preserving `url-test` / `fallback`
    /// / `load-balance` strategies instead of flattening every group to a plain
    /// `servers` container. Members resolve to dialable node ids, and `selected`
    /// resolves to a concrete member id. A nested group member is refused by the
    /// validator (the flat member list cannot carry the child's selection), so
    /// an accepted automatic group always lists leaf nodes.
    static func compilePolicyGroups(
        _ configuration: ParsedConfiguration,
        proxyIds: [String: UUID],
        directNodeID: UUID?
    ) -> [RuntimeProxyGroup] {
        configuration.proxyGroups.compactMap { group in
            guard let parsedKind = group.kind else { return nil }
            let kind: RuntimeProxyGroup.Kind
            switch parsedKind {
            // `select` keeps its recursive "selected" semantics (which may name
            // a built-in policy like DIRECT), so it is not modeled as a runtime
            // policy group.
            case .select: return nil
            case .urlTest: kind = .urlTest
            case .fallback: kind = .fallback
            case .loadBalance: kind = .loadBalance
            case .smart, .random: return nil   // reported as errors by the validator
            }

            var visited = Set<String>()
            let memberIDs = expandedMembers(
                of: group.name,
                configuration: configuration,
                proxyIds: proxyIds,
                directNodeID: directNodeID,
                visited: &visited
            )
            guard !memberIDs.isEmpty else { return nil }

            var selectedID: UUID?
            if let selectedName = group.parameters["selected"] {
                selectedID = resolveMemberID(
                    named: selectedName,
                    configuration: configuration,
                    proxyIds: proxyIds,
                    directNodeID: directNodeID
                )
            }

            var interval: TimeInterval = 600
            if let text = group.parameters["interval"], let value = TimeInterval(text), value > 0 {
                interval = value
            }
            let url = group.parameters["url"].flatMap(Self.normalizeProbeURL)

            return RuntimeProxyGroup(
                name: group.name,
                kind: kind,
                memberIDs: memberIDs,
                selectedID: selectedID,
                interval: interval,
                url: url
            )
        }
    }

    /// Resolves a member name (a node or a nested group) to a dialable node id.
    private static func resolveMemberID(
        named name: String,
        configuration: ParsedConfiguration,
        proxyIds: [String: UUID],
        directNodeID: UUID?,
        visiting: Set<String> = []
    ) -> UUID? {
        if let id = proxyIds[name] { return id }
        if ConfigurationValidator.builtInPolicyName(name) == "DIRECT" { return directNodeID }
        guard !visiting.contains(name),
              let group = configuration.proxyGroup(named: name),
              let selected = group.parameters["selected"] ?? group.members.first else { return nil }
        return resolveMemberID(
            named: selected,
            configuration: configuration,
            proxyIds: proxyIds,
            directNodeID: directNodeID,
            visiting: visiting.union([name])
        )
    }

    /// True when any proxy group lists the built-in `DIRECT` policy as a member,
    /// so a shared probeable direct node must be synthesized instead of the
    /// token being dropped during member expansion.
    private static func referencesBuiltInDirect(_ configuration: ParsedConfiguration) -> Bool {
        configuration.proxyGroups.contains { group in
            group.members.contains { ConfigurationValidator.builtInPolicyName($0) == "DIRECT" }
        }
    }

    /// Accepts an http/https probe URL and rejects anything the prober cannot
    /// dial (missing host, non-http scheme).
    private static func normalizeProbeURL(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return nil }
        return raw
    }

    /// Flattens nested group references into proxy ids, guarding against cycles
    /// that validation has already reported. This still backs the UI-facing
    /// `servers` container, but an automatic group that reaches a nested group is
    /// rejected by the validator, so this expansion only ever sees leaf members
    /// for an activatable automatic group.
    static func expandedMembers(
        of name: String,
        configuration: ParsedConfiguration,
        proxyIds: [String: UUID],
        directNodeID: UUID?,
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
            if ConfigurationValidator.builtInPolicyName(member) == "DIRECT", let directNodeID {
                if !ids.contains(directNodeID) { ids.append(directNodeID) }
                continue
            }
            for id in expandedMembers(
                of: member,
                configuration: configuration,
                proxyIds: proxyIds,
                directNodeID: directNodeID,
                visited: &visited
            ) where !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Resolves every policy name to a route target. A group resolves to its
    /// own stable id (not to a flattened first member); the engine applies the
    /// group's selection strategy — `select` / `url-test` / `fallback` /
    /// `load-balance` — at dial time.
    static func policyTargets(
        _ configuration: ParsedConfiguration,
        proxyIds: [String: UUID],
        chainIds: [String: UUID],
        policyGroups: [RuntimeProxyGroup]
    ) -> [String: RouteTarget] {
        var targets: [String: RouteTarget] = [:]
        for proxy in configuration.proxies {
            if let id = proxyIds[proxy.name] {
                targets[proxy.name] = .proxy(id)
            }
        }
        for chain in configuration.chains {
            if let id = chainIds[chain.name] {
                targets[chain.name] = .proxy(id)
            }
        }
        // Automatic groups (url-test / fallback / load-balance) resolve to their
        // own id; the engine applies the selection strategy at dial time. `select`
        // groups keep recursive "selected" semantics (which may name a built-in
        // policy or another group).
        let groupIds = Dictionary(policyGroups.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        func resolve(_ name: String, visiting: Set<String>) -> RouteTarget? {
            switch ParsedRule.Policy(token: name) {
            case .direct: return .direct
            case .reject: return .reject
            case .defaultProxy: return .defaultProxy
            case .rejectTinyGIF: return nil
            case .named: break
            }
            if let id = proxyIds[name] { return .proxy(id) }
            if let id = chainIds[name] { return .proxy(id) }
            if let id = groupIds[name] { return .proxy(id) }
            guard !visiting.contains(name), let group = configuration.proxyGroup(named: name),
                  let selected = group.parameters["selected"] ?? group.members.first else { return nil }
            return resolve(selected, visiting: visiting.union([name]))
        }
        for group in configuration.proxyGroups {
            if let target = resolve(group.name, visiting: []) { targets[group.name] = target }
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

    /// Maps a parsed policy to the ordered matcher's action. A named policy that
    /// cannot be resolved returns `nil` so the rule is dropped (the validator
    /// already reported it) instead of silently falling back to the default route.
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

    /// Builds the ordered rule list in document order plus the terminal `FINAL`
    /// action — the exact input the kernel's `OrderedRouteMatcher` consumes.
    ///
    /// Unlike `compileRules`, this keeps every rule at its original line position
    /// with its own action (no grouping by policy), which is what first-match-wins
    /// semantics require. The tiered `compileRules` output remains only for the
    /// preserved manual baseline.
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

        return (rules, finalAction)
    }

    static func compileHosts(
        _ configuration: ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> [HostMapping] {
        var mappings: [HostMapping] = []
        for entry in configuration.hosts {
            guard let host = Self.normalizeHostMappingPattern(entry.host) else {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .invalidValue,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.host.displayName,
                        message: "Host '\(entry.host)' is not a valid domain or wildcard."
                    )
                )
                continue
            }

            guard entry.mode == .replace else {
                diagnostics.append(.init(severity: .error, code: .notApplied, line: entry.line, section: "Host",
                    message: "Host entries use exact names and IPv4 values; append/insert markers are not native syntax."))
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

    /// Accepts exact domains and `*.suffix` wildcards; the wildcard marker is
    /// kept so `DNSHosts` can match subdomains.
    static func normalizeHostMappingPattern(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("*.") {
            guard let suffix = DNSName.normalizedHost(String(host.dropFirst(2))) else { return nil }
            return "*." + suffix
        }
        return DNSName.normalizedHost(host)
    }

    static func compileChains(
        _ configuration: ParsedConfiguration,
        proxyIds: [String: UUID],
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> [ProxyChain] {
        configuration.chains.compactMap { chain in
            var memberIds: [UUID] = []
            for member in chain.members {
                guard let id = proxyIds[member] else {
                    diagnostics.append(.init(severity: .error, code: .unresolvedPolicy, line: chain.line,
                        section: "Chain", message: "Chain '\(chain.name)' references unknown node '\(member)'."))
                    return nil
                }
                memberIds.append(id)
            }
            return ProxyChain(name: chain.name, proxyIds: memberIds)
        }
    }

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

    static func routingRuleType(for kind: ParsedRule.Kind) -> RoutingRuleType? {
        switch kind {
        case .domainSuffix: return .domainSuffix
        case .domainKeyword: return .domainKeyword
        case .ipCIDR: return .ipCIDR
        default: return nil
        }
    }

    /// Fills in the implicit prefix length for bare addresses, matching
    /// `RoutingRuleType.normalized` without requiring main-actor isolation.
    static func routingValue(_ value: String, for type: RoutingRuleType) -> String {
        switch type {
        case .ipCIDR:
            return value.contains("/") ? value : value + "/32"
        default:
            return value
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
        case .ipCIDR:
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
                guard kind != .ruleSet, ConfigurationValidator.Capabilities.current.ruleKinds.contains(kind) else { return nil }
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
    static func compileGeo(_ parsed: ParsedConfiguration, rules: [OrderedRoutingRule], resources: NativeGeoDatabase? = nil, diagnostics: inout [ConfigurationDiagnostic]) -> NativeGeoDatabase {
        var result = resources ?? NativeGeoDatabase()
        var pending = false
        do {
            let refs = try NativeGeoResources.references(parsed)
            pending = !refs.isEmpty && resources == nil
            if pending { diagnostics.append(.init(severity: .warning, code: .notApplied, section: "GeoIP/GeoSite", message: "External Geo data will be downloaded and validated when applying; preview is incomplete.")) }
        } catch { diagnostics.append(.init(severity: .error, code: .invalidValue, section: "GeoIP/GeoSite", message: error.localizedDescription)) }
        for (key, raw) in parsed.geoIP.pairs {
            if NativeGeoResources.isExternal(raw) { continue }
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
            if NativeGeoResources.isExternal(raw) { continue }
            var suffixes: [String] = []
            for suffix in ConfigurationDocument.splitList(raw) {
                guard let host = DNSName.normalizedHost(suffix), !host.contains("*") else {
                    diagnostics.append(.init(severity: .error, code: .invalidValue, section: "GeoSite", message: "GeoSite lists plain domain suffixes."))
                    continue
                }
                suffixes.append(host)
            }
            result.sites[tag.lowercased()] = suffixes
        }
        let countries = Set(result.networks.compactMap(\.country))
        let asns = Set(result.networks.compactMap(\.asn))
        func check(_ matcher: OrderedRoutingRule.Matcher) {
            let exists: Bool
            switch matcher {
            case .geoSite(let tag): exists = result.contains(tag: tag)
            case .geoIP(let country): exists = countries.contains(country)
            case .geoASN(let asn), .ipASN(let asn): exists = asns.contains(asn)
            case .allOf(let children), .anyOf(let children): children.forEach(check); return
            case .negated(let child): check(child); return
            default: return
            }
            if !exists && !pending { diagnostics.append(.init(severity: .error, code: .missingValue, section: "Rule", message: "Geo rule references data absent from [GeoIP] or [GeoSite].")) }
        }
        rules.forEach { check($0.matcher) }
        do { try result.validate(); result.prepareIndex() }
        catch { diagnostics.append(.init(severity: .error, code: .invalidValue, section: "GeoIP/GeoSite", message: error.localizedDescription)) }
        return result
    }
}

nonisolated extension ConfigurationCompiler {
    /// Provider conditions receive the same load-time regex/depth validation.
    static func validateExpression(_ matcher: OrderedRoutingRule.Matcher, depth: Int = 0) throws {
        guard depth <= 16 else { throw NativeGeoFailure("Rule expression nesting exceeds 16 levels.") }
        switch matcher {
        case .domainRegex(let pattern), .urlRegex(let pattern):
            _ = try NSRegularExpression(pattern: pattern)
        case .protocolName(let name):
            guard name == "TCP" || name == "UDP" else { throw NativeGeoFailure("Unsupported protocol.") }
        case .allOf(let children), .anyOf(let children):
            guard !children.isEmpty else { throw NativeGeoFailure("Logical rule has no conditions.") }
            for child in children { try validateExpression(child, depth: depth + 1) }
        case .negated(let child): try validateExpression(child, depth: depth + 1)
        default: break
        }
    }
}

//
//  NaiveFlowConfigurationParser.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Builds a `ParsedConfiguration` from a `ConfigurationDocument`.
///
/// The parser only understands structure: it splits each section into typed
/// values (proxies, groups, rules, hosts, scripts) and reports anything it
/// cannot interpret. Checking values against the routing engine's capabilities
/// is `ConfigurationValidator`'s job, and turning the result into stores is
/// `ConfigurationCompiler`'s job.
nonisolated enum NaiveFlowConfigurationParser {

    struct ParseResult: Sendable {
        let document: ConfigurationDocument
        let configuration: ParsedConfiguration
        let diagnostics: [ConfigurationDiagnostic]

        var hasErrors: Bool { diagnostics.hasErrors }
        var errors: [ConfigurationDiagnostic] { diagnostics.errors }
    }

    /// Proxy type tokens accepted in a `[Proxy]` field line. They match the
    /// token set `ClashProxyParser` understands, plus the app's own aliases.
    static let supportedProxyTypes: Set<String> = [
        "vless", "hysteria", "hysteria2", "sudoku", "trojan", "anytls",
        "ss", "shadowsocks", "socks5", "http", "rfc", "direct",
    ]

    static func parse(text: String) -> ParseResult {
        build(from: ConfigurationDocument.parse(text: text))
    }

    static func build(from document: ConfigurationDocument) -> ParseResult {
        var configuration = ParsedConfiguration()
        var diagnostics = document.diagnostics

        for section in document.sections {
            switch section.kind {
            case .geoIP, .geoSite:
                for entry in section.entries {
                    guard let key = entry.key else { continue }
                    if section.kind == .geoIP { configuration.geoIP.set(key, entry.value) }
                    else { configuration.geoSite.set(key, entry.value) }
                }
            case .general:
                for entry in section.entries {
                    guard let key = entry.key else { continue }
                    configuration.general.set(key, ConfigurationDocument.unquoted(entry.value))
                }
            case .proxy:
                parseProxies(section, into: &configuration, diagnostics: &diagnostics)
            case .proxyGroup:
                parseProxyGroups(section, into: &configuration, diagnostics: &diagnostics)
            case .rule:
                parseRules(section, into: &configuration, diagnostics: &diagnostics)
            case .host:
                parseHosts(section, into: &configuration, diagnostics: &diagnostics)
            case .mitmSet:
                for entry in section.entries {
                    if let key = entry.key { configuration.mitmSets.set(key, entry.value) }
                }
            case .mitm:
                for entry in section.entries {
                    guard let key = entry.key else { continue }
                    configuration.mitm.set(key, ConfigurationDocument.unquoted(entry.value))
                }
            case .script:
                parseScripts(section, into: &configuration, diagnostics: &diagnostics)
            case .urlRewrite, .headerRewrite, .bodyRewrite, .mapLocal, .rewrite:
                for entry in section.entries {
                    configuration.rewrites.append(
                        ParsedRewriteDirective(line: entry.line, section: section.rawName, text: entry.value)
                    )
                }
            case .panel, .ssidSetting, .misc:
                configuration.unsupportedSections.append(section.rawName)
            }
        }

        return ParseResult(
            document: document,
            configuration: configuration,
            diagnostics: diagnostics.sorted
        )
    }
}


// MARK: - Proxy

nonisolated extension NaiveFlowConfigurationParser {

    static func parseProxies(
        _ section: ConfigurationDocument.Section,
        into configuration: inout ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for entry in section.entries {
            guard let rawName = entry.key else { continue }
            let name = ConfigurationDocument.unquoted(rawName)
            guard !name.isEmpty else { continue }

            guard let proxy = parseProxy(
                name: name,
                value: entry.value,
                line: entry.line,
                raw: entry.raw,
                diagnostics: &diagnostics
            ) else { continue }

            if configuration.proxies.contains(where: { $0.name == name }) {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .duplicateName,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.proxy.displayName,
                        message: "Proxy '\(name)' is declared more than once."
                    )
                )
                continue
            }
            configuration.proxies.append(proxy)
        }
    }

    static func parseProxy(
        name: String,
        value: String,
        line: Int,
        raw: String,
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> ParsedProxy? {
        let tokens = ConfigurationDocument.splitList(value)
        guard let first = tokens.first else {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .missingValue,
                    line: line,
                    section: ConfigurationDocument.SectionKind.proxy.displayName,
                    message: "Proxy '\(name)' has no value."
                )
            )
            return nil
        }

        // `Name = vless://…` — a proxy link, parsed by ProxyConfiguration later.
        if first.contains("://") {
            return ParsedProxy(
                name: name,
                line: line,
                form: .link(value.trimmingCharacters(in: .whitespaces)),
                raw: raw
            )
        }

        let type = first.lowercased()
        var index = 1
        var server: String?
        var port: UInt16?
        var parameters = OrderedParameters()

        if index < tokens.count, !tokens[index].contains("=") {
            server = tokens[index]
            index += 1
        }
        if index < tokens.count, !tokens[index].contains("="),
           let parsedPort = UInt16(tokens[index]), parsedPort > 0 {
            port = parsedPort
            index += 1
        }

        var positional: [String] = []
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard let equals = ConfigurationDocument.firstUnquotedEquals(in: token) else {
                positional.append(token)
                continue
            }
            let key = String(token[token.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(token[token.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            parameters.set(key, ConfigurationDocument.unquoted(value))
        }

        applyPositionalValues(
            positional,
            type: type,
            to: &parameters,
            name: name,
            line: line,
            diagnostics: &diagnostics
        )

        if !supportedProxyTypes.contains(type) {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .warning,
                    code: .unknownProxyType,
                    line: line,
                    section: ConfigurationDocument.SectionKind.proxy.displayName,
                    message: "Proxy '\(name)' uses unsupported type '\(type)'; the entry is preserved but cannot be dialed."
                )
            )
        }
        if server == nil, type != "direct" {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .missingValue,
                    line: line,
                    section: ConfigurationDocument.SectionKind.proxy.displayName,
                    message: "Proxy '\(name)' has no server address."
                )
            )
        }

        return ParsedProxy(
            name: name,
            line: line,
            form: .fields(type: type, server: server, port: port, parameters: parameters),
            raw: raw
        )
    }
}

// MARK: - Positional proxy values

nonisolated extension NaiveFlowConfigurationParser {

    /// Maps unlabelled positional values (`ss, host, 443, aes-128-gcm, pass`) to
    /// the parameter names each protocol expects, so the compact field form and
    /// Clash's labelled form compile to the same configuration.
    static func applyPositionalValues(
        _ values: [String],
        type: String,
        to parameters: inout OrderedParameters,
        name: String,
        line: Int,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        guard !values.isEmpty else { return }

        let keys: [String]
        switch type {
        case "vless": keys = ["uuid"]
        case "hysteria", "hysteria2", "trojan", "anytls", "sudoku": keys = ["password"]
        case "ss", "shadowsocks": keys = ["cipher", "password"]
        case "socks5", "http", "rfc": keys = ["username", "password"]
        case "direct": keys = []
        default: keys = []
        }

        for (offset, value) in values.enumerated() {
            if offset < keys.count, parameters[keys[offset]] == nil {
                parameters.set(keys[offset], value)
                continue
            }
            parameters.set("arg\(offset)", value)
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .unknownDirective,
                    line: line,
                    section: ConfigurationDocument.SectionKind.proxy.displayName,
                    message: "Proxy '\(name)' has an extra value '\(value)' that no field consumes."
                )
            )
        }
    }
}

// MARK: - Proxy Group

nonisolated extension NaiveFlowConfigurationParser {

    static func parseProxyGroups(
        _ section: ConfigurationDocument.Section,
        into configuration: inout ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for entry in section.entries {
            guard let rawName = entry.key else { continue }
            let name = ConfigurationDocument.unquoted(rawName)
            guard !name.isEmpty else { continue }

            let tokens = ConfigurationDocument.splitList(entry.value)
            guard let kindToken = tokens.first else { continue }

            var members: [String] = []
            var parameters = OrderedParameters()
            for token in tokens.dropFirst() {
                if let equals = ConfigurationDocument.firstUnquotedEquals(in: token) {
                    let key = String(token[token.startIndex..<equals])
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    if !key.isEmpty {
                        let value = String(token[token.index(after: equals)...])
                            .trimmingCharacters(in: .whitespaces)
                        parameters.set(key, ConfigurationDocument.unquoted(value))
                        continue
                    }
                }
                members.append(ConfigurationDocument.unquoted(token))
            }

            let kind = ParsedProxyGroup.Kind(token: kindToken)
            if kind == nil {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .warning,
                        code: .invalidValue,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.proxyGroup.displayName,
                        message: "Proxy group '\(name)' has unknown type '\(kindToken)'."
                    )
                )
            }
            if members.isEmpty {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .warning,
                        code: .missingValue,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.proxyGroup.displayName,
                        message: "Proxy group '\(name)' lists no members."
                    )
                )
            }
            if configuration.proxyGroups.contains(where: { $0.name == name }) {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .duplicateName,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.proxyGroup.displayName,
                        message: "Proxy group '\(name)' is declared more than once."
                    )
                )
                continue
            }

            configuration.proxyGroups.append(
                ParsedProxyGroup(
                    name: name,
                    line: entry.line,
                    kindToken: kindToken,
                    kind: kind,
                    members: members,
                    parameters: parameters,
                    raw: entry.raw
                )
            )
        }
    }
}


// MARK: - Rule

nonisolated extension NaiveFlowConfigurationParser {

    static func parseRules(
        _ section: ConfigurationDocument.Section,
        into configuration: inout ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for entry in section.entries {
            guard let rule = parseRule(entry, diagnostics: &diagnostics) else { continue }
            configuration.rules.append(rule)
            if rule.isFinal {
                configuration.finalRule = rule
            }
        }
    }

    static func parseRule(
        _ entry: ConfigurationDocument.Entry,
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> ParsedRule? {
        let tokens = ConfigurationDocument.splitExpression(entry.value)
        guard let kindToken = tokens.first else {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .missingValue,
                    line: entry.line,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "Rule line is empty."
                )
            )
            return nil
        }

        let kind = ParsedRule.Kind(token: kindToken)
        if case .unsupported(let token) = kind {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .warning,
                    code: .unsupportedRuleType,
                    line: entry.line,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "Rule type '\(token)' is not supported by this build."
                )
            )
        }

        // Logical rules carry a nested expression such as
        // `AND,((DOMAIN,a),(DOMAIN,b)),PROXY`; keep it intact instead of
        // splitting it on the commas inside the expression.
        if kind == .logicalAnd || kind == .logicalOr || kind == .logicalNot {
            guard tokens.count >= 3 else {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .malformedRule,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.rule.displayName,
                        message: "Logical rule '\(kind.token)' needs an expression and a policy."
                    )
                )
                return nil
            }
            let expression = tokens[1..<(tokens.count - 1)].joined(separator: ",")
            return ParsedRule(
                line: entry.line,
                kind: kind,
                value: expression,
                policy: ParsedRule.Policy(token: tokens[tokens.count - 1]),
                options: [],
                raw: entry.value
            )
        }

        var index = 1
        var value: String?
        if kind.argumentCount > 0 {
            guard index < tokens.count else {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .missingValue,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.rule.displayName,
                        message: "Rule '\(kind.token)' has no value."
                    )
                )
                return nil
            }
            value = tokens[index]
            index += 1
        }

        guard index < tokens.count else {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .missingRulePolicy,
                    line: entry.line,
                    section: ConfigurationDocument.SectionKind.rule.displayName,
                    message: "Rule '\(kind.token)' has no policy."
                )
            )
            return nil
        }

        let policy = ParsedRule.Policy(token: tokens[index])
        index += 1

        var options: [ParsedRule.Option] = []
        while index < tokens.count {
            let option = ParsedRule.Option(token: tokens[index])
            if case .unknown(let token) = option {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .unsupportedRuleOption,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.rule.displayName,
                        message: "Rule option '\(token)' is not recognized and is ignored."
                    )
                )
            }
            options.append(option)
            index += 1
        }

        return ParsedRule(
            line: entry.line,
            kind: kind,
            value: value,
            policy: policy,
            options: options,
            raw: entry.value
        )
    }
}


// MARK: - Host

nonisolated extension NaiveFlowConfigurationParser {

    static func parseHosts(
        _ section: ConfigurationDocument.Section,
        into configuration: inout ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for entry in section.entries {
            guard let rawHost = entry.key else { continue }
            let host = ConfigurationDocument.unquoted(rawHost)
            guard !host.isEmpty else { continue }

            var value = ConfigurationDocument.unquoted(entry.value)
            let lowered = value.lowercased()
            var mode = ParsedHostEntry.Mode.replace
            if lowered.hasPrefix("%append%") {
                mode = .append
                value = String(value.dropFirst("%append%".count)).trimmingCharacters(in: .whitespaces)
            } else if lowered.hasPrefix("%insert%") {
                mode = .insert
                value = String(value.dropFirst("%insert%".count)).trimmingCharacters(in: .whitespaces)
            }

            let addresses = ConfigurationDocument.splitList(value)
            guard !addresses.isEmpty else {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .warning,
                        code: .missingValue,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.host.displayName,
                        message: "Host '\(host)' has no address."
                    )
                )
                continue
            }

            for address in addresses {
                configuration.hosts.append(
                    ParsedHostEntry(host: host, address: address, mode: mode, line: entry.line)
                )
            }
        }
    }
}

// MARK: - Script

nonisolated extension NaiveFlowConfigurationParser {

    static func parseScripts(
        _ section: ConfigurationDocument.Section,
        into configuration: inout ParsedConfiguration,
        diagnostics: inout [ConfigurationDiagnostic]
    ) {
        for entry in section.entries {
            guard let rawName = entry.key else { continue }
            let name = ConfigurationDocument.unquoted(rawName)
            guard !name.isEmpty else { continue }

            let tokens = ConfigurationDocument.splitList(entry.value)
            var parameters = OrderedParameters()
            for token in tokens {
                guard let equals = ConfigurationDocument.firstUnquotedEquals(in: token) else {
                    parameters.set("arg\(parameters.count)", ConfigurationDocument.unquoted(token))
                    continue
                }
                let key = String(token[token.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(token[token.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                parameters.set(key, ConfigurationDocument.unquoted(value))
            }

            let phase = ParsedScript.Phase(token: parameters["type"])
            if !phase.isSupportedByEngine {
                diagnostics.append(
                    ConfigurationDiagnostic(
                        severity: .error,
                        code: .unsupportedRuleType,
                        line: entry.line,
                        section: ConfigurationDocument.SectionKind.script.displayName,
                        message: "Script '\(name)' uses phase '\(parameters["type"] ?? "unknown")', which the script runtime does not serve."
                    )
                )
            }

            configuration.scripts.append(
                ParsedScript(
                    name: name,
                    line: entry.line,
                    phase: phase,
                    pattern: parameters["pattern"],
                    path: parameters["source"] ?? parameters["script-path"],
                    requiresBody: parameters.bool("requires-body") ?? false,
                    maxSize: parameters.int("max-size"),
                    argument: parameters["argument"],
                    parameters: parameters,
                    raw: entry.raw
                )
            )
        }
    }
}


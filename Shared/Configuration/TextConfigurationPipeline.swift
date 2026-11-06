//
//  TextConfigurationPipeline.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Single entry point used by the configuration editor: text in, compiled
/// values and diagnostics out.
///
/// Keeping the three stages (document → typed configuration → engine values)
/// behind one call means the editor, the importer, and tests all exercise the
/// same path.
nonisolated enum TextConfigurationPipeline {

    struct Result: Sendable {
        let document: ConfigurationDocument
        let parsed: ParsedConfiguration
        let compiled: CompiledConfiguration

        var diagnostics: [ConfigurationDiagnostic] { compiled.diagnostics }
        var errorCount: Int { compiled.diagnostics.count { $0.severity == .error } }
        var warningCount: Int { compiled.diagnostics.count { $0.severity == .warning } }
        var isActivatable: Bool { compiled.isActivatable }

        /// Diagnostics grouped by line for the editor's gutter.
        var diagnosticsByLine: [Int: [ConfigurationDiagnostic]] {
            Dictionary(grouping: diagnostics.filter { $0.line != nil }, by: { $0.line ?? 0 })
        }
    }

    static func process(
        text: String,
        capabilities: ConfigurationValidator.Capabilities = .current
    ) -> Result {
        ConfigurationCoordinator(capabilities: capabilities).compile(text: text)
    }

    /// Processes the text and freezes the outcome as a snapshot. Activation is
    /// still a separate step so a document can be saved without going live.
    static func snapshot(
        text: String,
        capabilities: ConfigurationValidator.Capabilities = .current
    ) -> (result: Result, snapshot: ConfigurationSnapshot) {
        let result = process(text: text, capabilities: capabilities)
        return (result, ConfigurationSnapshot(text: text, compiled: result.compiled))
    }

    /// Lossless export: the document keeps original lines, comments, and order.
    static func export(_ document: ConfigurationDocument) -> String {
        document.text
    }

    /// Starter document that compiles cleanly with today's engine, so a new
    /// configuration is activatable before the user edits anything.
    ///
    /// The node is called `Node`, not `Proxy`: `PROXY` is a policy token meaning
    /// "the selected node", so a node with that name could never be referenced
    /// by a rule.
    static let template: String = """
        # NaiveFlow configuration
        #
        # [General]  proxy-mode = rule | global | direct
        # [Proxy]    Name = vless://…   or   Name = vless, host, 443, uuid=…
        # [Rule]     DOMAIN-SUFFIX, example.com, DIRECT

        [General]
        proxy-mode = rule
        quic-policy = automatic

        [Proxy]
        Node = direct

        [Rule]
        DOMAIN-SUFFIX, local, DIRECT
        IP-CIDR, 192.168.0.0/16, DIRECT, no-resolve
        IP-CIDR, 10.0.0.0/8, DIRECT, no-resolve
        DOMAIN-SUFFIX, example.com, Node
        """
}

/// Preview helpers for the configuration editor: "which rule wins for this
/// host or address?" runs through the ordered reference matcher (the live engine currently uses tiered rules).
nonisolated extension TextConfigurationPipeline.Result {

    func route(
        host: String? = nil,
        ip: String? = nil,
        port: UInt16? = nil,
        geoIP: any GeoIPLookup = EmptyGeoIPLookup(),
        geoSite: any GeoSiteLookup = EmptyGeoSiteLookup()
    ) -> OrderedRouteMatcher.Result {
        OrderedRouteMatcher(
            rules: compiled.orderedRules,
            finalAction: compiled.finalAction,
            geoIP: geoIP is EmptyGeoIPLookup ? compiled.geo : geoIP,
            geoSite: geoSite is EmptyGeoSiteLookup ? compiled.geo : geoSite
        ).match(RouteQuery(host: host, ip: ip, destinationPort: port))
    }

    /// Source line of the rule that decided the route, when a rule (not FINAL)
    /// produced it.
    func decidingLine(host: String? = nil, ip: String? = nil, port: UInt16? = nil) -> Int? {
        route(host: host, ip: ip, port: port).ruleLine
    }
}


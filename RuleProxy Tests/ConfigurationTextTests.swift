//
//  ConfigurationTextTests.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation
import Testing
@testable import RuleProxy

struct ConfigurationTextTests {

    // MARK: - Document

    @Test func parsesSectionsEntriesAndComments() {
        let document = ConfigurationDocument.parse(text: """
            // leading comment
            [General]
            proxy-mode = rule   # inline note

            [Rule]
            DOMAIN-SUFFIX, example.com, DIRECT
            """)

        #expect(document.sections.count == 2)
        #expect(document.sections.first?.kind == .general)
        #expect(document.sections.first?.entries.first?.key == "proxy-mode")
        #expect(document.sections.first?.entries.first?.value == "rule")
        #expect(document.sections.first?.entries.first?.comment == "inline note")
        #expect(document.sections.last?.kind == .rule)
        #expect(document.sections.last?.entries.first?.key == nil)
        #expect(document.preambleComments.count == 1)
        #expect(document.diagnostics.isEmpty)
    }

    @Test func normalizesCRLFAndBOM() {
        let document = ConfigurationDocument.parse(text: "\u{FEFF}[General]\r\nipv6 = true\r\n")
        #expect(document.sections.count == 1)
        #expect(document.sections.first?.entries.first?.value == "true")
        #expect(document.lines.count == 3)
    }

    @Test func keepsURLValuesIntact() {
        let result = SurgeConfigurationParser.parse(text: """
            [Script]
            rewrite = type=http-request, pattern=^https://example.com/, script-path=https://cdn.example.com/x.js
            """)

        #expect(result.configuration.scripts.count == 1)
        #expect(result.configuration.scripts.first?.path == "https://cdn.example.com/x.js")
        #expect(result.configuration.scripts.first?.pattern == "^https://example.com/")
        #expect(result.configuration.scripts.first?.phase == .httpRequest)
    }

    // MARK: - Proxies and groups

    @Test func parsesFieldFormProxyWithPositionalValues() {
        let result = SurgeConfigurationParser.parse(text: """
            [Proxy]
            HK = ss, 1.2.3.4, 8388, aes-128-gcm, secret, udp = true
            """)

        let proxy = result.configuration.proxies.first
        #expect(proxy?.typeToken == "ss")
        #expect(proxy?.server == "1.2.3.4")
        #expect(proxy?.port == 8388)

        if case .fields(_, _, _, let parameters)? = proxy?.form {
            #expect(parameters["cipher"] == "aes-128-gcm")
            #expect(parameters["password"] == "secret")
            #expect(parameters["udp"] == "true")
        } else {
            Issue.record("expected a field-form proxy")
        }
    }

    @Test func parsesLinkFormProxy() {
        let result = SurgeConfigurationParser.parse(text: """
            [Proxy]
            Node = vless://11111111-2222-3333-4444-555555555555@example.com:443?encryption=none#Node
            """)

        #expect(result.configuration.proxies.first?.isLink == true)
        #expect(result.configuration.proxies.first?.typeToken == "vless")
    }

    @Test func parsesProxyGroupMembersAndOptions() {
        let result = SurgeConfigurationParser.parse(text: """
            [Proxy Group]
            Auto = url-test, A, B, url = http://www.gstatic.com/generate_204, interval = 600
            """)

        let group = result.configuration.proxyGroups.first
        #expect(group?.kind == .urlTest)
        #expect(group?.members == ["A", "B"])
        #expect(group?.parameters["interval"] == "600")
    }
}

// MARK: - Rules

extension ConfigurationTextTests {

    @Test func parsesRulePolicyAndOptions() {
        let result = SurgeConfigurationParser.parse(text: """
            [Rule]
            IP-CIDR, 10.0.0.0/8, DIRECT, no-resolve
            DOMAIN-SUFFIX, example.com, REJECT
            FINAL, PROXY
            """)

        #expect(result.configuration.rules.count == 3)
        #expect(result.configuration.rules.first?.kind == .ipCIDR)
        #expect(result.configuration.rules.first?.value == "10.0.0.0/8")
        #expect(result.configuration.rules.first?.policy == .direct)
        #expect(result.configuration.rules.first?.options == [.noResolve])
        #expect(result.configuration.rules[1].policy == .reject)
        #expect(result.configuration.finalRule?.policy == .defaultProxy)
    }

    @Test func keepsLogicalExpressionIntact() {
        let result = SurgeConfigurationParser.parse(text: """
            [Rule]
            AND,((DOMAIN-SUFFIX,a.com),(DOMAIN-SUFFIX,b.com)),DIRECT
            """)

        let rule = result.configuration.rules.first
        #expect(rule?.kind == .logicalAnd)
        #expect(rule?.value == "((DOMAIN-SUFFIX,a.com),(DOMAIN-SUFFIX,b.com))")
        #expect(rule?.policy == .direct)
    }
}

// MARK: - Validation

extension ConfigurationTextTests {

    @Test func reportsUnknownPolicy() {
        let result = TextConfigurationPipeline.process(text: """
            [Rule]
            DOMAIN-SUFFIX, example.com, Missing
            """)

        #expect(result.diagnostics.contains { $0.code == .unknownPolicy })
        #expect(!result.isActivatable)
    }

    @Test func rejectsGeoRulesUntilDatabasesLand() {
        let result = TextConfigurationPipeline.process(text: """
            [Rule]
            GEOIP, CN, DIRECT
            """)

        #expect(result.diagnostics.contains { $0.code == .unsupportedRuleType })
        #expect(!result.isActivatable)
    }

    @Test func detectsProxyGroupCycle() {
        let result = TextConfigurationPipeline.process(text: """
            [Proxy]
            A = direct
            [Proxy Group]
            G1 = select, G2
            G2 = select, G1
            """)

        #expect(result.diagnostics.contains { $0.code == .groupCycle })
    }

    @Test func requiresFinalToBeLast() {
        let result = TextConfigurationPipeline.process(text: """
            [Proxy]
            A = direct
            [Rule]
            FINAL, PROXY
            DOMAIN-SUFFIX, example.com, DIRECT
            """)

        #expect(result.diagnostics.contains { $0.code == .finalNotLast })
    }
}


// MARK: - Compilation

extension ConfigurationTextTests {

    @Test func compilesTemplateIntoRuleSets() {
        let template = TextConfigurationPipeline.template
        let result = TextConfigurationPipeline.process(text: template)

        #expect(result.compiled.diagnostics.errors.isEmpty)
        #expect(result.compiled.proxies.count == 1)
        #expect(result.parsed.finalRule != nil)

        let policies = result.compiled.ruleSets.map(\.policy)
        #expect(policies.contains(.direct))
        // The template's own node must be a real policy target, not the built-in
        // `PROXY` token: that is why the node is called `Node`.
        #expect(result.compiled.ruleSets.contains { $0.name.contains("Node") })
        #expect(!result.compiled.diagnostics.contains { $0.code == .reservedPolicyName })
        #expect(!result.compiled.diagnostics.contains { $0.code == .unusedProxy })
        #expect(result.compiled.settings["proxy-mode"] == .text("rule"))
    }

    @Test func warnsWhenANodeNameIsABuiltInPolicy() {
        let result = TextConfigurationPipeline.process(text: """
            [Proxy]
            DIRECT = direct
            [Rule]
            DOMAIN-SUFFIX, example.com, DIRECT
            FINAL, PROXY
            """)

        let warnings = result.compiled.diagnostics.filter { $0.code == .reservedPolicyName }
        #expect(warnings.count == 1)
        #expect(warnings.first?.severity == .warning)
        // The node itself is still valid; only the reference is shadowed.
        #expect(result.compiled.proxies.count == 1)
        #expect(result.compiled.ruleSets.map(\.policy).contains(.direct))
    }

    @Test func groupsRulesByPolicy() {
        let result = TextConfigurationPipeline.process(text: """
            [Proxy]
            A = direct
            [Rule]
            DOMAIN-SUFFIX, a.com, DIRECT
            DOMAIN-SUFFIX, b.com, DIRECT
            DOMAIN-SUFFIX, c.com, REJECT
            """)

        #expect(result.compiled.ruleSets.count == 2)
        let direct = result.compiled.ruleSets.first { $0.policy == .direct }
        #expect(direct?.rules.count == 2)
        #expect(direct?.rules.first?.value == "a.com")
    }

    @Test func compilesProxyFieldsThroughClashBridge() throws {
        let result = TextConfigurationPipeline.process(text: """
            [Proxy]
            Local = socks5, 127.0.0.1, 1080, user, pass
            [Rule]
            DOMAIN-SUFFIX, example.com, Local
            """)

        let proxy = try #require(result.compiled.proxies.first)
        #expect(proxy.name == "Local")
        #expect(proxy.serverAddress == "127.0.0.1")
        #expect(proxy.serverPort == 1080)
        #expect(proxy.outboundProtocol == .socks5)

        let ruleSet = try #require(result.compiled.ruleSets.first)
        guard case .proxy(let id) = ruleSet.policy else {
            Issue.record("expected a proxy route target")
            return
        }
        #expect(id == proxy.id)
    }
}

// MARK: - Snapshots

extension ConfigurationTextTests {

    @Test func snapshotStoreActivatesAndRollsBack() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("rp-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigurationSnapshotStore(directory: directory)
        let template = TextConfigurationPipeline.template
        let result = TextConfigurationPipeline.process(text: template)

        let first = ConfigurationSnapshot(text: template, compiled: result.compiled)
        try store.save(first)
        #expect(store.snapshots().count == 1)

        try store.activate(first.id)
        #expect(store.activeSnapshot()?.id == first.id)
        #expect(store.previousSnapshot() == nil)

        let second = ConfigurationSnapshot(text: template, compiled: result.compiled)
        try store.save(second)
        try store.activate(second.id)
        #expect(store.previousSnapshot()?.id == first.id)

        let restored = try store.rollback()
        #expect(restored?.id == first.id)
        #expect(store.activeSnapshot()?.id == first.id)

        try store.remove(second.id)
        #expect(store.snapshots().map(\.id) == [first.id])
    }
}


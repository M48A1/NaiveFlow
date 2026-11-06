//
//  ConfigurationExporterTests.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation
import Testing
@testable import RuleProxy

struct ConfigurationExporterTests {

    // MARK: - Fixtures

    private func source(
        mitmEnabled: Bool = true,
        mitmHostnames: [String] = ["example.com"]
    ) -> ConfigurationExportSource {
        ConfigurationExportSource(
            proxies: [
                .init(name: "Relay", url: "socks5://1.2.3.4:1080#Relay"),
                .init(name: "Local", url: "direct://#Local")
            ],
            groups: [
                .init(name: "Auto", members: ["Relay", "Local"])
            ],
            ruleSets: [
                .init(
                    name: "Custom",
                    policy: "Auto",
                    rules: [
                        RoutingRule(type: .domainSuffix, value: "example.com"),
                        RoutingRule(type: .ipCIDR, value: "10.0.0.0/8")
                    ]
                )
            ],
            hosts: [HostMapping(host: "example.com", address: "1.2.3.4")],
            settings: [
                .init(key: "proxy-mode", value: "rule"),
                .init(key: "quic-policy", value: "automatic")
            ],
            mitmEnabled: mitmEnabled,
            mitmHostnames: mitmHostnames
        )
    }

    /// The banner repeats every section name as a hint, so layout assertions use
    /// a document without it.
    private func bannerlessExport(
        _ fixture: ConfigurationExportSource,
        finalPolicy: String = "PROXY"
    ) -> ConfigurationExporter.Result {
        var options = ConfigurationExporter.Options()
        options.includeBanner = false
        options.finalPolicy = finalPolicy
        return ConfigurationExporter.export(fixture, options: options)
    }

    // MARK: - Layout

    @Test func emitsSectionsInPipelineOrder() {
        let result = bannerlessExport(source())
        let text = result.text

        #expect(text.hasPrefix("[General]\nproxy-mode = rule"))
        #expect(text.contains("[Proxy]\nRelay = socks5://1.2.3.4:1080#Relay"))
        #expect(text.contains("[Proxy Group]\nAuto = select, Relay, Local"))
        #expect(text.contains("[Rule]\n"))
        #expect(text.contains("DOMAIN-SUFFIX, example.com, Auto"))
        #expect(text.contains("IP-CIDR, 10.0.0.0/8, Auto"))
        #expect(text.contains("[Host]\nexample.com = 1.2.3.4"))
        #expect(text.contains("[MITM]\nenable = true\nhostname = example.com"))
        #expect(text.contains("mitm = true"))

        let order = ["[General]", "[Proxy]", "[Proxy Group]", "[Rule]", "[Host]", "[MITM]"]
        let offsets = order.compactMap { text.range(of: $0)?.lowerBound }
        #expect(offsets.count == order.count)
        #expect(offsets == offsets.sorted())

        #expect(result.counts.proxies == 2)
        #expect(result.counts.groups == 1)
        #expect(result.counts.rules == 2)
        #expect(result.counts.hosts == 1)
        #expect(result.notes.isEmpty)
    }

    @Test func finalPolicyIsExportedAndApplied() {
        let exported = bannerlessExport(source(), finalPolicy: "DIRECT")
        let text = exported.text

        let ruleLines = text
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("DOMAIN-SUFFIX") || $0.hasPrefix("IP-CIDR") || $0.hasPrefix("FINAL") }
        #expect(ruleLines.last == "FINAL, DIRECT")
        #expect(TextConfigurationPipeline.process(text: text).compiled.finalAction == .direct)
    }

    @Test func bannerCanBeTurnedOff() {
        var options = ConfigurationExporter.Options()
        options.includeBanner = false
        let result = ConfigurationExporter.export(source(), options: options)

        #expect(!result.text.contains("# NaiveFlow configuration"))
        #expect(result.text.hasPrefix("[General]"))
    }

    // MARK: - Round trip

    /// The point of the exporter: what it writes must be a document the pipeline
    /// reads back without errors and with the same meaning.
    @Test func exportedTextCompilesWithoutErrors() {
        let result = ConfigurationExporter.export(source())
        let processed = TextConfigurationPipeline.process(text: result.text)

        #expect(processed.errorCount == 0)
        #expect(processed.compiled.proxies.map(\.name) == ["Relay", "Local"])
        #expect(processed.compiled.proxyGroups.map(\.name) == ["Auto"])
        #expect(processed.compiled.proxyGroups.first?.memberIds.count == 2)
        #expect(processed.compiled.ruleSets.count == 1)
        #expect(processed.compiled.ruleSets.first?.name == "Config · Auto")
        #expect(processed.compiled.ruleSets.first?.rules.count == 2)
        #expect(processed.compiled.hosts == [HostMapping(host: "example.com", address: "1.2.3.4")])
        #expect(processed.compiled.settings["proxy-mode"] == .text("rule"))
        #expect(processed.compiled.settings["quic-policy"] == .text("automatic"))
        #expect(processed.compiled.settings["mitm"] == .flag(true))
        #expect(processed.compiled.isActivatable)
    }

    @Test func groupPolicyResolvesToItsFirstMember() throws {
        let processed = TextConfigurationPipeline.process(
            text: ConfigurationExporter.export(source()).text
        )

        let relayId = try #require(processed.compiled.proxies.first { $0.name == "Relay" }?.id)
        #expect(processed.compiled.ruleSets.first?.policy == .proxy(relayId))
        #expect(processed.compiled.finalAction == .defaultProxy)
        #expect(processed.route(host: "www.example.com").action == .proxy(relayId))
        #expect(processed.route(host: "unrelated.org").isFinal)
    }

    // MARK: - Losses are reported, never invented

    @Test func reportsRuleSetsWithoutPolicy() {
        var fixture = source()
        fixture.ruleSets.append(
            .init(name: "AdBlock", policy: nil, rules: [RoutingRule(type: .domainKeyword, value: "ads")])
        )

        let result = ConfigurationExporter.export(fixture)

        #expect(result.counts.skippedRuleSets == ["AdBlock"])
        #expect(!result.text.contains("DOMAIN-KEYWORD"))
        #expect(result.notes.contains { $0.contains("AdBlock") })
        #expect(TextConfigurationPipeline.process(text: result.text).errorCount == 0)
    }

    @Test func reportsUnknownPolicy() {
        var fixture = source()
        fixture.ruleSets = [
            .init(
                name: "Orphan",
                policy: "Deleted Node",
                rules: [RoutingRule(type: .domainSuffix, value: "orphan.test")]
            )
        ]

        let result = ConfigurationExporter.export(fixture)

        #expect(result.counts.skippedRuleSets == ["Orphan"])
        #expect(result.notes.contains { $0.contains("Deleted Node") })
        #expect(TextConfigurationPipeline.process(text: result.text).errorCount == 0)
    }

    @Test func leavesOutMITMWhenNoHostIsConfigured() {
        let result = bannerlessExport(source(mitmEnabled: true, mitmHostnames: []))

        #expect(!result.text.contains("[MITM]"))
        #expect(result.notes.contains { $0.contains("MITM") })
        #expect(TextConfigurationPipeline.process(text: result.text).errorCount == 0)
    }

    @Test func dropsGroupMembersThatAreNotExported() {
        var fixture = source()
        fixture.groups = [.init(name: "Auto", members: ["Relay", "Missing"])]

        let result = ConfigurationExporter.export(fixture)

        #expect(result.text.contains("Auto = select, Relay"))
        #expect(!result.text.contains("Missing"))
        #expect(result.notes.contains { $0.contains("Missing") })
        #expect(TextConfigurationPipeline.process(text: result.text).errorCount == 0)
    }

    @Test func skipsNodesWithoutALink() {
        var fixture = source()
        fixture.proxies.append(.init(name: "Broken", url: "   "))

        let result = ConfigurationExporter.export(fixture)

        #expect(result.counts.proxies == 2)
        #expect(result.notes.contains { $0.contains("Broken") })
        #expect(TextConfigurationPipeline.process(text: result.text).errorCount == 0)
    }


    // MARK: - Names

    /// `[Proxy]` keys are separated by `=` and `[Rule]` splits on commas, so a
    /// name that carries either would parse differently on the way back in.
    @Test func renamesAndDeduplicatesUnusableNames() {
        let fixture = ConfigurationExportSource(
            proxies: [
                .init(name: "HK, 01", url: "socks5://1.2.3.4:1080#HK"),
                .init(name: "HK, 01", url: "socks5://5.6.7.8:1080#HK")
            ],
            ruleSets: [
                .init(
                    name: "Custom",
                    policy: "HK, 01",
                    rules: [RoutingRule(type: .domainSuffix, value: "example.com")]
                )
            ]
        )

        let result = ConfigurationExporter.export(fixture)
        #expect(result.text.contains("HK_ 01 = socks5://1.2.3.4:1080"))
        #expect(result.text.contains("HK_ 01 2 = socks5://5.6.7.8:1080"))
        #expect(result.text.contains("DOMAIN-SUFFIX, example.com, HK_ 01\n"))
        #expect(result.notes.count == 2)

        let processed = TextConfigurationPipeline.process(text: result.text)
        #expect(processed.errorCount == 0)
        #expect(processed.compiled.proxies.map(\.name) == ["HK_ 01", "HK_ 01 2"])
        #expect(processed.compiled.proxies.first?.outboundProtocol == .socks5)
    }

    /// A node named after a policy token can be declared but never referenced:
    /// `RULE, value, DIRECT` always means the built-in action. Exporting the name
    /// unchanged would flip the rule's meaning on the way back in, so the name is
    /// suffixed and the rename is reported.
    @Test func renamesNodesThatShadowAPolicyToken() {
        let fixture = ConfigurationExportSource(
            proxies: [
                .init(name: "DIRECT", url: "socks5://1.2.3.4:1080#DIRECT")
            ],
            ruleSets: [
                .init(
                    name: "Custom",
                    policy: "DIRECT",
                    rules: [RoutingRule(type: .domainSuffix, value: "example.com")]
                )
            ]
        )

        let result = ConfigurationExporter.export(fixture)
        #expect(result.text.contains("DIRECT_ = socks5://1.2.3.4:1080"))
        #expect(result.text.contains("DOMAIN-SUFFIX, example.com, DIRECT_\n"))
        #expect(result.notes.contains { $0.contains("Renamed node 'DIRECT' to 'DIRECT_'") })

        let processed = TextConfigurationPipeline.process(text: result.text)
        #expect(processed.errorCount == 0)
        #expect(processed.compiled.proxies.map(\.name) == ["DIRECT_"])
        // The rule now reaches the node instead of the built-in DIRECT action.
        #expect(processed.compiled.ruleSets.first?.policy != .direct)
    }
}

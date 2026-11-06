//
//  ConfigurationSettingsTests.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation
import Testing
@testable import RuleProxy

/// The catalog is the contract that every `[General]` key is parsed, validated,
/// compiled, applied and exported from one place. These tests hold that contract
/// together: they fail the build when a key is declared without a binding (or the
/// other way around), when two keys collide, or when a value does not survive the
/// parse → compile → export round trip.
struct ConfigurationSettingsTests {

    // MARK: - Catalog integrity

    @Test func everyAppliedKeyHasABinding() {
        let applied = Set(ConfigurationSettings.appliedKeys.map(\.name))
        let bound = ConfigurationSettingsBindings.names
        let unbound = applied.subtracting(bound).sorted()

        #expect(unbound.isEmpty, "Applied keys without a binding: \(unbound)")
    }

    @Test func everyBindingIsDeclaredInTheCatalog() {
        let declared = ConfigurationSettings.names
        let orphaned = ConfigurationSettingsBindings.names.subtracting(declared).sorted()

        #expect(orphaned.isEmpty, "Bindings with no catalog entry: \(orphaned)")
    }

    @Test func unappliedKeysHaveNoBinding() {
        // A key declared `applies: false` must not be writable, or it would
        // silently change behavior while the validator says it does not.
        let unapplied = Set(ConfigurationSettings.unappliedKeys.map(\.name))
        let bound = ConfigurationSettingsBindings.names.intersection(unapplied)

        #expect(bound.isEmpty, "Unapplied keys with a binding: \(bound.sorted())")
    }

    @Test func catalogHasNoDuplicateNames() {
        let names = ConfigurationSettings.catalog.map(\.name)
        #expect(names.count == Set(names).count)
    }

    @Test func catalogNamesAreLowercaseKebabCase() {
        for key in ConfigurationSettings.catalog {
            #expect(key.name == key.name.lowercased())
            #expect(!key.name.contains(" ") && !key.name.contains("_"))
        }
    }

    @Test func everyKeyHasASummary() {
        for key in ConfigurationSettings.catalog where key.summary.isEmpty {
            Issue.record("Key '\(key.name)' has no summary for the schema document.")
        }
    }

    // MARK: - Parsing

    @Test func parsesNaiveFlowBooleanSpellings() {
        let key = ConfigurationSettingKey(
            name: "flag", kind: .flag, scope: .live, applies: true, summary: ""
        )
        for spelling in ["true", "TRUE", "yes", "on", "1"] {
            #expect(key.parse(spelling) == .flag(true), "\(spelling) should be true")
        }
        for spelling in ["false", "FALSE", "no", "off", "0"] {
            #expect(key.parse(spelling) == .flag(false), "\(spelling) should be false")
        }
        #expect(key.parse("maybe") == nil)
        #expect(key.parse("") == nil)
    }

    @Test func parsesEnumerationsCaseInsensitively() {
        let key = ConfigurationSettingKey(
            name: "mode", kind: .enumeration(["rule", "global"]), scope: .live, applies: true, summary: ""
        )
        #expect(key.parse(" Rule ") == .text("rule"))
        #expect(key.parse("DIRECT") == nil)
    }

    @Test func parsesListsAndDropsBlanks() {
        let key = ConfigurationSettingKey(
            name: "routes", kind: .list, scope: .live, applies: true, summary: ""
        )
        #expect(key.parse("10.0.0.0/8, , 192.168.0.0/16") == .list(["10.0.0.0/8", "192.168.0.0/16"]))
        #expect(key.parse("") == .list([]))
    }

    @Test func normalizesCountryCode() {
        let key = ConfigurationSettingKey(
            name: "bypass-country", kind: .countryCode, scope: .live, applies: true, summary: ""
        )
        #expect(key.parse("cn") == .text("CN"))
        #expect(key.parse("") == nil)
        #expect(key.parse("CHN") == nil)
    }

    @Test func validatesDNSServers() {
        let plain = ConfigurationSettingKey(
            name: "dns-server", kind: .plainServer, scope: .live, applies: true, summary: ""
        )
        #expect(plain.parse("1.1.1.1") == .text("1.1.1.1"))
        #expect(plain.parse("1.1.1.1:5353") == .text("1.1.1.1:5353"))
        #expect(plain.parse("not-a-server") == nil)
        #expect(plain.parse("") == nil)

        let doh = ConfigurationSettingKey(
            name: "encrypted-dns-server", kind: .dohURL, scope: .live, applies: true, summary: ""
        )
        #expect(doh.parse("https://dns.example.com/dns-query") == .text("https://dns.example.com/dns-query"))
        #expect(doh.parse("http://dns.example.com/dns-query") == nil)
        #expect(doh.parse("1.1.1.1") == nil)
    }

    // MARK: - Compile

    @Test func compilesOnlyTheKeysTheDocumentMentions() {
        let result = NaiveFlowConfigurationParser.parse(text: """
            [General]
            block-udp = true
            include-apns = no
            """)

        let settings = ConfigurationCompiler.compileSettings(result.configuration)
        #expect(settings["block-udp"] == .flag(true))
        #expect(settings["include-apns"] == .flag(false))
        #expect(settings["quic-policy"] == nil)
    }

    @Test func dropsAValueTheKeyRejects() {
        let result = TextConfigurationPipeline.process(text: """
            [General]
            proxy-mode = sideways
            """)

        #expect(result.compiled.settings["proxy-mode"] == nil)
        #expect(result.compiled.diagnostics.contains { $0.code == .invalidValue })
    }

    @Test func mitmSectionWinsOverGeneralFlag() {
        let result = NaiveFlowConfigurationParser.parse(text: """
            [General]
            mitm = true

            [MITM]
            enable = false
            """)

        let settings = ConfigurationCompiler.compileSettings(result.configuration)
        #expect(settings["mitm"] == .flag(false))
    }

    // MARK: - Diagnostics

    @Test func reportsAnUnknownGeneralKey() {
        let result = TextConfigurationPipeline.process(text: """
            [General]
            not-a-real-setting = 1
            """)

        #expect(result.compiled.diagnostics.contains { $0.code == .unknownGeneralKey })
    }

    @Test func reportsEveryUnappliedKeyOnceWithTheRightCode() {
        let result = TextConfigurationPipeline.process(text: """
            [General]
            ipv6 = true
            skip-proxy = 10.0.0.0/8
            """)

        let unapplied = result.compiled.diagnostics.filter { $0.code == .notApplied }
        #expect(unapplied.count == 2)
        #expect(!result.compiled.diagnostics.contains { $0.code == .unknownGeneralKey })
    }

    // MARK: - Round trip

    @Test func everyRenderedValueParsesBackToItself() {
        // What the exporter writes must be what the parser accepts: `true` for a
        // flag, `a, b` for a list, the plain text for everything else.
        for key in ConfigurationSettings.appliedKeys {
            for value in sampleValues(for: key.kind) {
                let rendered = value.rendered
                #expect(
                    key.parse(rendered) == value,
                    "\(key.name) did not survive \(rendered) → \(String(describing: key.parse(rendered)))"
                )
            }
        }
    }

    private func sampleValues(for kind: ConfigurationSettingKey.Kind) -> [ConfigurationSettingValue] {
        switch kind {
        case .flag:
            return [.flag(true), .flag(false)]
        case .text:
            return [.text("example.com")]
        case .enumeration(let values):
            return values.map { .text($0) }
        case .countryCode:
            return [.text("CN")]
        case .list:
            return [.list(["one", "two"])]
        case .plainServer:
            return [.text("1.1.1.1"), .text("1.1.1.1:5353")]
        case .bootstrapDNS:
            return [.text("system"), .text("1.1.1.1, 2001:db8::53")]
        case .dohURL:
            return [.text("https://dns.example.com/dns-query")]
        }
    }

    // MARK: - Reload plan

    @Test func classifiesChangesByTheCatalogScope() {
        let previous = CompiledSettings()
        var current = CompiledSettings()
        current["block-udp"] = .flag(true)
        current["include-all-networks"] = .flag(true)

        let plan = ConfigurationReloadPlan.make(from: previous, to: current)
        #expect(plan.changes.count == 2)
        #expect(plan.contains(field: "block-udp"))
        #expect(plan.changes.first { $0.field == "block-udp" }?.scope == .live)
        #expect(plan.changes.first { $0.field == "include-all-networks" }?.scope == .reconnect)
        #expect(plan.requiresReconnect)
    }

    @Test func ignoresKeysTheDocumentLeavesOut() {
        var previous = CompiledSettings()
        previous["block-udp"] = .flag(true)

        let plan = ConfigurationReloadPlan.make(from: previous, to: CompiledSettings())
        #expect(plan.isEmpty)
    }
}

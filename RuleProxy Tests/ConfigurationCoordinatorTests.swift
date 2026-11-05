//
//  ConfigurationCoordinatorTests.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/5/26.
//

import Foundation
import Testing
@testable import RuleProxy

/// The work of describing a document is split in two: `ConfigurationCoordinator`
/// decides what the host has to say about it, and `RuntimeCoordinator` decides
/// what the extension does when it hears it. These tests pin the tables that make
/// the two halves agree — which module owns which `[General]` key, which
/// notifications an install owes, and which reload work each notification turns
/// into. A gap in any of them is invisible at runtime: the host would post a
/// notification the extension silently drops, or a changed setting would be
/// reported against a module that never reloads for it.
struct ConfigurationCoordinatorTests {

    static let document = """
        [General]
        proxy-mode = rule
        dns-server = 1.1.1.1
        block-udp = true

        [Host]
        example.org = 10.0.0.1

        [Rule]
        DOMAIN-SUFFIX, example.com, DIRECT
        """

    // MARK: - Ownership

    @Test func everyAppliedKeyHasAnOwner() {
        let applied = Set(ConfigurationSettings.appliedKeys.map(\.name))
        let owned = Set(ConfigurationModule.settingOwners.keys)

        #expect(
            applied.subtracting(owned).isEmpty,
            "Applied keys without an owner: \(applied.subtracting(owned).sorted())"
        )
        #expect(
            owned.subtracting(applied).isEmpty,
            "Owned keys that never reach the engine: \(owned.subtracting(applied).sorted())"
        )
    }

    @Test func unappliedKeysHaveNoOwner() {
        // A key the validator reports as `not applied` must not claim a module:
        // nothing reloads for it, so attributing it would promise work that never
        // happens.
        let unapplied = Set(ConfigurationSettings.unappliedKeys.map(\.name))
        let claimed = unapplied.intersection(ConfigurationModule.settingOwners.keys)

        #expect(claimed.isEmpty, "Unapplied keys with an owner: \(claimed.sorted())")
    }

    @Test func eachSettingIsListedUnderExactlyOneModule() {
        var seen: Set<String> = []

        for module in ConfigurationModule.allCases {
            #expect(module.settingNames == module.settingNames.sorted())
            for name in module.settingNames {
                #expect(!seen.contains(name), "\(name) is listed for more than one module.")
                seen.insert(name)
            }
        }

        #expect(seen == Set(ConfigurationModule.settingOwners.keys))
    }

    @Test func sectionHeadersMapToModules() {
        #expect(ConfigurationModule.owning(section: "Proxy") == .outbound)
        #expect(ConfigurationModule.owning(section: "proxy group") == .outbound)
        #expect(ConfigurationModule.owning(section: "SSID Setting") == .outbound)
        #expect(ConfigurationModule.owning(section: "Rule") == .rule)
        #expect(ConfigurationModule.owning(section: "Host") == .dns)
        #expect(ConfigurationModule.owning(section: "MITM") == .mitm)
        // The rewrite sections only do anything while interception is on, so they
        // reload together with the MITM policy.
        #expect(ConfigurationModule.owning(section: "URL Rewrite") == .mitm)
        // `[General]` keys are split between the modules one key at a time.
        #expect(ConfigurationModule.owning(section: "General") == nil)
        #expect(ConfigurationModule.owning(section: nil) == nil)
    }

    // MARK: - Preparation

    @Test func reportsTheModulesADocumentDescribes() {
        let preparation = ConfigurationCoordinator().prepare(text: Self.document)

        #expect(preparation.canActivate)
        #expect(preparation.modules.map(\.module) == [.rule, .dns, .outbound])
        #expect(preparation.documentDiagnostics.isEmpty)
        #expect(preparation.report(for: .dns)?.settingNames == ["dns-server"])
        #expect(preparation.report(for: .dns)?.payloadSummary == "1 host override(s)")
        #expect(preparation.report(for: .rule)?.payloadSummary == "1 rule(s)")
        #expect(preparation.report(for: .outbound)?.settingNames == ["block-udp", "proxy-mode"])
        // The document says nothing about interception, so the module is left out
        // instead of being reported as empty.
        #expect(preparation.report(for: .mitm) == nil)
    }

    @Test func attributesSectionDiagnosticsToTheirModule() {
        func module(section: String, message: String) -> ConfigurationModule? {
            ConfigurationCoordinator.module(
                for: ConfigurationDiagnostic(
                    severity: .warning, code: .notApplied, section: section, message: message
                )
            )
        }

        #expect(module(section: "Host", message: "anything") == .dns)
        #expect(module(section: "Rule", message: "anything") == .rule)
        // A `[General]` diagnostic carries no module of its own; the key it quotes
        // decides it.
        #expect(module(section: "General", message: "General setting 'block-udp' is recognized but not applied") == .outbound)
        #expect(module(section: "General", message: "General setting 'dns-server' is recognized but not applied") == .dns)
        // A key with no owner stays with the document: nothing reloads for it.
        #expect(module(section: "General", message: "General setting 'ipv6' is recognized but not applied") == nil)
    }

    @Test func keepsUnownedDiagnosticsOnTheDocument() {
        let preparation = ConfigurationCoordinator().prepare(text: """
            [General]
            loglevel = verbose
            """)

        #expect(preparation.documentDiagnostics.contains { $0.code == .notApplied })
        for module in ConfigurationModule.allCases {
            let attached = preparation.report(for: module)?.diagnostics.contains { $0.code == .notApplied } == true
            #expect(!attached, "\(module.title) claimed a note about a key it does not own.")
        }
    }

    // MARK: - Plans

    @Test func plansNothingWhenTheDocumentDidNotChange() {
        let running = TextConfigurationPipeline.process(text: Self.document).compiled

        let plan = ConfigurationCoordinator().plan(from: running, to: running, running: running.settings)

        #expect(plan.isEmpty)
        #expect(plan.announcements.isEmpty)
    }

    @Test func attributesASettingsChangeToItsModule() {
        let before = TextConfigurationPipeline.process(text: """
            [General]
            block-udp = false
            """).compiled
        let after = TextConfigurationPipeline.process(text: """
            [General]
            block-udp = false
            mitm = true
            """).compiled

        let plan = ConfigurationCoordinator().plan(from: before, to: after, running: before.settings)

        let mitm = plan.change(for: .mitm)
        #expect(mitm?.reload.contains(field: "mitm") == true)
        // `mitm` is a `[General]` key: it reloads interception but changes no
        // payload, so the module's report must say exactly that.
        #expect(mitm?.payloadChanged == false)
        #expect(plan.change(for: .dns) == nil)
        #expect(plan.change(for: .outbound) == nil)
        #expect(plan.announcements == [.settings, .mitm])
    }

    @Test func announcesOnlySettingsWhenMITMIsUntouched() {
        var after = CompiledSettings()
        after["block-udp"] = .flag(true)
        let reload = ConfigurationReloadPlan.make(from: CompiledSettings(), to: after)

        #expect(ConfigurationCoordinator.announcements(for: reload) == [.settings])
        #expect(ConfigurationCoordinator.announcements(for: ConfigurationReloadPlan()).isEmpty)
    }

    // MARK: - Extension side

    @Test func everyAnnouncementHasAnEventInTheExtension() {
        for announcement in ConfigurationCoordinator.Announcement.allCases {
            guard let event = RuntimeCoordinator.Event(announcement) else {
                Issue.record("The host can post \(announcement.rawValue), but no event recognizes it.")
                continue
            }
            // The names have to be the same string, or the two tables would agree
            // on the shape and disagree on the wire.
            #expect(RuntimeCoordinator.Event(notificationName: event.notificationName as String) == event)
        }
    }

    @Test func everyAnnouncementPlansSomeWork() {
        for announcement in ConfigurationCoordinator.Announcement.allCases {
            let plan = RuntimeCoordinator.plan(forAnnouncement: announcement)
            #expect(plan != nil, "The host can post \(announcement.rawValue) with nothing behind it.")
            #expect(plan?.actions.isEmpty == false)
            #expect(plan?.event == RuntimeCoordinator.Event(announcement))
        }
    }

    @Test func notificationNamesRoundTrip() {
        let names = RuntimeCoordinator.Event.notificationNames
        #expect(names.count == RuntimeCoordinator.Event.allCases.count)

        // The observer registers for exactly these names, so every one of them has
        // to decode; a name that does not is a wake-up the extension drops.
        for name in names {
            #expect(RuntimeCoordinator.Event(notificationName: name as String) != nil)
        }
        #expect(RuntimeCoordinator.Event(notificationName: "not.a.notification") == nil)
    }

    @Test func plansRunTheStepsInOrder() {
        #expect(RuntimeCoordinator.plan(for: .settings).actions == [.reloadHostMappings, .reloadSettings])
        #expect(RuntimeCoordinator.plan(for: .mitm).actions == [.reloadMITM, .revalidateQUIC])
        #expect(RuntimeCoordinator.plan(for: .routing).actions == [.reloadRouting])
        #expect(RuntimeCoordinator.plan(for: .activeConfiguration).actions == [.reloadActiveConfiguration])

        for event in RuntimeCoordinator.Event.allCases {
            #expect(!RuntimeCoordinator.plan(for: event).isEmpty, "\(event.rawValue) reloads nothing.")
            #expect(RuntimeCoordinator.plan(for: event).event == event)
        }
    }

    @Test func onlyHostInvalidationRunsOutsideTheRunningPhase() {
        for action in RuntimeCoordinator.Action.allCases {
            #expect(
                action.requiresRunningPhase == (action != .reloadHostMappings),
                "\(action.rawValue) has the wrong phase rule."
            )
        }
    }

}

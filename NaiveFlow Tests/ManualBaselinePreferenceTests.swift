//
//  ManualBaselinePreferenceTests.swift
//  NaiveFlow Tests
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation
import Testing
@testable import NaiveFlow

/// Verifies the manual-baseline preference rule at the real RuntimePreferences
/// read/write layer: rolling back to a baseline (`snapshotID == nil`) must leave
/// reads live so later manual edits take effect, while a text version pins its
/// captured values.
struct ManualBaselinePreferenceTests {
    private func bundle(snapshotID: UUID?, preferences: [String: RuntimePreferenceValue]) -> RuntimeConfigurationBundle {
        RuntimeConfigurationBundle(
            id: UUID(), snapshotID: snapshotID, parentID: nil,
            preferences: preferences, nodes: [], selectedNodeID: UUID(),
            rules: nil, finalAction: .defaultProxy, mitmRuleSets: [],
            legacyRouting: nil, legacyMITM: nil
        )
    }

    @Test func baselineLeavesReadsLiveWhileTextVersionPins() throws {
        let suite = "NaiveFlow-prefs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("rule", forKey: "proxyMode")
        let view = RuntimePreferences(defaults: defaults)

        // Manual baseline: installs no pin, so a later edit to UserDefaults is
        // observed. This is the exact scenario the review flagged (baseline must
        // not freeze the read view at the captured snapshot).
        let baseline = bundle(snapshotID: nil, preferences: ["proxyMode": .string("rule")])
        #expect(!baseline.pinsRuntimePreferences)
        #expect(baseline.runtimePreferencesForInstall == nil)
        view.install(pins: baseline.pinsRuntimePreferences, values: baseline.preferences)
        defaults.set("direct", forKey: "proxyMode")
        #expect(view.string(forKey: "proxyMode") == "direct")

        // Text version: pins the captured value, so a later edit is ignored.
        let text = bundle(snapshotID: UUID(), preferences: ["proxyMode": .string("rule")])
        #expect(text.pinsRuntimePreferences)
        #expect(text.runtimePreferencesForInstall?["proxyMode"] == .string("rule"))
        view.install(pins: text.pinsRuntimePreferences, values: text.preferences)
        defaults.set("direct", forKey: "proxyMode")
        #expect(view.string(forKey: "proxyMode") == "rule")
    }
}

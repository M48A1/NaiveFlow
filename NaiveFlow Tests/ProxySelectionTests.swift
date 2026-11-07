//
//  ProxySelectionTests.swift
//  NaiveFlow Tests
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation
import Testing
@testable import NaiveFlow

@MainActor
struct ProxySelectionTests {
    private func node(_ name: String) -> ProxyConfiguration {
        ProxyConfiguration(name: name, serverAddress: "1.2.3.4", serverPort: 443,
                           outbound: .direct(DirectConfiguration()))
    }

    private func bundle(node: ProxyConfiguration, snapshotID: UUID?) -> RuntimeConfigurationBundle {
        RuntimeConfigurationBundle(
            id: UUID(), snapshotID: snapshotID, parentID: nil,
            preferences: [:], nodes: [node], selectedNodeID: node.id,
            rules: nil, finalAction: .defaultProxy, mitmRuleSets: [],
            legacyRouting: nil, legacyMITM: nil
        )
    }

    @Test func textVersionPinsSelection() {
        let selection = ProxySelection()
        let n = node("A")
        selection.showRuntimeVersion(bundle(node: n, snapshotID: UUID()))
        #expect(selection.usesRuntimeVersion)
        #expect(selection.runtimeConfiguration?.id == n.id)
        #expect(selection.effectiveConfiguration?.id == n.id)
    }

    /// Rolling back to the manually captured baseline (snapshotID == nil) must
    /// un-lock the selection and restore the baseline's node, instead of leaving
    /// the app pinned to a non-editable runtime version.
    @Test func manualBaselineRestoresEditableSelection() {
        let selection = ProxySelection()
        let n = node("A")
        selection.showRuntimeVersion(bundle(node: n, snapshotID: nil))
        #expect(!selection.usesRuntimeVersion)
        #expect(selection.selectedConfiguration?.id == n.id)
        #expect(selection.effectiveConfiguration?.id == n.id)

        // Manual selection is possible again after the baseline restore.
        let other = node("B")
        selection.select(other)
        #expect(selection.selectedConfiguration?.id == other.id)
        #expect(selection.effectiveConfiguration?.id == other.id)
    }
}

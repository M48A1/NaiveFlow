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

    private func bundle(node: ProxyConfiguration, snapshotID: UUID) -> RuntimeConfigurationBundle {
        RuntimeConfigurationBundle(
            id: UUID(), snapshotID: snapshotID, parentID: nil,
            preferences: [:], nodes: [node], selectedNodeID: node.id,
            rules: [], finalAction: .defaultProxy, mitmRuleSets: []
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

    @Test func noSelectionWithoutAppliedProfile() {
        let selection = ProxySelection()
        #expect(selection.effectiveConfiguration == nil)
    }
}

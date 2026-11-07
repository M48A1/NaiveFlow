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

    /// Clears the persisted manual selection so each test controls `AWCore`
    /// state regardless of execution order.
    private func resetPersistedSelection() {
        AWCore.setSelectedChainId(nil)
        AWCore.setSelectedConfigurationId(nil)
    }

    @Test func textVersionPinsSelection() {
        resetPersistedSelection()
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
        resetPersistedSelection()
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

    /// A baseline must not clobber a newer manual node on relaunch: after choosing
    /// B over baseline A, a fresh selection plus adoption (startup / reconcile /
    /// reconnect confirmation) and revalidation keeps B instead of reverting to A.
    @Test func baselineAdoptionKeepsNewerManualNodeAcrossRelaunch() {
        resetPersistedSelection()
        let a = node("A")
        let b = node("B")
        let baseline = bundle(node: a, snapshotID: nil)

        let first = ProxySelection()
        first.showRuntimeVersion(baseline)
        first.select(b)
        #expect(AWCore.getSelectedConfigurationId() == b.id)

        // Relaunch: same persisted stores, a brand-new selection instance.
        let relaunched = ProxySelection()
        relaunched.showRuntimeVersion(baseline)
        relaunched.revalidate(configurations: [a, b], chains: [])
        #expect(relaunched.effectiveConfiguration?.id == b.id)
        #expect(AWCore.getSelectedConfigurationId() == b.id)

        // Repeated reconcile receipts are idempotent and keep B.
        relaunched.showRuntimeVersion(baseline)
        #expect(relaunched.effectiveConfiguration?.id == b.id)
    }

    /// The same protection applies to a selected chain.
    @Test func baselineAdoptionKeepsNewerManualChainAcrossRelaunch() {
        resetPersistedSelection()
        let a = node("A")
        let b = node("B")
        let chain = ProxyChain(name: "A-B", proxyIds: [a.id, b.id])
        let baseline = bundle(node: a, snapshotID: nil)

        let first = ProxySelection()
        first.showRuntimeVersion(baseline)
        #expect(first.selectChain(chain, configurations: [a, b]))
        #expect(AWCore.getSelectedChainId() == chain.id)

        let relaunched = ProxySelection()
        relaunched.showRuntimeVersion(baseline)
        relaunched.revalidate(configurations: [a, b], chains: [chain])
        #expect(relaunched.selectedChainId == chain.id)
        #expect(relaunched.effectiveConfiguration?.id == chain.id)
        #expect(AWCore.getSelectedChainId() == chain.id)
    }
}

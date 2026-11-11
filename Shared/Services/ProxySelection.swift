//
//  ProxySelection.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/3/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class ProxySelection {
    private(set) var selectedConfiguration: ProxyConfiguration?
    private(set) var runtimeGroups: [RuntimeGroupDisplay] = []
    private(set) var runtimeConfiguration: ProxyConfiguration?
    var usesRuntimeVersion: Bool { runtimeConfiguration != nil }
    var effectiveConfiguration: ProxyConfiguration? { runtimeConfiguration ?? selectedConfiguration }

    /// Adopts the active head configuration.
    ///
    /// A published text version (`snapshotID != nil`) pins the selection: the
    /// document controls routing and the manual library is read-only.
    ///
    /// A manually captured baseline (`snapshotID == nil`) only *exits* text mode.
    /// It must not overwrite the user's most recent manual selection: the live
    /// node/chain is whatever is already selected in memory, or whatever the store
    /// persisted (restored by `revalidate`). Only when nothing is selected and
    /// nothing was saved do we bootstrap from the baseline's node. Keeping this
    /// idempotent lets it run safely on every startup, reconnection confirmation
    /// and reconcile receipt.
    func showRuntimeVersion(_ bundle: RuntimeConfigurationBundle) {
        guard bundle.snapshotID != nil else {
            adoptManualBaseline(bundle.selectedNode)
            return
        }
        guard let node = bundle.selectedNode else { return }
        runtimeConfiguration = node
        runtimeGroups = bundle.displayGroups.isEmpty ? bundle.policyGroups.map {
            RuntimeGroupDisplay(id: $0.id, name: $0.name, memberCount: $0.memberIDs.count, iconURL: $0.iconURL)
        } : bundle.displayGroups
    }

    /// Leaves text mode without clobbering the saved manual selection. The
    /// baseline's node is reused only as a last resort, when neither an in-memory
    /// nor a persisted selection exists to restore.
    private func adoptManualBaseline(_ baselineNode: ProxyConfiguration?) {
        runtimeConfiguration = nil
        runtimeGroups = []
        guard selectedConfiguration == nil, selectedChainId == nil else { return }
        guard AWCore.getSelectedChainId() == nil, AWCore.getSelectedConfigurationId() == nil else { return }
        guard let baselineNode else { return }
        AWCore.setSelectedConfigurationId(baselineNode.id)
        selectedConfiguration = baselineNode
    }

    private(set) var selectedChainId: UUID?

    // MARK: - Mutations

    func select(_ configuration: ProxyConfiguration) {
        selectedChainId = nil
        AWCore.setSelectedChainId(nil)
        AWCore.setSelectedConfigurationId(configuration.id)
        selectedConfiguration = configuration
    }

    @discardableResult
    func selectChain(_ chain: ProxyChain, configurations: [ProxyConfiguration]) -> Bool {
        guard let resolved = chain.resolveComposite(from: configurations) else { return false }
        selectedChainId = chain.id
        AWCore.setSelectedChainId(chain.id)
        AWCore.setSelectedConfigurationId(nil)
        selectedConfiguration = resolved
        return true
    }

    @discardableResult
    func selectIfNone(_ configuration: ProxyConfiguration) -> Bool {
        guard selectedConfiguration == nil else { return false }
        select(configuration)
        return true
    }

    // MARK: - Revalidation
    
    func revalidate(configurations: [ProxyConfiguration], chains: [ProxyChain]) {
        if selectedConfiguration == nil, selectedChainId == nil {
            restoreSelection(configurations: configurations, chains: chains)
            return
        }
        if let chainId = selectedChainId {
            if let chain = chains.first(where: { $0.id == chainId }),
               let resolved = chain.resolveComposite(from: configurations) {
                if resolved != selectedConfiguration {
                    selectedConfiguration = resolved
                }
            } else {
                selectedChainId = nil
                AWCore.setSelectedChainId(nil)
                fallBack(to: configurations.first)
            }
        } else if let selected = selectedConfiguration {
            if let refreshed = configurations.first(where: { $0.id == selected.id }) {
                if refreshed != selected {
                    selectedConfiguration = refreshed
                }
            } else {
                fallBack(to: configurations.first)
            }
        }
    }

    private func restoreSelection(configurations: [ProxyConfiguration], chains: [ProxyChain]) {
        if let savedChainId = AWCore.getSelectedChainId(),
           let chain = chains.first(where: { $0.id == savedChainId }),
           let resolved = chain.resolveComposite(from: configurations) {
            selectedChainId = savedChainId
            selectedConfiguration = resolved
        } else if let savedConfigurationId = AWCore.getSelectedConfigurationId(),
                  let configuration = configurations.first(where: { $0.id == savedConfigurationId }) {
            selectedConfiguration = configuration
        } else {
            fallBack(to: configurations.first)
        }
    }

    private func fallBack(to configuration: ProxyConfiguration?) {
        AWCore.setSelectedChainId(nil)
        AWCore.setSelectedConfigurationId(configuration?.id)
        selectedConfiguration = configuration
    }
}

//
//  Operations.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/20/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class Operations {
    @ObservationIgnored private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    var configurations: ConfigurationOperations {
        ConfigurationOperations(store: container.configurationStore, reaction: container.mutationReaction)
    }

    var chains: ChainOperations {
        ChainOperations(store: container.chainStore, reaction: container.mutationReaction)
    }

    var subscriptions: SubscriptionOperations {
        SubscriptionOperations(
            store: container.subscriptionStore,
            configurationStore: container.configurationStore,
            reaction: container.mutationReaction,
            coordinator: container.subscriptionRefreshCoordinator
        )
    }

    var groups: GroupOperations {
        GroupOperations(store: container.groupStore)
    }

    /// The editable document and its immutable runtime publications.
    var configurationDocument: ConfigurationDocumentOperations {
        ConfigurationDocumentOperations(
            activation: ConfigurationActivation(),
            tunnel: container.tunnel,
            selection: container.selection
        )
    }

    var selection: SelectionOperations {
        SelectionOperations(proxySelection: container.selection)
    }

    var tunnel: TunnelOperations {
        TunnelOperations(tunnel: container.tunnel, selection: container.selection)
    }

    var latency: LatencyRunner {
        LatencyRunner(
            latency: container.latency,
            tunnel: container.tunnel,
            configurationStore: container.configurationStore,
            chainStore: container.chainStore
        )
    }
    

    func reload(_ keys: Set<SyncStore.Key>) async {
        let stores: [(SyncStore.Key, any Reloadable)] = [
            (.groups, container.groupStore),
            (.subscriptions, container.subscriptionStore),
            (.chains, container.chainStore),
            (.configurations, container.configurationStore),
        ]
        let affected = stores.filter { keys.contains($0.0) }.map(\.1)
        guard !affected.isEmpty else { return }
        await ReloadOperation(stores: affected, reaction: container.mutationReaction).run()
    }
}

//
//  StoreMutationReaction.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/20/26.
//

import Foundation

@MainActor
struct StoreMutationReaction {
    let configurationStore: ConfigurationStore
    let chainStore: ChainStore
    let selection: ProxySelection
    let latency: LatencyCenter

    func run() {
        let configurations = configurationStore.configurations
        let chains = chainStore.chains

        selection.revalidate(configurations: configurations, chains: chains)

        latency.pruneLatencyState(liveConfigurationIds: Set(configurations.map(\.id)))
        latency.pruneChainLatencyState(liveChainIds: Set(chains.map(\.id)))

    }
}

//
//  AppContainer.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/3/26.
//

import Foundation
import NetworkExtension
import Observation

@MainActor
final class AppContainer {
    let syncStore: SyncStore

    // MARK: - Residents

    let tunnel: TunnelController
    let selection = ProxySelection()
    let latency = LatencyCenter()
    let stats = ConnectionStats()

    let configurationStore: ConfigurationStore
    let chainStore: ChainStore
    let groupStore: GroupStore
    let subscriptionStore: SubscriptionStore
    let subscriptionRefreshCoordinator = SubscriptionRefreshCoordinator()

    private var started = false

    init(syncStore: SyncStore = .shared, tunnelProvider: TunnelProviding? = nil) {
        self.syncStore = syncStore
        AWCore.discardManualSettings()
        do {
            try syncStore.discardRemovedConfigurationCollections()
            let configurations = EngineConfirmationStore.directory
            let group = configurations.deletingLastPathComponent()
            for url in [configurations.appendingPathComponent("runtime"),
                        configurations.appendingPathComponent("installation.json"),
                        group.appendingPathComponent("routing.bin"), group.appendingPathComponent("mitm.bin")] {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        } catch { ConfigurationActivation().record(error.localizedDescription) }


        tunnel = TunnelController(provider: tunnelProvider ?? LiveTunnelProvider())
        configurationStore = ConfigurationStore(syncStore: syncStore)
        chainStore = ChainStore(syncStore: syncStore)
        groupStore = GroupStore(syncStore: syncStore)
        subscriptionStore = SubscriptionStore(syncStore: syncStore)
        do {
            let publisher = ConfigurationPublisher(activation: ConfigurationActivation(), tunnel: tunnel,
                clearStateSink: { [selection] in selection.clearRuntimeVersion() },
                stateSink: { [selection] in selection.showRuntimeVersion($0) })
            try publisher.reconcile()
            if let head = try RuntimeBundleStore().head() {
                let version = try RuntimeBundleStore().load(head.current)
                AWCore.installRuntimePreferences(version.preferences)
                selection.showRuntimeVersion(version)
            }
        } catch RuntimeConfigurationFailure.busy { }
        catch { ConfigurationActivation().record(error.localizedDescription) }
    }

    // MARK: - Operation Factories

    var mutationReaction: StoreMutationReaction {
        StoreMutationReaction(
            configurationStore: configurationStore,
            chainStore: chainStore,
            selection: selection,
            latency: latency
        )
    }

    // MARK: - Startup

    func start() {
        guard !started else { return }
        started = true
        // Migrate host-only test preferences before the tunnel reads them.
        _ = LatencyTestSettings.load()

        Task { await LoadOperation(configurationStore: configurationStore, reaction: mutationReaction).run() }
        observeTunnelStatus()
        observeSelection()
        tunnel.start()
    }
    
    private func observeTunnelStatus() {
        withObservationTracking {
            _ = tunnel.rawStatus
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                TunnelSessionReaction(tunnel: self.tunnel, stats: self.stats, selection: self.selection).run()
                self.observeTunnelStatus()
                if self.tunnel.rawStatus == .connected {
                    do {
                        try await ConfigurationPublisher(activation: ConfigurationActivation(), tunnel: self.tunnel,
                            clearStateSink: { [selection = self.selection] in selection.clearRuntimeVersion() },
                            stateSink: { [selection = self.selection] in selection.showRuntimeVersion($0) }).recoverPending()
                    } catch RuntimeConfigurationFailure.busy { }
                    catch { ConfigurationActivation().record(error.localizedDescription) }
                }
            }
        }
    }
    
    private func observeSelection() {
        withObservationTracking {
            _ = selection.effectiveConfiguration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSelection()
                await self.tunnel.publish(self.selection.effectiveConfiguration)
            }
        }
    }
}

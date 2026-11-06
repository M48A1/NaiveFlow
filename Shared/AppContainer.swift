//
//  AppContainer.swift
//  RuleProxy
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
    let appState = AppState()

    let configurationStore: ConfigurationStore
    let chainStore: ChainStore
    let groupStore: GroupStore
    let subscriptionStore: SubscriptionStore
    let routingRuleSetStore: RoutingRuleSetStore
    let mitmRuleSetStore: MITMRuleSetStore
    let moduleStore: ModuleStore
    let certificateStore: CertificateStore
    let configurationCloud: ConfigurationCloudStore

    private let routingExportDebouncer = Debouncer(interval: .seconds(2))
    private let mitmExportDebouncer = Debouncer(interval: .milliseconds(500))
    private var started = false

    init(syncStore: SyncStore = .shared, tunnelProvider: TunnelProviding? = nil) {
        self.syncStore = syncStore

        tunnel = TunnelController(provider: tunnelProvider ?? LiveTunnelProvider())
        configurationStore = ConfigurationStore(syncStore: syncStore)
        chainStore = ChainStore(syncStore: syncStore)
        groupStore = GroupStore(syncStore: syncStore)
        subscriptionStore = SubscriptionStore(syncStore: syncStore)
        routingRuleSetStore = RoutingRuleSetStore(syncStore: syncStore)
        mitmRuleSetStore = MITMRuleSetStore(syncStore: syncStore)
        moduleStore = ModuleStore(syncStore: syncStore)
        certificateStore = CertificateStore()
        configurationCloud = ConfigurationCloudStore()
        do {
            let publisher = ConfigurationPublisher(activation: ConfigurationActivation(), tunnel: tunnel,
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

    var routingExportScheduler: RoutingExportScheduler {
        RoutingExportScheduler(
            debouncer: routingExportDebouncer,
            ruleSetStore: routingRuleSetStore,
            moduleStore: moduleStore,
            configurationStore: configurationStore,
            chainStore: chainStore
        )
    }

    var mitmExportScheduler: MITMExportScheduler {
        MITMExportScheduler(
            debouncer: mitmExportDebouncer,
            ruleSetStore: mitmRuleSetStore,
            moduleStore: moduleStore
        )
    }

    var mutationReaction: StoreMutationReaction {
        StoreMutationReaction(
            configurationStore: configurationStore,
            chainStore: chainStore,
            routingRuleSetStore: routingRuleSetStore,
            moduleStore: moduleStore,
            selection: selection,
            latency: latency,
            appState: appState,
            routingExportScheduler: routingExportScheduler,
            mitmExportScheduler: mitmExportScheduler
        )
    }

    // MARK: - Startup

    func start() {
        guard !started else { return }
        started = true
        configurationCloud.reload()

        Task { await LoadOperation(configurationStore: configurationStore, reaction: mutationReaction).run() }
        observeTunnelStatus()
        observeSelection()
        routingExportScheduler.schedule()
        mitmExportScheduler.schedule()
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

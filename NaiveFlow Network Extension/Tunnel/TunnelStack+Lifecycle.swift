//
//  TunnelStack+Lifecycle.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/30/26.
//

import Foundation
import Synchronization
@preconcurrency import NetworkExtension
import NaiveFlowIP

nonisolated private let logger = NaiveFlowLogger(category: "TunnelStack+Lifecycle")

extension TunnelStack {

    // MARK: - Lifecycle

    func start(packetFlow: NEPacketTunnelFlow, configuration: ProxyConfiguration) async -> Bool {
        guard transition(to: .starting) else { return false }
        let epoch = claimStartEpoch()
        TransportReclaim.unsealAll()
        makeFreshDutyCycleStreams()
        purgeOutputBuffer()
        NaiveFlowLogger.installLogSink { [weak self] message, level in
            let logLevel: TunnelLogLevel
            switch level {
            case .debug, .info: logLevel = .info
            case .warning: logLevel = .warning
            case .error: logLevel = .error
            }
            self?.appendLog(message, level: logLevel)
        }
        attachPacketFlow(packetFlow)
        self.configuration = configuration

        let udpPlane = UDPPlane(stack: self)
        self.udpPlane = udpPlane

        guard phase == .starting, epoch == startEpoch else {
            if epoch == startEpoch {
                attachPacketFlow(nil)
                self.configuration = nil
                self.udpPlane = nil
            }
            return false
        }
        executeLifecycle(.start, configuration: configuration)

        rootTask = Task { await self.run(packetFlow: packetFlow, udpPlane: udpPlane) }

        transition(to: .running)

        recordEngineConfirmation()

        return true
    }

    // MARK: - Task tree

    private func run(packetFlow: NEPacketTunnelFlow, udpPlane: UDPPlane) async {
        await withDiscardingTaskGroup { group in
            group.addTask { [planeCommands] in
                for await command in planeCommands {
                    await udpPlane.apply(command)
                }
            }
            group.addTask {
                await self.runDutyCycle(packetFlow: packetFlow, udpPlane: udpPlane)
                await self.finishShutdown()
            }
        }
    }

    private func runDutyCycle(packetFlow: NEPacketTunnelFlow, udpPlane: UDPPlane) async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.runReadLoop(packetFlow: packetFlow, udpPlane: udpPlane) }
            group.addTask { await self.runSettingsObserver() }
            group.addTask { await self.runUDPCleanupLoop(udpPlane: udpPlane) }
            group.addTask { await self.runTCPIdleSweep() }
            for await job in self.nurseryJobs {
                switch job {
                case .deferredRestart(let configuration, let revalidateMode, let delay, let generation):
                    group.addTask {
                        await self.runDeferredRestart(
                            configuration: configuration,
                            revalidateMode: revalidateMode,
                            delay: delay,
                            generation: generation
                        )
                    }
                }
            }
            group.cancelAll()
        }
    }

    private func finishShutdown() {
        TransportReclaim.sealAll()
        executeLifecycle(.stop, configuration: configuration)
        finishPlaneCommands()
    }

    func stop() async {
        switch phase {
        case .idle, .stopped:
            return
        case .stopping:
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        case .starting, .running:
            break
        }
        transition(to: .stopping)
        nurseryJobContinuation.finish()
        await rootTask?.value
        rootTask = nil
        NaiveFlowLogger.installLogSink(nil)
        transition(to: .stopped)
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    
    func applyConfiguration(_ newConfiguration: ProxyConfiguration) {
        guard phase == .running, newConfiguration != configuration else { return }
        restartStack(configuration: newConfiguration)
    }

    func sleep() {
        guard !configurationTransition.load(ordering: .acquiring), phase == .running, let configuration else { return }
        executeLifecycle(.sleep, configuration: configuration)
    }

    func updateNetworkContext(_ context: NetworkContext) {
        guard context != networkContext else { return }
        networkContext = context

        guard phase == .running, let configuration else { return }
        let newEffective = computeEffectiveProxyMode()
        guard newEffective != proxyMode else { return }
        restartStack(configuration: configuration, revalidateMode: true)
    }

    // MARK: - Data plane

    private enum TCPTeardown {
        case graceful
        case silent
    }
    
    private func bringUpDataPlane(configuration: ProxyConfiguration) {
        guard !dataPlaneUp else {
            logger.error("[TunnelStack] Data plane already up")
            return
        }
        dataPlaneUp = true
        let ipStack = makeIPStack()
        self.ipStack = ipStack
        liveIPStack.withLock { $0 = ipStack }
        startIPStackTick()
        submitPlaneCommand(.setMultiplexerPool(configuration.makeUDPMultiplexerPool()))
    }
    
    private func tearDownDataPlane(tcp: TCPTeardown) {
        guard dataPlaneUp else { return }
        dataPlaneUp = false
        liveIPStack.withLock { $0 = nil }

        ipStackTick?.cancel()
        ipStackTick = nil

        ipStackAbortContext.store(.teardown, ordering: .relaxed)
        switch tcp {
        case .graceful:
            purgeOutputBuffer()
            closeAllActiveTCP()
            dataPlaneGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        case .silent:
            dataPlaneGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
            purgeOutputBuffer()
            discardAllActiveTCP()
        }

        reclaimAllOutboundPools()
        submitPlaneCommand(.reclaim)

        ipStack?.shutdown()
        ipStack = nil
        tcpConnections.withLock { $0.removeAll() }
        ipStackAbortContext.store(.none, ordering: .relaxed)
    }

    private func closeAllActiveTCP() {
        for connection in ipStack?.connections() ?? [] { connection.close() }
    }

    private func discardAllActiveTCP() {
        for connection in ipStack?.connections() ?? [] { connection.discard() }
    }

    private func reclaimAllOutboundPools() {
        TransportReclaim.reclaimAll()
        MITMScriptHTTP2Pool.shared.reclaim()
    }

    // MARK: - Restart

    /// Rebuilds the data plane in place.
    ///
    /// Called from the settings reload path (`TunnelStack+Runtime`) when a change
    /// cannot be applied live — a different proxy mode — and from the deferred
    /// restart job that throttles repeated requests.
    func restartStack(configuration: ProxyConfiguration, revalidateMode: Bool = false) {
        guard !configurationTransition.load(ordering: .acquiring) else { return }
        if revalidateMode, deferredRestartScheduled { return }

        let now = MonotonicClock.now
        let elapsed = now - lastRestartTime

        if elapsed < TunnelConstants.restartThrottleInterval {
            let delay = TunnelConstants.restartThrottleInterval - elapsed
            deferredRestartGeneration += 1
            deferredRestartScheduled = true
            nurseryJobContinuation.yield(.deferredRestart(
                configuration: configuration, revalidateMode: revalidateMode,
                delay: delay, generation: deferredRestartGeneration
            ))
            return
        }

        restartStackNow(configuration: configuration)
    }

    private func runDeferredRestart(
        configuration: ProxyConfiguration,
        revalidateMode: Bool,
        delay: TimeInterval,
        generation: Int
    ) async {
        try? await Task.sleep(seconds: delay, precision: .relaxed)
        guard generation == deferredRestartGeneration else { return }
        deferredRestartScheduled = false
        guard !Task.isCancelled, phase == .running else { return }
        if revalidateMode, computeEffectiveProxyMode() == proxyMode { return }
        restartStackNow(configuration: configuration)
    }

    private func restartStackNow(configuration: ProxyConfiguration) {
        guard !configurationTransition.load(ordering: .acquiring) else { return }
        guard phase == .running else { return }
        deferredRestartGeneration += 1
        deferredRestartScheduled = false
        lastRestartTime = MonotonicClock.now

        executeLifecycle(.restart, configuration: configuration)
    }

    /// Module adapters reuse the existing data plane and transport cleanup.
    /// All lifecycle ordering is supplied by RuntimeCoordinator.
    func executeLifecycle(
        _ event: RuntimeCoordinator.Lifecycle,
        configuration: ProxyConfiguration?
    ) {
        for action in RuntimeCoordinator.lifecyclePlan(for: event) {
            switch action {
            case .stopDataPlane: tearDownDataPlane(tcp: .graceful)
            case .discardDataPlane: tearDownDataPlane(tcp: .silent)
            case .configureModules:
                guard let configuration else { continue }
                connectionRouter.clearRejectMarks()
                self.configuration = configuration
                configureRuntime(for: configuration)
            case .startDataPlane:
                guard let configuration else { continue }
                bringUpDataPlane(configuration: configuration)
            case .releaseModules:
                groupProber.stop()
                purgeOutputBuffer()
                attachPacketFlow(nil)
                OutboundConnector.setRoutingContext(nil)
                DNSUpstreamClient.setProxyDoHTransport(nil)
                syntheticAddressPool.reset()
                connectionRouter.clearRejectMarks()
                domainRouter.reset()
                mitmPolicy.reset()
                ConnectionMetrics.shared.setDefaultServer(nil)
                self.configuration = nil
                EngineConfirmationStore.clear()
            }
        }
    }

    // MARK: - Engine Confirmation

    /// Records routing readiness without claiming a complete snapshot commit.
    func recordEngineConfirmation() {
        // Serialize with stop on this actor: a detached write could recreate a
        // stale confirmation after shutdown cleared it.
        guard phase == .running else { return }
        if let bundle = nativeBundle {
            EngineConfirmationStore.record(ConfigurationEngineConfirmation(
                snapshotId: bundle.snapshotID, engineVersion: ConfigurationEngineVersion.current
            ))
        }
    }

}

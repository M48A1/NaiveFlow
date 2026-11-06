//
//  TunnelStack+Runtime.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/5/26.
//

import Foundation
import Synchronization

nonisolated private let logger = RuleProxyLogger(category: "TunnelStack+Runtime")

/// Hot reload.
///
/// Nothing here decides *that* something changed — the host announces it and
/// `RuntimeCoordinator` turns the announcement into an ordered plan. What lives
/// here is the reloading itself, one method per coordinator action, so a step can
/// always be traced back to the plan that asked for it.
extension TunnelStack {

    // MARK: - Observation

    /// Streams the host's announcements and runs each one as a plan.
    ///
    /// Registration covers exactly the events `RuntimeCoordinator` knows about, so
    /// a new event is a case in the coordinator instead of a second list of
    /// notification names here.
    func runSettingsObserver() async {
        // Subscribe before reconciliation so an edit racing startup is either
        // loaded by this pass or buffered by the observer, never lost in between.
        let notifications = DarwinNotificationConcurrencyBridge.names(RuntimeCoordinator.Event.notificationNames)
        for event in RuntimeCoordinator.reconciliationOrder {
            await apply(RuntimeCoordinator.plan(for: event))
        }
        for await name in notifications {
            guard let event = RuntimeCoordinator.Event(notificationName: name) else { continue }
            await apply(RuntimeCoordinator.plan(for: event))
        }
    }

    // MARK: - Applying a plan

    /// Runs a plan's actions in order, skipping the ones the phase rules out.
    func apply(_ plan: RuntimeCoordinator.Plan) async {
        guard !configurationTransition.load(ordering: .acquiring) else { return }
        // A version pins all inputs. Legacy exporters cannot partially overwrite
        // it; publication is handled by the provider so OS settings participate.
        if nativeBundle != nil, plan.event != .configurationVersion { return }
        for action in plan.actions {
            guard !action.requiresRunningPhase || phase == .running else { continue }
            switch action {
            case .reloadConfigurationVersion: requestReapplyTunnelSettings()
            case .reloadHostMappings: reloadHostMappings()
            case .reloadDNS:
                let ticket = runtime.begin(.dns)
                reloadDNSConfiguration()
                runtime.complete(ticket)
            case .reloadSettings: reloadSettings()
            case .reloadRouting: await reloadRouting()
            case .reloadMITM: reloadMITM()
            case .reloadActiveConfiguration: reloadActiveConfiguration()
            case .revalidateQUIC: submitPlaneCommand(.revalidateQUIC)
            }
        }
    }

    // MARK: - Steps

    /// `[Host]` overrides are cached per process; a document change may have
    /// rewritten them, so the next lookup has to read the store again.
    private func reloadHostMappings() {
        DNSHosts.shared.invalidate()
    }

    /// Upstream getters are dynamic; flushing removes answers from old inputs.
    func reloadDNSConfiguration() {
        DNSHosts.shared.invalidate()
        DNSResolver.localRequests.flush()
        DNSResolver.proxies.flush()
        ECHResolver.shared.flush()
    }

    private func reloadSettings() {
        guard let configuration else { return }

        let old = settings
        let new = TunnelSettings.load()
        guard new != old else { return }
        let ticket = runtime.begin(.outbound)
        settings = new

        publishUDPConfig()

        if new.quicPolicy != old.quicPolicy {
            submitPlaneCommand(.revalidateQUIC)
        }
        if new.preventDNSLeak != old.preventDNSLeak {
            connectionRouter.preventDNSLeak.store(new.preventDNSLeak, ordering: .relaxed)
            publishOutboundRoutingContext(configuration: configuration)
        }
        if new.reflectionEnabled != old.reflectionEnabled {
            publishReflectionEnabled()
        }
        let tunnelRoutesChanged = new.tunnelIncludedRoutes != old.tunnelIncludedRoutes
            || new.tunnelExcludedRoutes != old.tunnelExcludedRoutes
            || new.hideVPNIcon != old.hideVPNIcon
            || new.reflectionEnabled != old.reflectionEnabled
        if tunnelRoutesChanged {
            requestReapplyTunnelSettings()
        }

        if computeEffectiveProxyMode() != proxyMode {
            restartStack(configuration: configuration)
        } else {
            runtime.complete(ticket)
        }
    }

    /// Recompiles the routing payload the host rewrote.
    ///
    /// `DomainRouter` holds the last compiled payload, so the recompile happens
    /// first and the result is installed only if the stack is still running in
    /// rule mode — an announcement that races a stop cannot install a stale
    /// payload.
    private func reloadRouting() async {
        guard proxyMode == .rule else { return }
        let ticket = runtime.begin(.rule)
        let compiled = await domainRouter.compileRoutingConfiguration()
        guard phase == .running, proxyMode == .rule, runtime.accepts(ticket) else { return }
        domainRouter.install(compiled)
        runtime.complete(ticket)
        connectionRouter.clearRejectMarks()
        recordEngineConfirmation()
    }

    /// Re-reads the MITM policy and republishes it to the UDP plane.
    private func reloadMITM() {
        let ticket = runtime.begin(.mitm)
        loadMITMSetting()
        publishUDPConfig()
        runtime.complete(ticket)
    }

    /// Switches the data plane to the node the host selected.
    private func reloadActiveConfiguration() {
        let ticket = runtime.begin(.outbound)
        let active: ProxyConfiguration?
        do {
            active = try ActiveConfiguration.load()
        } catch {
            logger.report(RuleProxyError.store(.corrupted(.configurations, detail: RuleProxyError.describe(error))))
            runtime.fail(ticket, message: "Could not load the outbound configuration.")
            return
        }
        guard let active else {
            runtime.fail(ticket, message: "No active outbound configuration is published.")
            return
        }
        if active == configuration {
            runtime.complete(ticket)
        } else {
            applyConfiguration(active)
        }
    }
}

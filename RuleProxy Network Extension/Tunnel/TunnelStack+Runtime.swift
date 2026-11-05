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
        for await name in DarwinNotificationConcurrencyBridge.names(RuntimeCoordinator.Event.notificationNames) {
            guard let event = RuntimeCoordinator.Event(notificationName: name) else { continue }
            await apply(RuntimeCoordinator.plan(for: event))
        }
    }

    // MARK: - Applying a plan

    /// Runs a plan's actions in order, skipping the ones the phase rules out.
    func apply(_ plan: RuntimeCoordinator.Plan) async {
        for action in plan.actions {
            guard !action.requiresRunningPhase || phase == .running else { continue }
            switch action {
            case .reloadHostMappings: reloadHostMappings()
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

    /// Re-reads everything the settings file can change while the stack runs.
    ///
    /// Only the fields the data plane caches are republished — the rest read the
    /// store on demand — and a different proxy mode is the one change that cannot
    /// be applied in place, so it rebuilds the stack instead.
    private func reloadSettings() {
        guard let configuration else { return }

        let old = settings
        let new = TunnelSettings.load()
        guard new != old else { return }
        settings = new

        publishUDPConfig()

        if new.quicPolicy != old.quicPolicy {
            submitPlaneCommand(.revalidateQUIC)
        }
        if new.preventDNSLeak != old.preventDNSLeak {
            connectionRouter.preventDNSLeak.store(new.preventDNSLeak, ordering: .relaxed)
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
        let compiled = await domainRouter.compileRoutingConfiguration()
        guard phase == .running, proxyMode == .rule else { return }
        domainRouter.install(compiled)
        connectionRouter.clearRejectMarks()
        recordEngineConfirmation()
    }

    /// Re-reads the MITM policy and republishes it to the UDP plane.
    private func reloadMITM() {
        loadMITMSetting()
        publishUDPConfig()
    }

    /// Switches the data plane to the node the host selected.
    private func reloadActiveConfiguration() {
        let active: ProxyConfiguration?
        do {
            active = try ActiveConfiguration.load()
        } catch {
            logger.report(RuleProxyError.store(.corrupted(.configurations, detail: RuleProxyError.describe(error))))
            return
        }
        guard let active else { return }
        applyConfiguration(active)
    }
}

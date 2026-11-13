//
//  TunnelStack+Runtime.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/5/26.
//

import Foundation
import Synchronization

nonisolated private let logger = NaiveFlowLogger(category: "TunnelStack+Runtime")

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

    func apply(_ plan: RuntimeCoordinator.Plan) async {
        guard !configurationTransition.load(ordering: .acquiring), phase == .running else { return }
        if plan.contains(.reloadConfigurationVersion) { requestReapplyTunnelSettings() }
    }

    func reloadDNSConfiguration() {
        DNSHosts.shared.invalidate()
        DNSResolver.localRequests.flush()
        DNSResolver.proxies.flush()
        ECHResolver.shared.flush()
    }
}

//
//  RuntimeCoordinator.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/5/26.
//

import Foundation
import Synchronization

/// Owns kernel lifecycle state, module ordering and configuration reload plans.
/// TunnelStack is the actor-isolated adapter that executes these decisions.
///
/// Manual mode reloads four inputs independently — the settings it reads from
/// the shared container, the routing payload, the MITM policy, and the selected
/// node — and each of those arrives as a Darwin notification. Before this type,
/// the notification name, its guard and its reload steps were spelled out inline
/// in `TunnelStack`; keeping the mapping here makes the sequence visible and
/// testable without a data plane.
///
/// This is the extension half of the announcement contract whose host half is
/// `ConfigurationCoordinator`: that type decides which announcements an
/// activation owes, this one decides what each announcement turns into. The two
/// tables are held against each other on the host side, in
/// `ConfigurationCoordinator.swift` — this file is built into the extension
/// without the compiler those announcements belong to, so the bridge from one
/// vocabulary to the other lives where both exist. A notification the host posts
/// that no event here recognizes is then a test failure instead of a silent
/// no-op in the extension.
///
/// Native text mode publishes one version notification; TunnelStack validates,
/// gates the data plane, and installs or restores all module inputs together.
///
/// The coordinator decides *what* to reload and *in which order*
/// (`TunnelStack+Runtime` performs the reloading, because that part needs the
/// running stack).
nonisolated enum RuntimeCoordinator {

    enum Module: String, CaseIterable, Identifiable, Sendable, Hashable {
        case rule, dns, mitm, outbound
        var id: String { rawValue }
    }

    enum Phase: UInt8, AtomicRepresentable, CustomStringConvertible, PhaseTransitionable, Sendable {
        case idle, starting, running, stopping, stopped

        static func canTransition(from old: Phase, to new: Phase) -> Bool {
            switch (old, new) {
            case (.idle, .starting), (.stopped, .starting), (.starting, .running),
                 (.starting, .stopping), (.running, .stopping), (.stopping, .stopped):
                return true
            default: return false
            }
        }

        var description: String {
            switch self {
            case .idle: "idle"
            case .starting: "starting"
            case .running: "running"
            case .stopping: "stopping"
            case .stopped: "stopped"
            }
        }
    }

    /// Actor-owned by TunnelStack. This is the single lifecycle state; published
    /// atomics are mirrors for the existing packet path, not another authority.
    struct State: Sendable {
        private(set) var phase: Phase = .idle
        private(set) var epoch: UInt64 = 0
        private(set) var modules: Set<Module> = []
        private var revisions: [Module: UInt64] = [:]
        private var failures: [Module: String] = [:]

        var status: Status {
            Status(
                phase: phase.description, epoch: epoch,
                readyModules: modules.map(\.rawValue).sorted(),
                pendingModules: revisions.keys.filter { !modules.contains($0) }.map(\.rawValue).sorted(),
                failures: Dictionary(uniqueKeysWithValues: failures.map { ($0.key.rawValue, $0.value) })
            )
        }

        struct Ticket: Equatable, Sendable {
            let module: Module
            let epoch: UInt64
            let revision: UInt64
        }

        mutating func transition(to next: Phase) -> Bool {
            guard Phase.transition(&phase, to: next) else { return false }
            if next == .starting || next == .stopping {
                epoch &+= 1
                modules.removeAll()
                revisions.removeAll()
                failures.removeAll()
            }
            return true
        }

        mutating func begin(_ module: Module) -> Ticket {
            let revision = (revisions[module] ?? 0) &+ 1
            revisions[module] = revision
            modules.remove(module)
            failures.removeValue(forKey: module)
            return Ticket(module: module, epoch: epoch, revision: revision)
        }

        func accepts(_ ticket: Ticket) -> Bool {
            (phase == .starting || phase == .running)
                && ticket.epoch == epoch && revisions[ticket.module] == ticket.revision
        }

        @discardableResult
        mutating func complete(_ ticket: Ticket) -> Bool {
            guard accepts(ticket) else { return false }
            modules.insert(ticket.module)
            failures.removeValue(forKey: ticket.module)
            return true
        }

        mutating func fail(_ ticket: Ticket, message: String) {
            guard accepts(ticket) else { return }
            modules.remove(ticket.module)
            failures[ticket.module] = message
        }
    }

    /// "Ready" means the module adapter has loaded its current inputs; this is
    /// not an acknowledgement that all independent stores form one snapshot.
    struct Status: Codable, Equatable, Sendable {
        var versionID: String? = nil
        var pendingVersionID: String? = nil
        let phase: String
        let epoch: UInt64
        let readyModules: [String]
        let pendingModules: [String]
        let failures: [String: String]
    }

    enum Lifecycle: Sendable { case start, restart, sleep, stop }
    enum LifecycleAction: Sendable, Equatable {
        case stopDataPlane, discardDataPlane, configureModules, startDataPlane, releaseModules
    }

    /// Preserve the kernel's existing teardown semantics and restart throttling.
    /// The coordinator owns order; the adapter owns sockets, pools and packets.
    static func lifecyclePlan(for event: Lifecycle) -> [LifecycleAction] {
        switch event {
        case .start: return [.configureModules, .startDataPlane]
        case .restart: return [.stopDataPlane, .configureModules, .startDataPlane]
        case .sleep: return [.discardDataPlane, .startDataPlane]
        case .stop: return [.stopDataPlane, .releaseModules]
        }
    }

    /// DNS/settings before dependent policies; publish outbound only after MITM.
    static let configurationOrder: [Module] = [.dns, .mitm, .outbound, .rule]
    static let reconciliationOrder: [Event] = [.settings, .mitm, .activeConfiguration, .routing]

    /// Something the host announced.
    enum Event: String, CaseIterable, Sendable, Hashable {
        /// The node list or the selected node changed.
        case configurationVersion
        case activeConfiguration
        /// `[General]` values changed (DNS, TUN, QUIC, mode, …).
        case settings
        /// The routing payload was rewritten.
        case routing
        /// MITM rules or the trusted certificate list changed.
        case mitm

        /// The Darwin notification that triggers this event.
        var notificationName: CFString {
            switch self {
            case .configurationVersion: return AWNotificationCenter.Notification.configurationVersionChanged
            case .activeConfiguration: return AWNotificationCenter.Notification.activeConfigurationChanged
            case .settings: return AWNotificationCenter.Notification.tunnelSettingsChanged
            case .routing: return AWNotificationCenter.Notification.routingChanged
            case .mitm: return AWNotificationCenter.Notification.mitmChanged
            }
        }

        /// The event a posted notification name stands for.
        ///
        /// The observer hands over the raw name it woke up for, so this is the
        /// only lookup the running extension performs per announcement.
        init?(notificationName: String) {
            guard let event = Self.allCases.first(where: { $0.notificationName as String == notificationName }) else {
                return nil
            }
            self = event
        }

        /// Every notification the observer registers for.
        ///
        /// Registration and decoding come from this one list, so a name the
        /// extension listens for but cannot decode cannot exist.
        static var notificationNames: [CFString] {
            allCases.map(\.notificationName)
        }
    }
}

// MARK: - Actions

nonisolated extension RuntimeCoordinator {

    /// One unit of reload work.
    enum Action: String, CaseIterable, Sendable, Hashable {
        /// Drop the cached host overrides so the next lookup reads them again.
        case reloadConfigurationVersion
        case reloadHostMappings
        /// Flush process-local DNS/ECH caches after upstream or Host changes.
        case reloadDNS
        /// Re-read the settings and publish what the data plane reads from them.
        case reloadSettings
        /// Recompile and install the routing payload.
        case reloadRouting
        /// Re-read the MITM policy.
        case reloadMITM
        /// Switch the data plane to the selected node.
        case reloadActiveConfiguration
        /// Re-check how SOCKS5 flows treat QUIC.
        case revalidateQUIC

        /// Whether the action only makes sense while the tunnel is running.
        ///
        /// Clearing the host cache is the exception: it is cheap, it has no
        /// effect without a stack, and it must not be skipped, or a stale
        /// override could survive a later start.
        var requiresRunningPhase: Bool {
            switch self {
            case .reloadHostMappings:
                return false
            case .reloadConfigurationVersion, .reloadDNS, .reloadSettings, .reloadRouting, .reloadMITM, .reloadActiveConfiguration, .revalidateQUIC:
                return true
            }
        }
    }
}

// MARK: - Plans

nonisolated extension RuntimeCoordinator {

    /// The work one announcement turns into.
    ///
    /// The actions are in the order they have to run, not an arbitrary list: the
    /// host cache is cleared before the new settings are read, because a settings
    /// change can move the DNS servers and a stale override would resolve through
    /// the old ones; the MITM policy is re-read before the UDP plane re-checks
    /// QUIC, because interception decides what QUIC traffic looks like.
    struct Plan: Sendable, Equatable {
        let event: Event
        let actions: [Action]

        var isEmpty: Bool { actions.isEmpty }

        func contains(_ action: Action) -> Bool { actions.contains(action) }
    }

    /// The work one announcement turns into.
    static func plan(for event: Event) -> Plan {
        switch event {
        case .configurationVersion:
            return Plan(event: event, actions: [.reloadConfigurationVersion])
        case .activeConfiguration:
            return Plan(event: event, actions: [.reloadActiveConfiguration])
        case .settings:
            return Plan(event: event, actions: [.reloadHostMappings, .reloadDNS, .reloadSettings])
        case .routing:
            return Plan(event: event, actions: [.reloadRouting])
        case .mitm:
            return Plan(event: event, actions: [.reloadMITM, .revalidateQUIC])
        }
    }
}


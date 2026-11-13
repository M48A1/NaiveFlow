//
//  RuntimeCoordinator.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/5/26.
//

import Foundation
import Synchronization

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
    static let reconciliationOrder: [Event] = [.configurationVersion]

    enum Event: String, CaseIterable, Sendable, Hashable {
        case configurationVersion
        var notificationName: CFString { AWNotificationCenter.Notification.configurationVersionChanged }
        init?(notificationName: String) {
            guard notificationName == Self.configurationVersion.notificationName as String else { return nil }
            self = .configurationVersion
        }
        static var notificationNames: [CFString] { allCases.map(\.notificationName) }
    }
}

// MARK: - Actions

nonisolated extension RuntimeCoordinator {

    enum Action: String, CaseIterable, Sendable, Hashable {
        case reloadConfigurationVersion
        var requiresRunningPhase: Bool { true }
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
        }
    }
}


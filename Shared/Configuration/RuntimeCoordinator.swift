//
//  RuntimeCoordinator.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/5/26.
//

import Foundation

/// Turns "something the host changed" into the ordered work the running tunnel
/// has to do about it.
///
/// The extension reloads four things while it runs — the settings it reads from
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
/// The coordinator decides *what* to reload and *in which order*
/// (`TunnelStack+Runtime` performs the reloading, because that part needs the
/// running stack).
nonisolated enum RuntimeCoordinator {

    /// Something the host announced.
    enum Event: String, CaseIterable, Sendable, Hashable {
        /// The node list or the selected node changed.
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
        case reloadHostMappings
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
            case .reloadSettings, .reloadRouting, .reloadMITM, .reloadActiveConfiguration, .revalidateQUIC:
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
        case .activeConfiguration:
            return Plan(event: event, actions: [.reloadActiveConfiguration])
        case .settings:
            return Plan(event: event, actions: [.reloadHostMappings, .reloadSettings])
        case .routing:
            return Plan(event: event, actions: [.reloadRouting])
        case .mitm:
            return Plan(event: event, actions: [.reloadMITM, .revalidateQUIC])
        }
    }
}


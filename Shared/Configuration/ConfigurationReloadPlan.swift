//
//  ConfigurationReloadPlan.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// What activating a text configuration changes, and what the tunnel has to do
/// about it.
///
/// The classification follows the existing extension code, not a guess:
/// - `TunnelStack+Runtime.reloadSettings()` picks `TunnelSettings` fields up on
///   the live stack (`blockUDP`, `quicPolicy`, `blockWebRTC`, `preventDNSLeak`,
///   `hideVPNIcon`, tunnel routes) and only restarts the data plane for a
///   proxy-mode change, so those are `live` / `stackRestart`.
/// - `includeAllNetworks`, `excludeLocalNetworks`, APNs and cellular services are
///   written into the packet-tunnel preferences by `TunnelController` when it
///   connects, so changing them needs a reconnect from the host.
/// - DNS upstreams are read by the extension when its stack starts and the
///   resolver caches per process, so a change is only certain after a restart.
nonisolated struct ConfigurationReloadPlan: Equatable, Sendable {

    /// How much work a change costs.
    enum Scope: String, Comparable, Sendable {
        /// The running extension applies it by itself.
        case live
        /// The extension rebuilds its data plane in place.
        case stackRestart
        /// The host has to reconnect so the tunnel settings are rewritten.
        case reconnect

        var rank: Int {
            switch self {
            case .live: return 0
            case .stackRestart: return 1
            case .reconnect: return 2
            }
        }

        var title: String {
            switch self {
            case .live: return String(localized: "Applies immediately")
            case .stackRestart: return String(localized: "Restarts the tunnel data plane")
            case .reconnect: return String(localized: "Requires reconnect")
            }
        }

        static func < (lhs: Scope, rhs: Scope) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// One field the new document changes.
    struct Change: Equatable, Sendable, Identifiable {
        let field: String
        let scope: Scope
        let summary: String

        var id: String { field }
    }

    let changes: [Change]

    init(changes: [Change] = []) {
        self.changes = changes
    }

    var isEmpty: Bool { changes.isEmpty }

    /// The most demanding scope across all changes.
    var scope: Scope { changes.map(\.scope).max() ?? .live }

    var requiresReconnect: Bool { changes.contains { $0.scope == .reconnect } }
    var requiresStackRestart: Bool { changes.contains { $0.scope != .live } }

    func fields(in scope: Scope) -> [String] {
        changes.filter { $0.scope == scope }.map(\.field)
    }

    func contains(field: String) -> Bool {
        changes.contains { $0.field == field }
    }

    var summary: String {
        guard !changes.isEmpty else { return String(localized: "No settings changed.") }
        let live = fields(in: .live).count
        let restarts = fields(in: .stackRestart).count
        let reconnects = fields(in: .reconnect).count
        var parts: [String] = []
        if live > 0 { parts.append("\(live) live") }
        if restarts > 0 { parts.append("\(restarts) data-plane") }
        if reconnects > 0 { parts.append("\(reconnects) reconnect") }
        return "\(changes.count) setting(s) changed: \(parts.joined(separator: ", "))."
    }
}


// MARK: - Diffing

nonisolated extension ConfigurationReloadPlan {

    /// Compares what the engine is running now with what the document asks for.
    ///
    /// A key the document does not mention is not a change, so the current value
    /// stays in place. Both the field list and how much work each field costs come
    /// from the catalog, so a new setting is classified the moment it is declared.
    static func make(
        from previous: CompiledSettings,
        to current: CompiledSettings
    ) -> ConfigurationReloadPlan {
        var changes: [Change] = []

        for key in ConfigurationSettings.catalog {
            guard let new = current.values[key.name], previous.values[key.name] != new else { continue }
            changes.append(
                Change(
                    field: key.name,
                    scope: key.scope,
                    summary: "\(key.name): \(describe(previous.values[key.name])) → \(describe(new))"
                )
            )
        }

        // A value the catalog does not know can only come from a future document
        // read by this build; report it as live rather than dropping it.
        for (name, new) in current.values where ConfigurationSettings.key(named: name) == nil {
            guard previous.values[name] != new else { continue }
            changes.append(
                Change(
                    field: name,
                    scope: .live,
                    summary: "\(name): \(describe(previous.values[name])) → \(describe(new))"
                )
            )
        }

        return ConfigurationReloadPlan(changes: changes.sorted { $0.field < $1.field })
    }

    private static func describe(_ value: ConfigurationSettingValue?) -> String {
        guard let value else { return String(localized: "unset") }
        switch value {
        case .flag(let flag):
            return flag ? "true" : "false"
        case .text(let text):
            return text.isEmpty ? String(localized: "empty") : text
        case .list(let items):
            return items.isEmpty ? String(localized: "empty") : items.joined(separator: ",")
        }
    }
}

// MARK: - Extension confirmation

/// App-side view of the extension's report. The record itself lives in
/// `EngineConfirmation.swift` so the extension can write it without linking the
/// configuration compiler or this store.
nonisolated extension ConfigurationSnapshotStore {

    func confirmation() -> ConfigurationEngineConfirmation? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("engine-confirmation.json")) else { return nil }
        return try? JSONDecoder().decode(ConfigurationEngineConfirmation.self, from: data)
    }

    func clearConfirmation() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("engine-confirmation.json"))
    }

    /// True when the extension confirmed the snapshot the manifest points at.
    func isActiveSnapshotConfirmed() -> Bool {
        guard let activeId = manifest().activeSnapshotId else { return false }
        guard let confirmation = confirmation(), confirmation.scope == .configuration else { return false }
        return confirmation.snapshotId == activeId
    }
}



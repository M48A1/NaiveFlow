//
//  LiveTunnelProvider.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/3/26.
//

import Foundation
import NetworkExtension

@MainActor
final class LiveTunnelProvider: TunnelProviding {
    static let providerBundleIdentifier = "com.argsment.NaiveFlow.Network-Extension"

    private var manager: NETunnelProviderManager?
    private var loadedFromPreferences = false
    private let sequencer = TunnelStartSequencer()

    var status: NEVPNStatus {
        guard let manager, loadedFromPreferences else { return .disconnected }
        return manager.connection.status
    }

    func prepare() async {
        guard manager == nil else { return }
        let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = Self.preferredManager(in: managers ?? []) {
            manager = existing
            loadedFromPreferences = true
        } else {
            manager = NETunnelProviderManager()
        }
    }

    /// Ignore other providers and prefer our live session over stale saved profiles.
    static func preferredManager(
        in managers: [NETunnelProviderManager],
        status: (NETunnelProviderManager) -> NEVPNStatus = { $0.connection.status }
    ) -> NETunnelProviderManager? {
        let matching = managers.filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
        }
        return matching.first { status($0) == .connected }
            ?? matching.first { status($0) == .reasserting || status($0) == .connecting }
            ?? matching.first
    }

    func statusUpdates() -> AsyncStream<NEVPNStatus> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await note in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange) {
                    guard let self else { break }
                    guard let connection = note.object as? NEVPNConnection,
                          connection === self.manager?.connection else { continue }
                    continuation.yield(connection.status)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func start(_ request: TunnelStartRequest) async throws {
        guard let manager else { return }
        let token = sequencer.begin()

        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = Self.providerBundleIdentifier
        tunnelProtocol.serverAddress = "NaiveFlow"
        #if !os(tvOS)
        tunnelProtocol.includeAllNetworks = request.includeAllNetworks
        tunnelProtocol.excludeLocalNetworks = request.excludeLocalNetworks
        tunnelProtocol.excludeAPNs = request.excludeAPNs
        tunnelProtocol.excludeCellularServices = request.excludeCellularServices
        tunnelProtocol.excludeDeviceCommunication = request.excludeDeviceCommunication
        #endif

        try await sequencer.perform { [weak self] in
            // A disconnect may have superseded this start before the preference
            // write even began.
            guard let self, self.sequencer.isCurrent(token) else { return }

            manager.protocolConfiguration = tunnelProtocol
            manager.localizedDescription = "NaiveFlow"
            manager.isEnabled = true

            if request.alwaysOn {
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]
                manager.isOnDemandEnabled = true
            } else {
                manager.isOnDemandEnabled = false
                manager.onDemandRules = nil
            }

            try await manager.saveToPreferences()
            // Saving suspends; a stop/disconnect can land here. Re-check before
            // reloading and before dialing so we never "stop then start".
            guard self.sequencer.isCurrent(token), !Task.isCancelled else { return }
            try await manager.loadFromPreferences()
            guard self.sequencer.isCurrent(token), !Task.isCancelled else { return }
            self.loadedFromPreferences = true
            try manager.connection.startVPNTunnel()
        }
    }

    func stop(disablingAlwaysOn: Bool) async {
        // Invalidate any in-flight start first so its post-await guards bail.
        sequencer.stop()
        guard let manager else { return }
        try? await sequencer.perform {
            if disablingAlwaysOn, manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                try? await manager.saveToPreferences()
            }
            manager.connection.stopVPNTunnel()
        }
    }

    func send(_ data: Data) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        let timeout: Duration?
        if case .fetchRequests? = try? JSONDecoder().decode(TunnelMessage.self, from: data) {
            timeout = .seconds(3)
        } else {
            timeout = nil
        }
        return await ProviderMessageConcurrencyBridge.send(data, over: session, timeout: timeout)
    }
}

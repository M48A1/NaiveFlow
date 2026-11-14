//
//  TunnelController.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/3/26.
//

import Foundation
import NetworkExtension
import Observation

nonisolated private let logger = NaiveFlowLogger(category: "TunnelController")

@MainActor
@Observable
final class TunnelController {
    private(set) var rawStatus: NEVPNStatus = .disconnected
    var status: VPNStatus { VPNStatus(rawStatus) }
    var hasRunningTunnel: Bool { rawStatus == .connected || rawStatus == .connecting || rawStatus == .reasserting }
    private(set) var isManagerReady = false
    var startError: String?
    private(set) var pendingReconnect = false

    @ObservationIgnored private let provider: TunnelProviding
    @ObservationIgnored private var statusObserver: Task<Void, Never>?
    @ObservationIgnored private var reassertingDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var publishQueue: Task<Void, Never>?
    /// In-flight connect preparation. Disconnect/reconnect bump `intentGeneration`
    /// and cancel this task so a preparation still awaiting cannot start the
    /// tunnel after the user asked to stop (the "stop then start" race).
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var intentGeneration: UInt64 = 0
    /// Test seam (mirrors the publisher's overrides): awaited after the connect's
    /// preferences load and before `start`, so a test can interleave a disconnect.
    @ObservationIgnored var connectPreparationOverride: (@MainActor () async throws -> Void)? = nil
    private static let reassertingDebounceInterval: Duration = .seconds(5)

    init(provider: TunnelProviding) {
        self.provider = provider
    }

    deinit {
        statusObserver?.cancel()
        reassertingDebounceTask?.cancel()
        connectTask?.cancel()
    }

    func start() {
        guard statusObserver == nil else { return }
        statusObserver = Task { [weak self, provider] in
            await provider.prepare()
            if let self {
                self.rawStatus = provider.status
                self.isManagerReady = true
            }
            for await status in provider.statusUpdates() {
                guard !Task.isCancelled, let self else { return }
                self.handleStatusChange(status)
            }
        }
    }

    // MARK: - Actions

    func connect(using configuration: ProxyConfiguration) {
        guard isManagerReady else { return }
        intentGeneration &+= 1
        let generation = intentGeneration
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            if let head = try? RuntimeBundleStore().head(),
               let version = try? RuntimeBundleStore().load(head.current) {
                AWCore.installRuntimePreferences(version.preferences)
            }
            guard let self else { return }
            await self.publish(configuration, refreshingIP: true)
            // The user may have disconnected while the publication was in flight.
            guard !Task.isCancelled, self.intentGeneration == generation else { return }
            do {
                try await self.connectPreparationOverride?()
            } catch {
                return
            }
            guard !Task.isCancelled, self.intentGeneration == generation else { return }

            var request = TunnelStartRequest()
            #if !os(tvOS)
            request.includeAllNetworks = AWCore.getTunnelIncludeAllNetworks()
            request.excludeLocalNetworks = AWCore.getTunnelExcludeLocalNetworks()
            request.excludeAPNs = AWCore.getTunnelExcludeAPNs()
            request.excludeCellularServices = AWCore.getTunnelExcludeCellularServices()
            request.excludeDeviceCommunication = AWCore.getTunnelExcludeDeviceCommunication()
            #endif
            request.alwaysOn = AWCore.getAlwaysOnEnabled()
            do {
                try await self.provider.start(request)
            } catch {
                self.startError = error.localizedDescription
            }
        }
    }

    func disconnect() {
        pendingReconnect = false
        // Invalidate any in-flight connect preparation, then stop.
        intentGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        Task { await provider.stop(disablingAlwaysOn: true) }
    }
    
    func reconnect() {
        guard rawStatus == .connected || rawStatus == .connecting else { return }
        pendingReconnect = true
        // A pending connect must not race the reconnect's stop/start.
        intentGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        Task { await provider.stop(disablingAlwaysOn: true) }
    }
    
    func consumePendingReconnect() -> Bool {
        guard pendingReconnect else { return false }
        pendingReconnect = false
        return true
    }

    // MARK: - Active Configuration
    
    func publish(_ configuration: ProxyConfiguration?, refreshingIP: Bool = false) async {
        let previous = publishQueue
        let task = Task {
            await previous?.value
            await Self.reconcileActiveConfiguration(configuration, refreshingIP: refreshingIP)
        }
        publishQueue = task
        await task.value
    }

    nonisolated private static func reconcileActiveConfiguration(
        _ configuration: ProxyConfiguration?,
        refreshingIP: Bool
    ) async {
        guard let configuration else {
            guard AWCore.getActiveConfigurationData() != nil else { return }
            try? ActiveConfiguration.store(nil)
            return
        }

        let stored = try? ActiveConfiguration.load()
        if !refreshingIP, let stored,
           stored.withResolvedIP(nil) == configuration.withResolvedIP(nil) {
            return
        }

        let resolved: ProxyConfiguration
        if configuration.chain?.isEmpty == false || configuration.isDirect {
            resolved = configuration
        } else {
            let resolvedIP = await DNSResolver.proxies.resolveHost(configuration.serverAddress, forceFresh: refreshingIP)
            resolved = configuration.withResolvedIP(resolvedIP ?? configuration.resolvedIP)
        }
        do {
            try ActiveConfiguration.store(resolved)
        } catch {
            logger.report("[Tunnel] Active configuration encode failed", error: error)
            return
        }
    }

    /// Apply a complete version. Connection-level NE preferences participate by
    /// reconnecting the provider; ordinary module changes use one provider IPC.
    func applyRuntimeVersion(_ bundle: RuntimeConfigurationBundle, requireRunning: Bool) async throws -> RuntimeConfigurationReceipt? {
        await provider.prepare()
        let wasUp = provider.status == .connected || provider.status == .connecting || provider.status == .reasserting
        guard wasUp || requireRunning else { return nil }
        let started = Date()
        let statusData = await send(.fetchRuntimeStatus)
        let runtimeStatus = statusData.flatMap { try? JSONDecoder().decode(RuntimeCoordinator.Status.self, from: $0) }
        let activeID = runtimeStatus?.versionID.flatMap(UUID.init(uuidString:))
        let oldBundle = (activeID ?? bundle.parentID).flatMap { try? RuntimeBundleStore().load($0) }
        let reconnectKeys = ["alwaysOnEnabled", "tunnelIncludeAllNetworks", "tunnelExcludeLocalNetworks",
            "tunnelExcludeAPNs", "tunnelExcludeCellularServices", "tunnelExcludeDeviceCommunication"]
        let reconnect = !wasUp || runtimeStatus?.phase != "running"
            || reconnectKeys.contains { oldBundle?.preferences[$0] != bundle.preferences[$0] }
        AWCore.installRuntimePreferences(bundle.preferences)
        if reconnect {
            pendingReconnect = false
            await provider.stop(disablingAlwaysOn: true)
            let stopDeadline = Date().addingTimeInterval(15)
            while provider.status != .disconnected && provider.status != .invalid {
                guard Date() < stopDeadline else { throw RuntimeConfigurationFailure.unavailable }
                try await Task.sleep(for: .milliseconds(100))
            }
            var request = TunnelStartRequest()
            #if !os(tvOS)
            request.includeAllNetworks = AWCore.getTunnelIncludeAllNetworks()
            request.excludeLocalNetworks = AWCore.getTunnelExcludeLocalNetworks()
            request.excludeAPNs = AWCore.getTunnelExcludeAPNs()
            request.excludeCellularServices = AWCore.getTunnelExcludeCellularServices()
            request.excludeDeviceCommunication = AWCore.getTunnelExcludeDeviceCommunication()
            #endif
            request.alwaysOn = AWCore.getAlwaysOnEnabled()
            try await provider.start(request)
        } else if let data = await send(.applyRuntimeVersion(bundle.id)),
                  let receipt = try? JSONDecoder().decode(RuntimeConfigurationReceipt.self, from: data) {
            return receipt
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let receipt = try RuntimeBundleStore().receipt(bundle.id), receipt.date >= started,
               receipt.requestID == (try RuntimeBundleStore().head()?.requestID) {
                return receipt
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RuntimeConfigurationFailure.unavailable
    }

    // MARK: - Provider IPC

    func send(_ message: TunnelMessage) async -> Data? {
        guard let data = try? JSONEncoder().encode(message) else { return nil }
        return await provider.send(data)
    }

    func sendRaw(_ data: Data) async -> Data? {
        await provider.send(data)
    }

    // MARK: - Status Pipeline

    private func handleStatusChange(_ status: NEVPNStatus) {
        reassertingDebounceTask?.cancel()
        reassertingDebounceTask = nil

        if status == .reasserting, rawStatus == .connected {
            reassertingDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.reassertingDebounceInterval, precision: .relaxed)
                guard !Task.isCancelled, let self else { return }
                // Re-check the live status: apply only if it never recovered.
                guard self.provider.status == .reasserting else { return }
                self.rawStatus = .reasserting
            }
            return
        }

        rawStatus = status
    }
}

extension TunnelController: LatencyTransport {
    var isTunnelActive: Bool { rawStatus == .connected }
}

extension NEVPNStatus {
    var isTransitioning: Bool {
        self == .connecting || self == .disconnecting || self == .reasserting
    }
}

extension VPNStatus {
    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid: self = .invalid
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reasserting: self = .reasserting
        case .disconnecting: self = .disconnecting
        @unknown default: self = .invalid
        }
    }
}

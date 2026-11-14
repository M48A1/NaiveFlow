//
//  PacketTunnelProvider.swift
//  NaiveFlow
//
//  Created by NodePassProject on 1/23/26.
//

import NetworkExtension
import Network
import Synchronization
#if os(iOS)
import WidgetKit
#endif

nonisolated private let logger = NaiveFlowLogger(category: "PacketTunnelProvider")

nonisolated class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let tunnelStack = TunnelStack()
    private let statsRecorder = StatsRecorder()

    private let pathMonitorBridge = PathMonitorConcurrencyBridge()

    private enum Phase: PhaseTransitionable {
        case idle
        case starting
        case running
        case stopping
        case stopped

        static func canTransition(from old: Phase, to new: Phase) -> Bool {
            switch (old, new) {
            case (.idle, .starting),
                 (.stopped, .starting),
                 (.starting, .running),
                 (.starting, .stopped),
                 (.idle, .stopping),
                 (.starting, .stopping),
                 (.running, .stopping),
                 (.stopped, .stopping),
                 (.stopping, .stopped):
                return true
            default:
                return false
            }
        }
    }
    private struct ProviderState: PhaseHolding {
        var phase: Phase = .idle
        var rootTask: Task<Void, Never>?
        var claimGeneration: UInt64 = 0
        var lanProxy: LANProxyServer?
    }
    private let providerState = Mutex(ProviderState())

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String : NSObject]? = nil) async throws {
        enum Claim { case proceed(UInt64), alreadyUp, superseded }
        let claim: Claim = providerState.withLock { state in
            switch state.phase {
            case .idle, .stopped:
                state.transition(to: .starting)
                state.claimGeneration += 1
                return .proceed(state.claimGeneration)
            case .starting, .running:
                return .alreadyUp
            case .stopping:
                return .superseded
            }
        }
        let myClaim: UInt64
        switch claim {
        case .proceed(let generation):
            myClaim = generation
        case .alreadyUp:
            return
        case .superseded:
            throw NaiveFlowError.tunnel(.sessionUnavailable)
        }

        let resolved: ProxyConfiguration?
        do { resolved = try await tunnelStack.prepareStartupVersion() }
        catch {
            releaseStartClaim(myClaim)
            throw error
        }
        guard var configuration = resolved else {
            let error = NaiveFlowError.tunnel(.invalidConfiguration)
            logger.report("[VPN] Start failed", error: error)
            releaseStartClaim(myClaim)
            throw error
        }

        do {
            do { try await applyTunnelSettings() }
            catch {
                guard let restored = try await tunnelStack.restoreStartupVersion(after: error) else { throw error }
                configuration = restored
                try await applyTunnelSettings()
            }
        } catch {
            let wrapped = NaiveFlowError.tunnel(.settingsApplyFailed(underlying: error))
            logger.report("[VPN] Start failed", error: wrapped)
            releaseStartClaim(myClaim)
            throw wrapped
        }

        guard providerState.withLock({ $0.phase == .starting && $0.claimGeneration == myClaim }) else {
            throw NaiveFlowError.tunnel(.sessionUnavailable)
        }

#if os(iOS)
        ControlCenter.shared.reloadControls(ofKind: "com.argsment.NaiveFlow.Widget.VPNToggle")
#endif

        let stackStarted = await tunnelStack.start(packetFlow: packetFlow, configuration: configuration)

        var installed: Bool = providerState.withLock { state in
            guard state.claimGeneration == myClaim, stackStarted,
                  state.transition(to: .running) else { return false }
            return true
        }
        if installed {
            enum Install { case adopted, taskAlreadyPresent, superseded }
            let rootTask = Task { await self.run() }
            let outcome: Install = providerState.withLock { state in
                guard state.phase == .running, state.claimGeneration == myClaim else { return .superseded }
                guard state.rootTask == nil else { return .taskAlreadyPresent }
                state.rootTask = rootTask
                return .adopted
            }
            switch outcome {
            case .adopted:
                startStatsRecorder(claim: myClaim)
            case .taskAlreadyPresent:
                rootTask.cancel()
                startStatsRecorder(claim: myClaim)
            case .superseded:
                rootTask.cancel()
                installed = false
            }
        }
        if installed {
            do { try await tunnelStack.confirmStartedVersion() }
            catch {
                let task = providerState.withLock { state in
                    state.transition(to: .stopping)
                    defer { state.rootTask = nil }
                    return state.rootTask
                }
                task?.cancel()
                await tunnelStack.stop()
                providerState.withLock { state in
                    if state.phase == .stopping { state.transition(to: .stopped) }
                }
                throw error
            }
        }
        guard installed else {
            releaseStartClaim(myClaim)
            if stackStarted {
                await tunnelStack.stop()
            }
            throw NaiveFlowError.tunnel(.sessionUnavailable)
        }
        refreshLANProxy(claim: myClaim)
    }

    private func refreshLANProxy(claim: UInt64? = nil) {
        providerState.withLock { state in
            guard state.phase == .running, claim == nil || state.claimGeneration == claim else { return }
            let old = state.lanProxy
            state.lanProxy = LANProxyServer.makeIfEnabled(
                settings: LANProxySettings.load(), profileAllowed: AWCore.getLANProxyAllowed()
            ) { [tunnelStack] in tunnelStack.udpConfig().configuration }
            old?.cancel()
            state.lanProxy?.start()
        }
    }

    private func startStatsRecorder(claim: UInt64) {
        statsRecorder.start { [tunnelStack] in
            return StatsRecorder.RawValues(
                byteCounts: tunnelStack.byteCountsSnapshot(),
                tcpConnectionCount: FlowGauge.tcpTable,
                udpConnectionCount: FlowGauge.udpTable,
                memoryBytes: Self.memoryFootprint()
            )
        }
        let stillRunning = providerState.withLock { $0.phase == .running && $0.claimGeneration == claim }
        if !stillRunning {
            statsRecorder.stop()
        }
    }

    @discardableResult
    private func releaseStartClaim(_ claim: UInt64) -> Bool {
        providerState.withLock { state in
            guard state.claimGeneration == claim else { return false }
            if state.phase == .starting { state.transition(to: .stopped) }
            return true
        }
    }

    private func resolveStartConfiguration() -> ProxyConfiguration? {
        do {
            return try ActiveConfiguration.load()
        } catch {
            logger.report(NaiveFlowError.store(.corrupted(.configurations, detail: NaiveFlowError.describe(error))))
            return nil
        }
    }

    // MARK: - Tunnel Settings

    private let discoveredMTU = Mutex<Int?>(nil)

    private func applyTunnelSettings() async throws {
        if let mtu = discoveredMTU.withLock({ $0 }) {
            try await setTunnelNetworkSettings(buildTunnelSettings(mtu: mtu))
            return
        }
        var mtu = TunnelConstants.fallbackMTU
        for candidate in TunnelConstants.tunnelMTUCandidates {
            guard (try? await setTunnelNetworkSettings(buildTunnelSettings(mtu: candidate))) != nil,
                  Self.interfaceMTU(forAddress: TunnelAddress.ipv4) == candidate else { continue }
            mtu = candidate
            break
        }
        if mtu == TunnelConstants.fallbackMTU {
            try await setTunnelNetworkSettings(buildTunnelSettings(mtu: mtu))
        }
        discoveredMTU.withLock { $0 = mtu }
    }

    private static func interfaceMTU(forAddress address: String) -> Int? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var mtus: [String: Int] = [:]
        var owner: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let name = String(cString: entry.pointee.ifa_name)
            guard let socketAddress = entry.pointee.ifa_addr else { continue }
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_LINK:
                if let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    mtus[name] = Int(data.pointee.ifi_mtu)
                }
            case AF_INET:
                var ipv4 = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    if String(decoding: bytes, as: UTF8.self) == address {
                        owner = name
                    }
                }
            default:
                break
            }
        }
        guard let owner else { return nil }
        return mtus[owner]
    }

    private func buildTunnelSettings(mtu: Int) -> NEPacketTunnelNetworkSettings {
        let tunnelAddressIPv4 = TunnelAddress.ipv4
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelAddressIPv4)

        let hideVPNIcon = AWCore.getHideVPNIcon()
        let reflectionEnabled = AWCore.getReflectionEnabled()
        let includedRoutes = Self.parseRoutes(AWCore.getTunnelIncludedRoutes())
        let excludedRoutes = Self.parseRoutes(AWCore.getTunnelExcludedRoutes())

        let ipv4Settings = NEIPv4Settings(addresses: [tunnelAddressIPv4], subnetMasks: ["255.255.255.0"])
        var includedIPv4Routes = [NEIPv4Route.default()] + includedRoutes
        if reflectionEnabled {
            includedIPv4Routes.append(NEIPv4Route(destinationAddress: TunnelAddress.reflection, subnetMask: "255.255.255.255"))
        }
        ipv4Settings.includedRoutes = includedIPv4Routes
        var excludedIPv4Routes = excludedRoutes
        if hideVPNIcon {
            excludedIPv4Routes.append(NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "255.255.255.254"))
        }
        ipv4Settings.excludedRoutes = excludedIPv4Routes
        settings.ipv4Settings = ipv4Settings

        // Capture the unsupported family solely to discard it at packet intake.
        // Removing this route would let applications bypass the IPv4 tunnel.
        let blocked = NEIPv6Settings(addresses: ["fd00:6e61:6976::1"], networkPrefixLengths: [128])
        blocked.includedRoutes = [NEIPv6Route.default()]
        blocked.excludedRoutes = []
        settings.ipv6Settings = blocked

        settings.dnsSettings = NEDNSSettings(servers: [tunnelAddressIPv4])
        settings.mtu = NSNumber(value: mtu)

        return settings
    }

    private static func parseRoutes(_ strings: [String]) -> [NEIPv4Route] {
        strings.compactMap(IPRoute.init).map { route in
            NEIPv4Route(destinationAddress: dottedQuad(route.network), subnetMask: dottedQuad(route.mask))
        }
    }

    private static func dottedQuad(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    private func reapplyTunnelSettings() async {
        do {
            try await applyTunnelSettings()
        } catch {
            guard !Task.isCancelled else { return }
            logger.report("[VPN] Tunnel settings apply failed", error: error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
#if os(iOS)
        ControlCenter.shared.reloadControls(ofKind: "com.argsment.NaiveFlow.Widget.VPNToggle")
#endif

        let task: Task<Void, Never>? = providerState.withLock { state in
            state.transition(to: .stopping)
            defer { state.rootTask = nil }
            return state.rootTask
        }

        let lan = providerState.withLock { state in
            defer { state.lanProxy = nil }
            return state.lanProxy
        }
        lan?.cancel()
        statsRecorder.stop()
        MITMScriptDiskStore.shared.flush()
        task?.cancel()

        logTunnelStop(reason: reason)

        await tunnelStack.stop()

        providerState.withLock { state in
            if state.phase == .stopping { state.transition(to: .stopped) }
        }
    }

    // MARK: - App Messages

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        let message: TunnelMessage
        do {
            message = try JSONDecoder().decode(TunnelMessage.self, from: messageData)
        } catch {
            logger.report("[IPC] Message decode failed", error: error)
            return nil
        }

        switch message {
        case .testLatency(let configuration):
            let response = LatencyTestResponse(await LatencyTester.test(configuration))
            return encodeReply(response)

        case .testLatencyWithSettings(let configuration, let settings):
            let response = LatencyTestResponse(await LatencyTester.test(configuration, target: settings.target, timeout: settings.timeout))
            return encodeReply(response)

        case .applyRuntimeVersion(let id):
            return await applyPublishedVersion(id)

        case .updateLatencyTestSettings(let settings):
            await tunnelStack.updateLatencyTestSettings(settings)
            return encodeReply(true)

        case .fetchRuntimeStatus:
            return encodeReply(await tunnelStack.runtimeStatus())

        case .fetchStats:
            return encodeReply(statsRecorder.snapshot())

        case .resetStats:
            tunnelStack.resetByteCounts()
            statsRecorder.reset()
            return encodeReply(statsRecorder.snapshot())

        case .fetchPolicyGroups:
            return encodeReply(await tunnelStack.policyGroupsResponse())

        case .clearLogs:
            tunnelStack.clearLogs()
            return encodeReply(LogsResponse(logs: []))

        case .fetchLogs:
            return encodeReply(LogsResponse(logs: tunnelStack.fetchLogs()))

        case .fetchRequests:
            let requests = tunnelStack.requestLog.snapshot()
            let ids = Set(requests.compactMap(\.activityID))
            let activities = (tunnelStack.tcpActivity.snapshot() + tunnelStack.udpActivity.snapshot())
                .filter { ids.contains($0.id) }
            return encodeReply(RequestsResponse(requests: requests, activities: activities))

        }
    }

    private func applyPublishedVersion(_ id: UUID) async -> Data? {
        do {
            let bundle = try RuntimeBundleStore().load(id)
            let receipt = try await tunnelStack.applyVersion(bundle) { [self] preferences in
                let capture = RuntimePreferenceCapture(preferences)
                try await RuntimePreferenceContext.$capture.withValue(capture) {
                    try await self.applyTunnelSettings()
                }
            }
            if receipt.status == .applied { refreshLANProxy() }
            return encodeReply(receipt)
        } catch RuntimeConfigurationFailure.rollbackFailed {
            cancelTunnelWithError(RuntimeConfigurationFailure.rollbackFailed)
            return encodeReply(RuntimeConfigurationReceipt(versionID: id, activeVersionID: nil,
                snapshotID: nil, status: .rejected, message: RuntimeConfigurationFailure.rollbackFailed.localizedDescription))
        } catch RuntimeConfigurationFailure.reconnectRequired {
            return nil
        } catch RuntimeConfigurationFailure.busy {
            // Another request already performs this transition; the host polls
            // the durable receipt rather than treating duplication as rejection.
            return nil
        } catch {
            let receipt = RuntimeConfigurationReceipt(versionID: id, activeVersionID: nil,
                snapshotID: nil, status: .rejected, message: error.localizedDescription)
            try? RuntimeBundleStore().record(receipt)
            return encodeReply(receipt)
        }
    }

    private func encodeReply(_ reply: some Encodable) -> Data? {
        do {
            return try JSONEncoder().encode(reply)
        } catch {
            logger.report("[IPC] Reply encode failed", error: error)
            return nil
        }
    }

    private static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    override func sleep() async {
        statsRecorder.noteSleep()
        MITMScriptDiskStore.shared.flush()
        await tunnelStack.sleep()
        TickScheduler.shared.suspend()
    }

    override func wake() {
        statsRecorder.noteWake()
        TickScheduler.shared.resume()
    }

    // MARK: - Provider task tree

    private func run() async {
        await withDiscardingTaskGroup { group in
            group.addTask { [reapplySignal = tunnelStack.reapplySettingsSignal] in
                for await _ in reapplySignal {
                    if let head = try? RuntimeBundleStore().head() {
                        _ = await self.applyPublishedVersion(head.current)
                    } else { await self.reapplyTunnelSettings() }
                }
            }
            group.addTask {
                for await path in self.pathMonitorBridge.paths() {
                    guard path.status == .satisfied else { continue }
                    await self.resolveAndUpdateNetworkContext(path)
                }
            }
        }
    }

    // MARK: - Path Monitoring

    private func resolveAndUpdateNetworkContext(_ path: Network.NWPath) async {
        DNSResolver.proxies.flush()
        ECHResolver.shared.flush()

        let primaryType = path.availableInterfaces.first?.type
        let isWiFi = primaryType == .wifi
        let isCellular = primaryType == .cellular
#if os(iOS)
        if isWiFi {
            let ssid = await pathMonitorBridge.currentWiFiSSID()
            await tunnelStack.updateNetworkContext(
                NetworkContext(
                    isWiFi: true, isCellular: false, ssid: ssid
                )
            )
            return
        }
#endif
        await tunnelStack.updateNetworkContext(
            NetworkContext(
                isWiFi: isWiFi, isCellular: isCellular, ssid: nil
            )
        )
    }

    private func logTunnelStop(reason: NEProviderStopReason) {
        let failure: String
        switch reason {
        case .providerFailed: failure = "provider failed"
        case .configurationFailed: failure = "configuration failed"
        case .connectionFailed: failure = "connection failed"
        case .internalError: failure = "internal error"
        default: return
        }
        logger.error("[VPN] Tunnel stopped: \(failure)")
    }
}

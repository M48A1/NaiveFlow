//
//  UDPPlane.swift
//  NaiveFlow
//
//  Created by NodePassProject on 7/17/26.
//

import Foundation
import Synchronization
import NaiveFlowIP

nonisolated private let logger = NaiveFlowLogger(category: "UDPPlane")

nonisolated enum UDPPlaneCommand {
    case setMultiplexerPool((any UDPMultiplexerPool)?)
    case revalidateQUIC
    case reclaim
}

actor UDPPlane {
    private unowned let stack: TunnelStack

    // MARK: Registry / session state

    private var flows: [TunnelStack.UDPFlowKey: UDPFlow] = [:] {
        didSet { FlowGauge.publishUDPTable(flows.count) }
    }

    private var cleanupDeadline: TimeInterval?
    
    nonisolated private let bufferLedger = UDPBufferLedger(budget: TunnelConstants.udpGlobalBufferBudget)

    private var udpPressureLog = PressureEventThrottle(message: "[UDP] Flow table full")

    private struct PendingDatagrams {
        let generation: UInt64
        var datagrams: [InboundDatagram] = []
        var byteCount = 0
    }
    private var pendingResolutions: [TunnelStack.UDPFlowKey: PendingDatagrams] = [:]

    private struct PendingSniff {
        var sniffer: QUICClientHelloSniffer
        var datagrams: [InboundDatagram] = []
        var byteCount = 0
        let generation: UInt64
    }
    private var pendingSniffs: [TunnelStack.UDPFlowKey: PendingSniff] = [:]
    private var sniffGeneration: UInt64 = 0
    private var pendingSniffCapWarned = false

    private struct QUICBlock {
        enum Cause {
            case policy
            case mitm(host: String)
            case proxied(RouteTarget)
            case rejected
        }
        let cause: Cause
        var deadline: TimeInterval
    }
    private var quicBlocks: [TunnelStack.UDPFlowKey: QUICBlock] = [:]

    private enum SniffStage {
        case pending
        case done(serverName: String?)
    }

    private var ssSessions: [UUID: ShadowsocksUDPSession] = [:]

    private var multiplexerPoolStorage: (any UDPMultiplexerPool)?

    private var pendingResolutionCapWarned = false

    init(stack: TunnelStack) {
        self.stack = stack
    }

    // MARK: - Multiplexer pool

    var multiplexerPool: (any UDPMultiplexerPool)? { multiplexerPoolStorage }

    func apply(_ command: UDPPlaneCommand) {
        switch command {
        case .setMultiplexerPool(let pool):
            multiplexerPoolStorage = pool
        case .revalidateQUIC:
            revalidateQUIC()
        case .reclaim:
            reclaim()
        }
    }

    // MARK: - Intake

    private struct FlowBatch {
        let flow: UDPFlow
        var payloads: [Data]
    }

    func feed(_ datagrams: [InboundDatagram]) async {
        guard !stack.configurationTransition.load(ordering: .acquiring) else { return }
        let generation = stack.dataPlaneGeneration.load(ordering: .acquiring)
        let udpConfig = stack.udpConfig()
        var batches: [FlowBatch] = []
        for datagram in datagrams {
            guard generation == stack.dataPlaneGeneration.load(ordering: .acquiring), stack.publishedPhase.load(ordering: .relaxed) == .running,
                  !stack.configurationTransition.load(ordering: .acquiring) else { break }
            if let flow = openFlow(for: datagram, udpConfig: udpConfig) {
                if let index = batches.firstIndex(where: { $0.flow === flow }) {
                    batches[index].payloads.append(datagram.payload)
                } else {
                    batches.append(FlowBatch(flow: flow, payloads: [datagram.payload]))
                }
                continue
            }
            await deliver(&batches)
            await handleInboundUDP(datagram)
        }
        await deliver(&batches)
    }

    private func openFlow(for datagram: InboundDatagram, udpConfig: TunnelStack.UDPConfig) -> UDPFlow? {
        let destination = datagram.destination
        if destination.port == 53 || udpConfig.blockUDP { return nil }
        if destination.port == 443 && udpConfig.quicPolicy.blocksAllQUIC { return nil }
        if udpConfig.blockWebRTC && TunnelStack.isSTUNMessage(datagram.payload) { return nil }
        guard let flow = flows[TunnelStack.UDPFlowKey(datagram)], !flow.isClosed else { return nil }
        return flow
    }

    private func deliver(_ batches: inout [FlowBatch]) async {
        for batch in batches {
            guard !stack.configurationTransition.load(ordering: .acquiring) else { break }
            await batch.flow.handleReceivedData(batch.payloads)
        }
        batches.removeAll(keepingCapacity: true)
    }

    private func deferUntilResolved(
        _ datagram: InboundDatagram,
        flowKey: TunnelStack.UDPFlowKey,
        domain: String
    ) -> Bool {
        if var pending = pendingResolutions[flowKey] {
            guard pending.byteCount + datagram.payload.count <= TunnelConstants.udpPendingResolutionMaxBytes
                    else { return true }
            pending.datagrams.append(datagram)
            pending.byteCount += datagram.payload.count
            pendingResolutions[flowKey] = pending
            return true
        }

        guard pendingResolutions.count < TunnelLimits.udpMaxPendingResolutions else {
            if !pendingResolutionCapWarned {
                pendingResolutionCapWarned = true
                logger.warning("[UDP] Pending-resolution table full")
            }
            return false
        }

        let generation = stack.dataPlaneGeneration.load(ordering: .acquiring)
        pendingResolutions[flowKey] = PendingDatagrams(generation: generation, datagrams: [datagram],
                                                       byteCount: datagram.payload.count)
        Task { [weak self] in
            _ = await DNSResolver.localRequests.resolveHost(domain, family: .ipv4)
            await self?.resumeAfterResolution(flowKey: flowKey, generation: generation)
        }
        return true
    }

    private func resumeAfterResolution(flowKey: TunnelStack.UDPFlowKey, generation: UInt64) async {
        guard generation == stack.dataPlaneGeneration.load(ordering: .acquiring),
              let pending = pendingResolutions[flowKey], pending.generation == generation else { return }
        pendingResolutions.removeValue(forKey: flowKey)
        if pendingResolutionCapWarned, pendingResolutions.count <= TunnelLimits.udpMaxPendingResolutions / 2 {
            pendingResolutionCapWarned = false
        }
        for datagram in pending.datagrams {
            guard stack.publishedPhase.load(ordering: .relaxed) == .running,
                  !stack.configurationTransition.load(ordering: .acquiring) else { return }
            await handleInboundUDP(datagram, awaitedResolution: true)
        }
    }

    private func handleInboundUDP(
        _ datagram: InboundDatagram,
        awaitedResolution: Bool = false,
        sniff: SniffStage = .pending
    ) async {
        guard !stack.configurationTransition.load(ordering: .acquiring) else { return }
        let payload = datagram.payload
        let dstAddress = datagram.destination.address
        let dstPort = datagram.destination.port

        let udpConfig = stack.udpConfig()

        if dstPort == 53 {
            if TunnelStack.dnsDestination(
                for: dstAddress.description, exempting: udpConfig.interceptExemptDNSServers
            ) != nil {
                if await handleDNSQuery(datagram) {
                    return
                }
            }
        }

        if udpConfig.blockUDP && dstPort != 53 {
            stack.sendICMPPortUnreachable(rejecting: datagram)
            return
        }

        let isQUIC = Self.isQUIC(payload, port: dstPort)
        let flowKey = TunnelStack.UDPFlowKey(datagram)

        if isQUIC && udpConfig.quicPolicy.blocksAllQUIC {
            blockQUIC(datagram, flowKey: flowKey, cause: .policy)
            return
        }

        if udpConfig.blockWebRTC && TunnelStack.isSTUNMessage(payload) {
            stack.sendICMPPortUnreachable(rejecting: datagram)
            return
        }

        if let flow = flows[flowKey] {
            if !flow.isClosed {
                await flow.handleReceivedData([payload])
                return
            }
            flows.removeValue(forKey: flowKey)
        }

        if replyToBlockedQUIC(datagram, flowKey: flowKey) {
            return
        }

        if stack.isRejectMarked(dstAddress) {
            return
        }

        guard let defaultConfiguration = udpConfig.configuration else { return }

        let decision = stack.connectionRouter.decision(forIP: dstAddress.description, sourceIP: datagram.source.address.description,
            sourcePort: datagram.source.port, destinationPort: dstPort, protocolName: "UDP", allowAddressResolution: !awaitedResolution)

        let dstHost = decision.host

        var flowConfiguration = defaultConfiguration
        var routeTarget: RouteTarget = .default
        var ruleSetName: String? = nil

        switch decision.action {
        case .route(let target, let configuration, let matchedRuleSet):
            routeTarget = target
            ruleSetName = matchedRuleSet
            if let configuration {
                flowConfiguration = configuration
            }
        case .reject(let matchedRuleSet):
            stack.requestLog.record(protocol: .udp, host: dstHost, port: dstPort, routeTarget: .reject, ruleSetName: matchedRuleSet)
            return
        case .unreachable:
            stack.sendICMPPortUnreachable(rejecting: datagram)
            return
        }

        var sniffedServerName: String?
        switch sniff {
        case .done(let serverName):
            sniffedServerName = serverName
        case .pending:
            if !decision.hostIsResolvedDomain {
                switch await sniffQUIC(datagram, flowKey: flowKey) {
                case .consumed:
                    return
                case .finished(let serverName):
                    sniffedServerName = serverName
                }
            }
        }

        if let sniffedServerName,
           let action = stack.connectionRouter.action(forSniffedHost: sniffedServerName) {
            switch action {
            case .route(let target, let configuration, let matchedRuleSet):
                routeTarget = target
                ruleSetName = matchedRuleSet
                flowConfiguration = configuration ?? defaultConfiguration
            case .reject(let matchedRuleSet):
                recordQUICBlock(flowKey, cause: .rejected)
                stack.requestLog.record(protocol: .udp, host: sniffedServerName, port: dstPort, routeTarget: .reject, ruleSetName: matchedRuleSet)
                return
            case .unreachable:
                stack.sendICMPPortUnreachable(rejecting: datagram)
                return
            }
        }

        let policyHost = sniffedServerName ?? dstHost

        if isQUIC, blocksQUIC(to: policyHost, udpConfig: udpConfig) {
            blockQUIC(datagram, flowKey: flowKey, cause: .mitm(host: policyHost))
            return
        }

        if !awaitedResolution, decision.ipRuleLookupPending,
           deferUntilResolved(datagram, flowKey: flowKey, domain: dstHost) {
            return
        }

        if isQUIC, blocksQUIC(routedTo: routeTarget, udpConfig: udpConfig) {
            blockQUIC(datagram, flowKey: flowKey, cause: .proxied(routeTarget))
            return
        }

        guard makeRoomForNewFlow() else { return }

        stack.requestLog.record(protocol: .udp, host: policyHost, port: dstPort, routeTarget: routeTarget, ruleSetName: ruleSetName)

        let flow = UDPFlow(
            stack: stack,
            plane: self,
            ledger: bufferLedger,
            flowKey: flowKey,
            dstHost: dstHost,
            sniffedHost: sniffedServerName,
            isQUIC: isQUIC,
            configuration: flowConfiguration,
            routeTarget: routeTarget,
            ruleSetName: ruleSetName
        )
        insert(flow)
        await flow.handleReceivedData([payload])
    }

    // MARK: - QUIC policy

    private func blocksQUIC(to host: String, udpConfig: TunnelStack.UDPConfig) -> Bool {
        udpConfig.quicPolicy.blocksQUIC(
            mitmListed: udpConfig.mitmEnabled && stack.mitmPolicy.matches(host)
        )
    }

    private func blocksQUIC(routedTo routeTarget: RouteTarget, udpConfig: TunnelStack.UDPConfig) -> Bool {
        udpConfig.quicPolicy.blocksQUIC(
            isProxied: routeTarget.resolved(against: udpConfig.defaultRouteTarget).configurationID != nil
        )
    }

    private func revalidateQUIC() {
        let udpConfig = stack.udpConfig()
        for (key, block) in quicBlocks where !stillBlocks(block.cause, udpConfig: udpConfig) {
            quicBlocks.removeValue(forKey: key)
        }
        for (key, flow) in flows where flow.isQUIC {
            let host = flow.sniffedHost ?? flow.dstHost
            let cause: QUICBlock.Cause
            if udpConfig.quicPolicy.blocksAllQUIC {
                cause = .policy
            } else if blocksQUIC(to: host, udpConfig: udpConfig) {
                cause = .mitm(host: host)
            } else if blocksQUIC(routedTo: flow.routeTarget, udpConfig: udpConfig) {
                cause = .proxied(flow.routeTarget)
            } else {
                continue
            }
            flows.removeValue(forKey: key)
            recordQUICBlock(key, cause: cause)
            Task { await flow.close() }
        }
    }

    private func stillBlocks(_ cause: QUICBlock.Cause, udpConfig: TunnelStack.UDPConfig) -> Bool {
        switch cause {
        case .policy: return udpConfig.quicPolicy.blocksAllQUIC
        case .mitm(let host): return blocksQUIC(to: host, udpConfig: udpConfig)
        case .proxied(let routeTarget): return blocksQUIC(routedTo: routeTarget, udpConfig: udpConfig)
        case .rejected: return true
        }
    }

    private static func isQUIC(_ payload: Data, port: UInt16) -> Bool {
        port == 443 || QUICClientHelloSniffer.looksLikeClientInitial(payload)
    }

    private func blockQUIC(_ datagram: InboundDatagram, flowKey: TunnelStack.UDPFlowKey, cause: QUICBlock.Cause) {
        recordQUICBlock(flowKey, cause: cause)
        stack.sendICMPPortUnreachable(rejecting: datagram)
    }

    private func recordQUICBlock(_ flowKey: TunnelStack.UDPFlowKey, cause: QUICBlock.Cause) {
        if quicBlocks[flowKey] == nil, quicBlocks.count >= TunnelLimits.udpMaxQUICBlocks,
           let oldest = quicBlocks.min(by: { $0.value.deadline < $1.value.deadline })?.key {
            quicBlocks.removeValue(forKey: oldest)
        }
        let deadline = MonotonicClock.now + TunnelConstants.udpQUICBlockIdleTimeout
        quicBlocks[flowKey] = QUICBlock(cause: cause, deadline: deadline)
        if cleanupDeadline.map({ deadline < $0 }) ?? true {
            stack.scheduleUDPCleanup(at: deadline)
        }
    }

    private func replyToBlockedQUIC(_ datagram: InboundDatagram, flowKey: TunnelStack.UDPFlowKey) -> Bool {
        guard var block = quicBlocks[flowKey] else { return false }
        let now = MonotonicClock.now
        guard now <= block.deadline else {
            quicBlocks.removeValue(forKey: flowKey)
            return false
        }
        block.deadline = now + TunnelConstants.udpQUICBlockIdleTimeout
        quicBlocks[flowKey] = block
        if case .rejected = block.cause { return true }
        stack.sendICMPPortUnreachable(rejecting: datagram)
        return true
    }

    // MARK: - QUIC SNI sniffing

    private enum SniffOutcome {
        case consumed
        case finished(serverName: String?)
    }

    private func sniffQUIC(_ datagram: InboundDatagram, flowKey: TunnelStack.UDPFlowKey) async -> SniffOutcome {
        var pending: PendingSniff
        if let held = pendingSniffs.removeValue(forKey: flowKey) {
            pending = held
        } else {
            guard QUICClientHelloSniffer.looksLikeClientInitial(datagram.payload) else {
                return .finished(serverName: nil)
            }
            guard pendingSniffs.count < TunnelLimits.udpMaxPendingSniffs else {
                if !pendingSniffCapWarned {
                    pendingSniffCapWarned = true
                    logger.warning("[UDP] Pending-sniff table full")
                }
                return .finished(serverName: nil)
            }
            sniffGeneration += 1
            pending = PendingSniff(
                sniffer: QUICClientHelloSniffer(
                    bufferLimit: TunnelConstants.quicSnifferBufferLimit,
                    datagramLimit: TunnelConstants.quicSnifferDatagramLimit
                ),
                generation: sniffGeneration
            )
        }

        var state = pending.sniffer.feed(datagram.payload)
        if state == .needMore, pending.byteCount + datagram.payload.count > TunnelConstants.udpPendingSniffMaxBytes {
            state = .unavailable
        }

        switch state {
        case .needMore:
            pending.datagrams.append(datagram)
            pending.byteCount += datagram.payload.count
            let isFirst = pending.datagrams.count == 1
            pendingSniffs[flowKey] = pending
            if isFirst {
                let generation = pending.generation
                Task { [weak self] in
                    try? await Task.sleep(seconds: TunnelConstants.sniffDeadline, precision: .prompt)
                    await self?.sniffDeadlineFired(flowKey: flowKey, generation: generation)
                }
            }
            return .consumed
        case .found(let serverName):
            notePendingSniffDrained()
            return await releaseHeldDatagrams(pending.datagrams, then: datagram, serverName: serverName)
        case .notQUIC, .unavailable:
            notePendingSniffDrained()
            return await releaseHeldDatagrams(pending.datagrams, then: datagram, serverName: nil)
        }
    }

    private func releaseHeldDatagrams(
        _ held: [InboundDatagram],
        then datagram: InboundDatagram,
        serverName: String?
    ) async -> SniffOutcome {
        guard !held.isEmpty else {
            return .finished(serverName: serverName)
        }
        for datagram in held + [datagram] {
            guard stack.publishedPhase.load(ordering: .relaxed) == .running,
                  !stack.configurationTransition.load(ordering: .acquiring) else { break }
            await handleInboundUDP(datagram, sniff: .done(serverName: serverName))
        }
        return .consumed
    }

    private func sniffDeadlineFired(flowKey: TunnelStack.UDPFlowKey, generation: UInt64) async {
        guard let pending = pendingSniffs[flowKey], pending.generation == generation else { return }
        pendingSniffs.removeValue(forKey: flowKey)
        notePendingSniffDrained()
        for datagram in pending.datagrams {
            guard stack.publishedPhase.load(ordering: .relaxed) == .running,
                  !stack.configurationTransition.load(ordering: .acquiring) else { return }
            await handleInboundUDP(datagram, sniff: .done(serverName: nil))
        }
    }

    private func notePendingSniffDrained() {
        if pendingSniffCapWarned, pendingSniffs.count <= TunnelLimits.udpMaxPendingSniffs / 2 {
            pendingSniffCapWarned = false
        }
    }

    // MARK: - Flow registry

    private func insert(_ flow: UDPFlow) {
        flows[flow.flowKey] = flow
        if cleanupDeadline.map({ flow.idleDeadline < $0 }) ?? true {
            stack.scheduleUDPCleanup(at: flow.idleDeadline)
        }
    }

    func remove(_ flow: UDPFlow) {
        if flows[flow.flowKey] === flow {
            flows.removeValue(forKey: flow.flowKey)
        }
    }
    
    func evictForBufferPressure(_ victims: [UDPBufferLedger.Victim]) {
        for victim in victims {
            guard let flow = flows[victim.handle], ObjectIdentifier(flow) == victim.id else { continue }
            flows.removeValue(forKey: victim.handle)
            logger.warning("[UDP] Uplink buffer full")
            Task { await flow.close() }
        }
    }
    
    private func makeRoomForNewFlow() -> Bool {
        guard flows.count >= TunnelLimits.udpMaxFlows else { return true }
        let now = MonotonicClock.now
        var unassured: (key: TunnelStack.UDPFlowKey, idleFor: TimeInterval)?
        var assured: (key: TunnelStack.UDPFlowKey, idleFor: TimeInterval)?
        for (key, flow) in flows {
            if flow.isClosed {
                flows.removeValue(forKey: key)
                return true
            }
            let snapshot = flow.pressureSnapshot(now: now)
            if !snapshot.isAssured {
                if snapshot.idleFor > (unassured?.idleFor ?? -1) { unassured = (key, snapshot.idleFor) }
            } else if snapshot.idleFor >= TunnelConstants.pressureIdleTimeout,
                      snapshot.idleFor > (assured?.idleFor ?? -1) {
                assured = (key, snapshot.idleFor)
            }
        }
        guard let victim = unassured ?? assured, let flow = flows.removeValue(forKey: victim.key) else {
            udpPressureLog.noteDropped(now: now, logger: logger)
            return false
        }
        Task { await flow.close() }
        return true
    }

    // MARK: - Cleanup

    func cleanup() -> TimeInterval? {
        let now = MonotonicClock.now
        var next: TimeInterval?
        for (key, flow) in flows {
            let deadline = flow.idleDeadline
            if now > deadline {
                Task { await flow.close() }
                flows.removeValue(forKey: key)
            } else if next.map({ deadline < $0 }) ?? true {
                next = deadline
            }
        }
        for (key, block) in quicBlocks {
            if now > block.deadline {
                quicBlocks.removeValue(forKey: key)
            } else if next.map({ block.deadline < $0 }) ?? true {
                next = block.deadline
            }
        }
        cleanupDeadline = next
        return next
    }

    // MARK: - Shadowsocks UDP sessions

    func shadowsocksSession(for configuration: ProxyConfiguration) -> Result<ShadowsocksUDPSession, NaiveFlowError> {
        if let existing = ssSessions[configuration.id], existing.isUsable {
            return .success(existing)
        }
        ssSessions.removeValue(forKey: configuration.id)

        guard case .shadowsocks(let shadowsocks) = configuration.outbound else {
            return .failure(NaiveFlowError.proxy(.shadowsocks, .protocolViolation(detail: "Shadowsocks password not set")))
        }
        guard let cipher = shadowsocks.cipher else {
            return .failure(NaiveFlowError.proxy(.shadowsocks, .cipher(.unsupportedMethod(shadowsocks.method))))
        }

        let mode: ShadowsocksUDPSession.Mode
        if cipher.isSS2022 {
            guard let pskList = ShadowsocksKeyDerivation.decodePSKList(password: shadowsocks.password, keySize: cipher.keySize) else {
                return .failure(NaiveFlowError.proxy(.shadowsocks, .cipher(.invalidKey)))
            }
            if cipher == .blake3chacha20poly1305 {
                mode = .ss2022ChaCha(psk: pskList.last!)
            } else {
                mode = .ss2022AES(cipher: cipher, pskList: pskList)
            }
        } else {
            let masterKey = ShadowsocksKeyDerivation.deriveKey(password: shadowsocks.password, keySize: cipher.keySize)
            mode = .legacy(cipher: cipher, masterKey: masterKey)
        }

        let session = ShadowsocksUDPSession(
            mode: mode,
            serverHost: configuration.serverAddress,
            serverPort: configuration.serverPort
        )
        ssSessions[configuration.id] = session
        return .success(session)
    }

    private func purgeShadowsocksUDPSessions() {
        let all = Array(ssSessions.values)
        ssSessions.removeAll()
        for session in all { session.cancel() }
    }

    private var dnsQueries: [UUID: Task<Void, Never>] = [:]

    // MARK: - DNS interception (synthetic address)

    private func handleDNSQuery(
        _ datagram: InboundDatagram
    ) async -> Bool {
        let query = datagram.payload
        guard query.withUnsafeBytes({ DNSPacket.parseQuery($0.bindMemory(to: UInt8.self)) }) != nil else {
            // Selected DNS traffic never falls through to the ordinary UDP router.
            return true
        }
        if let response = stack.syntheticDNSResponse(query) {
            stack.writeOutboundUDP(response, from: datagram.destination, to: datagram.source)
            return true
        }
        guard dnsQueries.count < 64 else {
            if let response = DNSPacket.errorResponse(query, code: 2) {
                stack.writeOutboundUDP(response, from: datagram.destination, to: datagram.source)
            }
            return true
        }
        let id = UUID()
        let generation = stack.dataPlaneGeneration.load(ordering: .acquiring)
        let upstream = AWCore.getFallbackDNSUpstream()
        dnsQueries[id] = Task { [weak self] in
            let response = (try? await DNSUpstreamClient.exchange(query, via: upstream))
                ?? DNSPacket.errorResponse(query, code: 2)
            await self?.completeDNS(id: id, generation: generation, query: query, response: response, datagram: datagram)
        }
        return true
    }

    private func completeDNS(id: UUID, generation: UInt64, query: Data, response: Data?, datagram: InboundDatagram) {
        guard dnsQueries.removeValue(forKey: id) != nil, !Task.isCancelled,
              generation == stack.dataPlaneGeneration.load(ordering: .acquiring),
              stack.publishedPhase.load(ordering: .relaxed) == .running,
              !stack.configurationTransition.load(ordering: .acquiring), let response else { return }
        // Conservative 512-byte UDP limit; larger answers retry over TCP even with EDNS.
        let bounded = response.count <= 512 ? response : DNSPacket.truncatedResponse(query)
        if let bounded { stack.writeOutboundUDP(bounded, from: datagram.destination, to: datagram.source) }
    }

    // MARK: - Reclaim

    private func reclaim() {
        for task in dnsQueries.values { task.cancel() }
        dnsQueries.removeAll()
        multiplexerPoolStorage?.closeAll()
        multiplexerPoolStorage = nil
        purgeShadowsocksUDPSessions()
        pendingResolutions.removeAll()
        pendingResolutionCapWarned = false
        pendingSniffs.removeAll()
        pendingSniffCapWarned = false
        quicBlocks.removeAll()
        let all = Array(flows.values)
        flows.removeAll()
        for flow in all {
            Task { await flow.close() }
        }
    }
}

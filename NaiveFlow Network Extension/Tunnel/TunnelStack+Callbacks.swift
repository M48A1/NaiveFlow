//
//  TunnelStack+Callbacks.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/30/26.
//

import Foundation
import Synchronization
import NaiveFlowIP

nonisolated private let logger = NaiveFlowLogger(category: "TunnelStack+Callbacks")

extension TunnelStack {
    func makeIPStack() -> IPStack {
        let generation = dataPlaneGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        outputBuffer.withLock { $0.generation = generation }
        return IPStack(
            configuration: .init(
                maximumConnections: TunnelLimits.tcpMaxConnections,
                pendingSendBytes: TunnelConstants.tcpWindowSize,
                acknowledgmentDelay: TunnelConstants.tcpAcknowledgmentDelay,
                maximumWindow: TunnelConstants.tcpMaximumWindow,
                maximumSendBuffer: TunnelConstants.tcpMaximumSendBuffer,
                bufferGrowthBudget: TunnelConstants.tcpBufferGrowthBudget
            ),
            output: { [weak self] packets in
                self?.enqueueTCPOutput(packets, generation: generation)
            },
            accept: { [weak self] pending in
                guard let self else { pending.reject(); return }
                Task { await self.accept(pending, generation: generation)?.start() }
            },
            datagrams: { [weak self] batch in
                self?.admitDatagrams(batch)
            },
            synFilter: { [weak self] source, destination in
                guard let self else { return .drop }
                let isDNS = destination.port == 53 && Self.dnsDestination(
                    for: destination.address.description, exempting: self.udpConfig().interceptExemptDNSServers
                ) != nil
                if !isDNS && self.isRejectMarked(destination.address) {
                    self.recordRejectedSYN(from: source, to: destination, reason: .rule)
                    return .drop
                }
                guard self.ipStackSynVerdict() else {
                    self.recordRejectedSYN(from: source, to: destination, reason: .resourceLimit)
                    return .drop
                }
                return .accept
            },
            strayFilter: { [weak self] _, destination in
                self.map { !$0.isRejectMarked(destination.address) } ?? false
            }
        )
    }

    nonisolated func isRejectMarked(_ address: IPAddress) -> Bool {
        withUnsafeTemporaryAllocation(byteCount: 16, alignment: 8) { bytes in
            address.write(to: bytes.baseAddress!)
            return connectionRouter.isRejectMarkedDestination(rawIP: bytes.baseAddress!)
        }
    }

    nonisolated private func recordRejectedSYN(from source: IPEndpoint, to destination: IPEndpoint, reason: TunnelRequestBlockReason) {
        let ip = destination.address.description
        requestLog.record(
            protocol: .tcp,
            host: connectionRouter.syntheticAddressPool.lookup(ip: ip)?.domain ?? ip,
            port: destination.port,
            routeTarget: .reject,
            blockReason: reason,
            deduplicationKey: "tcp-reject:\(source.address):\(source.port)>\(ip):\(destination.port)"
        )
    }

    nonisolated private func ipStackSynVerdict() -> Bool {
        guard tcpConnections.withLock({ $0.count }) >= TunnelLimits.tcpMaxConnections else { return true }
        let now = MonotonicClock.now
        guard let victim = findPressureVictim(now: now) else {
            tcpPressureLog.withLock { $0.noteDropped(now: now, logger: logger) }
            return false
        }
        victim.evictForConnectionPressure()
        return true
    }

    nonisolated private func findPressureVictim(now: TimeInterval) -> TCPConnection? {
        var establishing: (connection: TCPConnection, idleFor: TimeInterval)?
        var established: (connection: TCPConnection, idleFor: TimeInterval)?
        for delegate in tcpConnections.withLock({ Array($0.connections.values) }) {
            guard let tier = delegate.connectionPressureCandidate(now: now) else { continue }
            switch tier {
            case .establishing(let idleFor):
                if idleFor > (establishing?.idleFor ?? -1) { establishing = (delegate, idleFor) }
            case .established(let idleFor):
                if idleFor > (established?.idleFor ?? -1) { established = (delegate, idleFor) }
            }
        }
        return (establishing ?? established)?.connection
    }

    private func accept(_ pending: PendingConnection, generation: UInt64) -> TCPConnection? {
        guard !configurationTransition.load(ordering: .acquiring), dataPlaneUp, dataPlaneGeneration.load(ordering: .acquiring) == generation, let defaultConfiguration = configuration else {
            pending.reject(); return nil
        }
        let dstIPString = pending.destination.address.description
        let dstPort = pending.destination.port
        if dstPort == 53, Self.dnsDestination(for: dstIPString, exempting: udpConfig().interceptExemptDNSServers) != nil {
            guard let nativeConnection = pending.accept() else { return nil }
            let delegate = TCPConnection(stack: self, connection: nativeConnection,
                dstHost: dstIPString, dstPort: dstPort, configuration: defaultConfiguration,
                routeTarget: .direct, interceptDNS: true,
                sourceIP: pending.source.address.description, sourcePort: pending.source.port)
            tcpConnections.withLock { $0.insert(delegate) }
            return delegate
        }
        let decision = connectionRouter.decision(forIP: dstIPString, sourceIP: pending.source.address.description,
            sourcePort: pending.source.port, destinationPort: dstPort, protocolName: "TCP",
            consumingGroupSelection: false)

        var connectionConfiguration = defaultConfiguration
        var routeTarget: RouteTarget = .default
        var ruleSetName: String? = nil

        switch decision.action {
        case .route(let target, let configuration, let matchedRuleSet):
            routeTarget = target
            ruleSetName = matchedRuleSet
            if let configuration {
                connectionConfiguration = configuration
            }
        case .reject(let matchedRuleSet):
            // A FINAL reject before the domain is known (real IP via encrypted
            // DNS) must not preempt SNI sniffing: keep the reject as the fallback
            // and let the post-sniff re-match override it with a domain rule.
            if decision.isFinal, !decision.hostIsResolvedDomain {
                routeTarget = .reject
                ruleSetName = matchedRuleSet
            } else {
                requestLog.record(
                    protocol: .tcp,
                    host: decision.host,
                    port: dstPort,
                    routeTarget: .reject,
                    ruleSetName: matchedRuleSet,
                    deduplicationKey: "tcp-reject:\(pending.source.address):\(pending.source.port)>\(dstIPString):\(dstPort)"
                )
                pending.reject(reset: false); return nil
            }
        case .unreachable:
            pending.reject(); return nil
        }

        let dstHost = decision.host

        var sniffSNI = !decision.hostIsResolvedDomain
        if mitmEnabled && mitmPolicy.matches(dstHost) {
            sniffSNI = true
        }
        
        guard let nativeConnection = pending.accept() else { return nil }
        let delegate = TCPConnection(
            stack: self,
            connection: nativeConnection,
            dstHost: dstHost,
            dstPort: dstPort,
            configuration: connectionConfiguration,
            routeTarget: routeTarget,
            ruleSetName: ruleSetName,
            sniffSNI: sniffSNI,
            hostIsResolvedDomain: decision.hostIsResolvedDomain,
            sourceIP: pending.source.address.description, sourcePort: pending.source.port
        )
        tcpConnections.withLock { $0.insert(delegate) }
        return delegate
    }
}

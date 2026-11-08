//
//  RequestsModel.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/18/26.
//

import Foundation
import Observation

@MainActor
@Observable
class RequestsModel {
    struct Entry: Identifiable, Equatable {
        enum `Protocol`: String {
            case tcp
            case udp
            case quic
            case unknown
        }
        
        let id: UUID
        let timestamp: Date
        let `protocol`: `Protocol`
        let host: String
        let port: UInt16
        let routeTarget: RouteTarget
        let ruleSetName: String?
        let defaultRouteTarget: RouteTarget?
        let outbound: TunnelRequestOutbound?
        let blockReason: TunnelRequestBlockReason?

        var displayRouteTarget: RouteTarget {
            guard routeTarget != .reject, let outbound else { return routeTarget }
            return outbound.isDirect ? .direct : .defaultProxy
        }
    }

    enum RefreshState {
        case loading
        case current
        case unavailable
    }

    private(set) var requests: [Entry] = []
    private(set) var refreshState: RefreshState = .loading
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Runs independently of IPC, including while polling is paused or awaiting a reply.
    func pruneExpired() {
        let cutoff = now().addingTimeInterval(-RequestLog.retentionInterval)
        requests.removeAll { $0.timestamp < cutoff }
    }

    func clear() {
        requests = []
    }

    func poll(using tunnel: TunnelController) async {
        pruneExpired()
        let response = await tunnel.send(.fetchRequests)
        guard !Task.isCancelled else { return }
        pruneExpired()
        guard let response,
              let payload = try? JSONDecoder().decode(RequestsResponse.self, from: response) else {
            refreshState = .unavailable
            return
        }
        apply(payload.requests)
        pruneExpired()
        refreshState = .current
    }

    private func apply(_ entries: [TunnelRequestEntry]) {
        self.requests = entries.map { entry in
            var `protocol`: Entry.`Protocol`
            switch entry.protocol {
            case .tcp:
                `protocol` = .tcp
            case .udp:
                if entry.isQUIC == true {
                    `protocol` = .quic
                } else {
                    `protocol` = .udp
                }
            case .unknown:
                `protocol` = .unknown
            }
            return Entry(
                id: entry.id,
                timestamp: Date(timeIntervalSinceReferenceDate: entry.timestamp),
                protocol: `protocol`,
                host: entry.host,
                port: entry.port,
                routeTarget: entry.routeTarget,
                ruleSetName: entry.ruleSetName,
                defaultRouteTarget: entry.defaultRouteTarget,
                outbound: entry.outbound,
                blockReason: entry.blockReason
            )
        }
    }
}

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
        enum Transport: String {
            case tcp
            case udp
            case quic
            case unknown
        }
        
        let id: UUID
        let timestamp: Date
        let `protocol`: Transport
        let host: String
        let port: UInt16
        let routeTarget: RouteTarget
        let ruleSetName: String?
        let defaultRouteTarget: RouteTarget?
        let outbound: TunnelRequestOutbound?
        let blockReason: TunnelRequestBlockReason?
        let activity: TunnelActivityEntry?
        let observedAt: Date

        enum State { case connecting, established, closed, failed, rejected, unknown }
        var state: State {
            if routeTarget == .reject || blockReason != nil { return .rejected }
            if activity?.failure != nil { return .failed }
            switch activity?.state {
            case .connecting: return .connecting
            case .established: return .established
            case .closed: return .closed
            case nil: return .unknown
            }
        }

        func duration(at date: Date) -> TimeInterval? {
            guard let activity else { return nil }
            return max(0, (activity.endedAt ?? date.timeIntervalSinceReferenceDate) - activity.startedAt)
        }
        var connectDuration: TimeInterval? {
            guard let activity, let establishedAt = activity.establishedAt else { return nil }
            return max(0, establishedAt - activity.startedAt)
        }

        var displayRouteTarget: RouteTarget {
            guard routeTarget != .reject, let outbound else { return routeTarget }
            return outbound.isDirect ? .direct : .defaultProxy
        }
    }

    enum Filter: String, CaseIterable {
        case all, active, failed, rejected
    }

    enum RefreshState {
        case loading
        case current
        case unavailable
    }

    private(set) var requests: [Entry] = []
    private(set) var refreshState: RefreshState = .loading
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var clearedThrough: Date?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Runs independently of IPC, including while polling is paused or awaiting a reply.
    func pruneExpired() {
        let cutoff = now().addingTimeInterval(-RequestLog.retentionInterval)
        requests.removeAll { $0.timestamp < cutoff }
    }

    func clear() {
        clearedThrough = now()
        requests = []
    }

    func visibleRequests(query: String = "", filter: Filter = .all,
                         protocol selectedProtocol: Entry.Transport? = nil) -> [Entry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return requests.reversed().filter { entry in
            if let selectedProtocol, entry.protocol != selectedProtocol { return false }
            switch filter {
            case .all: break
            case .active:
                guard entry.state == .connecting || entry.state == .established else { return false }
            case .failed: guard entry.state == .failed else { return false }
            case .rejected: guard entry.state == .rejected else { return false }
            }
            let searchable = [entry.host, String(entry.port), entry.protocol.rawValue,
                              entry.outbound?.name, entry.ruleSetName, entry.activity?.failure]
                .compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { searchable.localizedStandardContains($0) }
        }
    }

    /// Export only the rows the user is viewing, with connection-level metrics kept explicit.
    func export(_ entries: [Entry]) -> String {
        struct Record: Encodable {
            let id: UUID
            let timestamp: Date
            let host: String
            let port: UInt16
            let transport: String
            let policy: RouteTarget
            let outbound: TunnelRequestOutbound?
            let rule: String?
            let blockReason: TunnelRequestBlockReason?
            let connection: TunnelActivityEntry?
        }
        let records = entries.map {
            Record(id: $0.id, timestamp: $0.timestamp, host: $0.host, port: $0.port,
                   transport: $0.protocol.rawValue, policy: $0.routeTarget, outbound: $0.outbound,
                   rule: $0.ruleSetName, blockReason: $0.blockReason, connection: $0.activity)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
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
        apply(payload.requests, activities: payload.activities ?? [])
        pruneExpired()
        refreshState = .current
    }

    private func apply(_ entries: [TunnelRequestEntry], activities: [TunnelActivityEntry]) {
        // Match by identity, never by host: concurrent connections can share a destination.
        let activityByID = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let previous = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.requests = entries.filter {
            guard let clearedThrough else { return true }
            return $0.timestamp > clearedThrough.timeIntervalSinceReferenceDate
        }.map { entry in
            var `protocol`: Entry.Transport
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
                blockReason: entry.blockReason,
                activity: entry.activityID.flatMap { activityByID[$0] }
                    ?? previous[entry.id]?.activity.flatMap { $0.state == .closed ? $0 : nil },
                observedAt: now()
            )
        }
    }
}

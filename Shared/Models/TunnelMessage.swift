//
//  TunnelMessage.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/9/26.
//

import Foundation

nonisolated enum TunnelMessage: Codable, Sendable {
    case testLatency(ProxyConfiguration)
    case testLatencyWithSettings(ProxyConfiguration, LatencyTestSettings)
    case updateLatencyTestSettings(LatencyTestSettings)
    case applyRuntimeVersion(UUID)
    case fetchPolicyGroups
    case fetchRuntimeStatus
    case clearLogs
    case fetchLogs
    case fetchRequests
}

// MARK: - Active Configuration

nonisolated enum ActiveConfiguration {
    static func load() throws -> ProxyConfiguration? {
        guard let data = AWCore.getActiveConfigurationData() else { return nil }
        return try JSONDecoder().decode(ProxyConfiguration.self, from: data)
    }

    static func store(_ configuration: ProxyConfiguration?) throws {
        AWCore.setActiveConfigurationData(try configuration.map { try JSONEncoder().encode($0) })
    }
}

// MARK: - Responses

nonisolated struct LogsResponse: Codable, Sendable {
    var logs: [TunnelLogEntry]
}

nonisolated struct RequestsResponse: Codable, Sendable {
    var requests: [TunnelRequestEntry]
    var activities: [TunnelActivityEntry]? = nil
}

nonisolated struct LatencyTestResponse: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case success
        case failed
        case insecure
    }
    var result: Kind
    var ms: Int?
}

nonisolated extension LatencyTestResponse {
    init(_ result: LatencyResult) {
        switch result {
        case .success(let ms): self.init(result: .success, ms: ms)
        case .insecure: self.init(result: .insecure, ms: nil)
        case .failed, .testing: self.init(result: .failed, ms: nil)
        }
    }

    var asLatencyResult: LatencyResult {
        switch result {
        case .success: return .success(ms ?? 0)
        case .insecure: return .insecure
        case .failed: return .failed
        }
    }
}

// MARK: - Shared Types

nonisolated struct TunnelLogEntry: Codable, Sendable, Hashable {
    var id: UUID = UUID()
    var timestamp: TimeInterval
    var level: TunnelLogLevel
    var message: String
}

nonisolated enum TunnelLogLevel: String, Codable, Sendable, Hashable {
    case info
    case warning
    case error
}

nonisolated struct TunnelRequestEntry: Codable, Sendable, Hashable {
    var id: UUID = UUID()
    var timestamp: TimeInterval
    var `protocol`: TunnelRequestProtocol
    var host: String
    var port: UInt16
    var routeTarget: RouteTarget
    var ruleSetName: String? = nil
    var defaultRouteTarget: RouteTarget? = nil
    var outbound: TunnelRequestOutbound? = nil
    var blockReason: TunnelRequestBlockReason? = nil
    /// nil means the producer did not identify the application protocol.
    var isQUIC: Bool? = nil
    var activityID: UUID? = nil
    var resolvedAddress: String? = nil
    var resolutionPurpose: String? = nil
}

/// Captured at route commit so later edits and group switches cannot rewrite history.
nonisolated struct TunnelRequestOutbound: Codable, Sendable, Hashable {
    var id: UUID?
    var name: String
    var isDirect: Bool

    init(configuration: ProxyConfiguration) {
        id = configuration.id
        name = configuration.name
        isDirect = configuration.isDirect
    }

    private init(name: String, isDirect: Bool) {
        self.name = name
        self.isDirect = isDirect
    }

    static let direct = Self(name: "DIRECT", isDirect: true)
}

nonisolated enum TunnelRequestBlockReason: String, Codable, Sendable, Hashable {
    case rule
    case udpDisabled
    case quicPolicy
    case quicMITM
    case quicProxyPolicy
    case webRTC
    case resourceLimit
}

nonisolated enum TunnelRequestProtocol: String, Codable, Sendable, Hashable {
    case tcp
    case udp
    case unknown
}

nonisolated struct TunnelActivityEntry: Codable, Sendable, Hashable {
    var id: UUID
    var host: String
    var port: UInt16
    var routeTarget: RouteTarget
    var defaultRouteTarget: RouteTarget
    var ruleSetName: String?
    var state: TunnelActivityState
    var startedAt: TimeInterval
    var endedAt: TimeInterval?
    var bytesIn: Int64
    var bytesOut: Int64
    var establishedAt: TimeInterval? = nil
    var failure: String? = nil
}

nonisolated enum TunnelActivityState: String, Codable, Sendable, Hashable {
    case connecting
    case established
    case closed
}

/// Read-only status for the policy UI; names bridge compiler-local node IDs.
nonisolated struct PolicyGroupsResponse: Codable, Sendable {
    struct Group: Codable, Sendable {
        let name: String
        let nextMember: String?
        let latencies: [String: Int]
    }
    let versionID: UUID?
    let groups: [Group]
}

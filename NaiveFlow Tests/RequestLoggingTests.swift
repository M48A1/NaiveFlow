import Foundation
import NetworkExtension
import Testing
@testable import NaiveFlow

@MainActor
struct RequestLoggingTests {
    @Test func duplicateSuppressionExpiresWithoutSlidingOnRetries() {
        let log = RequestLog()
        for now in [0.0, 1, 5, 9, 10, 11] {
            log.record(protocol: .unknown, host: "blocked.test", port: 53, routeTarget: .reject,
                       deduplicationKey: "dns:blocked.test", now: now)
        }
        #expect(log.snapshot(now: 11).map(\.timestamp) == [0, 10])
        #expect(log.snapshot(now: 311).isEmpty)
        log.record(protocol: .unknown, host: "blocked.test", port: 53, routeTarget: .reject,
                   deduplicationKey: "dns:blocked.test", now: 311)
        #expect(log.snapshot(now: 311).count == 1)
    }

    @Test func evictedRecordCannotSuppressNewReject() {
        let log = RequestLog()
        func blocked() {
            log.record(protocol: .unknown, host: "blocked.test", port: 53, routeTarget: .reject,
                       deduplicationKey: "dns:blocked.test", now: 1)
        }
        blocked()
        for index in 0..<RequestLog.maxEntries {
            log.record(protocol: .tcp, host: "\(index).test", port: 443, routeTarget: .direct, now: 1)
        }
        blocked()
        let entries = log.snapshot(now: 1)
        #expect(entries.count == RequestLog.maxEntries)
        #expect(entries.last?.host == "blocked.test")
    }

    @Test func retransmitsShareAnIDButDifferentSourcesAndCausesRemainVisible() {
        let log = RequestLog()
        func record(_ key: String, _ reason: TunnelRequestBlockReason, at now: Double) {
            log.record(protocol: .tcp, host: "blocked.test", port: 443, routeTarget: .reject,
                       blockReason: reason, deduplicationKey: key, now: now)
        }
        record("source1>destination", .rule, at: 0)
        let id = log.snapshot(now: 0).first?.id
        record("source1>destination", .rule, at: 1)
        #expect(log.snapshot(now: 1).map(\.id) == [id!])
        record("source2>destination", .rule, at: 1)
        record("source1>destination", .resourceLimit, at: 1)
        #expect(log.snapshot(now: 1).count == 3)
        #expect(log.snapshot(now: 1).last?.blockReason == .resourceLimit)
    }

    @Test func fastRejectRetriesRetainTheOriginalRuleAndID() {
        let log = RequestLog()
        log.record(protocol: .tcp, host: "blocked.test", port: 443, routeTarget: .reject,
                   ruleSetName: "Original rule", deduplicationKey: "flow", now: 0)
        let original = log.snapshot(now: 0).first
        log.record(protocol: .tcp, host: "blocked.test", port: 443, routeTarget: .reject,
                   deduplicationKey: "flow", now: 1)
        #expect(log.snapshot(now: 1).count == 1)
        #expect(log.snapshot(now: 1).first == original)
        // A genuinely different rule must still produce a distinct decision.
        log.record(protocol: .tcp, host: "blocked.test", port: 443, routeTarget: .reject,
                   ruleSetName: "Changed rule", deduplicationKey: "flow", now: 2)
        #expect(log.snapshot(now: 2).count == 2)
    }

    @Test func everyBlockReasonSurvivesTheWireWithItsOwnDeduplicationScope() throws {
        let log = RequestLog()
        let reasons: [TunnelRequestBlockReason] = [.rule, .udpDisabled, .quicPolicy, .quicMITM,
                                                  .quicProxyPolicy, .webRTC, .resourceLimit]
        for reason in reasons {
            log.record(protocol: .udp, host: "blocked.test", port: 443, routeTarget: .reject,
                       blockReason: reason, isQUIC: true, deduplicationKey: "same-flow", now: 0)
        }
        let response = RequestsResponse(requests: log.snapshot(now: 0))
        let decoded = try JSONDecoder().decode(RequestsResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded.requests.map(\.blockReason) == reasons.map(Optional.some))
        #expect(decoded.requests.allSatisfy { $0.isQUIC == true && $0.routeTarget == .reject })
    }

    @Test func outboundSnapshotSurvivesLaterConfigurationEditsAndDefaultSwitch() {
        let log = RequestLog()
        var node = ProxyConfiguration(name: "Original DIRECT member", serverAddress: "", serverPort: 0,
                                      outbound: .direct(DirectConfiguration()))
        let originalID = node.id
        let groupID = UUID()
        log.setDefaultRouteTarget(.proxy(groupID))
        log.record(protocol: .tcp, host: "test", port: 80, routeTarget: .proxy(groupID),
                   outbound: TunnelRequestOutbound(configuration: node), now: 0)
        node = ProxyConfiguration(id: originalID, name: "Renamed", serverAddress: "", serverPort: 0,
                                  outbound: .direct(DirectConfiguration()))
        #expect(node.name == "Renamed")
        log.setDefaultRouteTarget(.direct)
        let entry = log.snapshot(now: 0).first
        #expect(entry?.outbound?.name == "Original DIRECT member")
        #expect(entry?.outbound?.id == originalID)
        #expect(entry?.outbound?.isDirect == true)
        #expect(entry?.defaultRouteTarget == .proxy(groupID))
        #expect(entry?.routeTarget == .proxy(groupID))
    }

    @Test func pollingUsesTheInjectedTunnelAndProtocolEvidenceRatherThanPort() async throws {
        let provider = ScriptedTunnelProvider(initialStatus: .connected)
        let controller = TunnelController(provider: provider)
        let groupID = UUID()
        let entries = [
            TunnelRequestEntry(timestamp: 0, protocol: .udp, host: "plain", port: 443,
                               routeTarget: .direct, isQUIC: false),
            TunnelRequestEntry(timestamp: 1, protocol: .udp, host: "quic", port: 8443,
                               routeTarget: .proxy(groupID), outbound: .direct, isQUIC: true),
            TunnelRequestEntry(timestamp: 2, protocol: .udp, host: "legacy", port: 443,
                               routeTarget: .direct)
        ]
        let response = try JSONEncoder().encode(RequestsResponse(requests: entries))
        var fetchCount = 0
        provider.onMessage = { data in
            if case .fetchRequests? = try? JSONDecoder().decode(TunnelMessage.self, from: data) {
                fetchCount += 1
                return response
            }
            return nil
        }
        let model = RequestsModel(now: { Date(timeIntervalSinceReferenceDate: 2) })
        await model.poll(using: controller)
        #expect(fetchCount == 1)
        #expect(model.requests.map(\.protocol) == [.udp, .quic, .udp])
        #expect(model.requests.map(\.id) == entries.map(\.id))
        #expect(model.requests[1].displayRouteTarget == .direct)
        #expect(model.requests[1].routeTarget == .proxy(groupID))
        #expect(model.requests[1].outbound?.name == "DIRECT")
    }

    @Test func failedPollExpiresOldRowsButRetainsRecentRowsAndReportsFailure() async throws {
        var now = Date(timeIntervalSinceReferenceDate: 300)
        let model = RequestsModel(now: { now })
        let provider = ScriptedTunnelProvider()
        let tunnel = TunnelController(provider: provider)
        let entries = [
            TunnelRequestEntry(timestamp: 0, protocol: .tcp, host: "old", port: 80, routeTarget: .direct),
            TunnelRequestEntry(timestamp: 200, protocol: .tcp, host: "recent", port: 80, routeTarget: .direct)
        ]
        let payload = try JSONEncoder().encode(RequestsResponse(requests: entries))
        provider.onMessage = { _ in payload }
        await model.poll(using: tunnel)
        #expect(model.requests.count == 2)
        #expect(model.refreshState == .current)
        now = Date(timeIntervalSinceReferenceDate: 301)
        provider.onMessage = { _ in nil }
        await model.poll(using: tunnel)
        #expect(model.requests.map(\.host) == ["recent"])
        #expect(model.refreshState == .unavailable)
        now = Date(timeIntervalSinceReferenceDate: 501)
        model.pruneExpired() // No IPC reply or additional poll is required.
        #expect(model.requests.isEmpty)
    }

    @Test func cachedRowsExpireWhilePollingIsPausedAndRecoveryClearsFailure() async throws {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        let model = RequestsModel(now: { now })
        let provider = ScriptedTunnelProvider()
        let tunnel = TunnelController(provider: provider)
        let payload = try JSONEncoder().encode(RequestsResponse(requests: [
            TunnelRequestEntry(timestamp: 0, protocol: .udp, host: "test", port: 53, routeTarget: .direct)
        ]))
        provider.onMessage = { _ in payload }
        await model.poll(using: tunnel)
        now = Date(timeIntervalSinceReferenceDate: 301)
        model.pruneExpired()
        #expect(model.requests.isEmpty)
        provider.onMessage = { _ in Data("invalid reply".utf8) }
        await model.poll(using: tunnel)
        #expect(model.refreshState == .unavailable)
        // An empty, valid response is a successful refresh, not an error.
        let empty = try JSONEncoder().encode(RequestsResponse(requests: []))
        provider.onMessage = { _ in empty }
        await model.poll(using: tunnel)
        #expect(model.refreshState == .current)
        #expect(model.requests.isEmpty)
    }

    @Test func successfulButStaleReplyCannotReintroduceExpiredRows() async throws {
        let model = RequestsModel(now: { Date(timeIntervalSinceReferenceDate: 301) })
        let provider = ScriptedTunnelProvider()
        let payload = try JSONEncoder().encode(RequestsResponse(requests: [
            TunnelRequestEntry(timestamp: 0, protocol: .tcp, host: "expired", port: 80, routeTarget: .direct)
        ]))
        provider.onMessage = { _ in payload }
        await model.poll(using: TunnelController(provider: provider))
        #expect(model.requests.isEmpty)
        #expect(model.refreshState == .current)
    }

    @Test func sessionSelectionIgnoresOtherProvidersAndPrefersTheLiveProfile() {
        func manager(_ identifier: String) -> NETunnelProviderManager {
            let manager = NETunnelProviderManager()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = identifier
            manager.protocolConfiguration = configuration
            return manager
        }
        let unrelated = manager("other.provider")
        let stale = manager(LiveTunnelProvider.providerBundleIdentifier)
        let live = manager(LiveTunnelProvider.providerBundleIdentifier)
        let selected = LiveTunnelProvider.preferredManager(in: [unrelated, stale, live]) {
            $0 === live || $0 === unrelated ? .connected : .disconnected
        }
        #expect(selected === live)
        #expect(LiveTunnelProvider.preferredManager(in: [unrelated]) == nil)
        #expect(LiveTunnelProvider.preferredManager(in: [unrelated, stale]) === stale)
    }

    @Test func legacyPayloadDoesNotRequireNewOptionalMetadata() throws {
        let data = Data("""
        {"requests":[{"timestamp":0,"id":"00000000-0000-0000-0000-000000000001",
        "protocol":"udp","host":"test","port":443,"routeTarget":"direct"}]}
        """.utf8)
        let entry = try #require(JSONDecoder().decode(RequestsResponse.self, from: data).requests.first)
        #expect(entry.outbound == nil && entry.blockReason == nil && entry.isQUIC == nil)
    }
}

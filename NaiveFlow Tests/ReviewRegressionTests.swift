import Foundation
import Synchronization
import Testing
@testable import NaiveFlow

struct ReviewRegressionTests {
    private func bundle() -> RuntimeConfigurationBundle {
        let node = ProxyConfiguration(name: "Direct", serverAddress: "", serverPort: 0,
                                      outbound: .direct(DirectConfiguration()))
        return RuntimeConfigurationBundle(id: UUID(), snapshotID: UUID(), parentID: UUID(),
            preferences: [:], nodes: [node], selectedNodeID: node.id,
            rules: [], finalAction: .direct, mitmRuleSets: [],
            policyGroups: [RuntimeProxyGroup(name: "Auto", kind: .loadBalance, memberIDs: [node.id])],
            legacyRouting: Data([1]), legacyMITM: Data([2]))
    }

    @Test func oldBundleDefaultsMissingPolicyGroupsAndGeo() throws {
        let original = bundle()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "policyGroups")
        json.removeValue(forKey: "geo")
        let restored = try JSONDecoder().decode(RuntimeConfigurationBundle.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.policyGroups.isEmpty)
        #expect(restored.id == original.id)
        #expect(restored.selectedNodeID == original.selectedNodeID)
        #expect(restored.geo.entryCount == 0)
        #expect(restored.legacyRouting == original.legacyRouting)
    }

    @Test func bundleRoundTripPreservesCurrentFields() throws {
        let original = bundle()
        let restored = try JSONDecoder().decode(RuntimeConfigurationBundle.self, from: JSONEncoder().encode(original))
        #expect(restored.policyGroups == original.policyGroups)
        #expect(restored.snapshotID == original.snapshotID)
        #expect(restored.parentID == original.parentID)
        #expect(restored.rules == original.rules)
        #expect(restored.finalAction == original.finalAction)
        #expect(restored.legacyMITM == original.legacyMITM)
    }

    @Test func malformedPolicyGroupsStillFailDecoding() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle())) as? [String: Any])
        json["policyGroups"] = "invalid"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RuntimeConfigurationBundle.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func tcpIntakePreviewsDoNotConsumeRoundRobinSlots() {
        let a = UUID(), b = UUID()
        let group = RuntimeProxyGroup(name: "Balance", kind: .loadBalance, memberIDs: [a, b])
        var selection = ProxyGroupSelection()
        let actual = (0..<6).compactMap { _ -> UUID? in
            // Intake may inspect the same route more than once before dialing.
            _ = selection.select(group: group, latencies: [:], consuming: false)
            _ = selection.select(group: group, latencies: [:], consuming: false)
            return selection.select(group: group, latencies: [:])
        }
        #expect(actual == [a, b, a, b, a, b])
    }

    @Test func tcpFinalMatchUsesCachedAddressForNoResolveRule() throws {
        let nodeID = UUID()
        let matcher = OrderedRouteMatcher(rules: [OrderedRoutingRule(line: 1,
            matcher: .ipCIDR(try #require(CIDRPrefix.parse("203.0.113.0/24"))),
            action: .proxy(nodeID), noResolve: true)], finalAction: .direct)
        var cacheReads: [String] = []
        let query = RouteQuery(destinationHost: "example.com", sourceIP: "192.0.2.1",
            sourcePort: 1234, destinationPort: 443, protocolName: "TCP") { host in
                cacheReads.append(host)
                return "203.0.113.7"
            }
        guard case .matched(let result) = matcher.evaluate(query, deferOnHostUnknown: false) else {
            Issue.record("cached no-resolve rule must decide the route")
            return
        }
        #expect(result.action == .proxy(nodeID))
        #expect(result.ruleLine == 1)
        #expect(cacheReads == ["example.com"])
        #expect(query.sourceIP == "192.0.2.1")
        #expect(query.sourcePort == 1234 && query.destinationPort == 443 && query.protocolName == "TCP")
    }

    @Test func tcpNoResolveWithoutCachedAddressReachesFinal() throws {
        let matcher = OrderedRouteMatcher(rules: [OrderedRoutingRule(line: 1,
            matcher: .ipCIDR(try #require(CIDRPrefix.parse("203.0.113.0/24"))),
            action: .reject, noResolve: true)], finalAction: .direct)
        let query = RouteQuery(destinationHost: "example.com") { _ in nil }
        guard case .matched(let result) = matcher.evaluate(query, deferOnHostUnknown: false) else {
            Issue.record("no-resolve must not request DNS when the cache is empty")
            return
        }
        #expect(result.action == .direct && result.isFinal)
    }

    @Test func tcpSniffPreservesRealDestinationInsteadOfCachedAddress() {
        let query = RouteQuery(destinationHost: "203.0.113.7", sniffedHost: "example.com") { _ in
            Issue.record("a real destination must not need a cached DNS answer")
            return "192.0.2.9"
        }
        #expect(query.host == "example.com")
        #expect(query.ip == "203.0.113.7")
        let literal = RouteQuery(destinationHost: "203.0.113.7") { _ in
            Issue.record("literal IP must not read DNS cache")
            return nil
        }
        #expect(literal.host == nil && literal.ip == "203.0.113.7")
    }

    @Test func tcpSniffUsesCacheForRecoveredHost() {
        var cacheReads: [String] = []
        let query = RouteQuery(destinationHost: "original.example", sniffedHost: "sniffed.example") { host in
            cacheReads.append(host)
            return host == "sniffed.example" ? "203.0.113.7" : "192.0.2.9"
        }
        #expect(query.host == "sniffed.example" && query.ip == "203.0.113.7")
        #expect(cacheReads == ["sniffed.example"])
    }

    @Test func udpBufferedSniffAndDNSPreviewsConsumeOneSlotPerFlow() {
        let a = UUID(), b = UUID()
        let group = RuntimeProxyGroup(name: "UDP", kind: .loadBalance, memberIDs: [a, b])
        var selection = ProxyGroupSelection()
        var actual: [UUID] = []
        for previews in [2, 5, 1, 4, 3, 2] {
            // Buffered QUIC Initial packets and DNS retries must be previews;
            // only the flow that is actually created commits a selection.
            for _ in 0..<previews {
                _ = selection.select(group: group, latencies: [:], consuming: false)
            }
            if let selected = selection.select(group: group, latencies: [:]) { actual.append(selected) }
        }
        #expect(actual == [a, b, a, b, a, b])
    }

    @Test func udpAbandonedPreviewDoesNotConsumeOldGroupsSlot() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let old = RuntimeProxyGroup(name: "Before sniff", kind: .loadBalance, memberIDs: [a, b])
        let final = RuntimeProxyGroup(name: "After sniff", kind: .loadBalance, memberIDs: [c, d])
        var before = ProxyGroupSelection(), after = ProxyGroupSelection()
        _ = before.select(group: old, latencies: [:], consuming: false)
        _ = after.select(group: final, latencies: [:], consuming: false)
        #expect(after.select(group: final, latencies: [:]) == c)
        #expect(before.select(group: old, latencies: [:]) == a)
        #expect(after.select(group: final, latencies: [:]) == d)
    }

    @Test func probeAcceptsEveryHeaderSplitBoundary() async throws {
        let response = Data("HTTP/1.1 204 No Content\r\nX-Probe: yes\r\n\r\n".utf8)
        for split in 1..<response.count {
            let connection = ProbeConnection(chunks: [Data(response.prefix(split)), Data(response.dropFirst(split))])
            var reader = LatencyProbeResponseReader()
            try await reader.readSuccess(from: connection)
            #expect(connection.readCount == 2)
        }
    }

    @Test func warmupConsumesFullHeaderBeforeMeasuredResponse() async throws {
        let connection = ProbeConnection(chunks: [
            Data("HTTP/1.1 200 OK\r\nX-Probe: ".utf8),
            Data("yes\r\n\r\n".utf8),
            Data("HTTP/1.1 503 Unavailable\r\n\r\n".utf8)
        ])
        var reader = LatencyProbeResponseReader()
        try await reader.readSuccess(from: connection)
        #expect(connection.readCount == 2)
        await #expect(throws: (any Error).self) { try await reader.readSuccess(from: connection) }
    }

    @Test func probePreservesSurplusAndSkipsInformationalHeaders() async throws {
        let connection = ProbeConnection(chunks: [Data((
            "HTTP/1.1 103 Early Hints\r\n\r\n" +
            "HTTP/1.1 204 No Content\r\n\r\n" +
            "HTTP/1.1 200 OK\r\n\r\n").utf8)])
        var reader = LatencyProbeResponseReader()
        try await reader.readSuccess(from: connection)
        try await reader.readSuccess(from: connection)
        #expect(connection.readCount == 1)
    }

    @Test func probeRejectsTruncatedOversizedAndInvalidResponses() async {
        for text in ["HTTP/1.1 200 OK\r\n", "HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 65_536),
                     "HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 65_536) + "\r\n\r\n",
                     "invalid 200 OK\r\n\r\n", "HTTP/1.1 101 Switching Protocols\r\n\r\n"] {
            let connection = ProbeConnection(chunks: [Data(text.utf8)])
            var reader = LatencyProbeResponseReader()
            await #expect(throws: (any Error).self) { try await reader.readSuccess(from: connection) }
        }
    }
}

private nonisolated final class ProbeConnection: ProxyConnection {
    private struct State {
        var chunks: [Data]
        var readCount = 0
    }
    private let state: Mutex<State>
    init(chunks: [Data]) { state = Mutex(State(chunks: chunks)) }
    var isConnected: Bool { true }
    var readCount: Int { state.withLock { $0.readCount } }
    func sendRaw(_ data: Data) async throws {}
    func receiveRaw() async throws -> Data? {
        state.withLock {
            $0.readCount += 1
            return $0.chunks.isEmpty ? nil : $0.chunks.removeFirst()
        }
    }
    func cancel() {}
}

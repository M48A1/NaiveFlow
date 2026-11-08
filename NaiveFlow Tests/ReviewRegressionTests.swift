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

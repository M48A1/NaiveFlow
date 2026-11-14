import Foundation
import Testing
@testable import NaiveFlow

@MainActor
struct LatencyTestSettingsTests {
    @Test func settingsPersistAndCorruptPreferencesFallBackToDefaults() throws {
        let name = "LatencyTestSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(LatencyTestSettings.load(from: defaults) == .default)
        let settings = LatencyTestSettings(url: "https://example.com:8443/probe?edge=1", timeoutSeconds: 6, concurrency: 3)
        try settings.save(to: defaults)
        #expect(LatencyTestSettings.load(from: defaults) == settings)
        #expect(settings.target.port == 8443)
        #expect(settings.target.path == "/probe?edge=1")
        #expect(settings.timeout == .seconds(6))
        defaults.set(Data("broken".utf8), forKey: LatencyTestSettings.storageKey)
        #expect(LatencyTestSettings.load(from: defaults) == .default)
        defaults.set(try JSONEncoder().encode(LatencyTestSettings(timeoutSeconds: 0, concurrency: 0)), forKey: LatencyTestSettings.storageKey)
        #expect(LatencyTestSettings.load(from: defaults) == .default)
    }

    @Test func invalidURLsAndOutOfRangeOptionsAreRejected() {
        for url in ["", "example.com", "ftp://example.com", "https:///probe", "http://example.com:0/", "https://example.com:65536/", "https://user:password@example.com/", "https://example.com/#fragment"] {
            #expect(!LatencyTestSettings(url: url).isValid, "\(url)")
        }
        #expect(!LatencyTestSettings(timeoutSeconds: 31).isValid)
        #expect(!LatencyTestSettings(concurrency: 17).isValid)
        #expect(LatencyTestSettings.default.isValid)
    }

    @Test func existingSettingsMigrateOnceIntoSharedPreferences() throws {
        let sharedName = "SharedLatencyTests.\(UUID())"
        let legacyName = "LegacyLatencyTests.\(UUID())"
        let shared = try #require(UserDefaults(suiteName: sharedName))
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        defer { shared.removePersistentDomain(forName: sharedName); legacy.removePersistentDomain(forName: legacyName) }
        let old = LatencyTestSettings(url: "https://example.com/old", timeoutSeconds: 4, concurrency: 3)
        try old.save(to: legacy)
        #expect(LatencyTestSettings.load(from: shared, legacyDefaults: legacy) == old)
        #expect(LatencyTestSettings.load(from: shared) == old)
        let current = LatencyTestSettings(timeoutSeconds: 6, concurrency: 2)
        try current.save(to: shared)
        #expect(LatencyTestSettings.load(from: shared, legacyDefaults: legacy) == current)
        let data = try JSONEncoder().encode(TunnelMessage.updateLatencyTestSettings(current))
        guard case .updateLatencyTestSettings(let received) = try JSONDecoder().decode(TunnelMessage.self, from: data) else {
            Issue.record("Expected background settings update"); return
        }
        #expect(received == current)
    }

    @Test func manualBatchHonorsConcurrencyAndFreezesSettingsUntilNextTest() async throws {
        let store = SettingsStore()
        store.value = LatencyTestSettings(url: "https://example.com/probe", timeoutSeconds: 5, concurrency: 2)
        let original = store.value
        let transport = ProbeTransport()
        let center = LatencyCenter(settingsProvider: { store.value })
        let nodes = (0..<5).map { ProxyConfiguration(name: "Node \($0)", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration())) }
        center.testLatencies(for: nodes, transport: transport)
        try await waitUntil { transport.received.count == 2 }
        #expect(transport.peak == 2)
        store.value = LatencyTestSettings(url: "http://example.org/next", timeoutSeconds: 3, concurrency: 1)
        transport.release()
        try await waitUntil { nodes.allSatisfy { center.latencyResults[$0.id] == .success(24) } }
        #expect(transport.received.count == 5)
        #expect(transport.received.allSatisfy { $0 == original })
        #expect(transport.peak <= 2)
        center.testLatency(for: nodes[0], transport: transport)
        try await waitUntil { center.latencyResults[nodes[0].id] == .success(24) }
        #expect(transport.received.last == store.value)
    }

    @Test func tunnelMessageRoundTripsCustomProbeParametersAndLegacyMessages() throws {
        let node = ProxyConfiguration(name: "Test", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration()))
        let settings = LatencyTestSettings(url: "https://example.com/probe", timeoutSeconds: 7, concurrency: 4)
        let data = try JSONEncoder().encode(TunnelMessage.testLatencyWithSettings(node, settings))
        guard case .testLatencyWithSettings(let decodedNode, let decodedSettings) = try JSONDecoder().decode(TunnelMessage.self, from: data) else {
            Issue.record("Expected configured latency test message"); return
        }
        #expect(decodedNode.id == node.id)
        #expect(decodedSettings == settings)
        let legacy = try JSONEncoder().encode(TunnelMessage.testLatency(node))
        guard case .testLatency = try JSONDecoder().decode(TunnelMessage.self, from: legacy) else {
            Issue.record("Legacy latency messages must remain supported"); return
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }

    private final class SettingsStore { var value = LatencyTestSettings.default }

    private final class ProbeTransport: LatencyTransport {
        let isTunnelActive = true
        var received: [LatencyTestSettings] = []
        var peak = 0
        private var active = 0
        private var gated = true
        private var pending: [CheckedContinuation<Void, Never>] = []

        func sendRaw(_ data: Data) async -> Data? {
            guard let message = try? JSONDecoder().decode(TunnelMessage.self, from: data),
                  case .testLatencyWithSettings(_, let settings) = message else { return nil }
            received.append(settings)
            active += 1
            peak = max(peak, active)
            if gated { await withCheckedContinuation { pending.append($0) } }
            active -= 1
            return try? JSONEncoder().encode(LatencyTestResponse(.success(24)))
        }

        func release() {
            gated = false
            let waiting = pending
            pending = []
            for continuation in waiting { continuation.resume() }
        }
    }
}

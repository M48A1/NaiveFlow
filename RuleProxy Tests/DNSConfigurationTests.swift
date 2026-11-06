import Foundation
import Synchronization
import Testing
@testable import RuleProxy

nonisolated private final class BootstrapCalls: Sendable {
    let entries = Mutex<[(String, String)]>([])
}

struct DNSConfigurationTests {
    @Test func dedicatedSectionSupportsPlainDoHAndExplicitBootstrap() {
        let result = ConfigurationCoordinator().compile(text: """
            [DNS]
            mode = doh
            server = 223.5.5.5
            doh = https://resolver.example/dns-query
            bootstrap-dns = 1.1.1.1, 2001:db8::53
            proxy-dns-mode = system
            [Rule]
            FINAL,DIRECT
            """)
        #expect(result.isActivatable)
        #expect(result.compiled.settings.values["dns-mode"] == .text("doh"))
        #expect(result.compiled.settings.values["dns-server"] == .text("223.5.5.5"))
        #expect(result.compiled.settings.values["proxy-dns-mode"] == .text("default"))
        #expect(result.compiled.settings.values["bootstrap-dns"] == .text("1.1.1.1, 2001:db8::53"))
        #expect(ConfigurationModule.owning(section: "DNS") == .dns)
    }

    @Test func rejectsAmbiguousDuplicateUnknownAndInvalidDNSSettings() {
        for text in [
            "[DNS]\nserver=1.1.1.1\ndoh=https://resolver.example/dns-query",
            "[General]\ndns-server=1.1.1.1\n[DNS]\nserver=223.5.5.5",
            "[DNS]\nbootstrap-dns=resolver.example",
            "[DNS]\nbootstrap-dns=system,1.1.1.1",
            "[DNS]\ndoh=http://resolver.example/dns-query",
            "[DNS]\ndoh=https://resolver.example:70000/dns-query",
            "[DNS]\nunknown-key=true"
        ] { #expect(!ConfigurationCoordinator().compile(text: text).isActivatable) }
    }

    @Test func bootstrapAcceptsOnlySystemOrNumericSeedList() {
        #expect(DNSBootstrapPolicy.parse("SYSTEM") == .system)
        #expect(DNSBootstrapPolicy.parse("1.1.1.1, 1.1.1.1, [2001:db8::53]") == .servers(["1.1.1.1", "2001:db8::53"]))
        for value in ["", "1.1.1.1,", "1.1.1.1:5353", "https://resolver.example", "invalid", "system,1.1.1.1"] {
            #expect(DNSBootstrapPolicy.parse(value) == nil)
        }
    }

    @Test func numericEndpointsSkipBootstrapAndNamesUseOnlyConfiguredSeeds() async throws {
        let calls = BootstrapCalls()
        let policy = DNSBootstrapPolicy.servers(["192.0.2.1", "192.0.2.2"])
        let ipv6 = try await policy.endpointAddresses(for: "[2001:db8::1]") { name, seed in
            calls.entries.withLock { $0.append((name, seed)) }
            return []
        }
        #expect(ipv6 == ["2001:db8::1"])
        #expect(calls.entries.withLock { $0.isEmpty })
        let resolved = try await policy.endpointAddresses(for: "resolver.example") { name, seed in
            calls.entries.withLock { $0.append((name, seed)) }
            return seed == "192.0.2.1" ? [] : ["203.0.113.53"]
        }
        #expect(resolved == ["203.0.113.53"])
        #expect(calls.entries.withLock { $0.map(\.0) } == ["resolver.example", "resolver.example"])
        #expect(calls.entries.withLock { $0.map(\.1) } == ["192.0.2.1", "192.0.2.2"])
    }

    @Test func failedExplicitBootstrapDoesNotReturnSystemName() async {
        await #expect(throws: (any Error).self) {
            try await DNSBootstrapPolicy.servers(["192.0.2.1"]).endpointAddresses(for: "resolver.example") { _, _ in [] }
        }
    }

    @Test func existingVersionWithoutBootstrapRemainsLoadable() throws {
        let direct = ProxyConfiguration(name: "Direct", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration()))
        var old = AWCore.runtimePreferences()
        old.removeValue(forKey: "bootstrapDNS")
        let bundle = RuntimeConfigurationBundle(id: UUID(), snapshotID: nil, parentID: nil,
            preferences: old, nodes: [direct], selectedNodeID: direct.id, rules: [], finalAction: .direct,
            mitmRuleSets: [], legacyRouting: nil, legacyMITM: nil)
        try bundle.validate()
        old["bootstrapDNS"] = .string("https://recursive.example")
        let invalid = RuntimeConfigurationBundle(id: UUID(), snapshotID: nil, parentID: nil,
            preferences: old, nodes: [direct], selectedNodeID: direct.id, rules: [], finalAction: .direct,
            mitmRuleSets: [], legacyRouting: nil, legacyMITM: nil)
        #expect(throws: (any Error).self) { try invalid.validate() }
    }

    @Test func parsesBoundedDoHContentLengthChunkedAndCloseDelimitedBodies() throws {
        let prefix = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\n"
        #expect(try BootstrapDoHClient.parseResponse(Data((prefix + "Content-Length: 3\r\n\r\nabc").utf8), eof: false) == Data("abc".utf8))
        #expect(try BootstrapDoHClient.parseResponse(Data((prefix + "Transfer-Encoding: chunked\r\n\r\n1\r\na\r\n2\r\nbc\r\n0\r\n\r\n").utf8), eof: false) == Data("abc".utf8))
        #expect(try BootstrapDoHClient.parseResponse(Data((prefix + "\r\nabc").utf8), eof: true) == Data("abc".utf8))
        #expect(try BootstrapDoHClient.parseResponse(Data((prefix + "Content-Length: 3\r\n\r\nab").utf8), eof: false) == nil)
    }

    @Test func rejectsRedirectsCompressionAmbiguousAndTruncatedHTTPBodies() {
        let prefix = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\n"
        for response in [
            "HTTP/1.1 302 Found\r\nLocation: https://other.example\r\n\r\n",
            prefix + "Content-Length: 3\r\nContent-Length: 3\r\n\r\nabc",
            prefix + "Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\nabc",
            prefix + "Content-Encoding: gzip\r\n\r\nabc",
            prefix + "Content-Length: 3\r\n\r\nab",
            prefix + "Transfer-Encoding: chunked\r\n\r\n3\r\nabcXX0\r\n\r\n",
            prefix + "Content-Length: 65536\r\n\r\n"
        ] { #expect(throws: (any Error).self) { try BootstrapDoHClient.parseResponse(Data(response.utf8), eof: true) } }
    }
}

@MainActor
struct DNSPublicationTests {
    @Test func explicitModeWinsAndBootstrapRollsBackWithEntireVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activation = ConfigurationActivation(store: ConfigurationSnapshotStore(directory: directory))
        let publisher = ConfigurationPublisher(activation: activation, tunnel: nil, preferencesSink: { _ in })
        _ = try await publisher.publish(text: "[DNS]\nmode=plain\nserver=223.5.5.5\ndoh=https://resolver.example/dns-query\nbootstrap-dns=1.1.1.1\n[Rule]\nFINAL,DIRECT")
        let first = try #require(publisher.bundleStore.head())
        let version = try publisher.bundleStore.load(first.current)
        #expect(version.preferences["localRequestDNSMode"] == .string("plain"))
        #expect(version.preferences["bootstrapDNS"] == .string("1.1.1.1"))
        _ = try await publisher.publish(text: "[DNS]\nmode=doh\ndoh=https://other.example/dns-query\nbootstrap-dns=system\n[Rule]\nFINAL,DIRECT")
        _ = try await publisher.rollback()
        let restored = try publisher.bundleStore.load(try #require(publisher.bundleStore.head()).current)
        #expect(restored.id == first.current)
        #expect(restored.preferences["bootstrapDNS"] == .string("1.1.1.1"))
    }
}

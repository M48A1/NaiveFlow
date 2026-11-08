import Foundation
import Network
import Testing
@testable import NaiveFlow

@Suite(.serialized)
@MainActor
struct OverallReviewRegressionTests {
    private let hostileHost = String(repeating: "a", count: 31) + "b"

    @Test func pathologicalRoutingRegexStopsAndRejectsIncludingNegation() {
        let slow = OrderedRoutingRule.Matcher.domainRegex("^(a+)+$")
        for condition in [slow, .negated(slow), .allOf([.domain(hostileHost), slow]),
                          .anyOf([.domain("other.example"), slow])] {
            let matcher = OrderedRouteMatcher(rules: [
                .init(line: 1, matcher: condition, action: .direct, noResolve: false)
            ], finalAction: .direct)
            let start = ContinuousClock.now
            let result = matcher.match(RouteQuery(host: hostileHost))
            #expect(ContinuousClock.now - start < .seconds(1))
            #expect(result.action == .reject && result.ruleLine == 1)
        }
    }

    @Test func geoRegexUsesTheSameBoundedFailClosedEvaluation() {
        var geo = NativeGeoDatabase()
        geo.domains["slow"] = [.init(kind: .regex, value: "^(a+)+$")]
        geo.prepareIndex()
        let matcher = OrderedRouteMatcher(rules: [
            .init(line: 1, matcher: .negated(.geoSite("slow")), action: .direct, noResolve: false)
        ], finalAction: .direct, geoSite: geo)
        let start = ContinuousClock.now
        #expect(matcher.match(RouteQuery(host: hostileHost)).action == .reject)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func ordinaryRegexStillMatchesAndExpiredBudgetIsExplicit() {
        #expect(RoutingRegex.evaluate("^api\\.[a-z]+\\.com$", in: "api.example.com") == .matched)
        #expect(RoutingRegex.evaluate("^api\\.", in: "www.example.com") == .noMatch)
        #expect(RoutingRegex.evaluate("[", in: "anything") == .noMatch)
        #expect(RoutingRegex.evaluate(".*", in: "example.com", deadline: .now - .seconds(1)) == .timedOut)
    }

    @Test func missingTunnelMetadataIsRejectedBeforePublication() {
        for rule in ["PROCESS-NAME,App,DIRECT", "USER-AGENT,Test,DIRECT", "URL-REGEX,.*,DIRECT",
                     "NOT,((PROCESS-NAME,App)),DIRECT"] {
            let result = ConfigurationCoordinator().compile(text: "[Rule]\n\(rule)\nFINAL,DIRECT\n")
            #expect(!result.isActivatable)
            #expect(result.diagnostics.contains { $0.severity == .error && $0.line == 2 })
        }
    }

    @Test func hysteriaPoolsDistinguishEverySessionSetting() {
        let host = UUID().uuidString.lowercased() + ".invalid"
        func runtime(_ stored: HysteriaConfiguration) -> HysteriaRuntimeConfiguration {
            HysteriaRuntimeConfiguration(configuration: stored, proxyHost: host, proxyPort: 443)
        }
        let original = HysteriaConfiguration(password: "same", serverName: "test.invalid")
        let first = HysteriaClient.shared(for: runtime(original))
        #expect(first === HysteriaClient.shared(for: runtime(original)))
        let variants = [
            HysteriaConfiguration(password: "same", congestionControl: .bbr, serverName: "test.invalid"),
            HysteriaConfiguration(password: "same", uploadMbps: 100, serverName: "test.invalid"),
            HysteriaConfiguration(password: "same", downloadMbps: 100, serverName: "test.invalid"),
            HysteriaConfiguration(password: "same", obfuscation: .salamander(password: "obfs"), serverName: "test.invalid"),
            HysteriaConfiguration(password: "same", obfuscation: .gecko(password: "obfs", minPacketSize: 512, maxPacketSize: 1200), serverName: "test.invalid")
        ]
        let clients = variants.map { HysteriaClient.shared(for: runtime($0)) }
        #expect(clients.allSatisfy { $0 !== first })
        #expect(Set(clients.map(ObjectIdentifier.init)).count == variants.count)
    }

    private let subscriptionBody = Data("{\"naiveflow\":1,\"proxies\":[{\"name\":\"Test\",\"protocol\":\"direct\"}]}".utf8)

    @Test func subscriptionRejectsHTTPErrorEvenWithValidNodes() throws {
        for status in [301, 403, 404, 500, 503] {
            let response = try #require(HTTPURLResponse(url: URL(string: "https://test.invalid/sub")!,
                statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]))
            do {
                _ = try SubscriptionFetcher.parse(data: subscriptionBody, response: response)
                Issue.record("HTTP \(status) must not become a successful subscription")
            } catch NaiveFlowError.subscription(.invalidStatusCode(let actual)) {
                #expect(actual == status)
            }
        }
    }

    @Test func subscriptionAcceptsSuccessfulHTTPAndRejectsNonHTTP() throws {
        let url = URL(string: "https://test.invalid/sub")!
        for status in [200, 201] {
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]))
            #expect(try SubscriptionFetcher.parse(data: subscriptionBody, response: response).configurations.count == 1)
        }
        #expect(throws: (any Error).self) {
            try SubscriptionFetcher.parse(data: subscriptionBody,
                response: URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil))
        }
    }

    @Test func deepLinksPreserveInnerEscapesAndDecodeOuterEncodingOnce() throws {
        let inner = "https://example.com/sub/a%2Fb%20c?token=x%252Fy&other=1"
        let raw = "naiveflow://add-proxy?link=" + inner
        #expect(DeepLinkManager.extractAddProxyLink(from: raw) == inner)
        let encoded = try #require(inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        #expect(DeepLinkManager.extractAddProxyLink(from: "naiveflow://add-proxy?link=" + encoded) == inner)
        let manager = DeepLinkManager()
        manager.handle(url: try #require(URL(string: raw)))
        #expect(manager.url == inner)
        manager.handle(url: try #require(URL(string: "naiveflow://add-rule-set?link=" + inner)))
        #expect(manager.ruleSetLink?.absoluteString == inner)
    }

    @Test func profileRequestsAreIncrementalBoundedAndPathRestricted() {
        let request = Data("GET /NaiveFlowMITMRoot.mobileconfig HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        for split in 1..<request.count {
            var reader = MITMProfileRequest()
            #expect(reader.append(Data(request.prefix(split))) == .incomplete)
            #expect(reader.append(Data(request.dropFirst(split))) == .respond(headOnly: false))
        }
        var oversized = MITMProfileRequest()
        #expect(oversized.append(Data(repeating: 65, count: MITMProfileRequest.maximumHeaderBytes)) == .incomplete)
        #expect(oversized.append(Data([65])) == .reject)
        for line in ["POST /NaiveFlowMITMRoot.mobileconfig HTTP/1.1", "GET /other HTTP/1.1"] {
            var reader = MITMProfileRequest()
            #expect(reader.append(Data((line + "\r\n\r\n").utf8)) == .reject)
        }
        var head = MITMProfileRequest()
        #expect(head.append(Data("HEAD /NaiveFlowMITMRoot.mobileconfig HTTP/1.1\r\n\r\n".utf8)) == .respond(headOnly: true))
        guard case .hostPort(let host, let port) = MITMProfileListener.parameters().requiredLocalEndpoint else {
            Issue.record("profile server must bind an explicit loopback endpoint"); return
        }
        #expect(host == "127.0.0.1" && port == .any)
    }

    @Test func profileServerServesOnlyBoundedRequestsAndExpiresIdleClients() async throws {
        let payload = Data("certificate-payload".utf8)
        let server = try MITMProfileListener(payload: payload, requestTimeout: 0.2)
        defer { server.cancel() }
        let port = try await server.start()
        func connect() async throws -> TCPTransport {
            let connection = TCPTransport(host: "127.0.0.1", port: port.rawValue)
            try await connection.connect()
            return connection
        }
        let good = try await connect()
        defer { good.cancel() }
        try await good.send(Data("GET /NaiveFlowMITMRoot.mobileconfig HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
        var response = Data()
        while case .bytes(let bytes) = try await good.receive() { response.append(bytes) }
        #expect(response.suffix(payload.count) == payload)
        let idle = try await connect()
        defer { idle.cancel() }
        try await idle.send(Data("G".utf8))
        let start = ContinuousClock.now
        do {
            let next = try await withDialDeadline(.seconds(2), onExpiry: { idle.cancel() }, error: { URLError(.timedOut) }) {
                try await idle.receive()
            }
            if case .bytes(let data) = next { #expect(data.isEmpty) }
        } catch let error as URLError { Issue.record("idle client was not closed by the server: \(error)") }
        catch { /* TCP reset is also a valid server-side close. */ }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < end else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func profileServerCapsConnectionsAndReleasesSlots() async throws {
        let server = try MITMProfileListener(payload: Data("test".utf8))
        defer { server.cancel() }
        let port = try await server.start()
        var clients: [TCPTransport] = []
        defer { clients.forEach { $0.cancel() } }
        for count in 1...MITMProfileListener.maximumConnections {
            let client = TCPTransport(host: "127.0.0.1", port: port.rawValue)
            clients.append(client)
            try await client.connect()
            try await client.send(Data("G".utf8))
            try await waitUntil { server.activeConnectionCount == count }
        }
        let excess = TCPTransport(host: "127.0.0.1", port: port.rawValue)
        defer { excess.cancel() }
        do {
            try await excess.connect()
            try await excess.send(Data("G".utf8))
            let next = try await withDialDeadline(.seconds(1), onExpiry: { excess.cancel() }, error: { URLError(.timedOut) }) {
                try await excess.receive()
            }
            if case .bytes(let bytes) = next { #expect(bytes.isEmpty) }
        } catch let error as URLError { Issue.record("excess connection was not closed: \(error)") }
        catch { /* reset is an expected admission rejection */ }
        #expect(server.activeConnectionCount == MITMProfileListener.maximumConnections)
        clients[0].cancel()
        try await waitUntil { server.activeConnectionCount == MITMProfileListener.maximumConnections - 1 }
        server.cancel()
        #expect(server.activeConnectionCount == 0)
    }

    @Test func publicationAutomaticallyBoundsRuntimeHistory() async throws {
        let path = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let activation = ConfigurationActivation(store: ConfigurationSnapshotStore(directory: path))
        let publisher = ConfigurationPublisher(activation: activation, tunnel: nil, preferencesSink: { _ in })
        for _ in 0..<(RuntimeBundleStore.retainedVersionCount + 3) {
            _ = try await publisher.publish(text: "[General]\nproxy-mode=direct\n[Rule]\nFINAL,DIRECT\n")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: publisher.bundleStore.directory.path)
        let bundles = files.filter { $0.hasSuffix(".json") && UUID(uuidString: String($0.dropLast(5))) != nil }
        #expect(bundles.count == RuntimeBundleStore.retainedVersionCount)
        _ = try await publisher.rollback()
    }

    private func bundle(parent: UUID?, padding: Int = 0) -> RuntimeConfigurationBundle {
        let node = ProxyConfiguration(name: "Direct", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration()))
        let preferences = Dictionary(uniqueKeysWithValues: AWCore.runtimePreferenceKeys.map { ($0, RuntimePreferenceValue.absent) })
        return RuntimeConfigurationBundle(id: UUID(), snapshotID: nil, parentID: parent, preferences: preferences,
            nodes: [node], selectedNodeID: node.id, rules: nil, finalAction: .direct, mitmRuleSets: [],
            legacyRouting: Data(repeating: 65, count: padding), legacyMITM: nil)
    }

    @Test func runtimePruningRetainsHeadsAndStopsRollbackAtRetentionBoundary() throws {
        let path = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = RuntimeBundleStore(directory: path)
        let lease = try store.lease()
        defer { withExtendedLifetime(lease) {} }
        var ids: [UUID] = []
        for index in 0..<25 {
            let head = try store.head()
            let version = bundle(parent: head?.current)
            try store.publish(version, expected: head)
            ids.append(version.id)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))],
                ofItemAtPath: path.appendingPathComponent("\(version.id).json").path)
            try Data("{}".utf8).write(to: path.appendingPathComponent("\(version.id).manifest-backup.json"))
        }
        let orphan = UUID()
        try Data("{}".utf8).write(to: path.appendingPathComponent("\(orphan).receipt.json"))
        try Data("keep".utf8).write(to: path.appendingPathComponent("unrelated.txt"))
        #expect(try store.prune(maximumVersions: 3) == 23)
        let files = try FileManager.default.contentsOfDirectory(atPath: path.path)
        #expect(files.count == 9) // three bundles + backups, head, lease, unrelated file
        #expect(try store.load(ids[24]).id == ids[24])
        #expect(try store.load(ids[23]).id == ids[23])
        _ = try store.rollback(expected: ids[24])
        _ = try store.rollback(expected: ids[23])
        #expect(try store.head()?.current == ids[22])
        #expect(try store.head()?.previous == nil)
    }

    @Test func runtimeByteBudgetNeverDeletesCurrentOrImmediateRollback() throws {
        let path = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = RuntimeBundleStore(directory: path)
        for _ in 0..<4 {
            let head = try store.head()
            try store.publish(bundle(parent: head?.current, padding: 1024), expected: head)
        }
        let head = try #require(try store.head())
        #expect(try store.prune(maximumBytes: 0) == 2)
        #expect(try store.load(head.current).id == head.current)
        #expect(try store.load(try #require(head.previous)).id == head.previous)
    }
}

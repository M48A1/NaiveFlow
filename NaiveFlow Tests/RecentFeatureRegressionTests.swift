import Foundation
import enum NetworkExtension.NEVPNStatus
import Testing
@testable import NaiveFlow

struct NodeShareRoundTripTests {
    private func node(_ transport: XrayTransportLayer) -> ProxyConfiguration {
        ProxyConfiguration(name: "测试 #1", serverAddress: "203.0.113.10", serverPort: 443,
            outbound: .vless(VLESSConfiguration(uuid: UUID(), encryption: "none", flow: nil,
                                                transport: transport, security: .none)))
    }

    @Test(arguments: ["/ws?token=a&mode=private#part", "/literal%2Fpath/%25/end", "/literal%invalid"])
    func webSocketPreservesPath(_ path: String) throws {
        let original = node(.ws(WebSocketConfiguration(host: "cdn.example.com", path: path)))
        let imported = try ProxyConfiguration.parse(url: original.toURLString())
        #expect(imported.outbound == original.outbound)
        #expect(imported.name == original.name)
    }

    @Test func httpUpgradePreservesReservedCharacters() throws {
        let original = node(.httpUpgrade(HTTPUpgradeConfiguration(host: "cdn.example.com", path: "/a%2Fb?x=1&y=2#part")))
        let imported = try ProxyConfiguration.parse(url: original.toURLString())
        #expect(imported.outbound == original.outbound)
    }

    @Test func grpcPreservesServiceNameAndAuthority() throws {
        let original = node(.grpc(GRPCConfiguration(serviceName: "service&name=custom#1", authority: "cdn.example.com:443")))
        let imported = try ProxyConfiguration.parse(url: original.toURLString())
        #expect(imported.outbound == original.outbound)
    }

    @Test func xhttpPreservesPercentLiteralsInPathAndJSON() throws {
        let original = node(.xhttp(XHTTPConfiguration(host: "cdn.example.com", path: "/x%2Fy?x=1&y=2",
                                                     headers: ["X-Token": "literal%2F&value#1"])))
        let imported = try ProxyConfiguration.parse(url: original.toURLString())
        guard case .vless(let config) = imported.outbound,
              case .xhttp(let xhttp) = config.transport else {
            Issue.record("Expected XHTTP node after importing its share link")
            return
        }
        #expect(xhttp.path == "/x%2Fy?x=1&y=2")
        #expect(xhttp.headers["X-Token"] == "literal%2F&value#1")
    }

    @Test(arguments: ["trojan", "anytls", "hysteria2"])
    func passwordProtocolsPreserveURLDelimiters(_ scheme: String) throws {
        let original = try ProxyConfiguration.parse(url: "\(scheme)://p%3Aass%40%3F%23%25%26word@203.0.113.10:443#test")
        let imported = try ProxyConfiguration.parse(url: original.toURLString())
        #expect(imported.outbound == original.outbound)
    }

    @Test func socksCredentialsPreserveColonAndURLDelimiters() throws {
        let original = ProxyConfiguration(name: "SOCKS", serverAddress: "203.0.113.10", serverPort: 1080,
            outbound: .socks5(SOCKS5Configuration(username: "user:name@home", password: "p:ass@?#%&word")))
        let imported = try ProxyConfiguration.parse(url: original.toURLString())
        #expect(imported.outbound == original.outbound)
    }
}

@MainActor
struct RuntimeGroupRefreshTests {
    @Test func iconOnlyPublicationRefreshesWithUnchangedNode() {
        let node = ProxyConfiguration(name: "A", serverAddress: "203.0.113.10", serverPort: 1080,
                                      outbound: .socks5(SOCKS5Configuration()))
        var bundle = RuntimeConfigurationBundle(id: UUID(), snapshotID: UUID(), parentID: nil,
            preferences: [:], nodes: [node], selectedNodeID: node.id, rules: [],
            finalAction: .defaultProxy, mitmRuleSets: [])
        let groupID = UUID()
        bundle.displayGroups = [.init(id: groupID, name: "Media", memberCount: 1, iconURL: "https://example.com/old.png")]
        let selection = ProxySelection()
        selection.showRuntimeVersion(bundle)
        #expect(selection.runtimeGroups.first?.iconURL == "https://example.com/old.png")
        bundle.displayGroups = [.init(id: groupID, name: "Media", memberCount: 1, iconURL: "https://example.com/new.png")]
        selection.showRuntimeVersion(bundle)
        #expect(selection.runtimeConfiguration == node)
        #expect(selection.runtimeGroups.first?.iconURL == "https://example.com/new.png")
        #expect(RouteTarget.defaultProxy.outboundName(defaultRouteTarget: nil, selection: selection) == node.name)
        #expect(RouteTarget.proxy(node.id).outboundName(defaultRouteTarget: nil, selection: selection) == node.name)

        let baseline = RuntimeConfigurationBundle(id: UUID(), snapshotID: UUID(), parentID: nil,
            preferences: [:], nodes: [], selectedNodeID: UUID(), rules: [],
            finalAction: .defaultProxy, mitmRuleSets: [])
        selection.showRuntimeVersion(baseline)
        #expect(selection.runtimeGroups.isEmpty)
        #expect(selection.runtimeOutboundNames.isEmpty)
        #expect(!selection.usesRuntimeVersion)
    }
}

@MainActor
struct LogsProviderRegressionTests {
    @Test func pollsTheInjectedTunnelInsteadOfAnArbitrarySavedVPN() async throws {
        let entry = TunnelLogEntry(timestamp: Date().timeIntervalSinceReferenceDate,
                                   level: .warning, message: "test-provider-log")
        let payload = try JSONEncoder().encode(LogsResponse(logs: [entry]))
        let provider = ScriptedTunnelProvider(initialStatus: .connected)
        var requestedLogs = false
        provider.onMessage = { data in
            if let message = try? JSONDecoder().decode(TunnelMessage.self, from: data), case .fetchLogs = message {
                requestedLogs = true
                return payload
            }
            return nil
        }
        let model = LogsModel()
        await model.poll(using: TunnelController(provider: provider))
        #expect(requestedLogs)
        #expect(model.logs.first?.id == entry.id)
        #expect(model.logs.first?.message == entry.message)
        #expect(model.logs.first?.level == .warning)
    }
}

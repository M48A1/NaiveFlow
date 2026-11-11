import Foundation
import Testing
@testable import NaiveFlow

struct ProxyGroupIconTests {
    @Test func importedIconsReachManualAndRuntimeGroups() throws {
        let icon = "https://example.com/icons/media.png?style=dark&v=2"
        let compiled = ConfigurationCoordinator().compile(text: """
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            [Proxy Group]
            Manual = select, A, icon-url=\(icon)
            Auto = url-test, A, icon-url=\(icon)
            [Rule]
            FINAL,Manual
            """).compiled
        #expect(compiled.proxyGroups.count == 2)
        #expect(compiled.proxyGroups.allSatisfy { $0.iconURL == icon })
        #expect(compiled.policyGroups.first?.iconURL == icon)
    }

    @Test func exportedIconSurvivesCommasAndFragments() {
        let icon = "https://example.com/media,a.png?style=dark#image"
        let source = ConfigurationExportSource(
            proxies: [.init(name: "A", url: "socks5://1.2.3.4:1080#A")],
            groups: [.init(name: "Media", members: ["A"], iconURL: icon)])
        let exported = ConfigurationExporter.export(source)
        let compiled = ConfigurationCoordinator().compile(text: exported.text).compiled
        #expect(compiled.proxyGroups.first?.iconURL == icon)
    }

    @Test func oldGroupsStillDecodeWithoutIcons() throws {
        let group = ProxyGroup(name: "Legacy", kind: .servers)
        let data = try JSONEncoder().encode(group)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "iconURL")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ProxyGroup.self, from: legacy)
        #expect(decoded.iconURL == nil)
        #expect(decoded.name == group.name)
    }

    @Test func invalidIconDoesNotChangeGroupRouting() {
        let compiled = ConfigurationCoordinator().compile(text: """
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            [Proxy Group]
            G = url-test, A, icon-url=file:///tmp/icon.png
            [Rule]
            FINAL,G
            """).compiled
        #expect(compiled.proxyGroups.first?.iconURL == nil)
        #expect(compiled.policyGroups.first?.memberIDs.count == 1)
        #expect(ProxyGroupIconURL.parse("https://example.com/icon.png") != nil)
        #expect(ProxyGroupIconURL.parse("https://user:pass@example.com/icon.png") == nil)
    }
}

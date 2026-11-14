import Foundation
import Testing
@testable import NaiveFlow

@Suite(.serialized)
@MainActor
struct ClientInterfaceTests {
    private let text = """
    # user configuration
    [General]
    proxy-mode = rule
    [Proxy]
    First = direct
    Second = socks5, 192.0.2.1, 1080
    [Proxy Group]
    Video = select, First, Second, selected=First
    [Rule]
    DOMAIN-SUFFIX, example.com, Video
    FINAL, PROXY
    """

    private func workspace() -> (URL, ClientModel) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selection = ProxySelection()
        let document = ConfigurationDocumentOperations(activation: ConfigurationActivation(store: ConfigurationSnapshotStore(directory: root.appendingPathComponent("configuration"))), selection: selection)
        let model = ClientModel(operations: Operations(container: AppContainer.preview()), directory: root.appendingPathComponent("library"), document: document)
        return (root, model)
    }

    @Test func geoSourceEditorPreservesInlineDataAndRejectsInvalidEdits() throws {
        let original = "[GeoIP]\nCN = 192.0.2.0/24 # local data\n[GeoSite]\ninternal = example.com\n"
        var draft = ClientGeoSourceDraft(site: true)
        draft.key = "ads"
        draft.source = "https://example.com/geosite,a.dat"
        draft.category = "category-ads-all"
        let updated = try draft.applying(to: original, site: true)
        let parsed = NaiveFlowConfigurationParser.parse(text: updated).configuration
        let reference = try #require(try NativeGeoResources.references(parsed).first)
        #expect(reference.url.absoluteString == draft.source)
        #expect(reference.category == draft.category)
        #expect(reference.format == "geosite-dat")
        #expect(updated.contains("CN = 192.0.2.0/24 # local data"))
        #expect(parsed.geoSite["internal"] == "example.com")
        #expect(throws: (any Error).self) { try draft.applying(to: updated, site: true) }
        var edit = ClientGeoSourceDraft(site: true, reference: reference, originalValue: parsed.geoSite["ads"])
        edit.source = "https://example.com/new.dat"
        let edited = try edit.applying(to: updated, site: true)
        #expect(try NativeGeoResources.references(NaiveFlowConfigurationParser.parse(text: edited).configuration).first?.url.absoluteString == edit.source)
        #expect(throws: (any Error).self) { try edit.applying(to: edited, site: true) }
        edit.checksum = "invalid"
        #expect(throws: (any Error).self) { try edit.applying(to: updated, site: true) }
        draft.source = "http://example.com/geosite.dat"
        #expect(throws: (any Error).self) { try draft.applying(to: original, site: true) }
        var duplicateInline = ClientGeoSourceDraft(site: false)
        duplicateInline.key = "cn"
        duplicateInline.source = "https://example.com/geoip.dat"
        #expect(throws: (any Error).self) { try duplicateInline.applying(to: original, site: false) }
    }

    @Test func manualGeoRefreshPublishesNewDataAndRetainsOldVersionOnFailure() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ipFile = root.appendingPathComponent("ip.txt")
        let siteFile = root.appendingPathComponent("site.txt")
        try Data("192.0.2.0/24\n".utf8).write(to: ipFile)
        try Data("example.com\n".utf8).write(to: siteFile)
        var ip = ClientGeoSourceDraft(site: false)
        ip.key = "CN"; ip.source = ipFile.absoluteString; ip.format = "cidr"
        var site = ClientGeoSourceDraft(site: true)
        site.key = "custom"; site.source = siteFile.absoluteString; site.format = "domain"
        var source = "[Rule]\nGEOIP, CN, DIRECT\nGEOSITE, custom, DIRECT\nFINAL, DIRECT\n"
        source = try ip.applying(to: source, site: false)
        source = try site.applying(to: source, site: true)
        await model.activate(model.createProfile(name: "Geo", text: source))
        #expect(model.error == nil)
        let store = RuntimeBundleStore(directory: model.document.activation.store.directory.appendingPathComponent("runtime-v2"))
        let first = try store.load(try #require(try store.head()).current)
        #expect(first.geo.countryCode(for: "192.0.2.1") == "CN")
        #expect(first.geo.matches(host: "www.example.com", tag: "custom"))
        try Data("198.51.100.0/24\n".utf8).write(to: ipFile)
        try Data("example.net\n".utf8).write(to: siteFile)
        #expect(await model.commit(model.operatingText))
        let refreshed = try store.load(try #require(try store.head()).current)
        #expect(refreshed.id != first.id)
        #expect(refreshed.geo.countryCode(for: "198.51.100.1") == "CN")
        #expect(refreshed.geo.countryCode(for: "192.0.2.1") == nil)
        #expect(refreshed.geo.matches(host: "www.example.net", tag: "custom"))
        #expect(!refreshed.geo.matches(host: "www.example.com", tag: "custom"))
        #expect(refreshed.geo.sources.count == 2)
        try Data("not an IPv4 network\n".utf8).write(to: ipFile)
        #expect(!(await model.commit(model.operatingText)))
        #expect(model.error != nil)
        #expect(try store.head()?.current == refreshed.id)
        #expect(model.profile?.text == source)
    }

    @Test func underlyingProxyCompilesInOrderAndRejectsInvalidGraphs() throws {
        let source = """
        [Proxy]
        Entry = socks5, 192.0.2.1, 1080
        Middle = socks5, 192.0.2.2, 1080, underlying-proxy=Entry
        Exit = socks5, 192.0.2.3, 1080, underlying-proxy=Middle
        [Rule]
        FINAL, Exit
        """
        let result = TextConfigurationPipeline.process(text: source)
        #expect(result.isActivatable)
        let exit = try #require(result.compiled.proxies.first { $0.name == "Exit" })
        #expect(exit.chain?.map(\.name) == ["Entry", "Middle"])
        #expect(exit.chain?.allSatisfy { $0.chain == nil } == true)
        #expect(exit.underlyingProxy == "Middle")
        for broken in [
            source.replacingOccurrences(of: "underlying-proxy=Middle", with: "underlying-proxy=Missing"),
            source.replacingOccurrences(of: "underlying-proxy=Middle", with: "underlying-proxy=Exit"),
            source.replacingOccurrences(of: "Entry = socks5, 192.0.2.1, 1080", with: "Entry = socks5, 192.0.2.1, 1080, underlying-proxy=Exit"),
            source.replacingOccurrences(of: "Entry = socks5, 192.0.2.1, 1080", with: "Entry = direct")
        ] { #expect(!TextConfigurationPipeline.process(text: broken).isActivatable) }
        var linkNode = exit.withChain(nil)
        linkNode.underlyingProxy = "Front, CN+α &"
        linkNode.blockQUIC = false
        let decoded = try ProxyConfiguration.parse(url: linkNode.toURLString())
        #expect(decoded.underlyingProxy == linkNode.underlyingProxy)
        #expect(decoded.blockQUIC == false)
        #expect(try JSONDecoder().decode(ProxyConfiguration.self, from: JSONEncoder().encode(linkNode)).underlyingProxy == linkNode.underlyingProxy)
        #expect(linkNode.withResolvedIP("192.0.2.4").underlyingProxy == linkNode.underlyingProxy)
    }

    @Test func nodeChainChangesReachRuntimeAndProtectReferences() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        [General]
        default-node = Exit
        [Proxy]
        Entry = socks5, 192.0.2.1, 1080
        Exit = socks5, 192.0.2.2, 1080, underlying-proxy=Entry
        [Rule]
        FINAL, Exit
        """
        await model.activate(model.createProfile(name: "Chain", text: source))
        #expect(model.error == nil)
        let exitID = try #require(model.nodes.first { $0.name == "Exit" }?.id)
        let entry = try #require(model.nodes.first { $0.name == "Entry" })
        let changed = ProxyConfiguration(id: entry.id, name: entry.name, serverAddress: "192.0.2.9", serverPort: entry.serverPort, outbound: entry.outbound)
        await model.saveNode(changed, replacing: entry.name)
        #expect(model.error == nil)
        #expect(model.nodes.first { $0.name == "Exit" }?.id == exitID)
        #expect(model.nodes.first { $0.name == "Exit" }?.chain?.first?.serverAddress == "192.0.2.9")
        let renamed = ProxyConfiguration(id: entry.id, name: "Front", serverAddress: changed.serverAddress, serverPort: entry.serverPort, outbound: entry.outbound)
        await model.saveNode(renamed, replacing: entry.name)
        #expect(model.error == nil)
        #expect(model.nodes.first { $0.name == "Exit" }?.underlyingProxy == "Front")
        #expect(model.nodes.first { $0.name == "Exit" }?.chain?.first?.serverAddress == "192.0.2.9")
        let store = RuntimeBundleStore(directory: model.document.activation.store.directory.appendingPathComponent("runtime-v2"))
        let bundle = try store.load(try #require(try store.head()).current)
        #expect(bundle.selectedNode?.name == "Exit")
        #expect(bundle.selectedNode?.chain?.map(\.name) == ["Front"])
        await model.deleteNode("Front")
        #expect(model.error != nil)
        #expect(model.nodes.contains { $0.name == "Front" })
        model.error = nil
        var cyclic = renamed
        cyclic.underlyingProxy = "Exit"
        await model.saveNode(cyclic, replacing: "Front")
        #expect(model.error != nil)
        #expect(model.nodes.first { $0.name == "Front" }?.underlyingProxy == nil)
        model.error = nil
        var exit = try #require(model.nodes.first { $0.name == "Exit" })
        exit.underlyingProxy = nil
        await model.saveNode(exit, replacing: exit.name)
        #expect(model.error == nil)
        #expect(model.nodes.first { $0.name == "Exit" }?.chain == nil)
    }

    @Test func nodeQUICPreferenceRoundTripsAndPreservesLegacyDefault() throws {
        for value in [true, false] {
            let node = ProxyConfiguration(name: "QUIC Node", serverAddress: "192.0.2.1", serverPort: 1080,
                outbound: .socks5(SOCKS5Configuration(username: nil, password: nil)), blockQUIC: value)
            let parsed = try ProxyConfiguration.parse(url: node.toURLString())
            #expect(parsed.blockQUIC == value)
            #expect(node.withChain([]).blockQUIC == value)
            #expect(node.withResolvedIP("192.0.2.2").blockQUIC == value)
            let entry = ProxyConfiguration(name: "Entry", serverAddress: "192.0.2.2", serverPort: 1080,
                outbound: .socks5(SOCKS5Configuration(username: nil, password: nil)))
            let chain = ProxyChain(name: "Chain", proxyIds: [entry.id, node.id])
            #expect(chain.resolveComposite(from: [entry, node])?.blockQUIC == value)
            let compiled = TextConfigurationPipeline.process(text: "[Proxy]\nTest = \(node.toURLString())\n[Rule]\nFINAL, Test")
            #expect(compiled.isActivatable)
            #expect(compiled.compiled.proxies.first?.blockQUIC == value)
            #expect(try JSONDecoder().decode(ProxyConfiguration.self, from: JSONEncoder().encode(node)).blockQUIC == value)
        }
        let legacy = ProxyConfiguration(name: "Old", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration()))
        #expect(try JSONDecoder().decode(ProxyConfiguration.self, from: JSONEncoder().encode(legacy)).blockQUIC == nil)
        #expect(QUICPolicy.automatic.blocksQUIC(isProxied: true, nodeOverride: nil))
        #expect(!QUICPolicy.automatic.blocksQUIC(isProxied: true, nodeOverride: false))
        #expect(QUICPolicy.unblocked.blocksQUIC(isProxied: true, nodeOverride: true))
        #expect(QUICPolicy.blocked.blocksQUIC(isProxied: true, nodeOverride: false))
        #expect(QUICPolicy.automatic.blocksQUIC(mitmListed: true))
    }

    @Test func nodeQUICFieldFormCompilesAndRejectsInvalidValues() {
        for value in ["true", "false"] {
            let result = TextConfigurationPipeline.process(text: "[Proxy]\nTest = socks5, 192.0.2.1, 1080, block-quic=\(value)\n[Rule]\nFINAL, Test")
            #expect(result.isActivatable)
            #expect(result.compiled.proxies.first?.blockQUIC == (value == "true"))
        }
        let invalid = TextConfigurationPipeline.process(text: "[Proxy]\nTest = socks5, 192.0.2.1, 1080, block-quic=invalid")
        #expect(!invalid.isActivatable)
    }

    @Test func savingNodeQUICPreferenceReachesRuntimeBundle() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: text))
        var node = try #require(model.nodes.first { $0.name == "Second" })
        node.blockQUIC = false
        await model.saveNode(node, replacing: node.name)
        #expect(model.error == nil)
        #expect(model.nodes.first { $0.name == node.name }?.blockQUIC == false)
        let store = RuntimeBundleStore(directory: model.document.activation.store.directory.appendingPathComponent("runtime-v2"))
        let bundle = try store.load(try #require(try store.head()).current)
        #expect(bundle.nodes.first { $0.name == node.name }?.blockQUIC == false)
    }

    @Test func externalIconPackDecodesFiltersAndDeduplicates() throws {
        let data = Data(#"{"name":"离歌图标包","description":"示例","icons":[{"name":"A","url":"https://example.com/a.png"},{"name":"Duplicate","url":"https://example.com/a.png"},{"name":"Bad","url":"http://example.com/b.png"}]}"#.utf8)
        let pack = try ClientIconPack.decode(data, source: ClientIconPack.defaultSource)
        #expect(pack.name == "离歌图标包")
        #expect(pack.icons.count == 1)
        #expect(pack.icons.first?.url == "https://example.com/a.png")
        #expect(pack.description == "示例")
        #expect(throws: (any Error).self) {
            try ClientIconPack.decode(Data(#"{"name":"Bad","icons":[{"name":"Bad","url":"http://example.com/a.png"}]}"#.utf8), source: ClientIconPack.defaultSource)
        }
        #expect(throws: (any Error).self) {
            try ClientIconPack.decode(Data(#"{"name":"Bad","icons":[]}"#.utf8), source: ClientIconPack.defaultSource)
        }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(try JSONEncoder().encode([pack]), forKey: "client.externalIconPacks.v1")
        let library = ClientIconPackLibrary(defaults: defaults)
        #expect(library.packs.first?.icons == pack.icons)
        library.remove(pack.id)
        #expect(ClientIconPackLibrary(defaults: defaults).packs.isEmpty)
    }

    @Test func newRuleSetPrecedesFinalAndPreservesQuotedPolicy() throws {
        let updated = try ClientDocumentEditing.saveRuleSet(text, original: nil,
            source: "https://example.com/rules,a.list", policy: "Media, Video", noResolve: true)
        let parsed = NaiveFlowConfigurationParser.parse(text: updated).configuration
        let added = try #require(parsed.rules.first { $0.kind == .ruleSet })
        #expect(added.value == "https://example.com/rules,a.list")
        #expect(added.policy == .named("Media, Video"))
        #expect(added.hasOption(.noResolve))
        #expect(added.line < (parsed.finalRule?.line ?? 0))
        #expect(updated.contains("# user configuration"))
        #expect(parsed.rules.count == 3)
    }

    @Test func editingRuleSetPreservesOtherRulesAndComments() throws {
        let source = text.replacingOccurrences(of: "FINAL, PROXY", with: "RULE-SET, https://example.com/old.list, DIRECT, no-resolve  # keep comment\nFINAL, PROXY")
        let original = try #require(NaiveFlowConfigurationParser.parse(text: source).configuration.rules.first { $0.kind == .ruleSet })
        let updated = try ClientDocumentEditing.saveRuleSet(source, original: original,
            source: "https://example.com/new.list", policy: "REJECT", noResolve: false)
        let parsed = NaiveFlowConfigurationParser.parse(text: updated).configuration
        let edited = try #require(parsed.rules.first { $0.kind == .ruleSet })
        #expect(edited.value == "https://example.com/new.list")
        #expect(edited.policy == .reject)
        #expect(!edited.hasOption(.noResolve))
        #expect(updated.contains("# keep comment"))
        #expect(parsed.rules.first?.policy == .named("Video"))
        #expect(parsed.rules.last?.kind == .final)
        #expect(parsed.rules.count == 3)
        #expect(throws: (any Error).self) {
            try ClientDocumentEditing.saveRuleSet(updated, original: original,
                source: "https://example.com/another.list", policy: "DIRECT", noResolve: false)
        }
    }

    @Test func ruleSetSourceRejectsInvalidURLsAndNewlines() throws {
        for source in ["http://example.com/rules.list", "https://user:pass@example.com/rules.list", "https://example.com/rules.list\nFINAL, DIRECT"] {
            #expect(throws: (any Error).self) {
                try ClientDocumentEditing.saveRuleSet(text, original: nil, source: source, policy: "DIRECT", noResolve: false)
            }
        }
        let updated = try ClientDocumentEditing.saveRuleSet("[General]\nproxy-mode = rule\n", original: nil,
            source: "https://example.com/rules.list", policy: "DIRECT", noResolve: false)
        #expect(NaiveFlowConfigurationParser.parse(text: updated).configuration.rules.first?.kind == .ruleSet)
    }

    @Test func structuredSettingPreservesCommentsAndRejectsNoKeys() {
        let updated = ClientDocumentEditing.set(text, section: .general, key: "default-node", value: ClientDocumentEditing.token("Second"))
        let compiled = TextConfigurationPipeline.process(text: updated)
        #expect(compiled.isActivatable)
        #expect(compiled.parsed.general["default-node"] == "Second")
        #expect(updated.contains("# user configuration"))
    }

    @Test func repeatedSettingsDoNotCreateDuplicateKeys() {
        var updated = ClientDocumentEditing.set(text, section: .general, key: "proxy-mode", value: "global")
        updated = ClientDocumentEditing.set(updated, section: .general, key: "proxy-mode", value: "direct")
        let document = ConfigurationDocument.parse(text: updated)
        #expect(document.entries(.general).filter { $0.key == "proxy-mode" }.count == 1)
        #expect(TextConfigurationPipeline.process(text: updated).isActivatable)
    }

    @Test func defaultNodeMustResolve() {
        let invalid = text.replacingOccurrences(of: "proxy-mode = rule", with: "default-node = Missing")
        #expect(!TextConfigurationPipeline.process(text: invalid).isActivatable)
    }

    @Test func selectingNodePublishesTheSameNodeToTheKernel() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = model.createProfile(name: "Test", text: text)
        await model.activate(profile)
        await model.selectNode("Second")
        #expect(model.error == nil)
        #expect(model.selectedNodeName == "Second")
        let store = RuntimeBundleStore(directory: model.document.activation.store.directory.appendingPathComponent("runtime-v2"))
        let head = try #require(try store.head())
        let bundle = try store.load(head.current)
        #expect(bundle.selectedNode?.name == "Second")
        #expect(model.profile?.text.contains("default-node") == true)
        let loaded = try ClientProfileLibrary.load(from: root.appendingPathComponent("library"))
        #expect(loaded.selectedID == profile.id)
    }

    @Test func editingGroupUpdatesRuleRoutingAndKeepsNodeIdentityForLatency() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: text))
        let firstID = try #require(model.nodes.first?.id)
        let group = try #require(model.groups.first)
        await model.selectMember("Second", in: group)
        #expect(model.error == nil)
        #expect(model.groups.first?.parameters["selected"] == "Second")
        #expect(model.nodes.first?.id == firstID)
        let store = RuntimeBundleStore(directory: model.document.activation.store.directory.appendingPathComponent("runtime-v2"))
        let bundle = try store.load(try #require(try store.head()).current)
        guard case .proxy(let id) = bundle.rules.first?.action else { Issue.record("Expected a selected proxy action"); return }
        #expect(bundle.nodes.first { $0.id == id }?.name == "Second")
    }

    @Test func renameGroupRewritesItsRulesAndPreservesComments() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: text))
        let success = await model.saveGroup(original: "Video", name: "Media", kind: "select", members: ["First", "Second"], parameters: [("selected", "Second")], style: ClientGroupStyle(palette: 4))
        #expect(success)
        #expect(model.parsed.rules.first?.policy == .named("Media"))
        #expect(model.groups.map(\.name) == ["Media"])
        #expect(model.profile?.text.contains("# user configuration") == true)
    }

    @Test func referencedNodeDeletionCannotSilentlyBreakAConfiguration() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = text.replacingOccurrences(of: "example.com, Video", with: "example.com, Second")
        await model.activate(model.createProfile(name: "Test", text: source))
        let before = model.profile?.text
        await model.deleteNode("Second")
        #expect(model.error != nil)
        #expect(model.profile?.text == before)
        #expect(model.nodes.contains { $0.name == "Second" })
    }

    @Test func savingWithoutApplyingDoesNotChangeDisplayedRuntimeMode() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: text))
        var draft = try #require(model.profile)
        draft.text = ClientDocumentEditing.set(draft.text, section: .general, key: "proxy-mode", value: "global")
        #expect(await model.saveProfile(draft, apply: false))
        #expect(model.mode == .rule)
        #expect(model.profile?.text.contains("global") == true)
    }

    @Test func removingActiveProfileRequiresSwitchingFirst() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = model.createProfile(name: "Test", text: text)
        await model.activate(profile)
        model.deleteProfile(profile.id)
        #expect(model.library.profiles.contains { $0.id == profile.id })
        #expect(model.error != nil)
    }

    @Test func groupKeysWithSpacesAndCommaRoundTrip() {
        let updated = ClientDocumentEditing.set(text, section: .proxyGroup, key: "Media, US", value: ClientDocumentEditing.groupValue(kind: "select", members: ["First", "Second"], parameters: [("selected", "Second")]))
        let parsed = TextConfigurationPipeline.process(text: updated)
        #expect(parsed.isActivatable)
        #expect(parsed.parsed.proxyGroups.last?.name == "Media, US")
        #expect(parsed.parsed.proxyGroups.last?.parameters["selected"] == "Second")
    }
    @Test func modulesArePublishedAsDocumentRulesAndCanBeDisabled() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: text))
        let module = ClientModule(name: "Rewrite", summary: "Test rewrite", source: "[URL Rewrite]\n^https://module.example/ https://example.org/ 302\n[MITM]\nhostname = module.example", format: .surge)
        #expect(await model.saveModule(module))
        let saved = try #require(model.modules.first)
        #expect(saved.setKeys.count == 1)
        #expect(model.parsed.mitmSets.pairs.count == 1)
        await model.toggleModule(saved, enabled: false)
        #expect(model.modules.first?.enabled == false)
        let compiled = TextConfigurationPipeline.process(text: model.operatingText)
        #expect(compiled.compiled.textMITM.embeddedSets.first?.enabled == false)
        await model.deleteModule(try #require(model.modules.first))
        #expect(model.modules.isEmpty)
        #expect(model.parsed.mitmSets.pairs.isEmpty)
    }

    @Test func pastedBase64SubscriptionsImportIntoTheDocument() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: text))
        let source = "socks5://192.0.2.9:1080#Imported"
        let encoded = Data(source.utf8).base64EncodedString()
        #expect(try await model.importNodes(encoded))
        #expect(model.nodes.contains { $0.name == "Imported" })
        #expect(model.profile?.text.contains("Imported") == true)
    }

    @Test func updatingAGroupDoesNotReorderCardsOrLoseInlineComments() {
        let source = "[Proxy Group]\nFirst = select, A  # Keep this\nSecond = select, B\n"
        let updated = ClientDocumentEditing.set(source, section: .proxyGroup, key: "First", value: "select, C")
        let entries = ConfigurationDocument.parse(text: updated).entries(.proxyGroup)
        #expect(entries.map { ConfigurationDocument.unquoted($0.key ?? "") } == ["First", "Second"])
        #expect(updated.contains("# Keep this"))
        let renamed = ClientDocumentEditing.renameKey(updated, section: .proxyGroup, from: "First", to: "Renamed")
        #expect(ConfigurationDocument.parse(text: renamed).entries(.proxyGroup).first?.value == "select, C")
        #expect(renamed.contains("# Keep this"))
    }

}

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

    @Test func dnsMappingEditorPreservesConfigurationAndCompilesMultipleAddresses() throws {
        let source = text + "\n[DNS]\ndns-mode = default\n[Host]\n# local services\nold.example = 192.0.2.1  # office\n[MITM]\nenable = false\n"
        let mappings = [
            HostMapping(host: " Example.COM ", address: " 192.0.2.10 "),
            HostMapping(host: "example.com", address: "192.0.2.11"),
            HostMapping(host: "*.internal.example", address: "10.0.0.1")
        ]
        let updated = try ClientDocumentEditing.setHostMappings(source, mappings: mappings)
        let result = TextConfigurationPipeline.process(text: updated)
        #expect(result.compiled.isActivatable)
        #expect(result.compiled.hosts == [
            HostMapping(host: "example.com", address: "192.0.2.10"),
            HostMapping(host: "example.com", address: "192.0.2.11"),
            HostMapping(host: "*.internal.example", address: "10.0.0.1")
        ])
        #expect(updated.contains("# local services"))
        #expect(updated.contains("# office"))
        #expect(updated.contains("[DNS]\ndns-mode = default"))
        #expect(updated.contains("[MITM]\nenable = false"))
        #expect(updated.hasPrefix(text))
        let deleted = try ClientDocumentEditing.setHostMappings(updated, mappings: [])
        #expect(NaiveFlowConfigurationParser.parse(text: deleted).configuration.hosts.isEmpty)
        let added = try ClientDocumentEditing.setHostMappings(text, mappings: [mappings[2]])
        #expect(TextConfigurationPipeline.process(text: added).compiled.hosts == [mappings[2]])
    }

    @Test func dnsMappingEditorRejectsInvalidOrIncompleteMappings() {
        for mapping in [
            HostMapping(host: "", address: "192.0.2.1"),
            HostMapping(host: "example.com", address: ""),
            HostMapping(host: "example.com", address: "256.1.1.1"),
            HostMapping(host: "example.com", address: "::1"),
            HostMapping(host: "bad\nhost", address: "192.0.2.1")
        ] {
            #expect(throws: (any Error).self) {
                try ClientDocumentEditing.setHostMappings(text, mappings: [mapping])
            }
        }
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

    @Test func bulkModuleRefreshPreservesLocalModulesAndEnabledStateAndRejectsPartialUpdates() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: text))
        func source(_ host: String, revision: String) -> String {
            "[URL Rewrite]\n^https://\(host)/ https://example.org/\(revision) 302\n[MITM]\nhostname = \(host)"
        }
        for (host, remote, enabled) in [("one.example", true, true), ("two.example", true, false), ("local.example", false, true)] {
            let module = ClientModule(name: host, summary: host, source: source(host, revision: "old"),
                sourceURL: remote ? "https://\(host)/module" : nil, format: .surge, enabled: enabled)
            #expect(await model.saveModule(module))
        }
        let local = try #require(model.modules.first { $0.sourceURL == nil })
        let before = model.operatingText
        #expect(!(await model.refreshAllModules { url in
            if url.contains("two.example") { throw ClientFailure("Download failed") }
            return source("one.example", revision: "new")
        }))
        #expect(model.operatingText == before)
        #expect(model.modules.filter { $0.sourceURL != nil }.allSatisfy { $0.source.contains("/old") })
        #expect(model.error?.contains("two.example") == true)
        model.error = nil
        #expect(await model.refreshAllModules { url in
            source(url.contains("one.example") ? "one.example" : "two.example", revision: "new")
        })
        #expect(model.modules.first { $0.sourceURL == nil } == local)
        #expect(model.modules.filter { $0.sourceURL != nil }.allSatisfy { $0.source.contains("/new") })
        #expect(model.modules.first { $0.name == "one.example" }?.enabled == true)
        #expect(model.modules.first { $0.name == "two.example" }?.enabled == false)
        #expect(model.parsed.mitmSets.pairs.count == 3)
        #expect(!model.isBusy)
    }

    @Test func subscriptionNodesRemainInAllNodesAndKeepManualEditsOnRefresh() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Subscriptions", text: text))
        let url = "https://subscription.example/nodes"
        let source = "[Proxy]\n\"HK Sub\" = socks5, 192.0.2.10, 1080\n\"JP Sub\" = socks5, 192.0.2.20, 1080"
        #expect(try await model.importNodes(source, subscriptionURL: url))
        #expect(model.nodes.count == 4)
        let hk = try #require(model.nodes.first { $0.name == "HK Sub" })
        let edited = ProxyConfiguration(name: "Custom HK", serverAddress: "198.51.100.99", serverPort: 1081, outbound: hk.outbound)
        await model.saveNode(edited, replacing: hk.name)
        #expect(try await model.importNodes(source.replacingOccurrences(of: "1080", with: "2080"), subscriptionURL: url))
        #expect(model.nodes.first { $0.name == "Custom HK" }?.serverAddress == "198.51.100.99")
        #expect(model.nodes.first { $0.name == "Custom HK" }?.serverPort == 1081)
        #expect(model.nodes.first { $0.name == "JP Sub" }?.serverPort == 2080)
        #expect(model.nodes.count == 4)
        let subscription = try #require(model.profile?.nodeSubscriptions?.first)
        #expect(subscription.members.map(\.name) == ["Custom HK", "JP Sub"])
        #expect(subscription.members.first?.edited == true)
        #expect(await model.saveGroup(original: nil, name: "HK Only", kind: "select", members: ["PROXY"],
            parameters: [("filter", "(HK|港)")], style: ClientGroupStyle()))
        let group = try #require(model.groups.first { $0.name == "HK Only" })
        #expect(model.resolvedGroup(group).members == ["Custom HK"])
        #expect(await model.saveGroup(original: nil, name: "PROXY", kind: "select", members: ["First"], parameters: [], style: ClientGroupStyle()) == false)
        await model.deleteGroup("PROXY")
        #expect(model.nodes.count == 4)
        #expect(model.profile?.nodeSubscriptions?.count == 1)
        let encoded = try JSONEncoder().encode(model.profile)
        #expect(try JSONDecoder().decode(ClientProfile?.self, from: encoded)?.nodeSubscriptions == [subscription])
    }

    @Test func subscriptionUpdateAllIsAtomicAndCanBeScopedToOneGroup() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Subscriptions", text: text))
        func source(_ name: String, port: Int) -> String { "[Proxy]\n\(name) = socks5, 192.0.2.1, \(port)" }
        for name in ["A", "B"] {
            #expect(try await model.importNodes(source(name, port: 1080), subscriptionURL: "https://\(name.lowercased()).example/list"))
        }
        let before = model.operatingText
        #expect(!(await model.refreshNodeSubscriptions { url in
            if url.contains("b.example") { throw ClientFailure("Download failed") }
            return source("A", port: 2080)
        }))
        #expect(model.operatingText == before)
        model.error = nil
        #expect(await model.refreshNodeSubscriptions { url in source(url.contains("a.example") ? "A" : "B", port: 2080) })
        #expect(model.nodes.first { $0.name == "A" }?.serverPort == 2080)
        #expect(model.nodes.first { $0.name == "B" }?.serverPort == 2080)
        let group = try #require(model.profile?.nodeSubscriptions?.first { $0.url.contains("a.example") })
        #expect(await model.refreshNodeSubscriptions(ids: [group.id]) { url in
            guard url == group.url else { throw ClientFailure("Only the selected subscription may refresh") }
            return source("A", port: 3080)
        })
        #expect(model.nodes.first { $0.name == "A" }?.serverPort == 3080)
        #expect(model.nodes.first { $0.name == "B" }?.serverPort == 2080)
        #expect(model.nodes.count == 4)
        #expect(!model.isBusy)
    }

    @Test func legacyProfileWithoutSubscriptionsStillDecodes() throws {
        let original = ClientProfile(name: "Legacy", text: text)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "nodeSubscriptions")
        let decoded = try JSONDecoder().decode(ClientProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.nodeSubscriptions == nil)
        #expect(decoded.name == "Legacy")
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

extension ClientInterfaceTests {
    @Test func unifiedResourceUpdatesHoldOneLockAndPublishOnlyOnce() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Resources", text: text))
        for name in ["first", "second"] {
            let module = ClientModule(name: name, summary: name,
                source: "[URL Rewrite]\n^https://\(name).example/ https://example.org/old 302\n[MITM]\nhostname=\(name).example",
                sourceURL: "https://\(name).example/module", format: .surge)
            #expect(await model.manageResource(.save(.module(module))))
        }
        let before = model.document.activation.store.snapshots().count
        let ids = model.modules.map(\.id)
        var blocked = false
        let updated = await model.manageResource(.update(.modules()), fetch: { url in
            guard model.isBusy else { throw ClientFailure("Resource lock must cover downloading") }
            let unrelated = ClientNodeSubscription(name: "Other", url: "https://other.example/list")
            blocked = !(await model.manageResource(.save(.subscription(unrelated))))
            guard blocked else { throw ClientFailure("Overlapping resource writes must be blocked") }
            let host = url.contains("first.example") ? "first.example" : "second.example"
            return "[URL Rewrite]\n^https://\(host)/ https://example.org/new 302\n[MITM]\nhostname=\(host)"
        })
        #expect(updated)
        #expect(blocked)
        #expect(!model.isBusy)
        #expect(model.document.activation.store.snapshots().count == before + 1)
        #expect(model.modules.map(\.id) == ids)
        #expect(model.modules.allSatisfy { $0.source.contains("/new") })
        #expect(model.profile?.nodeSubscriptions == nil)
    }

    @Test func unifiedMetadataEditsPreserveSavedDraftAndDoNotPublish() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Resources", text: text))
        let liveText = model.operatingText
        var draft = try #require(model.profile)
        draft.text += "\n# saved draft only\n"
        #expect(await model.saveProfile(draft, apply: false))
        let before = model.document.activation.store.snapshots().count
        let first = ClientNodeSubscription(name: "First", url: "https://first.example/list")
        let second = ClientNodeSubscription(name: "Second", url: "https://second.example/list")
        #expect(await model.manageResource(.save(.subscription(first))))
        #expect(await model.manageResource(.save(.subscription(second))))
        var renamed = first; renamed.name = "Renamed"
        #expect(await model.manageResource(.save(.subscription(renamed))))
        #expect(model.profile?.nodeSubscriptions?.map(\.id) == [first.id, second.id])
        #expect(model.profile?.text == draft.text)
        #expect(model.operatingText == liveText)
        #expect(await model.manageResource(.delete(.subscription(first.id))))
        #expect(model.nodes.count == 2)
        #expect(model.document.activation.store.snapshots().count == before)
        #expect(model.profile?.nodeSubscriptions?.map(\.id) == [second.id])
    }

    @Test func unifiedResourceUpdateRejectsConcurrentExternalProfileChange() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Resources", text: text))
        let subscription = ClientNodeSubscription(name: "External", url: "https://external.example/list")
        #expect(await model.manageResource(.save(.subscription(subscription))))
        let changed = model.operatingText + "\n# external version\n"
        let updated = await model.manageResource(.update(.subscriptions()), fetch: { _ in
            _ = try await model.document.apply(changed)
            model.refresh()
            return "socks5://192.0.2.99:1080#ShouldNotApply"
        })
        #expect(!updated)
        #expect(!model.isBusy)
        #expect(model.error?.contains("changed") == true)
        #expect(model.document.activation.active?.text == changed)
        #expect(!model.nodes.contains { $0.name == "ShouldNotApply" })
        #expect(model.profile?.nodeSubscriptions?.first?.members.isEmpty == true)
    }

    @Test func cancelledUnifiedResourceOperationNeverFetchesOrPublishes() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Resources", text: text))
        let subscription = ClientNodeSubscription(name: "External", url: "https://external.example/list")
        #expect(await model.manageResource(.save(.subscription(subscription))))
        let before = model.document.activation.store.manifest().activeSnapshotId
        var calls = 0
        let task = Task { await model.manageResource(.update(.subscriptions()), fetch: { _ in
            calls += 1
            return "socks5://192.0.2.99:1080#Cancelled"
        }) }
        task.cancel()
        #expect(!(await task.value))
        #expect(calls == 0)
        #expect(!model.isBusy)
        #expect(model.document.activation.store.manifest().activeSnapshotId == before)
        #expect(!model.nodes.contains { $0.name == "Cancelled" })
    }

    @Test func unifiedGeoResourceEditsValidateBeforeReplacingTheProfile() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Resources", text: text))
        let file = root.appendingPathComponent("geo.txt")
        try Data("example.com\nexample.org\n".utf8).write(to: file)
        var draft = ClientGeoSourceDraft(site: true)
        draft.key = "demo"; draft.source = file.absoluteString; draft.format = "domain"
        #expect(await model.manageResource(.save(.geo(draft, site: true))))
        let applied = model.operatingText
        let original = try #require(model.parsed.geoSite["demo"])
        let reference = try #require(try NativeGeoResources.references(model.parsed).first { $0.key == "demo" })
        var edit = ClientGeoSourceDraft(site: true, reference: reference, originalValue: original)
        edit.checksum = "invalid"
        #expect(!(await model.manageResource(.save(.geo(edit, site: true)))))
        #expect(model.operatingText == applied)
        model.error = nil
        edit.checksum = ""
        #expect(await model.manageResource(.delete(.geo(edit, site: true))))
        #expect(model.parsed.geoSite["demo"] == nil)
        #expect(!model.isBusy)
    }
}

extension ClientInterfaceTests {
    @Test func subscriptionHWIDDefaultsOffAndPersistsPerSubscription() throws {
        var enabled = ClientNodeSubscription(name: "Enabled", url: "https://enabled.example/list")
        #expect(!enabled.remnawaveHWIDEnabled)
        enabled.remnawaveHWIDEnabled = true
        let decoded = try JSONDecoder().decode(ClientNodeSubscription.self, from: JSONEncoder().encode(enabled))
        #expect(decoded.remnawaveHWIDEnabled)
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(enabled)) as? [String: Any])
        legacy.removeValue(forKey: "remnawaveHWIDEnabled")
        let old = try JSONDecoder().decode(ClientNodeSubscription.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!old.remnawaveHWIDEnabled)
        #expect(old.id == enabled.id)
    }

    @Test func unifiedSubscriptionUpdatesKeepEachHWIDOptionForImportAndUpdateAll() async throws {
        let enabled = ClientNodeSubscription(name: "Enabled", url: "https://enabled.example/list", remnawaveHWIDEnabled: true)
        let disabled = ClientNodeSubscription(name: "Disabled", url: "https://disabled.example/list")
        var profile = ClientProfile(name: "Requests", text: text)
        profile.nodeSubscriptions = [enabled, disabled]
        var seen: [UUID: Bool] = [:]
        let fetch: ClientResourceManager.FetchSubscription = { subscription in
            seen[subscription.id] = subscription.remnawaveHWIDEnabled
            return "socks5://192.0.2.10:1080#\(subscription.name)"
        }
        let generic: ClientResourceManager.FetchText = { _ in throw ClientFailure("Node subscriptions must use their own request options") }
        let all = try #require(try await ClientResourceManager.prepare(.update(.subscriptions()), profile: profile,
            text: text, fetch: generic, fetchSubscription: fetch))
        #expect(seen == [enabled.id: true, disabled.id: false])
        #expect(all.profile.nodeSubscriptions?.map(\.remnawaveHWIDEnabled) == [true, false])
        seen = [:]
        _ = try await ClientResourceManager.prepare(.update(.subscriptionURL(enabled.url)), profile: all.profile,
            text: all.profile.text, fetch: generic, fetchSubscription: fetch)
        #expect(seen == [enabled.id: true])
        seen = [:]
        let fresh = ClientNodeSubscription(name: "New", url: "https://new.example/list", remnawaveHWIDEnabled: true)
        let imported = try #require(try await ClientResourceManager.prepare(.update(.subscription(fresh)), profile: all.profile,
            text: all.profile.text, fetch: generic, fetchSubscription: fetch))
        #expect(seen == [fresh.id: true])
        #expect(imported.profile.nodeSubscriptions?.first { $0.id == fresh.id }?.remnawaveHWIDEnabled == true)
    }
}

extension ClientInterfaceTests {
    @Test func groupEditorNoLongerSavesDefaultMemberButManualNodeSelectionStillWorks() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ClientDocumentEditing.set(text, section: .proxyGroup, key: "Video", value: "select, First, Second, selected=Second")
        await model.activate(model.createProfile(name: "Group Editor", text: source))
        let original = try #require(model.groups.first { $0.name == "Video" })
        #expect(model.selectedMember(in: original) == "Second")
        let draft = ClientGroupEditor(group: original)
        #expect(await model.saveGroup(original: draft.originalName, name: draft.name, kind: draft.kind,
            members: draft.members, parameters: draft.parameters, style: ClientGroupStyle()))
        let saved = try #require(model.groups.first { $0.name == "Video" })
        #expect(saved.parameters["selected"] == nil)
        #expect(model.selectedMember(in: saved) == "First")
        let firstResult = TextConfigurationPipeline.process(text: model.operatingText)
        let firstID = try #require(firstResult.compiled.proxies.first { $0.name == "First" }?.id)
        #expect(firstResult.route(host: "www.example.com").action == .proxy(firstID))
        await model.selectMember("Second", in: saved)
        let selected = try #require(model.groups.first { $0.name == "Video" })
        #expect(model.selectedMember(in: selected) == "Second")
        let secondResult = TextConfigurationPipeline.process(text: model.operatingText)
        let secondID = try #require(secondResult.compiled.proxies.first { $0.name == "Second" }?.id)
        #expect(secondResult.route(host: "www.example.com").action == .proxy(secondID))
    }

    @Test func automaticGroupEditorUsesEngineDefaultsInsteadOfParameterOverrides() throws {
        let source = ClientDocumentEditing.set(text, section: .proxyGroup, key: "Video",
            value: "url-test, First, Second, selected=Second, interval=10, tolerance=20, url=https://probe.example/check")
        let group = try #require(NaiveFlowConfigurationParser.parse(text: source).configuration.proxyGroup(named: "Video"))
        let draft = ClientGroupEditor(group: group)
        let updated = ClientDocumentEditing.set(source, section: .proxyGroup, key: draft.name,
            value: ClientDocumentEditing.groupValue(kind: draft.kind, members: draft.members, parameters: draft.parameters))
        let result = TextConfigurationPipeline.process(text: updated)
        #expect(result.isActivatable)
        let saved = try #require(result.parsed.proxyGroup(named: "Video"))
        for key in ["selected", "interval", "tolerance", "url"] { #expect(saved.parameters[key] == nil) }
        let runtime = try #require(result.compiled.policyGroups.first { $0.name == "Video" })
        #expect(runtime.interval == 600)
        #expect(runtime.url == nil)
        #expect(runtime.selectedID == nil)
        #expect(runtime.memberIDs.count == 2)
    }

    @Test func nodeNameRegexCanBeEnteredBeforeChoosingAnyGroup() throws {
        var draft = ClientGroupEditor()
        draft.name = "Filtered"
        draft.nameFilter = "(🇭🇰|港|HK|Hong Kong|HongKong)"
        #expect(draft.filterError == nil)
        #expect(draft.parameters.contains { $0.0 == "filter" && $0.1 == draft.nameFilter })
        draft.nameFilter = "["
        #expect(draft.filterError != nil)
        draft.nameFilter = "First"
        draft.members = ["Second"]
        var updated = ClientDocumentEditing.set(text, section: .proxyGroup, key: draft.name,
            value: ClientDocumentEditing.groupValue(kind: draft.kind, members: draft.members, parameters: draft.parameters))
        #expect(TextConfigurationPipeline.process(text: updated).isActivatable)
        draft.members = ["PROXY"]
        updated = ClientDocumentEditing.set(text, section: .proxyGroup, key: draft.name,
            value: ClientDocumentEditing.groupValue(kind: draft.kind, members: draft.members, parameters: draft.parameters))
        let result = TextConfigurationPipeline.process(text: updated)
        #expect(result.isActivatable)
        let firstID = try #require(result.compiled.proxies.first { $0.name == "First" }?.id)
        #expect(result.compiled.proxyGroups.first { $0.name == draft.name }?.memberIds == [firstID])
    }
}

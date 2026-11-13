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

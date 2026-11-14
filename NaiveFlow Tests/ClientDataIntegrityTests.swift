import Foundation
import Testing
@testable import NaiveFlow

@Suite(.serialized)
@MainActor
struct ClientDataIntegrityTests {
    private let base = "[Proxy]\nLocal = direct\n[Rule]\nFINAL, DIRECT\n"

    private func workspace() -> (URL, ClientModel) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = ConfigurationDocumentOperations(activation: ConfigurationActivation(store: ConfigurationSnapshotStore(directory: root.appendingPathComponent("configuration"))), selection: ProxySelection())
        return (root, ClientModel(operations: Operations(container: AppContainer.preview()), directory: root.appendingPathComponent("library"), document: document))
    }

    private func prepare(_ source: String, profile: ClientProfile) async throws -> ClientProfile {
        let change = try await ClientResourceManager.prepare(
            .importNodes(source, subscriptionURL: "https://example.com/sub", subscription: nil),
            profile: profile, text: profile.text, fetch: { _ in "" })
        return try #require(change).profile
    }

    @Test func duplicateSubscriptionNamesKeepDistinctNodesAcrossRepeatedRefreshes() async throws {
        var profile = ClientProfile(name: "Test", text: base)
        for port in [1080, 2080, 3080] {
            profile = try await prepare("socks5://192.0.2.1:\(port)#Same\nsocks5://192.0.2.2:\(port)#Same", profile: profile)
            #expect(profile.nodeSubscriptions?.first?.members.map(\.name) == ["Same", "Same (2)"])
            let nodes = TextConfigurationPipeline.process(text: profile.text).compiled.proxies
            #expect(nodes.first { $0.name == "Same" }?.serverAddress == "192.0.2.1")
            #expect(nodes.first { $0.name == "Same (2)" }?.serverAddress == "192.0.2.2")
            #expect(nodes.filter { $0.name.hasPrefix("Same") }.allSatisfy { $0.serverPort == UInt16(port) })
        }
    }

    @Test func rawConfigurationEditsAreNotOverwrittenBySubscriptionRefresh() async throws {
        var profile = try await prepare("socks5://192.0.2.1:1080#Remote", profile: ClientProfile(name: "Test", text: base))
        profile.text = base.replacingOccurrences(of: "Local = direct", with: "Local = direct\nRemote = socks5, 192.0.2.99, 9999")
        let refreshed = try await prepare("socks5://192.0.2.1:2080#Remote", profile: profile)
        let nodes = TextConfigurationPipeline.process(text: refreshed.text).compiled.proxies
        #expect(nodes.first { $0.name == "Remote" }?.serverAddress == "192.0.2.99")
        #expect(nodes.first { $0.name == "Remote (2)" }?.serverPort == 2080)
    }

    @Test func deletingSubscriptionNodeClearsOwnershipBeforeNameIsReused() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: base))
        #expect(try await model.importNodes("socks5://192.0.2.1:1080#Remote", subscriptionURL: "https://example.com/sub"))
        await model.deleteNode("Remote")
        #expect(model.profile?.nodeSubscriptions?.first?.members.isEmpty == true)
        await model.saveNode(try ProxyConfiguration.parse(url: "socks5://192.0.2.99:9999#Remote"))
        #expect(try await model.importNodes("socks5://192.0.2.1:2080#Remote", subscriptionURL: "https://example.com/sub"))
        #expect(model.nodes.first { $0.name == "Remote" }?.serverAddress == "192.0.2.99")
        #expect(model.nodes.first { $0.name == "Remote (2)" }?.serverAddress == "192.0.2.1")
    }

    @Test func olderSubscriptionMemberWithoutFingerprintStillDecodesAndRefreshes() async throws {
        let data = Data(#"{"sourceName":"Remote","name":"Remote","edited":false}"#.utf8)
        let member = try JSONDecoder().decode(ClientSubscriptionMember.self, from: data)
        #expect(member.importedURL == nil)
        var profile = ClientProfile(name: "Legacy", text: base + "\n[Proxy]\nRemote = socks5, 192.0.2.1, 1080\n")
        profile.nodeSubscriptions = [ClientNodeSubscription(name: "Test", url: "https://example.com/sub", members: [member])]
        let refreshed = try await prepare("socks5://192.0.2.1:2080#Remote", profile: profile)
        #expect(refreshed.nodeSubscriptions?.first?.members.first?.name == "Remote")
        #expect(refreshed.nodeSubscriptions?.first?.members.first?.importedURL != nil)
    }

    @Test func failedLibraryWriteCannotPublishOrChangeObservableState() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: base))
        let before = try #require(model.profile)
        let head = model.document.activation.store.manifest().activeSnapshotId
        let folder = root.appendingPathComponent("library")
        let file = folder.appendingPathComponent("profiles.json")
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("backup.json"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(!(await model.commit(base.replacingOccurrences(of: "Local = direct", with: "Changed = direct"))))
        #expect(model.error != nil)
        #expect(model.profile == before)
        #expect(model.operatingText == base)
        #expect(model.document.activation.store.manifest().activeSnapshotId == head)
    }

    @Test func rejectedPublicationRestoresDiskAndSelection() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: base))
        let before = try #require(model.profile)
        var broken = before
        broken.text = "[Rule]\nDOMAIN,example.com,Missing\n"
        #expect(!(await model.saveProfile(broken, apply: true)))
        let disk = try ClientProfileLibrary.load(from: root.appendingPathComponent("library"))
        #expect(disk.selectedID == before.id)
        #expect(disk.profiles.first { $0.id == before.id } == before)
        #expect(model.profile == before)
        #expect(model.operatingText == base)
    }

    @Test func runtimeEditsAndResourceUpdatesPreserveSavedDraftUntilExplicitApply() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.activate(model.createProfile(name: "Test", text: base))
        var draft = try #require(model.profile)
        draft.text = base + "# saved draft\n"
        #expect(await model.saveProfile(draft, apply: false))
        let subscription = ClientNodeSubscription(name: "Test", url: "https://example.com/sub")
        #expect(await model.manageResource(.save(.subscription(subscription))))
        await model.setSetting("proxy-mode", value: "direct")
        #expect(model.error != nil)
        #expect(!(await model.refreshNodeSubscriptions(fetch: { _ in "socks5://192.0.2.1:1080#Remote" })))
        #expect(model.profile?.text == draft.text)
        #expect(model.operatingText == base)
        model.error = nil
        await model.activate(try #require(model.profile))
        await model.setSetting("proxy-mode", value: "direct")
        #expect(model.error == nil)
        #expect(model.profile?.text.contains("# saved draft") == true)
        #expect(model.mode == .direct)
    }

    @Test func remoteUpdateLocksEditsAndDoesNotResurrectDeletedOrStaleProfiles() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = model.createProfile(name: "Remote", text: base, sourceURL: "https://example.com/profile")
        await model.updateProfile(remote, fetch: { _ in
            #expect(model.isBusy)
            model.deleteProfile(remote.id)
            var edit = remote; edit.name = "Concurrent edit"
            #expect(!(await model.saveProfile(edit, apply: false)))
            return base + "# downloaded\n"
        })
        let updated = try #require(model.library.profiles.first { $0.id == remote.id })
        #expect(updated.text.contains("# downloaded"))
        var fetched = false
        await model.updateProfile(remote, fetch: { _ in fetched = true; return base })
        #expect(!fetched)
        model.deleteProfile(remote.id)
        await model.updateProfile(updated, fetch: { _ in fetched = true; return base })
        #expect(!fetched)
        #expect(!model.library.profiles.contains { $0.id == remote.id })
    }

    @Test func remoteUpdateRejectsExternalRuntimeChangesAndCancellation() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = model.createProfile(name: "Remote", text: base, sourceURL: "https://example.com/profile")
        await model.activate(remote)
        let current = try #require(model.profile)
        let external = base + "# externally applied\n"
        await model.updateProfile(current, fetch: { _ in
            _ = try await model.document.apply(external)
            model.refresh()
            return base + "# download\n"
        })
        #expect(model.error?.contains("changed") == true)
        #expect(model.profile == current)
        #expect(model.operatingText == external)
        var calls = 0
        let task = Task { await model.updateProfile(current, fetch: { _ in calls += 1; return base }) }
        task.cancel()
        await task.value
        #expect(calls == 0)
        #expect(!model.isBusy)
    }

    @Test func unchangedRefreshAndMetadataSaveRetainNodeIdentities() async throws {
        let (root, model) = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = (1...500).map { "Node\($0) = socks5, 192.0.2.1, 1080" }.joined(separator: "\n")
        await model.activate(model.createProfile(name: "Large", text: "[Proxy]\n" + rows + "\n[Rule]\nFINAL,DIRECT\n"))
        let ids = model.nodes.map(\.id)
        model.refresh()
        var renamed = try #require(model.profile); renamed.name = "Renamed"
        #expect(await model.saveProfile(renamed, apply: false))
        #expect(model.nodes.map(\.id) == ids)
        #expect(model.nodes.count == 500)
    }
}

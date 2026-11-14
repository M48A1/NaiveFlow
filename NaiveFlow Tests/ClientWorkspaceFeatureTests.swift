import Foundation
import Testing
import CoreImage
import Network
import UIKit
@testable import NaiveFlow

@Suite(.serialized)
@MainActor
struct ClientWorkspaceFeatureTests {
    private let base = "[Proxy]\nLocal = direct\n[Rule]\nFINAL,DIRECT\n"
    private func workspace() async -> (URL, ClientModel) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = ConfigurationDocumentOperations(activation: ConfigurationActivation(store: ConfigurationSnapshotStore(directory: root.appendingPathComponent("configuration"))), selection: ProxySelection())
        let model = ClientModel(operations: Operations(container: AppContainer.preview()), directory: root.appendingPathComponent("library"), document: document)
        await model.activate(model.createProfile(name: "Feature test", text: base))
        return (root, model)
    }

    @Test func subscriptionPreviewStagesChangesAndCanRemoveMissingNodesAtomically() async throws {
        let (root, model) = await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await model.importNodes("socks5://192.0.2.1:1080#Old\nsocks5://192.0.2.2:1080#Keep", subscriptionURL: "https://example.com/sub"))
        let before = model.runningSnapshotID
        #expect(await model.prepareSubscriptionUpdate(fetch: { _ in "socks5://192.0.2.2:2080#Keep\nsocks5://192.0.2.3:1080#New" }))
        let review = try #require(model.subscriptionReview)
        #expect(review.added == ["New"])
        #expect(review.modified == ["Keep"])
        #expect(review.missing == ["Old"])
        #expect(review.removable == ["Old"])
        #expect(model.runningSnapshotID == before)
        #expect(model.nodes.contains { $0.name == "Old" })
        #expect(!model.nodes.contains { $0.name == "New" })
        #expect(await model.applySubscriptionReview(review, removeMissing: true))
        #expect(!model.nodes.contains { $0.name == "Old" })
        #expect(model.nodes.first { $0.name == "Keep" }?.serverPort == 2080)
        #expect(model.nodes.contains { $0.name == "New" })
        #expect(model.subscriptionReview == nil)
        let resource = try #require(model.resources.first { $0.kind == "Subscription" })
        #expect(model.resourceActivity[resource.id]?.succeededAt != nil)
        #expect(model.resourceActivity[resource.id]?.awaitingReview == false)
    }

    @Test func subscriptionPreviewPreservesManualNodesAndRejectsStaleReview() async throws {
        let (root, model) = await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await model.importNodes("socks5://192.0.2.1:1080#Remote", subscriptionURL: "https://example.com/sub"))
        let node = try #require(model.nodes.first { $0.name == "Remote" })
        await model.saveNode(try ProxyConfiguration.parse(url: "socks5://192.0.2.99:9999#Custom"), replacing: node.name)
        #expect(await model.prepareSubscriptionUpdate(fetch: { _ in "socks5://192.0.2.1:2080#Remote" }))
        let review = try #require(model.subscriptionReview)
        #expect(review.preserved == ["Custom"])
        #expect(review.modified.isEmpty)
        await model.setSetting("proxy-mode", value: "direct")
        let head = model.runningSnapshotID
        #expect(!(await model.applySubscriptionReview(review, removeMissing: true)))
        #expect(model.runningSnapshotID == head)
        #expect(model.nodes.first { $0.name == "Custom" }?.serverPort == 9999)
        model.discardSubscriptionReview()
        #expect(model.subscriptionReview == nil)
        #expect(model.resourceActivity.values.allSatisfy { !$0.awaitingReview })
    }

    @Test func bulkDeletionRejectsReferencesWithoutPartialChanges() async throws {
        let (root, model) = await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await model.importNodes("socks5://192.0.2.1:1080#A\nsocks5://192.0.2.2:1080#B"))
        #expect(await model.commit(model.operatingText + "\n[Proxy Group]\nVideo = select, A, B, selected=A\n"))
        #expect(await model.removeNodes(["A"]))
        #expect(model.groups.first { $0.name == "Video" }?.members == ["B"])
        let before = model.profile
        #expect(!(await model.removeNodes(["Local", "B"])))
        #expect(model.profile == before)
        #expect(model.nodes.contains { $0.name == "Local" })
        #expect(model.nodes.contains { $0.name == "B" })
    }

    @Test func bulkGroupMembershipAndNodeFiltersRespectSelections() async throws {
        let (root, model) = await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await model.importNodes("socks5://192.0.2.1:1080#Tokyo\nsocks5://192.0.2.2:1080#London"))
        #expect(await model.commit(model.operatingText + "\n[Proxy Group]\nVideo = select, Local\n"))
        #expect(await model.addNodes(["Tokyo", "London"], to: "Video"))
        #expect(model.groups.first?.members == ["Local", "Tokyo", "London"])
        let tokyo = try #require(model.nodes.first { $0.name == "Tokyo" })
        let results = [tokyo.id: LatencyResult.success(42)]
        let filtered = ClientNodeTools.filtered(model.nodes, query: "tok 192.0.2", protocolName: "socks5", subscriptionNames: ["Tokyo"], availability: "available", results: results)
        #expect(filtered.map(\.name) == ["Tokyo"])
        #expect(ClientNodeTools.filtered(model.nodes, query: "", protocolName: "", subscriptionNames: nil, availability: "untested", results: results).count == 2)
    }

    @Test func backupRoundTripsAllProfileMetadataAndDoesNotApplyOnRestore() async throws {
        let (root, model) = await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        var candidate = try #require(model.profile)
        candidate.groupStyles["Media"] = ClientGroupStyle(symbol: "star", palette: 2)
        candidate.nodeSubscriptions = [ClientNodeSubscription(name: "Remote", url: "https://example.com/sub", remnawaveHWIDEnabled: true)]
        candidate.modules = [ClientModule(name: "Local", summary: "Backup test", source: "test", format: .surge)]
        candidate.text += "# backup version\n"
        let originalHead = model.runningSnapshotID
        let backup = try ClientBackup.decode(JSONEncoder().encode(ClientBackup(library: ClientProfileLibrary(selectedID: candidate.id, profiles: [candidate]))))
        #expect(backup.library.profiles.first == candidate)
        #expect(await model.restoreBackup(backup, replaceMatches: false))
        #expect(model.profile?.modules.isEmpty == true)
        #expect(await model.restoreBackup(backup, replaceMatches: true))
        #expect(model.profile?.modules == candidate.modules)
        #expect(model.profile?.groupStyles == candidate.groupStyles)
        #expect(model.profile?.nodeSubscriptions == candidate.nodeSubscriptions)
        #expect(model.runningSnapshotID == originalHead)
        #expect(model.hasSavedDraft)
        var invalid = backup; invalid.formatVersion = 99
        #expect(throws: (any Error).self) { try ClientBackup.decode(JSONEncoder().encode(invalid)) }
        invalid = backup; invalid.library.profiles.append(candidate)
        #expect(throws: (any Error).self) { try ClientBackup.decode(JSONEncoder().encode(invalid)) }
    }

    @Test func managedDownloadCanBeCancelledAndFailureHistoryPersists() async throws {
        let (root, model) = await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await model.importNodes("socks5://192.0.2.1:1080#Remote", subscriptionURL: "https://example.com/sub"))
        let head = model.runningSnapshotID
        var started = false
        let task = Task { await model.prepareSubscriptionUpdate(fetch: { _ in
            started = true
            try await Task.sleep(for: .seconds(30))
            return "socks5://192.0.2.1:2080#Remote"
        }) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !started && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(started)
        model.cancelResourceOperation()
        #expect(!(await task.value))
        #expect(model.error == nil)
        #expect(!model.isBusy)
        #expect(model.activeResourceTitle == nil)
        #expect(model.runningSnapshotID == head)
        #expect(model.resourceActivity.values.contains { $0.error == "Cancelled" })
        let reloaded = ClientModel(operations: Operations(container: AppContainer.preview()), directory: root.appendingPathComponent("library"), document: model.document)
        #expect(reloaded.resourceActivity.values.contains { $0.error == "Cancelled" })
    }

    @Test func qrImportAcceptsLinksAndRejectsUnrelatedOrOversizedContent() throws {
        let link = "socks5://192.0.2.1:1080#QR"
        #expect(try ClientQRPayload.normalize("  " + link + "\n") == link)
        #expect(try ClientQRPayload.normalize("naiveflow://add-proxy?link=" + link) == link)
        #expect(try ClientQRPayload.normalize("https://example.com/sub?token=abc") == "https://example.com/sub?token=abc")
        for bad in ["javascript:alert(1)", "https://", "ordinary text", String(repeating: "a", count: 65_537)] {
            #expect(throws: (any Error).self) { try ClientQRPayload.normalize(bad) }
        }
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(link.utf8), forKey: "inputMessage")
        let image = try #require(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)))
        let cg = try #require(CIContext().createCGImage(image, from: image.extent))
        let data = try #require(UIImage(cgImage: cg).pngData())
        #expect(try ClientQRPayload.readImage(data) == [link])
        #expect(throws: (any Error).self) { try ClientQRPayload.readImage(Data("invalid".utf8)) }
    }

    @Test func connectionDiagnosticsChecksLocalTargetWithoutChangingSelection() async throws {
        let server = try MITMProfileListener(payload: Data("test".utf8), requestTimeout: 1)
        defer { server.cancel() }
        let port = try await server.start()
        let model = ClientConnectionDiagnostics()
        let direct = ProxyConfiguration(name: "Local test", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration()))
        model.start(node: direct, target: LatencyTarget(scheme: .http, host: "127.0.0.1", port: port.rawValue, path: "/NaiveFlowMITMRoot.mobileconfig"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        defer { model.cancel() }
        #expect(!model.isRunning)
        #expect(model.steps[0].state == .skipped)
        #expect(model.steps[3].state == .passed)
        #expect(model.steps[4].state == .skipped)
        #expect(model.steps[5].state == .passed)
    }
}

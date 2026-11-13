import Foundation
import Synchronization
import Testing
@testable import NaiveFlow

@Suite(.serialized)
@MainActor
struct VersionedConfigurationTests {
    private func workspace() -> (URL, ConfigurationActivation) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (directory, ConfigurationActivation(store: ConfigurationSnapshotStore(directory: directory)))
    }
    private func publisher(_ activation: ConfigurationActivation) -> ConfigurationPublisher {
        ConfigurationPublisher(activation: activation, tunnel: nil, preferencesSink: { _ in })
    }
    private let first = "[General]\nproxy-mode = direct\n[Host]\nexample.com = 10.0.0.1\n[Rule]\nFINAL, DIRECT\n"
    private let second = "[General]\nproxy-mode = rule\n[Host]\nexample.com = 10.0.0.2\n[Rule]\nFINAL, REJECT\n"

    @Test func offlinePublicationIsOneCompleteUnconfirmedVersion() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = publisher(activation)
        let (active, _) = try await publisher.publish(text: first)
        let head = try #require(try publisher.bundleStore.head())
        let bundle = try publisher.bundleStore.load(head.current)
        #expect(bundle.snapshotID == active.snapshot.id)
        #expect(bundle.finalAction == .direct)
        #expect(bundle.preferences["proxyMode"] == .string("direct"))
        #expect(bundle.preferences["hostMappings"] != nil)
        #expect(activation.store.manifest().appliedAt == nil)
        #expect(head.previous != nil)
        #expect(!activation.isActiveSnapshotConfirmed())
    }

    @Test func rejectionRestoresAllInputsAndManifest() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        var publisher = publisher(activation)
        _ = try await publisher.publish(text: first)
        let before = try #require(try publisher.bundleStore.head())
        let previous = try publisher.bundleStore.load(before.current)
        let oldManifest = activation.store.manifest()
        var delivered: [UUID] = []
        publisher.runningOverride = true
        publisher.deliveryOverride = { bundle, _ in
            delivered.append(bundle.id)
            return .init(versionID: bundle.id, activeVersionID: bundle.id == previous.id ? bundle.id : previous.id,
                snapshotID: bundle.snapshotID, status: bundle.id == previous.id ? .applied : .rejected,
                message: bundle.id == previous.id ? nil : "Injected module preparation failure")
        }
        await #expect(throws: (any Error).self) { try await publisher.publish(text: second) }
        let after = try #require(try publisher.bundleStore.head())
        #expect(after.current == previous.id)
        #expect(delivered.count == 2 && delivered.last == previous.id)
        let restored = try publisher.bundleStore.load(after.current)
        #expect(restored.preferences == previous.preferences)
        #expect(restored.rules == previous.rules)
        #expect(restored.finalAction == previous.finalAction)
        #expect(activation.store.manifest().activeSnapshotId == oldManifest.activeSnapshotId)
        #expect(activation.store.manifest().lastFailure != nil)
    }

    @Test func appliedReceiptForWrongVersionIsRejected() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        var publisher = publisher(activation)
        _ = try await publisher.publish(text: first)
        let before = try #require(try publisher.bundleStore.head())
        publisher.runningOverride = true
        publisher.deliveryOverride = { bundle, _ in
            .init(versionID: bundle.id, activeVersionID: before.current,
                snapshotID: bundle.snapshotID, status: .applied, message: nil)
        }
        await #expect(throws: (any Error).self) { try await publisher.publish(text: second) }
        #expect(try publisher.bundleStore.head()?.current == before.current)
        #expect(activation.store.manifest().lastFailure != nil)
    }

    @Test func explicitRollbackReusesPinnedScriptBytes() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Data("$done({});".utf8).base64EncodedString()
        let text = first + "\n[MITM]\nenable = false\nhostname = example.com\n[Script]\nrewrite = type=http-response, pattern=^https://example.com/, source=base64:\(source)\n"
        let publisher = publisher(activation)
        _ = try await publisher.publish(text: text)
        let firstHead = try #require(try publisher.bundleStore.head())
        let pinned = try publisher.bundleStore.load(firstHead.current)
        _ = try await publisher.publish(text: second)
        _ = try await publisher.rollback()
        let restoredHead = try #require(try publisher.bundleStore.head())
        let restored = try publisher.bundleStore.load(restoredHead.current)
        #expect(restored.id == pinned.id)
        #expect(restored.mitmRuleSets.map(\.rules).flatMap { $0 }.map(\.operation) == pinned.mitmRuleSets.map(\.rules).flatMap { $0 }.map(\.operation))
        #expect(restoredHead.requestID != firstHead.requestID)
    }

    @Test func interruptedHostPublicationResumesAfterVPNStatusIsKnown() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        var publisher = publisher(activation)
        _ = try await publisher.publish(text: first)
        let saved = try #require(try publisher.bundleStore.head())
        publisher.runningOverride = true
        publisher.deliveryOverride = { bundle, _ in
            .init(versionID: bundle.id, activeVersionID: bundle.id,
                snapshotID: bundle.snapshotID, status: .applied, message: nil)
        }
        try await publisher.recoverPending()
        #expect(try publisher.bundleStore.head()?.current == saved.current)
        #expect(activation.store.manifest().appliedAt != nil)
        #expect(try publisher.bundleStore.receipt(saved.current)?.requestID == saved.requestID)
    }

    @Test func invalidScriptDoesNotChangePublishedHead() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = publisher(activation)
        _ = try await publisher.publish(text: first)
        let before = try publisher.bundleStore.head()
        let invalid = Data("$done({".utf8).base64EncodedString()
        let text = first + "\n[MITM]\nhostname = example.com\n[Script]\nx = type=http-request, pattern=., source=base64:\(invalid)\n"
        await #expect(throws: (any Error).self) { try await publisher.publish(text: text) }
        #expect(try publisher.bundleStore.head() == before)
    }

    @Test func staleReceiptCannotConfirmRepublishedVersion() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = publisher(activation)
        _ = try await publisher.publish(text: first)
        let firstHead = try #require(try publisher.bundleStore.head())
        let version = try publisher.bundleStore.load(firstHead.current)
        try publisher.bundleStore.record(.init(versionID: version.id, activeVersionID: version.id,
            snapshotID: version.snapshotID, status: .applied, message: nil))
        _ = try await publisher.publish(text: second)
        _ = try publisher.bundleStore.rollback(expected: try #require(try publisher.bundleStore.head()).current)
        let restored = try #require(try publisher.bundleStore.head())
        let receipt = try #require(try publisher.bundleStore.receipt(version.id))
        #expect(receipt.requestID != restored.requestID)
        try publisher.reconcile()
        #expect(activation.store.manifest().appliedAt == nil)
    }

    @Test func offlineRejectionRecoversOnNextRead() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = publisher(activation)
        let (firstActive, _) = try await publisher.publish(text: first)
        let previous = try #require(try publisher.bundleStore.head()).current
        _ = try await publisher.publish(text: second)
        let current = try #require(try publisher.bundleStore.head()).current
        try publisher.bundleStore.record(.init(versionID: current, activeVersionID: previous,
            snapshotID: nil, status: .rejected, message: "Injected startup failure"))
        try publisher.reconcile()
        #expect(try publisher.bundleStore.head()?.current == previous)
        #expect(activation.store.manifest().activeSnapshotId == firstActive.snapshot.id)
    }

    @Test func integrityFailureAndCASCannotDestroyPreviousVersion() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = publisher(activation)
        _ = try await publisher.publish(text: first)
        let old = try #require(try publisher.bundleStore.head())
        _ = try await publisher.publish(text: second)
        let current = try #require(try publisher.bundleStore.head())
        #expect(throws: (any Error).self) { try publisher.bundleStore.rollback(expected: old.current) }
        let file = publisher.bundleStore.directory.appendingPathComponent("\(current.current.uuidString).json")
        let fileData = try Data(contentsOf: file)
        var envelope = try #require(JSONSerialization.jsonObject(with: fileData) as? [String: Any])
        envelope["sha256"] = "tampered"
        try JSONSerialization.data(withJSONObject: envelope).write(to: file, options: .atomic)
        #expect(throws: (any Error).self) { try publisher.bundleStore.load(current.current) }
        _ = try publisher.bundleStore.rollback(expected: current.current)
        #expect(try publisher.bundleStore.head()?.current == old.current)
    }

    @Test func publicationLeaseRejectsConcurrentWriter() throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = publisher(activation).bundleStore
        let lease = try store.lease()
        defer { withExtendedLifetime(lease) {} }
        #expect(throws: (any Error).self) { try store.lease() }
    }

    @Test func preferenceCaptureAndPinnedReadsDoNotMutateDefaults() throws {
        let suite = "NaiveFlow-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old", forKey: "value")
        let view = RuntimePreferences(defaults: defaults)
        let capture = RuntimePreferenceCapture(["value": .string("old")])
        RuntimePreferenceContext.$capture.withValue(capture) { view.set("new", forKey: "value") }
        #expect(defaults.string(forKey: "value") == "old")
        view.install(capture.values.withLock { $0 })
        defaults.set("later", forKey: "value")
        #expect(view.string(forKey: "value") == "new")
        view.install(["value": .absent])
        #expect(view.string(forKey: "value") == nil)
    }

    /// Rolling back from the first text version returns the manually captured
    /// baseline, whose head bundle carries `snapshotID == nil`. That is the signal
    /// the app uses to restore editable manual mode (see ProxySelectionTests).
    @Test func rollbackToManualBaselineYieldsNilSnapshotHead() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        var captured: [UUID?] = []
        let publisher = ConfigurationPublisher(activation: activation, tunnel: nil,
            preferencesSink: { _ in }, stateSink: { captured.append($0.snapshotID) })
        _ = try await publisher.publish(text: first)
        let textHead = try #require(try publisher.bundleStore.head())
        #expect(try publisher.bundleStore.load(textHead.current).snapshotID != nil)

        _ = try await publisher.rollback()
        let restoredHead = try #require(try publisher.bundleStore.head())
        #expect(try publisher.bundleStore.load(restoredHead.current).snapshotID == nil)
        // The app's selection sink received the manual baseline last.
        #expect(captured.last! == nil)
    }
}

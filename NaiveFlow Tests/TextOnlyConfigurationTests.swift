import Foundation
import Testing
@testable import NaiveFlow

@Suite(.serialized)
@MainActor
struct TextOnlyConfigurationTests {
    private func workspace() -> (URL, ConfigurationActivation) {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (directory, ConfigurationActivation(store: ConfigurationSnapshotStore(directory: directory)))
    }

    @Test func removedCountrySettingIsRejected() {
        let result = TextConfigurationPipeline.process(text: "[General]\nbypass-country = CN\n[Rule]\nFINAL,DIRECT\n")
        #expect(!result.isActivatable)
        #expect(ConfigurationSettings.key(named: "bypass-country") == nil)
        #expect(result.diagnostics.contains { $0.code == .unknownGeneralKey })
    }

    @Test func omittedSettingsResetInsteadOfInheritingPreviousVersion() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = ConfigurationPublisher(activation: activation, tunnel: nil, preferencesSink: { _ in })
        _ = try await publisher.publish(text: "[General]\nblock-udp=true\ntrusted-ssid=Old Network\n[Rule]\nFINAL,DIRECT\n")
        _ = try await publisher.publish(text: "[Rule]\nFINAL,DIRECT\n")
        let head = try #require(try publisher.bundleStore.head())
        let bundle = try publisher.bundleStore.load(head.current)
        let defaults = AWCore.defaultRuntimePreferences()
        #expect(bundle.preferences["blockUDP"] == defaults["blockUDP"])
        #expect(bundle.preferences["trustedSSIDs"] == defaults["trustedSSIDs"])
    }

    @Test func rejectedFirstPublicationLeavesNoHeadOrManualFallback() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        var cleared = false
        let publisher = ConfigurationPublisher(activation: activation, tunnel: nil, runningOverride: true,
            deliveryOverride: { _, _ in throw RuntimeConfigurationFailure.unavailable },
            preferencesSink: { _ in }, clearStateSink: { cleared = true })
        await #expect(throws: (any Error).self) { try await publisher.publish(text: "[Rule]\nFINAL,DIRECT\n") }
        #expect(try publisher.bundleStore.head() == nil)
        #expect(activation.store.manifest().activeSnapshotId == nil)
        #expect(cleared)
    }

    @Test func currentRuntimeRequiresSnapshotRulesAndCurrentSchema() async throws {
        let (directory, activation) = workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = ConfigurationPublisher(activation: activation, tunnel: nil, preferencesSink: { _ in })
        _ = try await publisher.publish(text: "[Rule]\nFINAL,DIRECT\n")
        let head = try #require(try publisher.bundleStore.head())
        let bundle = try publisher.bundleStore.load(head.current)
        let encoded = try JSONEncoder().encode(bundle)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["legacyRouting"] == nil)
        #expect(json["legacyMITM"] == nil)
        for key in ["snapshotID", "rules", "policyGroups", "displayGroups", "geo"] {
            var incomplete = json
            incomplete.removeValue(forKey: key)
            let bytes = try JSONSerialization.data(withJSONObject: incomplete)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(RuntimeConfigurationBundle.self, from: bytes) }
        }
        var old = bundle
        old.schemaVersion = 1
        #expect(throws: (any Error).self) { try old.validate() }
    }
}

import Foundation
import Testing
@testable import RuleProxy

struct ConfigurationCloudCodecTests {
    @Test func chunkedUnicodeRoundTripFitsCloudRecordLimit() throws {
        let owner = UUID()
        let text = String(repeating: "规则👋\r\n", count: 100_000)
        let items = try ConfigurationCloudCodec.encode(text: text, owner: owner, deviceName: "Test", stamp: .now)
        #expect(items.count > 2)
        #expect(items.allSatisfy { $0.payload.count < SyncStore.maxSyncedPayloadBytes })
        let document = try #require(ConfigurationCloudCodec.decode(items.map(\.payload)).first)
        #expect(document.text == text)
        #expect(document.id == owner)
    }

    @Test func emptyInvalidDraftStillSyncsLosslessly() throws {
        for text in ["", "[unfinished", "# comments\r\n\n"] {
            let items = try ConfigurationCloudCodec.encode(text: text, owner: UUID(), deviceName: "Test", stamp: .now)
            #expect(ConfigurationCloudCodec.decode(items.map(\.payload)).first?.text == text)
        }
    }

    @Test func incompleteOrMixedRevisionNeverBecomesAFile() throws {
        let owner = UUID()
        let first = try ConfigurationCloudCodec.encode(text: "old", owner: owner, deviceName: "Test", stamp: .now)
        let second = try ConfigurationCloudCodec.encode(text: "new", owner: owner, deviceName: "Test", stamp: .now)
        #expect(ConfigurationCloudCodec.decode([try #require(second.last).payload]).isEmpty)
        #expect(ConfigurationCloudCodec.decode([try #require(first.first).payload, try #require(second.last).payload]).isEmpty)
        #expect(ConfigurationCloudCodec.decode(second.map(\.payload)).first?.text == "new")
    }

    @Test func corruptedPartFailsIntegrityCheck() throws {
        var items = try ConfigurationCloudCodec.encode(text: "original", owner: UUID(), deviceName: "Test", stamp: .now)
        let record = try JSONDecoder().decode(ConfigurationCloudCodec.Record.self, from: items[0].payload)
        guard case .part(let part) = record else { Issue.record("Expected part"); return }
        let corrupted = try JSONEncoder().encode(ConfigurationCloudCodec.Record.part(.init(owner: part.owner, index: part.index, bytes: Data("tampered".utf8))))
        items[0] = .init(id: items[0].id, payload: corrupted, updatedAt: .now, deletedAt: nil)
        #expect(ConfigurationCloudCodec.decode(items.map(\.payload)).isEmpty)
    }

    @Test func separateDevicesAndAppliedSlotHaveDistinctIdentity() throws {
        let firstOwner = UUID(), secondOwner = UUID()
        let applied = ConfigurationCloudCodec.appliedOwner(firstOwner)
        #expect(applied != firstOwner && applied != secondOwner)
        #expect(applied == ConfigurationCloudCodec.appliedOwner(firstOwner))
        let first = try ConfigurationCloudCodec.encode(text: "first", owner: firstOwner, deviceName: "First", stamp: .now)
        let second = try ConfigurationCloudCodec.encode(text: "second", owner: secondOwner, deviceName: "Second", stamp: .now)
        let active = try ConfigurationCloudCodec.encode(text: "applied", owner: applied, deviceName: "Applied", stamp: .now)
        let decoded = ConfigurationCloudCodec.decode((first + second + active).map(\.payload))
        #expect(Set(decoded.map(\.text)) == Set(["first", "second", "applied"]))
    }

    @Test func rejectsTextLargerThanConfigurationLimit() {
        #expect(throws: (any Error).self) {
            try ConfigurationCloudCodec.encode(text: String(repeating: "a", count: ConfigurationImport.maximumBytes + 1), owner: UUID(), deviceName: "Test", stamp: .now)
        }
    }

    @Test func fixedChunkSlotsIgnoreOldTrailingPartsAfterShrink() async throws {
        let store = SyncStore.ephemeral()
        let owner = UUID()
        let writer = ConfigurationCloudWriter(store: store, owner: owner, deviceName: "Test")
        try await writer.save(String(repeating: "a", count: ConfigurationCloudCodec.partBytes * 2 + 1))
        let count = store.allItemRefs().count
        try await writer.save("small")
        try await writer.save("latest")
        #expect(store.allItemRefs().count == count)
        #expect(ConfigurationCloudCodec.decode(store.loadItems(.configurationDocuments)).first?.text == "latest")
    }
}

@MainActor
struct ConfigurationCloudStoreTests {
    @Test func remoteReloadDoesNotChangeDraftOrRuntimeAndKeepsCompleteCopy() async throws {
        let store = SyncStore.ephemeral()
        let owner = UUID()
        let viewer = ConfigurationCloudStore(store: store, owner: UUID(), deviceName: "Viewer")
        let first = try ConfigurationCloudCodec.encode(text: "old", owner: owner, deviceName: "Remote", stamp: .now)
        store.save(.configurationDocuments, items: first, order: [])
        await viewer.reload()
        #expect(viewer.documents.first?.text == "old")
        let next = try ConfigurationCloudCodec.encode(text: "new", owner: owner, deviceName: "Remote", stamp: Date.now.addingTimeInterval(1))
        store.save(.configurationDocuments, items: [try #require(next.last)], order: [])
        await viewer.reload()
        #expect(viewer.documents.first?.text == "old")
        store.save(.configurationDocuments, items: next, order: [])
        await viewer.reload()
        #expect(viewer.documents.first?.text == "new")
        #expect(store.loadItems(.configurations).isEmpty)
    }

    @Test func draftAndAppliedTextAreSavedIndependently() async {
        let cloud = ConfigurationCloudStore(store: .ephemeral(), owner: UUID(), deviceName: "Test")
        await cloud.saveApplied("applied")
        await cloud.saveNow("draft with unfinished edits")
        #expect(cloud.documents.count == 2)
        #expect(Set(cloud.documents.map(\.text)) == Set(["applied", "draft with unfinished edits"]))
        #expect(cloud.errorMessage == nil)
    }
}

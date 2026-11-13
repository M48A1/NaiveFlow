import Foundation
import Testing
@testable import NaiveFlow

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

    @Test func independentCloudCopiesHaveDistinctIdentity() throws {
        let firstOwner = UUID(), secondOwner = UUID()
        let applied = UUID()
        #expect(applied != firstOwner && applied != secondOwner)
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

    @Test func configurationDocumentsAreExcludedFromAutomaticSync() {
        #expect(!SyncStore.Key.configurationDocuments.automaticallySyncs)
        #expect(SyncStore.Key.allCases.filter { $0 != .configurationDocuments }.allSatisfy { $0.automaticallySyncs })
    }

}

private actor ManualCloudFixture: ConfigurationCloudTransport {
    var uploads = 0
    var downloads = 0
    var server: [CloudConfigurationDocument] = []
    var failUpload = false
    var failDownload = false
    func counts() -> (Int, Int) { (uploads, downloads) }
    func failures(upload: Bool = false, download: Bool = false) { failUpload = upload; failDownload = download }
    func upload(text: String) async throws -> CloudConfigurationDocument {
        uploads += 1
        if failUpload { throw ConfigurationCloudCodec.Failure(message: "Offline") }
        let item = CloudConfigurationDocument(id: UUID(), deviceName: "Test", updatedAt: .now, text: text)
        server.append(item)
        return item
    }
    func download() async throws -> [CloudConfigurationDocument] {
        downloads += 1
        if failDownload { throw ConfigurationCloudCodec.Failure(message: "Offline") }
        return server
    }
}

@MainActor
struct ConfigurationCloudStoreTests {
    @Test func openingAndReloadingOnlyReadLocalCache() async {
        let transport = ManualCloudFixture()
        let cloud = ConfigurationCloudStore(transport: transport, cacheURL: nil)
        cloud.reload()
        cloud.reload()
        let counts = await transport.counts()
        #expect(counts.0 == 0 && counts.1 == 0)
        #expect(cloud.documents.isEmpty)
    }

    @Test func uploadCreatesNewCopiesAndNeverDownloads() async {
        let transport = ManualCloudFixture()
        let cloud = ConfigurationCloudStore(transport: transport, cacheURL: nil)
        await cloud.upload("first")
        await cloud.upload("second")
        #expect(cloud.documents.count == 2)
        #expect(Set(cloud.documents.map(\.text)) == Set(["first", "second"]))
        #expect(Set(cloud.documents.map(\.id)).count == 2)
        let counts = await transport.counts()
        #expect(counts.0 == 2 && counts.1 == 0)
    }

    @Test func downloadFailureRetainsCacheAndDoesNotUpload() async throws {
        let transport = ManualCloudFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache.json")
        let first = ConfigurationCloudStore(transport: transport, cacheURL: cache)
        await first.upload("preserved")
        let reopened = ConfigurationCloudStore(transport: transport, cacheURL: cache)
        reopened.reload()
        #expect(reopened.documents.first?.text == "preserved")
        await transport.failures(download: true)
        await reopened.download()
        #expect(reopened.errorMessage != nil)
        #expect(reopened.documents.first?.text == "preserved")
        let counts = await transport.counts()
        #expect(counts.0 == 1 && counts.1 == 1)
    }

    @Test func failedUploadDoesNotQueueRetryAndDownloadIsExplicit() async {
        let transport = ManualCloudFixture()
        let cloud = ConfigurationCloudStore(transport: transport, cacheURL: nil)
        await transport.failures(upload: true)
        await cloud.upload("local draft")
        cloud.reload()
        let reopened = ConfigurationCloudStore(transport: transport, cacheURL: nil)
        reopened.reload()
        #expect(cloud.errorMessage != nil)
        #expect(cloud.documents.isEmpty)
        await transport.failures()
        await cloud.download()
        let counts = await transport.counts()
        #expect(counts.0 == 1 && counts.1 == 1)
    }
}

struct ConfigurationDriveTests {
    @Test func namedFileCanBeUpdatedAndStaleDraftCannotOverwriteIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = ConfigurationDrive(localDirectory: folder)
        let second = ConfigurationDrive(localDirectory: folder)
        let name = try ConfigurationDrive.fileName(" Home ")
        let original = try await first.save("# original\r\n", name: name, replacing: nil)
        #expect(try await second.files() == ["Home.conf"])
        #expect(try await second.read(name).text == "# original\r\n")
        let edited = try await second.save("# edited", name: name, replacing: original.digest)
        await #expect(throws: ConfigurationDrive.Failure.changed) {
            try await first.save("# stale", name: name, replacing: original.digest)
        }
        await #expect(throws: ConfigurationDrive.Failure.alreadyExists) {
            try await first.save("# collision", name: name, replacing: nil)
        }
        #expect(try await first.read(name).digest == edited.digest)
        #expect(throws: ConfigurationDrive.Failure.invalidName) { try ConfigurationDrive.fileName("../outside") }
    }
}

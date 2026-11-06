import Foundation
import CloudKit

nonisolated protocol ConfigurationCloudTransport: Sendable {
    func upload(text: String) async throws -> CloudConfigurationDocument
    func download() async throws -> [CloudConfigurationDocument]
}

/// No CKSyncEngine, subscription, retry queue or startup network work. Only the
/// explicit editor commands call these operations. New uploads are immutable.
actor ManualConfigurationCloudTransport: ConfigurationCloudTransport {
    static let shared = ManualConfigurationCloudTransport()
    private static let zoneName = "NaiveFlowConfigurationFiles"
    private var database: CKDatabase {
        CKContainer(identifier: AWCore.Identifier.iCloudContainer).privateCloudDatabase
    }
    private static func zone(_ name: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
    }

    func upload(text: String) async throws -> CloudConfigurationDocument {
        let owner = UUID()
        let stamp = Date()
        let name = ProcessInfo.processInfo.hostName
        let items = try ConfigurationCloudCodec.encode(text: text, owner: owner, deviceName: name, stamp: stamp)
        let zoneID = Self.zone(Self.zoneName)
        let database = database
        try Task.checkCancellation()
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        // Keep requests below CloudKit's size limit. The manifest is sent only
        // after every part is acknowledged; partial uploads never become files.
        for start in stride(from: 0, to: items.count - 1, by: 4) {
            try Task.checkCancellation()
            try await save(Array(items[start..<min(start + 4, items.count - 1)]), zoneID: zoneID, database: database)
        }
        try Task.checkCancellation()
        guard let manifest = items.last else { throw ConfigurationCloudCodec.Failure(message: "Missing configuration manifest.") }
        try await save([manifest], zoneID: zoneID, database: database)
        return CloudConfigurationDocument(id: owner, deviceName: name, updatedAt: stamp, text: text)
    }

    private func save(_ items: [SyncPayloadItem], zoneID: CKRecordZone.ID, database: CKDatabase) async throws {
        let records = items.map { item in
            let record = CKRecord(recordType: "SyncItem", recordID: CKRecord.ID(recordName: "configurationDocuments:\(item.id)", zoneID: zoneID))
            record.encryptedValues["payload"] = item.payload
            record.encryptedValues["updatedAt"] = item.updatedAt
            return record
        }
        let outcome = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        for record in records {
            guard let result = outcome.saveResults[record.recordID] else {
                throw ConfigurationCloudCodec.Failure(message: "iCloud did not confirm every configuration record. Upload again to retry.")
            }
            _ = try result.get()
        }
    }

    func download() async throws -> [CloudConfigurationDocument] {
        let database = database
        var payloads: [Data] = []
        var totalBytes = 0
        // Read legacy copies only on this explicit command. Never delete or
        // overwrite them during migration to the manual-only zone.
        for name in [Self.zoneName, "NaiveFlowSync"] {
            var token: CKServerChangeToken?
            var records: [CKRecord.ID: Data] = [:]
            do {
                while true {
                    try Task.checkCancellation()
                    let page = try await database.recordZoneChanges(inZoneWith: Self.zone(name), since: token, desiredKeys: nil, resultsLimit: 100)
                    for (id, change) in page.modificationResultsByID where id.recordName.hasPrefix("configurationDocuments:") {
                        let record = try change.get().record
                        guard record.encryptedValues["deletedAt"] == nil,
                              let data = record.encryptedValues["payload"] as? Data else { records.removeValue(forKey: id); continue }
                        guard data.count <= SyncStore.maxSyncedPayloadBytes else { throw ConfigurationCloudCodec.Failure(message: "An iCloud configuration record is too large.") }
                        totalBytes += data.count
                        guard totalBytes <= 128 * 1024 * 1024 else { throw ConfigurationCloudCodec.Failure(message: "The configuration download exceeds 128 MiB.") }
                        records[id] = data
                    }
                    for deletion in page.deletions { records.removeValue(forKey: deletion.recordID) }
                    token = page.changeToken
                    if !page.moreComing { break }
                }
                payloads.append(contentsOf: records.values)
            } catch let error as CKError where error.code == .zoneNotFound { continue }
        }
        return ConfigurationCloudCodec.decode(payloads)
    }
}

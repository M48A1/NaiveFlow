import Foundation
import CryptoKit
import Observation

/// One latest text draft per installation. Separate owners preserve concurrent
/// edits on different devices; receiving a file never changes runtime state.
nonisolated struct CloudConfigurationDocument: Identifiable, Sendable, Equatable {
    let id: UUID
    let deviceName: String
    let updatedAt: Date
    let text: String
}

nonisolated enum ConfigurationCloudCodec {
    static let partBytes = 256_000
    static let maximumParts = (ConfigurationImport.maximumBytes + partBytes - 1) / partBytes

    struct Manifest: Codable, Sendable {
        let owner: UUID
        let deviceName: String
        let updatedAt: Date
        let byteCount: Int
        let hashes: [String]
        let digest: String
    }
    struct Part: Codable, Sendable {
        let owner: UUID
        let index: Int
        let bytes: Data
    }
    enum Record: Codable, Sendable {
        case manifest(Manifest), part(Part)
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func appliedOwner(_ owner: UUID) -> UUID {
        let hex = Array(digest(Data((owner.uuidString + ":applied").utf8)).prefix(32))
        let value = [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]), String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-")
        return UUID(uuidString: value)!
    }
    static func manifestID(_ owner: UUID) -> String { "\(owner.uuidString):manifest" }
    static func partID(_ owner: UUID, _ index: Int) -> String { "\(owner.uuidString):part:\(index)" }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func encode(text: String, owner: UUID, deviceName: String, stamp: Date) throws -> [SyncPayloadItem] {
        let bytes = Data(text.utf8)
        guard bytes.count <= ConfigurationImport.maximumBytes else {
            throw Failure(message: "Configuration exceeds the 16 MiB sync limit; the local draft is preserved.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let count = max(1, (bytes.count + partBytes - 1) / partBytes)
        var hashes: [String] = []
        var items: [SyncPayloadItem] = []
        for index in 0..<count {
            let start = min(bytes.count, index * partBytes)
            let end = min(bytes.count, start + partBytes)
            let part = bytes.subdata(in: start..<end)
            hashes.append(digest(part))
            items.append(.init(id: partID(owner, index), payload: try encoder.encode(Record.part(.init(owner: owner, index: index, bytes: part))), updatedAt: stamp, deletedAt: nil))
        }
        let manifest = Manifest(owner: owner, deviceName: String(deviceName.prefix(128)), updatedAt: stamp,
            byteCount: bytes.count, hashes: hashes, digest: digest(bytes))
        items.append(.init(id: manifestID(owner), payload: try encoder.encode(Record.manifest(manifest)), updatedAt: stamp, deletedAt: nil))
        guard items.allSatisfy({ $0.payload.count <= SyncStore.maxSyncedPayloadBytes }) else {
            throw Failure(message: "A configuration sync record is too large.")
        }
        return items
    }

    static func decode(_ payloads: [Data]) -> [CloudConfigurationDocument] {
        var manifests: [UUID: Manifest] = [:]
        var parts: [String: Data] = [:]
        for payload in payloads where payload.count <= SyncStore.maxSyncedPayloadBytes {
            guard let record = try? JSONDecoder().decode(Record.self, from: payload) else { continue }
            switch record {
            case .manifest(let manifest):
                guard (0...ConfigurationImport.maximumBytes).contains(manifest.byteCount),
                      !manifest.hashes.isEmpty, manifest.hashes.count <= maximumParts,
                      manifest.hashes.count == max(1, (manifest.byteCount + partBytes - 1) / partBytes),
                      manifest.deviceName.count <= 128 else { continue }
                if let previous = manifests[manifest.owner], previous.updatedAt > manifest.updatedAt { continue }
                manifests[manifest.owner] = manifest
            case .part(let part):
                guard (0..<maximumParts).contains(part.index), part.bytes.count <= partBytes else { continue }
                parts[partID(part.owner, part.index)] = part.bytes
            }
        }
        return manifests.values.compactMap { manifest -> CloudConfigurationDocument? in
            var bytes = Data()
            for (index, hash) in manifest.hashes.enumerated() {
                guard let part = parts[partID(manifest.owner, index)], digest(part) == hash else { return nil }
                bytes.append(part)
            }
            guard bytes.count == manifest.byteCount, digest(bytes) == manifest.digest,
                  let text = String(data: bytes, encoding: .utf8) else { return nil }
            return CloudConfigurationDocument(id: manifest.owner, deviceName: manifest.deviceName, updatedAt: manifest.updatedAt, text: text)
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }
}

/// Encoding and SQLite writes run off the main actor and are serialized. Fixed
/// per-device chunk slots bound storage; manifests reject mixed/incomplete data
/// while CKSyncEngine delivers a revision across multiple records.
actor ConfigurationCloudWriter {
    let store: SyncStore
    let owner: UUID
    let deviceName: String
    init(store: SyncStore, owner: UUID, deviceName: String) {
        self.store = store; self.owner = owner; self.deviceName = deviceName
    }
    func save(_ text: String) throws {
        let ref = SyncItemRef(key: .configurationDocuments, itemID: ConfigurationCloudCodec.manifestID(owner))
        let previous = store.snapshots(for: [ref])[ref]
        if let previous, let record = try? JSONDecoder().decode(ConfigurationCloudCodec.Record.self, from: previous.payload),
           case .manifest(let manifest) = record, manifest.digest == ConfigurationCloudCodec.digest(Data(text.utf8)),
           ConfigurationCloudCodec.decode(store.loadItems(.configurationDocuments)).contains(where: { $0.id == owner && $0.text == text }) { return }
        let refs = [ref] + (0..<ConfigurationCloudCodec.maximumParts).map {
            SyncItemRef(key: .configurationDocuments, itemID: ConfigurationCloudCodec.partID(owner, $0))
        }
        let snapshots = store.snapshots(for: refs)
        let stamp = SyncStamp.after(snapshots.values.map(\.updatedAt).max())
        let items = try ConfigurationCloudCodec.encode(text: text, owner: owner, deviceName: deviceName, stamp: stamp)
        let changes = items.filter { snapshots[SyncItemRef(key: .configurationDocuments, itemID: $0.id)]?.payload != $0.payload }
        store.save(.configurationDocuments, items: changes, order: [])
        guard store.snapshots(for: [ref])[ref]?.payload == items.last?.payload,
              ConfigurationCloudCodec.decode(store.loadItems(.configurationDocuments)).contains(where: { $0.id == owner && $0.text == text }) else {
            throw ConfigurationCloudCodec.Failure(message: "Could not queue the configuration for iCloud; the local draft is preserved.")
        }
    }
}

@MainActor
@Observable
final class ConfigurationCloudStore {
    private(set) var documents: [CloudConfigurationDocument] = []
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    let owner: UUID
    @ObservationIgnored private let store: SyncStore
    @ObservationIgnored private let writer: ConfigurationCloudWriter
    @ObservationIgnored private let appliedWriter: ConfigurationCloudWriter
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(store: SyncStore, owner: UUID? = nil, deviceName: String = ProcessInfo.processInfo.hostName) {
        self.store = store
        let identity: UUID
        if let owner { identity = owner }
        else if let raw = UserDefaults.standard.string(forKey: "configurationCloudDeviceID"), let id = UUID(uuidString: raw) { identity = id }
        else {
            identity = UUID()
            UserDefaults.standard.set(identity.uuidString, forKey: "configurationCloudDeviceID")
        }
        self.owner = identity
        self.writer = ConfigurationCloudWriter(store: store, owner: identity, deviceName: "\(deviceName) · Draft")
        self.appliedWriter = ConfigurationCloudWriter(store: store, owner: ConfigurationCloudCodec.appliedOwner(identity), deviceName: "\(deviceName) · Applied")
    }

    func schedule(_ text: String) {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            await saveNow(text)
        }
    }

    func saveNow(_ text: String) async {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try await writer.save(text)
            errorMessage = nil
            statusMessage = AWCore.getICloudSyncEnabled()
                ? "Saved on this device. iCloud will sync when your account and network are available."
                : "Saved on this device. Enable iCloud Sync to upload this configuration."
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    func saveApplied(_ text: String) async {
        do {
            try await appliedWriter.save(text)
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    func reload() async {
        let items = await Task.detached(priority: .utility) { [store] in
            ConfigurationCloudCodec.decode(store.loadItems(.configurationDocuments))
        }.value
        // Keep a previously complete copy visible during partial cloud delivery.
        var complete = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for item in items where complete[item.id].map({ $0.updatedAt <= item.updatedAt }) ?? true { complete[item.id] = item }
        documents = complete.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await CloudSync.shared.refresh()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        await reload()
    }
}

import Foundation
import CryptoKit
import Observation

/// A complete cloud copy. Uploads use new IDs; receiving a copy never changes runtime state.
nonisolated struct CloudConfigurationDocument: Codable, Identifiable, Sendable, Equatable {
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

/// Local cache plus explicit transfer actions. Opening the editor reads disk;
/// editing/applying never queues data for CKSyncEngine or starts network work.
@MainActor
@Observable
final class ConfigurationCloudStore {
    private(set) var documents: [CloudConfigurationDocument] = []
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var isTransferring = false
    @ObservationIgnored private let transport: any ConfigurationCloudTransport
    @ObservationIgnored private let cacheURL: URL?

    init(transport: any ConfigurationCloudTransport = ManualConfigurationCloudTransport.shared,
         cacheURL: URL? = EngineConfirmationStore.directory.appendingPathComponent("manual-cloud-configurations.json")) {
        self.transport = transport
        self.cacheURL = cacheURL
    }

    func upload(_ text: String) async {
        guard !isTransferring else { return }
        isTransferring = true
        defer { isTransferring = false }
        do {
            let document = try await transport.upload(text: text)
            documents.removeAll { $0.id == document.id }
            documents.insert(document, at: 0)
            statusMessage = "Uploaded a new iCloud copy. Existing cloud configurations were preserved."
            errorMessage = nil
            saveCache()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Disk only; never initiates a fetch, upload, migration or retry.
    func reload() {
        guard let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do {
            guard (try cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128 * 1024 * 1024 else { return }
            documents = try JSONDecoder().decode([CloudConfigurationDocument].self, from: Data(contentsOf: cacheURL))
        } catch { errorMessage = error.localizedDescription }
    }

    func download() async {
        guard !isTransferring else { return }
        isTransferring = true
        defer { isTransferring = false }
        do {
            let downloaded = try await transport.download()
            documents = downloaded
            statusMessage = "Downloaded iCloud copies. Select one to load into the editor; nothing has been applied."
            errorMessage = nil
            saveCache()
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveCache() {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(documents).write(to: cacheURL, options: .atomic)
        } catch { errorMessage = "Transfer completed, but the local cache could not be saved: \(error.localizedDescription)" }
    }
}

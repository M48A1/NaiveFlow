import Foundation
import Observation

nonisolated struct ClientIconPack: Codable, Identifiable {
    struct Icon: Codable, Identifiable, Equatable {
        let name: String
        let url: String
        var id: String { url }
    }

    static let defaultSource = "https://raw.githubusercontent.com/lige47/lige_icon/main/ligeicon.json"
    var id = UUID()
    var source: String
    var name: String
    var description = ""
    var icons: [Icon] = []
    var updatedAt: Date?

    static func decode(_ data: Data, source: String, id: UUID = UUID()) throws -> ClientIconPack {
        struct Payload: Decodable {
            let name: String
            let description: String?
            let icons: [Icon]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.icons.isEmpty, payload.icons.count <= 10_000 else {
            throw ClientFailure("Invalid icon pack name or icon count.")
        }
        var seen = Set<String>()
        let icons = payload.icons.compactMap { icon -> Icon? in
            guard !icon.name.isEmpty, let normalized = URL(string: icon.url)?.absoluteString,
                  ProxyGroupIconURL.parse(normalized) != nil, seen.insert(normalized).inserted else { return nil }
            return Icon(name: icon.name, url: normalized)
        }
        guard !icons.isEmpty else { throw ClientFailure("This icon pack contains no valid HTTPS icons.") }
        return ClientIconPack(id: id, source: source, name: payload.name, description: payload.description ?? "", icons: icons, updatedAt: .now)
    }
}

@MainActor @Observable
final class ClientIconPackLibrary {
    private(set) var packs: [ClientIconPack]
    private(set) var updating = Set<UUID>()
    var error: String?
    private let defaults: UserDefaults
    private let key = "client.externalIconPacks.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([ClientIconPack].self, from: data) {
            packs = saved
        } else {
            packs = [ClientIconPack(source: ClientIconPack.defaultSource, name: "Lige Icons")]
        }
    }

    func pack(_ id: UUID) -> ClientIconPack? { packs.first { $0.id == id } }

    @discardableResult
    func update(id: UUID, source: String? = nil) async -> Bool {
        guard let previous = pack(id), !updating.contains(id) else { return false }
        return await fetch(id: id, source: source ?? previous.source)
    }

    @discardableResult
    func add(source: String) async -> Bool {
        await fetch(id: UUID(), source: source)
    }

    private func fetch(id: UUID, source: String) async -> Bool {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = ProxyGroupIconURL.parse(source) else { error = "Enter a valid HTTPS icon pack JSON URL."; return false }
        guard !packs.contains(where: { $0.id != id && $0.source == source }) else { error = "This icon pack has already been added."; return false }
        updating.insert(id)
        defer { updating.remove(id) }
        do {
            let (data, response) = try await BoundedHTTPFetcher.fetch(url, maxBytes: 4 * 1024 * 1024)
            guard (200...299).contains(response.statusCode), response.url?.scheme?.lowercased() == "https" else {
                throw ClientFailure("Could not download the icon pack. Check the URL and try again.")
            }
            let loaded = try ClientIconPack.decode(data, source: source, id: id)
            if let index = packs.firstIndex(where: { $0.id == id }) { packs[index] = loaded }
            else { packs.append(loaded) }
            persist()
            return true
        } catch is CancellationError { return false }
        catch { self.error = error.localizedDescription; return false }
    }

    func remove(_ id: UUID) {
        guard !updating.contains(id) else { return }
        packs.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do { defaults.set(try JSONEncoder().encode(packs), forKey: key) }
        catch { self.error = error.localizedDescription }
    }
}

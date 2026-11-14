import Foundation

nonisolated struct ClientGroupStyle: Codable, Equatable {
    var symbol = "square.stack.3d.up.fill"
    var palette = 0
}

nonisolated struct ClientModule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var summary: String
    var source: String
    var sourceURL: String?
    var format: ModuleFormat
    var enabled = true
    var setKeys: [String] = []
}

nonisolated struct ClientProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String
    var updatedAt = Date()
    var sourceURL: String?
    var modules: [ClientModule] = []
    var groupStyles: [String: ClientGroupStyle] = [:]
    var nodeSubscriptions: [ClientNodeSubscription]?

    // Display the legacy built-in label in English without renaming stored data.
    var displayName: String { name == "默认配置" ? "Default Profile" : name }
}

nonisolated struct ClientSubscriptionMember: Codable, Equatable {
    var sourceName: String
    var name: String
    var edited = false
}

nonisolated struct ClientNodeSubscription: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var members: [ClientSubscriptionMember] = []
    var updatedAt = Date()
    var remnawaveHWIDEnabled = false
}

nonisolated extension ClientNodeSubscription {
    private enum CodingKeys: String, CodingKey {
        case id, name, url, members, updatedAt, remnawaveHWIDEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        members = try container.decodeIfPresent([ClientSubscriptionMember].self, forKey: .members) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        remnawaveHWIDEnabled = try container.decodeIfPresent(Bool.self, forKey: .remnawaveHWIDEnabled) ?? false
    }
}

nonisolated struct ClientProfileLibrary: Codable {
    var selectedID: UUID?
    var profiles: [ClientProfile] = []

    static var directory: URL { EngineConfirmationStore.directory.appendingPathComponent("client-ui", isDirectory: true) }

    static func load(from directory: URL = Self.directory) throws -> Self {
        let url = directory.appendingPathComponent("profiles.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(to directory: URL = Self.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("profiles.json"), options: .atomic)
    }
}

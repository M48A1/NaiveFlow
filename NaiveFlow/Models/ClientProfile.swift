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

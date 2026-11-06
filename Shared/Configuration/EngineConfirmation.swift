//
//  EngineConfirmation.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// The extension's answer to "what are you actually running?".
///
/// The host app records what it activated; this record is written by the
/// Network Extension itself, so "activated" and "running" can be told apart
/// instead of being assumed to be the same event.
///
/// It is deliberately self-contained (Foundation + `AWCore` only) so both the
/// app and the extension can use it: the extension does not link the
/// configuration compiler or the snapshot store.
nonisolated struct ConfigurationEngineConfirmation: Codable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable { case routing, configuration }
    var scope: Scope?
    var snapshotId: UUID?
    var confirmedAt: Date
    var engineVersion: String

    init(snapshotId: UUID?, confirmedAt: Date = .now, engineVersion: String, scope: Scope = .routing) {
        self.scope = scope
        self.snapshotId = snapshotId
        self.confirmedAt = confirmedAt
        self.engineVersion = engineVersion
    }
}

/// Version of the binary that is reporting, so a confirmation from an older
/// extension build is recognizable.
nonisolated enum ConfigurationEngineVersion {

    static var current: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}

/// File bridge between the two processes. The extension only reads the active
/// snapshot id out of `manifest.json` and writes its own file, so the two sides
/// never rewrite each other's data.
nonisolated enum EngineConfirmationStore {

    /// Only the field the extension needs; the rest of the manifest is ignored.
    private struct ActiveSnapshotPointer: Codable {
        var activeSnapshotId: UUID?
    }

    static var directory: URL {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AWCore.Identifier.appGroupSuite
        ) {
            return container.appendingPathComponent("configurations", isDirectory: true)
        }
        return URL.temporaryDirectory.appendingPathComponent("configurations", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("engine-confirmation.json")
    }

    private static var manifestURL: URL {
        directory.appendingPathComponent("manifest.json")
    }

    static func load() -> ConfigurationEngineConfirmation? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ConfigurationEngineConfirmation.self, from: data)
    }

    static func activeSnapshotId() -> UUID? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return (try? JSONDecoder().decode(ActiveSnapshotPointer.self, from: data))?.activeSnapshotId
    }

    static func record(_ confirmation: ConfigurationEngineConfirmation) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(confirmation) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Routing telemetry only. Independent store publications do not prove that
    /// all modules consumed one snapshot, so never infer its id from the latest
    /// host manifest. A future transactional publisher can emit .configuration
    /// only after verifying all module receipts for that exact snapshot.
    static func recordRoutingReady(engineVersion: String = ConfigurationEngineVersion.current) {
        record(ConfigurationEngineConfirmation(snapshotId: nil, engineVersion: engineVersion, scope: .routing))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

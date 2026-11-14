//
//  ConfigurationSnapshotStore.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// A compiled text configuration frozen at activation time.
///
/// Snapshots live in the App Group container so the host app can record what it
/// activated and the Network Extension can read the same history. Each snapshot
/// keeps the original text, a summary of what was compiled, and the diagnostics
/// seen at the time, which makes "what changed?" answerable without a rebuild.
nonisolated struct ConfigurationSnapshot: Codable, Equatable, Sendable, Identifiable {
    struct Summary: Codable, Equatable, Sendable {
        let proxyCount: Int
        let groupCount: Int
        let ruleCount: Int
        let ruleSetCount: Int
        let hostCount: Int

        var isEmpty: Bool {
            proxyCount == 0 && groupCount == 0 && ruleCount == 0 && ruleSetCount == 0 && hostCount == 0
        }
    }

    let id: UUID
    let createdAt: Date
    let text: String
    let summary: Summary
    let diagnostics: [ConfigurationDiagnostic]
    var ruleSetContents: [String: String]?

    var errorCount: Int { diagnostics.count { $0.severity == .error } }
    var warningCount: Int { diagnostics.count { $0.severity == .warning } }

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        text: String,
        compiled: CompiledConfiguration,
        ruleSetContents: [String: String]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.summary = Summary(
            proxyCount: compiled.proxies.count,
            groupCount: compiled.proxyGroups.count,
            ruleCount: compiled.orderedRules.count,
            ruleSetCount: compiled.ruleSets.count,
            hostCount: compiled.hosts.count
        )
        self.diagnostics = compiled.diagnostics
        self.ruleSetContents = ruleSetContents
    }
}

/// File-backed snapshot history plus the "which snapshot is live" pointer.
///
/// Layout inside the App Group container:
/// ```
/// configurations/manifest.json
/// configurations/snapshots/<uuid>.json
/// ```
/// Writes are atomic, so a crash mid-activation leaves either the old or the
/// new manifest on disk, never a partially written one.
nonisolated struct ConfigurationSnapshotStore: Sendable {

    enum Failure: LocalizedError {
        case directoryUnavailable
        case snapshotMissing(UUID)
        case writeFailed(String)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .directoryUnavailable:
                return "The shared configuration directory is unavailable."
            case .snapshotMissing(let id):
                return "Snapshot \(id.uuidString) no longer exists."
            case .writeFailed(let detail):
                return "Could not save the configuration snapshot: \(detail)"
            case .readFailed(let detail):
                return "Could not read the configuration snapshot: \(detail)"
            }
        }
    }

    struct Manifest: Codable, Equatable, Sendable {
        var activeSnapshotId: UUID?
        var previousSnapshotId: UUID?
        var updatedAt: Date = .now
        var lastFailure: String?
        /// When the host last made a snapshot active. The extension's own answer
        /// lives in `engine-confirmation.json`, written separately so the two
        /// processes never rewrite each other's file.
        var appliedAt: Date?
    }

    /// Newest snapshots kept on disk; older ones are pruned after each save.
    static let retainedSnapshotCount = 20

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AWCore.Identifier.appGroupSuite
        ) {
            self.directory = container.appendingPathComponent("configurations", isDirectory: true)
        } else {
            self.directory = URL.temporaryDirectory.appendingPathComponent("configurations", isDirectory: true)
        }
    }

    private var snapshotsDirectory: URL {
        directory.appendingPathComponent("snapshots", isDirectory: true)
    }

    private var manifestURL: URL {
        directory.appendingPathComponent("manifest.json")
    }

    private func snapshotURL(_ id: UUID) -> URL {
        snapshotsDirectory.appendingPathComponent("\(id.uuidString).json")
    }
}

// MARK: - Reading

nonisolated extension ConfigurationSnapshotStore {

    func manifest() -> Manifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return Manifest() }
        return manifest
    }

    func snapshot(_ id: UUID) -> ConfigurationSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(id)) else { return nil }
        return try? JSONDecoder().decode(ConfigurationSnapshot.self, from: data)
    }

    func activeSnapshot() -> ConfigurationSnapshot? {
        manifest().activeSnapshotId.flatMap(snapshot)
    }

    func previousSnapshot() -> ConfigurationSnapshot? {
        manifest().previousSnapshotId.flatMap(snapshot)
    }

    /// All snapshots, newest first. Unreadable files are skipped rather than
    /// failing the whole listing.
    func snapshots() -> [ConfigurationSnapshot] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: snapshotsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ConfigurationSnapshot? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ConfigurationSnapshot.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - Writing

nonisolated extension ConfigurationSnapshotStore {

    @discardableResult
    func save(_ snapshot: ConfigurationSnapshot) throws -> ConfigurationSnapshot {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(snapshot).write(to: snapshotURL(snapshot.id), options: .atomic)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
        prune()
        return snapshot
    }

    /// Marks a snapshot active. The previously active snapshot stays on disk as
    /// the rollback target.
    func activate(_ id: UUID, confirmed: Bool = true) throws {
        guard snapshot(id) != nil else { throw Failure.snapshotMissing(id) }
        var current = manifest()
        if current.activeSnapshotId == id {
            if confirmed, current.appliedAt == nil {
                current.appliedAt = .now
                try write(current)
            }
            return
        }
        current.previousSnapshotId = current.activeSnapshotId
        current.activeSnapshotId = id
        current.updatedAt = .now
        current.appliedAt = confirmed ? current.updatedAt : nil
        current.lastFailure = nil
        try write(current)
    }

    func restoreManifest(_ manifest: Manifest) throws { try write(manifest) }

    func recordFailure(_ message: String) throws {
        var current = manifest()
        current.lastFailure = message
        current.updatedAt = .now
        try write(current)
    }

    /// Restores the previous snapshot and returns it. The failed snapshot stays
    /// on disk for inspection but is no longer active.
    @discardableResult
    func rollback() throws -> ConfigurationSnapshot? {
        var current = manifest()
        guard let previousId = current.previousSnapshotId,
              let previous = snapshot(previousId)
        else { return nil }
        current.activeSnapshotId = previousId
        current.previousSnapshotId = nil
        current.updatedAt = .now
        current.appliedAt = current.updatedAt
        try write(current)
        return previous
    }

    func remove(_ id: UUID) throws {
        var current = manifest()
        try? FileManager.default.removeItem(at: snapshotURL(id))
        if current.activeSnapshotId == id { current.activeSnapshotId = nil }
        if current.previousSnapshotId == id { current.previousSnapshotId = nil }
        try write(current)
    }

    func removeAll() throws {
        try? FileManager.default.removeItem(at: snapshotsDirectory)
        try? FileManager.default.removeItem(at: manifestURL)
        try ensureDirectories()
        try write(Manifest())
    }

    private func ensureDirectories() throws {
        do {
            try FileManager.default.createDirectory(
                at: snapshotsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw Failure.directoryUnavailable
        }
    }

    private func write(_ value: Manifest) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(value).write(to: manifestURL, options: .atomic)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Drops the oldest snapshots, never touching the active or rollback one.
    private func prune() {
        let all = snapshots()
        guard all.count > Self.retainedSnapshotCount else { return }
        let current = manifest()
        for snapshot in all.dropFirst(Self.retainedSnapshotCount)
        where snapshot.id != current.activeSnapshotId && snapshot.id != current.previousSnapshotId {
            try? FileManager.default.removeItem(at: snapshotURL(snapshot.id))
        }
    }
}


//
//  ConfigurationActivation.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Glue between the editor and the snapshot store.
///
/// Three pieces of state are kept apart on purpose:
/// - the **draft** (`configurations/draft.txt`), which is what the user typed and
///   survives an app relaunch even while it has errors;
/// - the **snapshot** written on activation, which is what the engine is asked to
///   run;
/// - the **manifest**, which records which snapshot is live and which one is the
///   rollback target.
///
/// The draft is never validated away: a half-finished document stays on disk so
/// the user does not lose work, while activation is refused until the compiled
/// result is clean.
nonisolated struct ConfigurationActivation: Sendable {

    enum Failure: LocalizedError {
        case draftUnavailable(String)
        case notActivatable(errors: Int, warnings: Int)
        case nothingToRollBack

        var errorDescription: String? {
            switch self {
            case .draftUnavailable(let detail):
                return "Could not save the configuration draft: \(detail)"
            case .notActivatable(let errors, let warnings):
                let plural = errors == 1 ? "error" : "errors"
                return "The configuration has \(errors) \(plural) and \(warnings) warning(s), so it was not activated."
            case .nothingToRollBack:
                return "There is no previous configuration to roll back to."
            }
        }
    }

    /// A compiled configuration that has been frozen as a snapshot.
    struct Activation: Sendable {
        let snapshot: ConfigurationSnapshot
        let result: TextConfigurationPipeline.Result

        var text: String { snapshot.text }
        var compiled: CompiledConfiguration { result.compiled }
        var summary: ConfigurationSnapshot.Summary { snapshot.summary }
    }

    let store: ConfigurationSnapshotStore

    init(store: ConfigurationSnapshotStore = ConfigurationSnapshotStore()) {
        self.store = store
    }

    private var draftURL: URL {
        store.directory.appendingPathComponent("draft.txt")
    }

    // MARK: - Draft

    /// Text the editor should show. Falls back to the starter template so a
    /// first launch lands on something that already compiles.
    func draft() -> String {
        guard let text = try? String(contentsOf: draftURL, encoding: .utf8) else {
            return TextConfigurationPipeline.template
        }
        return text
    }

    func hasDraft() -> Bool {
        FileManager.default.fileExists(atPath: draftURL.path)
    }

    /// Stores the editor contents. Saving never implies activation, so a draft
    /// with errors can still be persisted.
    func saveDraft(_ text: String) throws {
        try createDirectory()
        do {
            try Data(text.utf8).write(to: draftURL, options: .atomic)
        } catch {
            throw Failure.draftUnavailable(error.localizedDescription)
        }
    }

    /// Drops the draft so the next launch starts from the template again.
    func discardDraft() {
        try? FileManager.default.removeItem(at: draftURL)
    }

    /// Compiles the stored draft; used for the editor's live diagnostics before
    /// the first keystroke of a session.
    func processDraft(
        capabilities: ConfigurationValidator.Capabilities = .current
    ) -> TextConfigurationPipeline.Result {
        TextConfigurationPipeline.process(text: draft(), capabilities: capabilities)
    }

    private func createDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.draftUnavailable(error.localizedDescription)
        }
    }

    // MARK: - Activation

    /// Compiles the text, refuses to go live while it still has errors, then
    /// freezes it as a snapshot and makes that snapshot the active one.
    ///
    /// The draft is written after the check but before the snapshot so an
    /// interrupted activation cannot leave the editor showing one document and
    /// the engine running another.
    @discardableResult
    func activate(
        text: String,
        capabilities: ConfigurationValidator.Capabilities = .current
    ) throws -> Activation {
        let result = TextConfigurationPipeline.process(text: text, capabilities: capabilities)
        guard result.isActivatable else {
            record("Activation refused: \(result.errorCount) error(s)")
            throw Failure.notActivatable(errors: result.errorCount, warnings: result.warningCount)
        }

        try saveDraft(text)

        let snapshot = ConfigurationSnapshot(text: text, compiled: result.compiled)
        do {
            try store.save(snapshot)
            try store.activate(snapshot.id)
        } catch {
            record(error.localizedDescription)
            throw error
        }
        return Activation(snapshot: snapshot, result: result)
    }

    /// Recompiles and reactivates a stored snapshot, e.g. after the engine gained
    /// rule types it did not support when the snapshot was first written.
    @discardableResult
    func activate(_ snapshot: ConfigurationSnapshot) throws -> Activation {
        try activate(text: snapshot.text)
    }

    /// The snapshot the engine is expected to be running.
    var active: Activation? {
        guard let id = store.manifest().activeSnapshotId,
              let snapshot = store.snapshot(id)
        else { return nil }
        return Activation(
            snapshot: snapshot,
            result: TextConfigurationPipeline.process(text: snapshot.text)
        )
    }

    /// Snapshots newest first, for the history list in the editor.
    func history(limit: Int = 10) -> [ConfigurationSnapshot] {
        Array(store.snapshots().prefix(max(0, limit)))
    }

    /// Restores the snapshot that was live before the current one and loads its
    /// text back into the draft.
    @discardableResult
    func rollback() throws -> Activation {
        guard let snapshot = try store.rollback() else {
            throw Failure.nothingToRollBack
        }
        try saveDraft(snapshot.text)
        return Activation(
            snapshot: snapshot,
            result: TextConfigurationPipeline.process(text: snapshot.text)
        )
    }

    /// Notes a runtime failure (tunnel start, handshake, …) next to the manifest
    /// so the editor can show why the last activation did not stick.
    func record(_ message: String) {
        try? store.recordFailure(message)
    }

    // MARK: - Rollout state

    /// What the extension last reported running, or `nil` while it has not
    /// confirmed anything.
    func engineConfirmation() -> ConfigurationEngineConfirmation? {
        store.confirmation()
    }

    /// True when the extension confirmed the snapshot the manifest points at.
    /// The editor shows "not yet confirmed" until then, instead of assuming a
    /// successful activation means a running configuration.
    func isActiveSnapshotConfirmed() -> Bool {
        store.isActiveSnapshotConfirmed()
    }

    /// When the host last made a snapshot active.
    func appliedAt() -> Date? {
        store.manifest().appliedAt
    }
}

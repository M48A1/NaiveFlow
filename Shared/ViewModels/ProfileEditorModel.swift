//
//  ProfileEditorModel.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation
import Observation

/// What the profile editor needs from the configuration pipeline.
///
/// `Shared/Configuration/` stays free of UI and of editor state: it parses,
/// validates, compiles, snapshots and installs, and knows nothing about a screen
/// being open. This protocol is the seam in between, so the editor's state
/// machine can be exercised without a running tunnel, an App Group container or
/// a real installation.
@MainActor
protocol ProfileEditing {
    /// Text the editor should show (the persisted draft, or the template).
    func loadDraft() -> String
    /// Persists the editor buffer without activating it.
    func persistDraft(_ text: String) throws
    /// Compiles without touching the stores, for live feedback.
    func previewDocument(_ text: String) -> TextConfigurationPipeline.Result
    /// Compiles and writes the document into the app's stores.
    func applyDocument(_ text: String) throws -> ProfileApplyOutcome
    /// Renders the stores back into a document.
    func exportDocument() -> ConfigurationExporter.Result
    /// Reads a picked file so it can be reviewed before it is applied.
    func readDocument(at url: URL) throws -> String
    /// When the host last made a snapshot active.
    func lastAppliedAt() -> Date?
    /// Recently applied documents, newest first.
    func appliedHistory() -> [ConfigurationSnapshot]
}

/// The part of an activation the editor reports back to the user.
///
/// Deliberately smaller than `ConfigurationInstaller.Outcome`: a screen shows
/// the summary, the notes and how much work the running tunnel has to do. The
/// per-store diff lists stay in the installer, where they are calculated.
nonisolated struct ProfileApplyOutcome: Equatable, Sendable {
    let summary: String
    let notes: [String]
    let plan: ConfigurationReloadPlan
}

/// The state machine behind the profile screen.
///
/// The page itself only renders. Everything that can go wrong or be forgotten
/// lives here, so it behaves the same on both platforms and can be tested
/// without SwiftUI:
///
/// - **the buffer** — `text` only changes through `edit`, `apply`, `importFile`,
///   `revert` or `discardChanges`, each of which keeps the preview, the draft on
///   disk and the "unsaved changes" flag in step;
/// - **the draft** — typing debounces the recompile and then writes the draft, so
///   a half-finished document survives a relaunch while activation stays refused;
/// - **the cost of a change** — after an apply the plan says whether the running
///   tunnel picks the document up, restarts its data plane, or needs a reconnect;
/// - **what the user last saw** — status line, error, notes and history, so the
///   page never has to invent a message.
///
/// `text` is read-only from the outside on purpose: a view that could assign it
/// would bypass the preview and the draft.
@MainActor
@Observable
final class ProfileEditorModel {

    // MARK: - State

    /// The document as shown in the editor.
    private(set) var text = ""
    /// Result of compiling `text`; `nil` only before the first load.
    private(set) var preview: TextConfigurationPipeline.Result?
    /// The text the stores were last loaded from or applied with.
    ///
    /// Compared against `text` to answer "are there unsaved changes", so the flag
    /// survives re-rendering and the debounce window.
    private(set) var baseline = ""
    private(set) var history: [ConfigurationSnapshot] = []
    /// What the last apply (or export) could not carry into the document.
    private(set) var notes: [String] = []
    private(set) var lastAppliedAt: Date?
    /// Result of the last successful apply, including its reload plan.
    private(set) var lastOutcome: ProfileApplyOutcome?
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var isApplying = false
    private(set) var isLoaded = false

    @ObservationIgnored private let document: any ProfileEditing
    @ObservationIgnored private let previewDelay: Duration
    @ObservationIgnored private var pendingPreview: Task<Void, Never>?

    init(document: any ProfileEditing, previewDelay: Duration = .milliseconds(250)) {
        self.document = document
        self.previewDelay = previewDelay
    }

    // MARK: - Derived state

    /// True when the buffer holds changes that were never applied.
    var isDirty: Bool {
        isLoaded && text != baseline
    }

    var canApply: Bool {
        isLoaded && !isApplying && (preview?.isActivatable ?? false)
    }

    var errorCount: Int { preview?.errorCount ?? 0 }
    var warningCount: Int { preview?.warningCount ?? 0 }
    var diagnostics: [ConfigurationDiagnostic] { preview?.diagnostics ?? [] }

    /// Diagnostics grouped by line, for an editor gutter.
    var diagnosticsByLine: [Int: [ConfigurationDiagnostic]] {
        preview?.diagnosticsByLine ?? [:]
    }

    /// What activating the last applied document costs the running tunnel.
    var reloadPlan: ConfigurationReloadPlan? { lastOutcome?.plan }

    var requiresReconnect: Bool { lastOutcome?.plan.requiresReconnect ?? false }

    /// One line the page can show after an apply, or `nil` when nothing changed.
    var reloadNotice: String? {
        guard let plan = lastOutcome?.plan, !plan.isEmpty else { return nil }
        return "\(plan.summary) \(Self.cost(of: plan))"
    }

    // MARK: - Lifecycle

    /// Loads the draft once; repeated calls (every appearance) are ignored so a
    /// returning user does not lose typed text.
    func load() {
        guard !isLoaded else { return }
        isLoaded = true
        text = document.loadDraft()
        baseline = text
        preview = document.previewDocument(text)
        lastAppliedAt = document.lastAppliedAt()
        history = document.appliedHistory()
    }

    // MARK: - Editing

    /// Replaces the buffer and schedules the debounced recompile + draft save.
    ///
    /// With `previewDelay` at zero this is synchronous, so a test can observe a
    /// burst of edits step by step instead of through a timer.
    func edit(_ value: String) {
        guard value != text else { return }
        text = value
        statusMessage = nil
        schedulePreview()
    }

    /// Recompiles immediately and drops any debounced work in flight.
    func refreshPreview() {
        pendingPreview?.cancel()
        pendingPreview = nil
        preview = document.previewDocument(text)
    }

    // MARK: - Actions

    /// Writes the buffer into the app's stores.
    ///
    /// A document with errors is refused by the pipeline before the stores are
    /// touched, so a failed apply leaves the buffer and the baseline alone and
    /// keeps the error on screen.
    func apply() {
        guard !isApplying else { return }
        pendingPreview?.cancel()
        pendingPreview = nil
        isApplying = true
        defer { isApplying = false }

        do {
            let outcome = try document.applyDocument(text)
            baseline = text
            preview = document.previewDocument(text)
            notes = outcome.notes
            lastOutcome = outcome
            lastAppliedAt = document.lastAppliedAt()
            history = document.appliedHistory()
            errorMessage = nil
            statusMessage = "\(outcome.summary) \(Self.cost(of: outcome.plan))"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renders the app's current stores into the buffer, so editing starts from
    /// what the tunnel already runs instead of a blank page.
    func reloadFromCurrentSetup() {
        let exported = document.exportDocument()
        replaceText(with: exported.text)
        notes = exported.notes
        errorMessage = nil
        let counts = exported.counts
        statusMessage = "Loaded \(counts.proxies) nodes, \(counts.groups) groups and \(counts.rules) rules from the app. Press Apply to write the document back."
    }

    /// Loads a picked file into the buffer. Reading never applies.
    func importFile(at url: URL) {
        do {
            let imported = try document.readDocument(at: url)
            replaceText(with: imported)
            statusMessage = "Imported \(url.lastPathComponent). Review it, then press Apply."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Puts an already applied document back into the buffer for review.
    func revert(to snapshot: ConfigurationSnapshot) {
        replaceText(with: snapshot.text)
        let applied = snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)
        statusMessage = "Restored the document applied on \(applied). Press Apply to use it again."
    }

    /// Throws away edits that were never applied.
    func discardChanges() {
        guard isDirty else { return }
        replaceText(with: baseline)
        statusMessage = "Discarded the changes that were not applied."
    }

    /// Surfaces an error raised outside the model, e.g. a failed file picker.
    func report(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    /// Clears the error banner without touching the status line.
    func dismissError() {
        errorMessage = nil
    }

    func dismissMessages() {
        statusMessage = nil
        errorMessage = nil
    }

    // MARK: - Helpers

    /// Replaces the buffer outside the debounce path: preview and draft are
    /// settled in the same step, so the page never shows text it has not
    /// compiled.
    private func replaceText(with value: String) {
        pendingPreview?.cancel()
        pendingPreview = nil
        text = value
        preview = document.previewDocument(value)
        persistDraft()
    }

    private func schedulePreview() {
        pendingPreview?.cancel()

        guard previewDelay > .zero else {
            refreshPreview()
            persistDraft()
            return
        }

        pendingPreview = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: previewDelay)
            guard !Task.isCancelled else { return }
            refreshPreview()
            persistDraft()
        }
    }

    private func persistDraft() {
        try? document.persistDraft(text)
    }

    private static func cost(of plan: ConfigurationReloadPlan) -> String {
        if plan.requiresReconnect {
            return String(localized: "Reconnect the tunnel so it picks the new settings up.")
        }
        if plan.requiresStackRestart {
            return String(localized: "The tunnel restarts its data plane to apply them.")
        }
        return String(localized: "The running tunnel picks them up without a restart.")
    }
}

// MARK: - Pipeline conformance

/// The pipeline already offers these crossings; the model reaches them through
/// `ProfileEditing` so a test can substitute a stub.
extension ConfigurationDocumentOperations: ProfileEditing {

    func loadDraft() -> String {
        draft()
    }

    func persistDraft(_ text: String) throws {
        try saveDraft(text)
    }

    func previewDocument(_ text: String) -> TextConfigurationPipeline.Result {
        preview(text)
    }

    func applyDocument(_ text: String) throws -> ProfileApplyOutcome {
        let outcome = try apply(text)
        return ProfileApplyOutcome(
            summary: outcome.summary,
            notes: outcome.notes,
            plan: outcome.plan
        )
    }

    func exportDocument() -> ConfigurationExporter.Result {
        exportCurrent()
    }

    func readDocument(at url: URL) throws -> String {
        try read(contentsOf: url)
    }

    func lastAppliedAt() -> Date? {
        appliedAt()
    }

    func appliedHistory() -> [ConfigurationSnapshot] {
        history(limit: 5)
    }
}


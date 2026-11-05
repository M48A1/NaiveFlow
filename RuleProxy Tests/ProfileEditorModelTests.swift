//
//  ProfileEditorModelTests.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation
import Testing
@testable import RuleProxy

/// The editor's session logic used to live inside `ConfigurationView`, where only
/// a human tapping around could exercise it. These tests pin the behaviour the
/// page relies on: what marks the document dirty, what a refused apply leaves
/// behind, what a successful apply publishes, and that a burst of typing costs
/// one compile and one draft write.
@MainActor
struct ProfileEditorModelTests {

    static let invalidDocument = """
        [Rule]
        DOMAIN-SUFFIX, example.com, Missing
        """

    static let validDocument = """
        [Rule]
        DOMAIN-SUFFIX, example.net, DIRECT
        """

    static let fileURL = URL(fileURLWithPath: "/tmp/profile.conf")

    // MARK: - Loading

    @Test func loadReadsDraftHistoryAndAppliedDate() {
        let document = ProfileDocumentStub()
        let appliedAt = Date(timeIntervalSince1970: 1_700_000_000)
        document.appliedAt = appliedAt
        document.snapshots = [Self.snapshot(Self.validDocument)]

        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()

        #expect(model.isLoaded)
        #expect(model.text == document.draft)
        #expect(model.baseline == document.draft)
        #expect(!model.isDirty, "A freshly loaded draft is not a change.")
        #expect(model.lastAppliedAt == appliedAt)
        #expect(model.history.count == 1)
        #expect(model.preview?.isActivatable == true)
        #expect(model.errorCount == 0)
    }

    @Test func loadNeverDiscardsTypedText() {
        let model = ProfileEditorModel(document: ProfileDocumentStub(), previewDelay: .zero)
        model.load()
        model.edit(Self.validDocument)

        // The page calls `load()` from `.task`, which runs again on every
        // appearance.
        model.load()

        #expect(model.text == Self.validDocument)
    }

    // MARK: - Editing

    @Test func editingMarksDirtyCompilesAndSavesDraft() {
        let document = ProfileDocumentStub()
        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()
        document.previewed.removeAll()
        document.persisted.removeAll()

        model.edit(Self.validDocument)

        #expect(model.isDirty)
        #expect(model.text == Self.validDocument)
        #expect(document.previewed == [Self.validDocument])
        #expect(document.persisted == [Self.validDocument], "The draft is what survives a relaunch.")
        #expect(model.preview?.isActivatable == true)
    }

    @Test func debouncedPreviewCoalescesRapidEdits() async throws {
        let document = ProfileDocumentStub()
        let model = ProfileEditorModel(document: document, previewDelay: .milliseconds(60))
        model.load()
        document.previewed.removeAll()

        model.edit("[Rule]\n#1\n")
        model.edit("[Rule]\n#2\n")
        model.edit("[Rule]\n#3\n")

        // Before the debounce elapses nothing has been compiled.
        #expect(document.previewed.isEmpty)

        try await Task.sleep(for: .milliseconds(400))

        #expect(document.previewed == ["[Rule]\n#3\n"])
        #expect(document.persisted.last == "[Rule]\n#3\n")
        #expect(model.text == "[Rule]\n#3\n")
    }

    @Test func documentWithErrorsCannotBeApplied() {
        let model = ProfileEditorModel(document: ProfileDocumentStub(), previewDelay: .zero)
        model.load()
        model.edit(Self.invalidDocument)

        #expect(model.errorCount > 0)
        #expect(model.canApply == false)
    }

    // MARK: - Applying

    @Test func refusedApplyKeepsTheBufferAndReportsWhy() {
        let document = ProfileDocumentStub()
        document.applyError = ConfigurationActivation.Failure.notActivatable(errors: 2, warnings: 0)
        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()
        model.edit(Self.invalidDocument)

        model.apply()

        #expect(model.errorMessage?.contains("2 errors") == true)
        #expect(model.text == Self.invalidDocument, "A refused apply must not touch what the user typed.")
        #expect(model.isDirty, "The buffer still differs from what the stores run.")
        #expect(model.lastAppliedAt == nil)
        #expect(model.isApplying == false)
    }

    @Test func applyPublishesHistoryBaselineAndReloadPlan() {
        let document = ProfileDocumentStub()
        let appliedAt = Date(timeIntervalSince1970: 1_700_000_500)
        document.outcome = ProfileApplyOutcome(
            summary: "Applied 1 rule set.",
            notes: ["Node “Tokyo” was dropped because its share link is invalid."],
            plan: ConfigurationReloadPlan(changes: [
                ConfigurationReloadPlan.Change(
                    field: "include-all-networks",
                    scope: .reconnect,
                    summary: "false → true"
                )
            ])
        )
        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()
        model.edit(Self.validDocument)
        document.appliedAt = appliedAt
        document.snapshots = [Self.snapshot(Self.validDocument)]

        model.apply()

        #expect(model.isDirty == false, "A successful apply makes the buffer the applied document.")
        #expect(model.baseline == Self.validDocument)
        #expect(model.errorMessage == nil)
        #expect(model.lastAppliedAt == appliedAt)
        #expect(model.history.count == 1)
        #expect(model.notes == ["Node “Tokyo” was dropped because its share link is invalid."])
        #expect(model.requiresReconnect)
        #expect(model.reloadNotice?.contains("Reconnect") == true)
        #expect(model.statusMessage?.hasPrefix("Applied 1 rule set.") == true)
        #expect(model.isApplying == false)
    }

    @Test func liveOnlyPlanDoesNotAskForAReconnect() {
        let document = ProfileDocumentStub()
        document.outcome = ProfileApplyOutcome(
            summary: "Applied.",
            notes: [],
            plan: ConfigurationReloadPlan(changes: [
                ConfigurationReloadPlan.Change(field: "dns-upstream", scope: .live, summary: "a → b")
            ])
        )
        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()
        model.edit(Self.validDocument)

        model.apply()

        #expect(model.requiresReconnect == false)
        #expect(model.statusMessage?.contains("without a restart") == true)
    }

    // MARK: - Importing and exporting

    @Test func importReplacesTheBufferAndStaysDirty() {
        let document = ProfileDocumentStub()
        document.fileText = .success("[Rule]\nFINAL, PROXY\n")
        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()

        model.importFile(at: Self.fileURL)

        #expect(model.text == "[Rule]\nFINAL, PROXY\n")
        #expect(model.isDirty, "Importing a file enters the buffer; it is not applied.")
        #expect(document.persisted.last == "[Rule]\nFINAL, PROXY\n")
        #expect(model.statusMessage?.contains("profile.conf") == true)
        #expect(model.errorMessage == nil)
    }

    @Test func failedImportKeepsTheBufferIntact() {
        let document = ProfileDocumentStub()
        document.fileText = .failure(ProfileDocumentStub.Failure.unreadable)
        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()
        let before = model.text

        model.importFile(at: Self.fileURL)

        #expect(model.text == before)
        #expect(!model.isDirty)
        #expect(model.errorMessage == "The file could not be read.")
    }

    @Test func reloadFromCurrentSetupLoadsTheExportAndItsNotes() {
        let document = ProfileDocumentStub()
        document.exportResult = ConfigurationExporter.Result(
            text: "[General]\nproxy-mode = tun\n",
            notes: ["Rule set “Ads” was skipped because its rules are not in the profile."],
            counts: .init()
        )
        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()

        model.reloadFromCurrentSetup()

        #expect(model.text == "[General]\nproxy-mode = tun\n")
        #expect(model.notes == ["Rule set “Ads” was skipped because its rules are not in the profile."])
        #expect(model.isDirty, "The export still has to be applied to be written back.")
        #expect(document.persisted.last == "[General]\nproxy-mode = tun\n")
    }

    // MARK: - History and discarding

    @Test func revertToSnapshotPutsItsTextBackInTheBuffer() {
        let document = ProfileDocumentStub()
        let older = Self.snapshot("[Rule]\nFINAL, REJECT\n", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        document.snapshots = [older]
        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()

        model.revert(to: older)

        #expect(model.text == older.text)
        #expect(model.isDirty, "An old document is a change until it is applied again.")
        #expect(document.persisted.last == older.text)
        #expect(model.statusMessage?.contains("Restored") == true)
    }

    @Test func discardChangesRestoresTheAppliedDocument() {
        let document = ProfileDocumentStub()
        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()
        model.edit("[Rule]\nDOMAIN, example.com, DIRECT\n")

        model.discardChanges()

        #expect(model.text == document.draft)
        #expect(!model.isDirty)
        #expect(document.persisted.last == document.draft)
        #expect(model.statusMessage == "Discarded the changes that were not applied.")
    }

    @Test func discardChangesIsANoOpWithoutEdits() {
        let document = ProfileDocumentStub()
        let model = ProfileEditorModel(document: document, previewDelay: .zero)
        model.load()
        document.persisted.removeAll()

        model.discardChanges()

        #expect(document.persisted.isEmpty)
        #expect(model.statusMessage == nil)
    }

    // MARK: - Helpers

    static func snapshot(_ text: String, createdAt: Date = .now) -> ConfigurationSnapshot {
        ConfigurationSnapshot(
            createdAt: createdAt,
            text: text,
            compiled: TextConfigurationPipeline.process(text: text).compiled
        )
    }
}

// MARK: - Stub

/// Stands in for `ConfigurationDocumentOperations`: records what the pipeline was
/// asked to do and returns documents the tests can reason about, without an App
/// Group container, a snapshot history on disk or a tunnel.
@MainActor
private final class ProfileDocumentStub: ProfileEditing {

    enum Failure: LocalizedError {
        case unreadable

        var errorDescription: String? {
            "The file could not be read."
        }
    }

    var draft = """
        [Rule]
        DOMAIN-SUFFIX, example.com, DIRECT
        """
    var previewed: [String] = []
    var persisted: [String] = []
    var applyError: (any Error)?
    var outcome = ProfileApplyOutcome(summary: "Applied.", notes: [], plan: ConfigurationReloadPlan())
    var exportResult = ConfigurationExporter.Result(
        text: "[Rule]\nFINAL, DIRECT\n",
        notes: [],
        counts: .init()
    )
    var fileText: Result<String, any Error> = .success("[Rule]\nFINAL, DIRECT\n")
    var snapshots: [ConfigurationSnapshot] = []
    var appliedAt: Date?

    func loadDraft() -> String {
        draft
    }

    func persistDraft(_ text: String) throws {
        persisted.append(text)
    }

    func previewDocument(_ text: String) -> TextConfigurationPipeline.Result {
        previewed.append(text)
        return TextConfigurationPipeline.process(text: text)
    }

    func applyDocument(_ text: String) throws -> ProfileApplyOutcome {
        if let applyError { throw applyError }
        return outcome
    }

    func exportDocument() -> ConfigurationExporter.Result {
        exportResult
    }

    func readDocument(at url: URL) throws -> String {
        switch fileText {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    func lastAppliedAt() -> Date? {
        appliedAt
    }

    func appliedHistory() -> [ConfigurationSnapshot] {
        snapshots
    }
}

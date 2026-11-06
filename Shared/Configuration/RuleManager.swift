import Foundation

/// Owns the editable NaiveFlow document and its history. Parsing is structural;
/// validation, compilation and engine adaptation belong to the coordinator.
/// There is one backing store, shared with the installer and editor.
nonisolated struct RuleManager: Sendable {
    let activation: ConfigurationActivation

    init(activation: ConfigurationActivation = ConfigurationActivation()) {
        self.activation = activation
    }

    static func parse(_ text: String) -> NaiveFlowConfigurationParser.ParseResult {
        NaiveFlowConfigurationParser.parse(text: text)
    }

    func draft() -> String { activation.draft() }
    func hasDraft() -> Bool { activation.hasDraft() }
    func saveDraft(_ text: String) throws { try activation.saveDraft(text) }
    func discardDraft() { activation.discardDraft() }
    func read(contentsOf url: URL) throws -> String { try ConfigurationImport.read(from: url) }
    func history(limit: Int = 10) -> [ConfigurationSnapshot] { activation.history(limit: limit) }
    func appliedAt() -> Date? { activation.appliedAt() }

    func preview(_ text: String) -> TextConfigurationPipeline.Result {
        ConfigurationCoordinator().compile(text: text)
    }

    /// Freezes an accepted document; the installer remains responsible for
    /// applying it to existing stores and restoring the previous installation.
    func activate(text: String) throws -> ConfigurationActivation.Activation {
        try activation.activate(text: text)
    }

    func rollback() throws -> ConfigurationActivation.Activation {
        try activation.rollback()
    }
}

import Foundation

/// Installation reports are shared with the editor. The only applying adapter
/// is ConfigurationPublisher; there is no separate store-by-store apply path.
@MainActor
enum ConfigurationInstaller {
    struct Outcome: Equatable, Sendable {
        let plan: ConfigurationReloadPlan
        let modulePlan: ConfigurationCoordinator.Plan
        let addedProxies: [String]
        let updatedProxies: [String]
        let removedProxies: [String]
        let addedGroups: [String]
        let removedGroups: [String]
        let ruleSets: [String]
        let removedRuleSets: [String]
        let notes: [String]

        var requiresReconnect: Bool { plan.requiresReconnect }
        var requiresStackRestart: Bool { plan.requiresStackRestart }

        var summary: String {
            var parts: [String] = []
            if !addedProxies.isEmpty { parts.append("+\(addedProxies.count) node(s)") }
            if !updatedProxies.isEmpty { parts.append("~\(updatedProxies.count) node(s)") }
            if !removedProxies.isEmpty { parts.append("-\(removedProxies.count) node(s)") }
            if !ruleSets.isEmpty { parts.append("\(ruleSets.count) rule set(s)") }
            if !removedRuleSets.isEmpty { parts.append("-\(removedRuleSets.count) rule set(s)") }
            let changes = parts.isEmpty ? String(localized: "Configuration applied.") : parts.joined(separator: ", ")
            return "\(changes) · \(modulePlan.summary)"
        }
    }

}

import Foundation

@MainActor
struct ClientSubscriptionReview: Identifiable {
    let id = UUID()
    let original: ClientProfile
    let originalText: String
    var change: ClientResourceManager.Change
    let added: [String]
    let modified: [String]
    let missing: [String]
    let preserved: [String]
    let removable: Set<String>
    let resourceIDs: [String]
}

nonisolated struct ClientResourceDescriptor: Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
    let source: String
}

nonisolated struct ClientResourceActivity: Codable, Sendable {
    var attemptedAt: Date?
    var succeededAt: Date?
    var error: String?
    var version: String?
    var awaitingReview = false
}

nonisolated enum ClientNodeTools {
    static func filtered(_ nodes: [ProxyConfiguration], query: String, protocolName: String,
                         subscriptionNames: Set<String>?, availability: String,
                         results: [UUID: LatencyResult]) -> [ProxyConfiguration] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return nodes.filter { node in
            guard protocolName.isEmpty || node.outboundProtocol.rawValue == protocolName,
                  subscriptionNames?.contains(node.name) ?? true,
                  terms.allSatisfy({ node.name.localizedStandardContains($0) || node.serverAddress.localizedStandardContains($0) }) else { return false }
            switch (availability, results[node.id]) {
            case ("available", .success?): return true
            case ("failed", .failed?), ("failed", .insecure?): return true
            case ("testing", .testing?): return true
            case ("untested", nil): return true
            case ("", _): return true
            default: return false
            }
        }
    }

    /// Validate the entire batch before changing a single line.
    static func removing(_ names: Set<String>, from text: String) throws -> String {
        let parsed = NaiveFlowConfigurationParser.parse(text: text).configuration
        let nodes = TextConfigurationPipeline.process(text: text).compiled.proxies
        guard names.isSubset(of: Set(nodes.map(\.name))) else { throw ClientFailure("The node list changed. Select the nodes again.") }
        if parsed.rules.contains(where: { if case .named(let name) = $0.policy { return names.contains(name) }; return false }) ||
            parsed.chains.contains(where: { !$0.members.allSatisfy { !names.contains($0) } }) ||
            nodes.contains(where: { !names.contains($0.name) && $0.underlyingProxy.map(names.contains) == true }) {
            throw ClientFailure("Some selected nodes are referenced by rules or proxy chains. Update those references first.")
        }
        var result = text
        for group in parsed.proxyGroups where group.members.contains(where: names.contains) {
            let members = group.members.filter { !names.contains($0) }
            guard !members.isEmpty else { throw ClientFailure("\(group.name) requires at least one member.") }
            let parameters = group.parameters.pairs.filter { !($0.0 == "selected" && names.contains($0.1)) }
            result = ClientDocumentEditing.set(result, section: .proxyGroup, key: group.name,
                value: ClientDocumentEditing.groupValue(kind: group.kindToken, members: members, parameters: parameters))
        }
        for name in names { result = ClientDocumentEditing.set(result, section: .proxy, key: name, value: nil) }
        if parsed.general["default-node"].map(names.contains) == true {
            result = ClientDocumentEditing.set(result, section: .general, key: "default-node", value: nil)
        }
        return result
    }
}

nonisolated struct ClientBackup: Codable {
    static let maximumBytes = 64 * 1024 * 1024
    var formatVersion = 1
    var createdAt = Date()
    var library: ClientProfileLibrary

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ClientFailure("The backup exceeds the 64 MiB limit.") }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.formatVersion == 1, backup.library.profiles.count <= 1000,
              Set(backup.library.profiles.map(\.id)).count == backup.library.profiles.count,
              backup.library.profiles.allSatisfy({ $0.text.utf8.count <= ConfigurationImport.maximumBytes }),
              backup.library.selectedID.map({ id in backup.library.profiles.contains { $0.id == id } }) ?? true else {
            throw ClientFailure("Unsupported or invalid backup. No profiles were restored.")
        }
        return backup
    }

    func merging(into current: ClientProfileLibrary, replaceMatches: Bool) -> ClientProfileLibrary {
        var result = current
        for profile in library.profiles {
            if let index = result.profiles.firstIndex(where: { $0.id == profile.id }) {
                if replaceMatches { result.profiles[index] = profile }
            } else { result.profiles.append(profile) }
        }
        if result.selectedID == nil { result.selectedID = library.selectedID ?? result.profiles.first?.id }
        return result
    }
}

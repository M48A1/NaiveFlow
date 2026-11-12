import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Presentation-only group metadata, independent of the app's mutable stores.
nonisolated struct RuntimeGroupDisplay: Codable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let memberCount: Int
    let iconURL: String?
}

/// A complete immutable input to DNS, Rule, MITM and Outbound. Scripts are
/// embedded after fetching; the extension never downloads mutable dependencies.
nonisolated struct RuntimeConfigurationBundle: Codable, Sendable {
    static let schema = 1
    var schemaVersion = RuntimeConfigurationBundle.schema
    let id: UUID
    let snapshotID: UUID?
    let parentID: UUID?
    let preferences: [String: RuntimePreferenceValue]
    let nodes: [ProxyConfiguration]
    let selectedNodeID: UUID
    let rules: [OrderedRoutingRule]?
    let finalAction: RouteMatchAction
    let mitmRuleSets: [MITMRuleSet]
    /// Text-configured groups with their automatic-selection strategy. Defaults
    /// to empty so bundles published before this field existed still decode.
    var policyGroups: [RuntimeProxyGroup] = []
    /// UI metadata for every group, including select groups flattened by the engine.
    var displayGroups: [RuntimeGroupDisplay] = []
    /// Used only by the preserved manual/app configuration baseline.
    let legacyRouting: Data?
    let legacyMITM: Data?
    var geo = NativeGeoDatabase()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, snapshotID, parentID, preferences, nodes, selectedNodeID
        case rules, finalAction, mitmRuleSets, policyGroups, displayGroups, legacyRouting, legacyMITM, geo
    }

    var selectedNode: ProxyConfiguration? { nodes.first { $0.id == selectedNodeID } }

    /// A text version (`snapshotID != nil`) pins every runtime preference so the
    /// kernel reads exactly the published document. The preserved manual/app
    /// baseline (`snapshotID == nil`) does NOT pin: rolling back to it must return
    /// to a live, editable manual mode where later UserDefaults changes — proxy
    /// mode, node switches, Always On, certificates — take effect again.
    var pinsRuntimePreferences: Bool { snapshotID != nil }

    /// The value to hand to `AWCore.installRuntimePreferences(_:)`: the captured
    /// dict for a pinned text version, or `nil` (unpinned) for a manual baseline.
    var runtimePreferencesForInstall: [String: RuntimePreferenceValue]? {
        pinsRuntimePreferences ? preferences : nil
    }

    func validate() throws {
        guard schemaVersion == Self.schema, selectedNode != nil,
              Set(nodes.map(\.id)).count == nodes.count,
              nodes.count <= 10_000, (rules?.count ?? 0) <= 100_000,
              Set(preferences.keys).subtracting(["bootstrapDNS"]) == Set(AWCore.runtimePreferenceKeys).subtracting(["bootstrapDNS"])
        else { throw RuntimeConfigurationFailure.invalidBundle }
        if let value = preferences["bootstrapDNS"], value != .absent {
            guard case .string(let raw) = value, DNSBootstrapPolicy.parse(raw) != nil else {
                throw RuntimeConfigurationFailure.invalidBundle
            }
        }
        for prefix in ["localRequest", "proxy", "subscription", "ech"] {
            if preferences[prefix + "DNSMode"] == .string("plain"),
               case .string(let server) = preferences[prefix + "DNSPlainServer"], DNSUpstream.parsePlain(server) == nil {
                throw RuntimeConfigurationFailure.invalidBundle
            }
            if preferences[prefix + "DNSMode"] == .string("doh"),
               case .string(let url) = preferences[prefix + "DNSDoHURL"], DNSUpstream.parseDoH(url) == nil {
                throw RuntimeConfigurationFailure.invalidBundle
            }
        }
        for node in nodes where !node.isDirect {
            try IPv4Only.requireHost(node.serverAddress)
            if let address = node.resolvedIP { try IPv4Only.requireHost(address) }
            for hop in node.chain ?? [] { try IPv4Only.requireHost(hop.serverAddress) }
        }
        // A `.proxy` action may name a node or a text-configured group; both
        // carry stable ids in the bundle.
        let ids = Set(nodes.map(\.id)).union(policyGroups.map(\.id))
        for rule in rules ?? [] {
            if case .proxy(let id) = rule.action, !ids.contains(id) { throw RuntimeConfigurationFailure.invalidBundle }
            try validateMatcher(rule.matcher, depth: 0)
        }
        try geo.validate()
        for network in geo.networks { try validateMatcher(.ipCIDR(network.prefix), depth: 0) }

        if case .proxy(let id) = finalAction, !ids.contains(id) { throw RuntimeConfigurationFailure.invalidBundle }
        guard Set(mitmRuleSets.map(\.id)).count == mitmRuleSets.count else { throw RuntimeConfigurationFailure.invalidBundle }
        var scopes: Set<String> = []
        for set in mitmRuleSets {
            for suffix in set.domainSuffixes {
                guard let normalized = DNSName.normalizedHost(suffix) else { throw RuntimeConfigurationFailure.invalidBundle }
                if set.enabled, !scopes.insert(normalized).inserted { throw RuntimeConfigurationFailure.rejected("Duplicate MITM suffix scope.") }
            }
            guard set.parameters.count <= MITMRuleSet.maxParameterCount,
                  set.rules.count <= MITMRuleSet.maxRuleCount else { throw RuntimeConfigurationFailure.invalidBundle }
            for rule in set.rules {
                _ = try NSRegularExpression(pattern: rule.urlPattern)
                switch rule.operation {
                case .streamScript:
                    throw RuntimeConfigurationFailure.rejected("Anywhere stream-script is no longer supported. Use a buffered Surge or Quantumult X script.")
                case .script(let encoded, _):
                    guard let data = Data(base64Encoded: encoded), data.count <= 1_000_000,
                          let source = String(data: data, encoding: .utf8) else { throw RuntimeConfigurationFailure.invalidBundle }
                    try RuntimeJavaScript.validate(source)
                default: break
                }
            }
        }
    }
    private func validateMatcher(_ matcher: OrderedRoutingRule.Matcher, depth: Int) throws {
        guard depth <= 16 else { throw RuntimeConfigurationFailure.invalidBundle }
        switch matcher {
        case .allOf(let children), .anyOf(let children):
            guard !children.isEmpty, children.count <= 64 else { throw RuntimeConfigurationFailure.invalidBundle }
            for child in children { try validateMatcher(child, depth: depth + 1) }
        case .negated(let child): try validateMatcher(child, depth: depth + 1)
        case .domainRegex(let pattern): _ = try NSRegularExpression(pattern: pattern)
        case .ipCIDR(let cidr), .sourceIP(let cidr):
            guard cidr.bytes.count == cidr.family.byteCount,
                  (0...32).contains(cidr.prefixLength)
            else { throw RuntimeConfigurationFailure.invalidBundle }
        case .protocolName(let name):
            guard ["TCP", "UDP"].contains(name.uppercased()) else { throw RuntimeConfigurationFailure.invalidBundle }
        case .geoSite(let tag):
            guard geo.contains(tag: tag) else { throw RuntimeConfigurationFailure.invalidBundle }
        case .geoIP(let country):
            guard geo.hasCountry(country) else { throw RuntimeConfigurationFailure.invalidBundle }
        case .geoASN(let asn), .ipASN(let asn):
            guard asn > 0, geo.hasASN(asn) else { throw RuntimeConfigurationFailure.invalidBundle }
        case .domain, .domainSuffix, .domainKeyword, .domainWildcard, .sourcePort, .destinationPort: break
        default: throw RuntimeConfigurationFailure.invalidBundle
        }
    }

}

// Keep the memberwise initializer while decoding fields added to schema 1
// explicitly: synthesized Decodable does not use stored-property defaults.
nonisolated extension RuntimeConfigurationBundle {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(UUID.self, forKey: .id)
        snapshotID = try values.decodeIfPresent(UUID.self, forKey: .snapshotID)
        parentID = try values.decodeIfPresent(UUID.self, forKey: .parentID)
        preferences = try values.decode([String: RuntimePreferenceValue].self, forKey: .preferences)
        nodes = try values.decode([ProxyConfiguration].self, forKey: .nodes)
        selectedNodeID = try values.decode(UUID.self, forKey: .selectedNodeID)
        rules = try values.decodeIfPresent([OrderedRoutingRule].self, forKey: .rules)
        finalAction = try values.decode(RouteMatchAction.self, forKey: .finalAction)
        mitmRuleSets = try values.decode([MITMRuleSet].self, forKey: .mitmRuleSets)
        policyGroups = try values.decodeIfPresent([RuntimeProxyGroup].self, forKey: .policyGroups) ?? []
        displayGroups = try values.decodeIfPresent([RuntimeGroupDisplay].self, forKey: .displayGroups) ?? []
        legacyRouting = try values.decodeIfPresent(Data.self, forKey: .legacyRouting)
        legacyMITM = try values.decodeIfPresent(Data.self, forKey: .legacyMITM)
        geo = try values.decodeIfPresent(NativeGeoDatabase.self, forKey: .geo) ?? NativeGeoDatabase()
    }
}

nonisolated enum RuntimeConfigurationFailure: LocalizedError {
    case invalidBundle, corruptedBundle, busy, superseded, rejected(String), unavailable, reconnectRequired, rollbackFailed
    var errorDescription: String? {
        switch self {
        case .invalidBundle: "The runtime configuration is invalid or unsupported."
        case .corruptedBundle: "The runtime configuration file failed its integrity check."
        case .busy: "Another configuration transaction is in progress."
        case .superseded: "A newer configuration replaced this transaction."
        case .rejected(let detail): "The kernel rejected the configuration: \(detail)"
        case .unavailable: "The running kernel did not confirm the configuration."
        case .reconnectRequired: "The connection-level preferences require reconnecting the tunnel."
        case .rollbackFailed: "Rollback could not restore tunnel settings; the provider was stopped."
        }
    }
}

nonisolated struct RuntimeConfigurationReceipt: Codable, Sendable {
    enum Status: String, Codable, Sendable { case applied, rejected }
    var requestID: UUID? = nil
    let versionID: UUID
    let activeVersionID: UUID?
    let snapshotID: UUID?
    let status: Status
    let message: String?
    var date = Date()
}

/// Immutable content files plus one atomic head file. A lease serializes host
/// transactions across windows/processes. Compare-and-swap prevents a failure
/// from rolling back a version published by someone else.
nonisolated struct RuntimeBundleStore: Sendable {
    struct Head: Codable, Equatable, Sendable {
        var requestID = UUID()
        let current: UUID
        let previous: UUID?
    }
    private struct Envelope: Codable {
        let payload: Data
        let sha256: String
    }
    static let retainedVersionCount = 20
    static let maximumRetainedBytes = 256 * 1024 * 1024
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? EngineConfirmationStore.directory.appendingPathComponent("runtime", isDirectory: true)
    }

    func head() throws -> Head? {
        let url = directory.appendingPathComponent("head.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Head.self, from: Data(contentsOf: url))
    }

    func load(_ id: UUID) throws -> RuntimeConfigurationBundle {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 96 * 1024 * 1024 else { throw RuntimeConfigurationFailure.corruptedBundle }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.payload.count <= 64 * 1024 * 1024, digest(envelope.payload) == envelope.sha256 else { throw RuntimeConfigurationFailure.corruptedBundle }
        let bundle = try JSONDecoder().decode(RuntimeConfigurationBundle.self, from: envelope.payload)
        guard bundle.id == id else { throw RuntimeConfigurationFailure.corruptedBundle }
        try bundle.validate()
        return bundle
    }

    func save(_ bundle: RuntimeConfigurationBundle) throws {
        try bundle.validate()
        try ensureDirectory()
        let data = try JSONEncoder().encode(bundle)
        guard data.count <= 64 * 1024 * 1024 else { throw RuntimeConfigurationFailure.invalidBundle }
        let url = directory.appendingPathComponent("\(bundle.id.uuidString).json")
        // IDs are immutable: never overwrite a version another process may hold.
        guard !FileManager.default.fileExists(atPath: url.path) else { throw RuntimeConfigurationFailure.superseded }
        try JSONEncoder().encode(Envelope(payload: data, sha256: digest(data))).write(to: url, options: .atomic)
    }

    func publish(_ bundle: RuntimeConfigurationBundle, expected: Head?) throws {
        guard try head() == expected, bundle.parentID == expected?.current else { throw RuntimeConfigurationFailure.superseded }
        try save(bundle)
        try writeHead(Head(current: bundle.id, previous: expected?.current))
    }

    @discardableResult
    func rollback(expected id: UUID) throws -> Head? {
        guard let current = try head(), current.current == id else { throw RuntimeConfigurationFailure.superseded }
        guard let previous = current.previous else {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("head.json"))
            return nil
        }
        let bundle = try load(previous)
        let restored = Head(current: previous, previous: availableVersion(bundle.parentID))
        try writeHead(restored)
        return restored
    }

    func restoreHead(_ restored: Head, expected current: UUID) throws {
        guard try head()?.current == current else { throw RuntimeConfigurationFailure.superseded }
        _ = try load(restored.current)
        try writeHead(Head(current: restored.current, previous: availableVersion(restored.previous)))
    }

    func record(_ input: RuntimeConfigurationReceipt) throws {
        try ensureDirectory()
        var receipt = input
        if let head = try head(), head.current == receipt.versionID { receipt.requestID = head.requestID }
        try JSONEncoder().encode(receipt).write(
            to: directory.appendingPathComponent("\(receipt.versionID.uuidString).receipt.json"), options: .atomic
        )
    }

    func receipt(_ id: UUID) throws -> RuntimeConfigurationReceipt? {
        let url = directory.appendingPathComponent("\(id.uuidString).receipt.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RuntimeConfigurationReceipt.self, from: Data(contentsOf: url))
    }

    /// Run only under the publication lease, after a successful commit or
    /// reconciliation. The active version and immediate rollback target are
    /// always retained, even if they alone exceed the requested byte budget.
    @discardableResult
    func prune(maximumVersions: Int = Self.retainedVersionCount,
               maximumBytes: Int = Self.maximumRetainedBytes) throws -> Int {
        guard let head = try head() else { return 0 }
        let protected = Set([head.current, head.previous].compactMap { $0 })
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        struct Version {
            var files: [URL] = []
            var bytes = 0
            var stamp = Date.distantPast
            var hasBundle = false
        }
        var versions: [UUID: Version] = [:]
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".json"),
                  let first = name.split(separator: ".").first,
                  let id = UUID(uuidString: String(first)),
                  ["\(id.uuidString).json", "\(id.uuidString).receipt.json",
                   "\(id.uuidString).manifest-backup.json"].contains(name) else { continue }
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            versions[id, default: Version()].files.append(file)
            versions[id, default: Version()].bytes += values.fileSize ?? 0
            if name == "\(id.uuidString).json" {
                versions[id, default: Version()].hasBundle = true
                versions[id, default: Version()].stamp = values.contentModificationDate ?? .distantPast
            }
        }
        var retained = protected
        var retainedBytes = protected.reduce(0) { $0 + (versions[$1]?.bytes ?? 0) }
        let candidates = versions.keys.filter { !protected.contains($0) && versions[$0]?.hasBundle == true }
            .sorted { lhs, rhs in
                let l = versions[lhs]!.stamp, r = versions[rhs]!.stamp
                return l == r ? lhs.uuidString < rhs.uuidString : l > r
            }
        for id in candidates {
            let bytes = versions[id]!.bytes
            guard retained.count < max(2, maximumVersions),
                  bytes <= max(0, maximumBytes - retainedBytes) else { continue }
            retained.insert(id)
            retainedBytes += bytes
        }
        var removed = 0
        for (id, version) in versions where !retained.contains(id) {
            for file in version.files { try FileManager.default.removeItem(at: file) }
            removed += 1
        }
        return removed
    }

    private func availableVersion(_ id: UUID?) -> UUID? {
        id.flatMap { FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0.uuidString).json").path) ? $0 : nil }
    }

    func lease() throws -> Lease {
        try ensureDirectory()
        let fd = open(directory.appendingPathComponent("publication.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw RuntimeConfigurationFailure.busy }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw RuntimeConfigurationFailure.busy
        }
        return Lease(fd: fd)
    }

    final class Lease: @unchecked Sendable {
        private let fd: Int32
        fileprivate init(fd: Int32) { self.fd = fd }
        deinit { _ = flock(fd, LOCK_UN); close(fd) }
    }

    private func writeHead(_ head: Head) throws {
        try ensureDirectory()
        try JSONEncoder().encode(head).write(to: directory.appendingPathComponent("head.json"), options: .atomic)
    }
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

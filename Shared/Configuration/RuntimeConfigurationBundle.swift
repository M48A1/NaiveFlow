import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
    /// Used only by the preserved manual/app configuration baseline.
    let legacyRouting: Data?
    let legacyMITM: Data?
    var geo = NativeGeoDatabase()

    var selectedNode: ProxyConfiguration? { nodes.first { $0.id == selectedNodeID } }

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
        let ids = Set(nodes.map(\.id))
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
                case .script(let encoded), .streamScript(let encoded):
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
        let restored = Head(current: previous, previous: bundle.parentID)
        try writeHead(restored)
        return restored
    }

    func restoreHead(_ restored: Head, expected current: UUID) throws {
        guard try head()?.current == current else { throw RuntimeConfigurationFailure.superseded }
        _ = try load(restored.current)
        try writeHead(Head(current: restored.current, previous: restored.previous))
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
